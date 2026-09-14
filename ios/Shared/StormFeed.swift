import Foundation
import CoreLocation
import UIKit

/// Where the widget is watching. The app writes this to the shared container so
/// the extension and the app agree without either having to ask the other.
struct WatchLocation: Codable {
    var lat: Double
    var lon: Double
    var name: String
    /// Mirrored out of the dashboard's own settings so the widget draws what the
    /// app is set to draw, rather than keeping a second set of preferences.
    var showReports: Bool = true
    var showTemps: Bool = true
    var showAlerts: Bool = true
    var showTracks: Bool = true
    var showDiscussion: Bool = true
    var showOutlook: Bool = true
    var showFronts: Bool = true
    var stationModel: Bool = false
    var showIsobars: Bool = true
    var zoom: RadarZoom = .county
    /// Two-letter state, resolved by the app. The national station feed is
    /// 3.4 MB; one state's network is about 100 KB, and the API accepts only one.
    var state: String? = nil

    static let appGroup = "group.com.samjalbr.nightwatch"
    static let key = "watchLocation"
    static let fallback = WatchLocation(lat: 42.907058, lon: -85.763014, name: "Grand Rapids",
                                        showReports: true, showTemps: true, showAlerts: true,
                                        showTracks: true, showDiscussion: true,
                                        showOutlook: true, showFronts: true, stationModel: false, showIsobars: true,
                                        zoom: .county, state: "MI")

    static func load() -> WatchLocation {
        guard let d = UserDefaults(suiteName: appGroup)?.data(forKey: key),
              let v = try? JSONDecoder().decode(WatchLocation.self, from: d) else { return fallback }
        return v
    }
    func save() {
        guard let d = try? JSONEncoder().encode(self) else { return }
        UserDefaults(suiteName: Self.appGroup)?.set(d, forKey: Self.key)
    }
}

enum StormFeed {
    static let attributesURL = URL(string: "https://mesonet.agron.iastate.edu/geojson/nexrad_attr.geojson")!
    static let radarService = "https://mapservices.weather.noaa.gov/eventdriven/rest/services/radar/radar_base_reflectivity_time/ImageServer"
    /// IEM's N0Q national composite over WMS. Same NWS product and colour table
    /// as the NOAA service, but current: sampled at 4-5 minutes old while the
    /// NOAA event-driven service was 8-20 minutes behind and, once, moved its
    /// newest slice backwards. This is the primary; NOAA is the fallback.
    static let radarWMS = "https://mesonet.agron.iastate.edu/cgi-bin/wms/nexrad/n0q.cgi"

    private struct FeatureCollection: Decodable {
        struct Feature: Decodable {
            struct Geometry: Decodable { let coordinates: [Double] }
            struct Props: Decodable {
                let drct: Double?
                let sknt: Double?
                let max_dbz: Double?
                let max_size: Double?
                let posh: Double?
                let tvs: String?
                let meso: String?
                let valid: String?
            }
            let geometry: Geometry?
            let properties: Props
        }
        let features: [Feature]
    }

    static func cells() async throws -> [StormCell] {
        var req = URLRequest(url: attributesURL)
        req.timeoutInterval = 20
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, _) = try await URLSession.shared.data(for: req)
        let fc = try JSONDecoder().decode(FeatureCollection.self, from: data)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()

        return fc.features.compactMap { f in
            guard let c = f.geometry?.coordinates, c.count >= 2 else { return nil }
            let p = f.properties
            let observed = p.valid.flatMap { iso.date(from: $0) ?? isoPlain.date(from: $0) } ?? Date()
            return StormCell(
                lat: c[1], lon: c[0],
                drct: p.drct ?? 0, speedKt: p.sknt ?? 0,
                maxDbz: p.max_dbz ?? 0, hailInches: p.max_size ?? 0, posh: p.posh ?? 0,
                tvs: (p.tvs ?? "NONE") != "NONE", meso: (p.meso ?? "NONE") != "NONE",
                observed: observed)
        }
    }

    private static func mercator(_ lon: Double, _ lat: Double) -> (Double, Double) {
        let x = lon * 20037508.34 / 180
        let y = log(tan((90 + lat) * .pi / 360)) / (.pi / 180) * 20037508.34 / 180
        return (x, y)
    }

    /// Radar over an explicit corner box, so it can be registered against a map
    /// snapshot covering the same ground.
    /// The radar image for a box, and the pixel dimensions it was rendered at.
    ///
    /// The image size must carry the bounding box's own aspect ratio. ArcGIS
    /// does not stretch a mismatched request, it *conforms the extent* to the
    /// image's shape, expanding the deficient axis around the centre — asking
    /// for a square image of a wide box came back covering 1.53x the latitude
    /// requested and shifted 96 km south, which was then painted into the rect
    /// for the box that was asked for. That is what put the radar out of
    /// register with the fronts, pressure centres and everything else.
    /// Matching the aspect brings it back to within a few metres.
    static func radarImageURL(sw: CLLocationCoordinate2D, ne: CLLocationCoordinate2D,
                              pixelsWide: Int, sliceMs: Int? = nil) -> (url: URL, width: Int, height: Int)? {
        let (x0, y0) = mercator(sw.longitude, sw.latitude)
        let (x1, y1) = mercator(ne.longitude, ne.latitude)
        let bw = x1 - x0, bh = y1 - y0
        guard bw > 0, bh > 0 else { return nil }
        let w = max(1, pixelsWide)
        let h = max(1, Int((Double(w) * bh / bw).rounded()))
        // Cache-bust per minute; the mosaic updates far more slowly than that.
        let stamp = Int(Date().timeIntervalSince1970 / 60)
        // `time` pins the instant. Without it this time-enabled service renders
        // its WHOLE extent — about two hours of scans mosaicked into one image,
        // so every position a storm has held is painted at once and the weather
        // appears to sit far behind where it really is. That is not latency, and
        // no refresh interval fixes it.
        let slice = sliceMs.map { "&time=\($0)" } ?? ""
        guard let url = URL(string:
            "\(radarService)/exportImage?bbox=\(Int(x0)),\(Int(y0)),\(Int(x1)),\(Int(y1))" +
            "&bboxSR=3857&imageSR=3857&size=\(w),\(h)&format=png32&transparent=true" +
            "&interpolation=RSP_BilinearInterpolation&f=image\(slice)&t=\(stamp)") else { return nil }
        return (url, w, h)
    }

    /// The newest slice the radar service holds, in epoch milliseconds, read
    /// from its own time extent. Returns nil if the service will not say, in
    /// which case the caller falls back to an unpinned request.
    static func radarLatestSliceMs() async -> Int? {
        guard let url = URL(string: "\(radarService)?f=json") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.cachePolicy = .reloadIgnoringLocalCacheData
        struct Doc: Decodable {
            struct TimeInfo: Decodable { let timeExtent: [Double]? }
            let timeInfo: TimeInfo?
        }
        guard let data = try? await URLSession.shared.data(for: req).0,
              let doc = try? JSONDecoder().decode(Doc.self, from: data),
              let extent = doc.timeInfo?.timeExtent, extent.count == 2, extent[1] > 0
        else { return nil }
        return Int(extent[1])
    }

    struct Report {
        let lat: Double
        let lon: Double
        let color: UIColor
    }

    /// Local storm reports in the last few hours, inside the given box. Same
    /// feed and colours the dashboard uses.
    static func recentReports(sw: CLLocationCoordinate2D, ne: CLLocationCoordinate2D) async -> [Report] {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm'Z'"
        f.timeZone = TimeZone(identifier: "UTC")
        let ets = f.string(from: Date()), sts = f.string(from: Date().addingTimeInterval(-6 * 3600))
        guard let url = URL(string: "https://mesonet.agron.iastate.edu/geojson/lsr.geojson?sts=\(sts)&ets=\(ets)")
        else { return [] }
        struct FC: Decodable {
            struct F: Decodable {
                struct G: Decodable { let coordinates: [Double] }
                struct P: Decodable { let typetext: String? }
                let geometry: G?; let properties: P
            }
            let features: [F]
        }
        var req = URLRequest(url: url); req.timeoutInterval = 15; req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let data = try? await URLSession.shared.data(for: req).0,
              let fc = try? JSONDecoder().decode(FC.self, from: data) else { return [] }
        return fc.features.compactMap { f in
            guard let c = f.geometry?.coordinates, c.count >= 2,
                  c[1] >= sw.latitude, c[1] <= ne.latitude,
                  c[0] >= sw.longitude, c[0] <= ne.longitude else { return nil }
            let t = (f.properties.typetext ?? "").uppercased()
            let color: UIColor
            if t.contains("TORNADO") || t.contains("FUNNEL") { color = UIColor(red: 0.88, green: 0.02, blue: 0, alpha: 1) }
            else if t.contains("HAIL") { color = UIColor(red: 0, green: 0.88, blue: 0.82, alpha: 1) }
            else if t.contains("WIND") || t.contains("TSTM") { color = UIColor(red: 0.23, green: 0.63, blue: 1, alpha: 1) }
            else if t.contains("FLOOD") || t.contains("RAIN") { color = UIColor(red: 0.18, green: 0.80, blue: 0.44, alpha: 1) }
            else { color = UIColor(red: 0.72, green: 0.44, blue: 1, alpha: 1) }
            return Report(lat: c[1], lon: c[0], color: color)
        }
    }

    /// A warning or watch polygon, in the dashboard's colours.
    /// Polygon and MultiPolygon differ by one level of nesting.
    struct GeoJSONGeometry: Decodable {
        struct Coords: Decodable {
            var rings: [[[Double]]] = []
            init(from decoder: Decoder) throws {
                let c = try decoder.singleValueContainer()
                if let poly = try? c.decode([[[Double]]].self) { rings = poly }
                else if let multi = try? c.decode([[[[Double]]]].self) { rings = multi.flatMap { $0 } }
            }
        }
        let type: String
        let coordinates: Coords
    }

    struct AlertArea {
        let rings: [[CLLocationCoordinate2D]]
        let color: UIColor
        let isWatch: Bool
    }

    static func alertColor(_ event: String) -> UIColor {
        let e = event.lowercased()
        if e.contains("tornado")      { return UIColor(red: 0.88, green: 0.02, blue: 0, alpha: 1) }
        if e.contains("thunderstorm") { return UIColor(red: 1.00, green: 0.83, blue: 0, alpha: 1) }
        if e.contains("flood")        { return UIColor(red: 0.18, green: 0.80, blue: 0.44, alpha: 1) }
        if e.contains("winter") || e.contains("snow") || e.contains("ice") || e.contains("blizzard") {
            return UIColor(red: 0.44, green: 0.72, blue: 1.00, alpha: 1) }
        if e.contains("heat")         { return UIColor(red: 1.00, green: 0.48, blue: 0, alpha: 1) }
        return UIColor(red: 0.72, green: 0.44, blue: 1.00, alpha: 1)
    }

    /// Geometry for a forecast zone, cached forever in the App Group.
    ///
    /// Most alerts — and *every* watch — carry no polygon of their own, only a
    /// list of zones. Zone boundaries are county and marine borders, so they do
    /// not change; once fetched a zone is good indefinitely and the cache fills
    /// in as alerts come and go.
    static func zoneGeometry(_ zoneURL: String) async -> [[CLLocationCoordinate2D]]? {
        let store = UserDefaults(suiteName: WatchLocation.appGroup)
        let key = "zone." + (zoneURL.split(separator: "/").last.map(String.init) ?? zoneURL)
        if let raw = store?.data(forKey: key),
           let rings = try? JSONDecoder().decode([[[Double]]].self, from: raw) {
            return rings.map { $0.compactMap { p in
                p.count >= 2 ? CLLocationCoordinate2D(latitude: p[0], longitude: p[1]) : nil } }
        }
        guard let url = URL(string: zoneURL) else { return nil }
        struct Z: Decodable { let geometry: GeoJSONGeometry? }
        var req = URLRequest(url: url); req.timeoutInterval = 15
        guard let data = try? await URLSession.shared.data(for: req).0,
              let z = try? JSONDecoder().decode(Z.self, from: data),
              let g = z.geometry else { return nil }
        let rings = g.coordinates.rings
            .map { $0.filter { $0.count >= 2 }.map { [$0[1], $0[0]] } }
            .filter { $0.count >= 3 }
        guard !rings.isEmpty else { return nil }
        if let enc = try? JSONEncoder().encode(rings) { store?.set(enc, forKey: key) }
        return rings.map { $0.map { CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) } }
    }

    /// Active warnings, watches and advisories overlapping the box.
    ///
    /// Restricted to the states in view, which drops ~96% of the national feed.
    /// Alerts without their own polygon are resolved through their zones — the
    /// dashboard does the same, and without it no watch is ever drawn, since
    /// watches are issued by zone and never carry geometry.
    static func alerts(states: [String], sw: CLLocationCoordinate2D, ne: CLLocationCoordinate2D) async -> [AlertArea] {
        // No message_type filter. Restricting to "alert" drops every alert that
        // has since been updated, and an update is not a different kind of
        // thing — it is the same alert, revised. Nationally that filter hid 90
        // of 197 active alerts, including every Lake Michigan gale watch and
        // eight flash flood warnings. The active endpoint already returns only
        // what is in force.
        var str = "https://api.weather.gov/alerts/active?status=actual"
        if !states.isEmpty { str += "&area=" + states.joined(separator: ",") }
        guard let url = URL(string: str) else { return [] }
        struct FC: Decodable {
            struct F: Decodable {
                struct P: Decodable { let event: String?; let affectedZones: [String]? }
                let geometry: GeoJSONGeometry?
                let properties: P
            }
            let features: [F]
        }
        var req = URLRequest(url: url); req.timeoutInterval = 20; req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let data = try? await URLSession.shared.data(for: req).0,
              let fc = try? JSONDecoder().decode(FC.self, from: data) else { return [] }

        // Gather the zones that still need fetching, so the cap applies to real
        // network work rather than to cache hits.
        // Most severe first, so if the cap bites it drops advisories rather than
        // warnings — with the update filter gone there are roughly twice as many
        // alerts to resolve.
        func rank(_ event: String) -> Int {
            let e = event.lowercased()
            if e.contains("warning") { return 0 }
            if e.contains("watch") { return 1 }
            return 2
        }
        var needed: [String] = []
        let resolvable = fc.features
            .filter { $0.geometry == nil }
            .filter { f in
                let e = (f.properties.event ?? "").lowercased()
                return e.contains("warning") || e.contains("watch")
            }
            .sorted { rank($0.properties.event ?? "") < rank($1.properties.event ?? "") }
        for f in resolvable {
            for z in f.properties.affectedZones ?? [] where !needed.contains(z) { needed.append(z) }
        }
        // A single watch can span forty counties; bound the work per refresh and
        // let the permanent cache close the gap over subsequent ones. One Lake
        // Michigan gale watch alone carries sixteen zones.
        var zones: [String: [[CLLocationCoordinate2D]]] = [:]
        await withTaskGroup(of: (String, [[CLLocationCoordinate2D]]?).self) { group in
            for z in needed.prefix(60) {
                group.addTask { (z, await zoneGeometry(z)) }
            }
            for await (z, rings) in group { if let rings { zones[z] = rings } }
        }

        return fc.features.compactMap { f -> AlertArea? in
            let event = f.properties.event ?? ""
            var rings: [[CLLocationCoordinate2D]] = []
            if let g = f.geometry {
                rings = g.coordinates.rings.map { ring in
                    ring.compactMap { p in
                        p.count >= 2 ? CLLocationCoordinate2D(latitude: p[1], longitude: p[0]) : nil }
                }.filter { $0.count >= 3 }
            } else {
                for z in f.properties.affectedZones ?? [] {
                    if let r = zones[z] { rings.append(contentsOf: r) }
                }
            }
            rings = rings.filter { boxOverlaps($0, sw: sw, ne: ne) }
            guard !rings.isEmpty else { return nil }
            return AlertArea(rings: rings, color: alertColor(event),
                             isWatch: event.lowercased().contains("watch"))
        }
    }

    /// Bounding-box overlap rather than a vertex-in-box test, so a zone larger
    /// than the view still counts as visible.
    static func boxOverlaps(_ ring: [CLLocationCoordinate2D],
                                 sw: CLLocationCoordinate2D, ne: CLLocationCoordinate2D) -> Bool {
        guard let first = ring.first else { return false }
        var minLat = first.latitude, maxLat = first.latitude
        var minLon = first.longitude, maxLon = first.longitude
        for c in ring {
            minLat = min(minLat, c.latitude);  maxLat = max(maxLat, c.latitude)
            minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
        }
        return maxLat >= sw.latitude && minLat <= ne.latitude
            && maxLon >= sw.longitude && minLon <= ne.longitude
    }

    // MARK: - Forecast discussion areas

    /// One hazard area decoded from a forecast discussion, as the dashboard
    /// draws it: the forecaster's own words turned into a polygon with a time
    /// window.
    struct AfdArea {
        let ring: [CLLocationCoordinate2D]
        let label: String
        let when: String        // the window, already formatted the way the dashboard writes it
        let color: UIColor
        let live: Bool          // inside its window now, rather than still ahead
        let rank: Int           // higher is more serious; drawn last so it sits on top
    }

    /// The time window as the dashboard's afdWhen() writes it: "NOW - TUE 8PM"
    /// once the window is open, "MON 8PM - WED 2AM" while it is still ahead.
    /// The weekday is dropped for today, since today is the common case and the
    /// label has little room.
    private static let afdHourFmt: DateFormatter = {
        let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("j"); return f
    }()
    private static let afdDayFmt: DateFormatter = {
        let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("E"); return f
    }()
    private static func afdWhen(start: Date, end: Date, live: Bool, now: Date) -> String {
        func hh(_ d: Date) -> String {
            afdHourFmt.string(from: d).replacingOccurrences(of: " ", with: "").uppercased()
        }
        func day(_ d: Date) -> String {
            Calendar.current.isDate(d, inSameDayAs: now) ? "" : afdDayFmt.string(from: d).uppercased() + " "
        }
        return live ? "NOW \u{2013} \(day(end))\(hh(end))"
                    : "\(day(start))\(hh(start)) \u{2013} \(day(end))\(hh(end))"
    }

    /// Colours and seriousness ranking, matching the dashboard's AFD_HAZARD table.
    private static let afdHazards: [String: (UIColor, Int)] = [
        "tornado":        (UIColor(red: 0.88, green: 0.02, blue: 0.00, alpha: 1), 6),
        "damaging wind":  (UIColor(red: 1.00, green: 0.48, blue: 0.00, alpha: 1), 5),
        "hail":           (UIColor(red: 0.23, green: 0.63, blue: 1.00, alpha: 1), 5),
        "severe storms":  (UIColor(red: 0.95, green: 0.72, blue: 0.02, alpha: 1), 4),
        "flash flooding": (UIColor(red: 0.18, green: 0.80, blue: 0.44, alpha: 1), 4),
        "heavy rain":     (UIColor(red: 0.00, green: 0.66, blue: 0.80, alpha: 1), 3),
        "heavy snow":     (UIColor(red: 0.81, green: 0.91, blue: 1.00, alpha: 1), 3),
        "ice":            (UIColor(red: 0.69, green: 0.31, blue: 1.00, alpha: 1), 3),
        "frost":          (UIColor(red: 0.66, green: 0.78, blue: 0.91, alpha: 1), 1),
        "extreme cold":   (UIColor(red: 0.56, green: 0.83, blue: 1.00, alpha: 1), 2),
        "heat":           (UIColor(red: 1.00, green: 0.23, blue: 0.96, alpha: 1), 2),
        "high wind":      (UIColor(red: 1.00, green: 0.48, blue: 0.00, alpha: 1), 2),
        "fire weather":   (UIColor(red: 1.00, green: 0.48, blue: 0.00, alpha: 1), 2),
        "dense fog":      (UIColor(red: 0.54, green: 0.58, blue: 0.65, alpha: 1), 1),
        "marine":         (UIColor(red: 0.29, green: 0.44, blue: 0.65, alpha: 1), 1),
    ]

    /// Hazard areas decoded from the current forecast discussions.
    ///
    /// Served as a static file from the same GitHub Pages site as the dashboard,
    /// rebuilt twice a day by the extraction workflow. Areas whose window has
    /// passed are dropped, so a build that stops updating fades to nothing
    /// rather than showing yesterday's hazards as current.
    static func afdAreas(sw: CLLocationCoordinate2D, ne: CLLocationCoordinate2D) async -> [AfdArea] {
        guard let url = URL(string: "https://samjalbr-cmd.github.io/Super-Radar/data/afd-areas.json")
        else { return [] }
        struct Doc: Decodable {
            struct Office: Decodable {
                struct Area: Decodable {
                    let hazard: String?; let label: String?
                    let start: String?;  let end: String?
                    let polygon: [[Double]]?
                }
                let areas: [Area]?
            }
            let offices: [String: Office]?
        }
        var req = URLRequest(url: url); req.timeoutInterval = 20; req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let data = try? await URLSession.shared.data(for: req).0,
              let doc = try? JSONDecoder().decode(Doc.self, from: data),
              let offices = doc.offices else { return [] }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        func parse(_ t: String?) -> Date? {
            guard let t else { return nil }
            return iso.date(from: t) ?? plain.date(from: t)
        }

        let now = Date()
        var out: [AfdArea] = []
        for (_, office) in offices {
            for a in office.areas ?? [] {
                guard let pts = a.polygon, pts.count >= 3,
                      let t0 = parse(a.start), let t1 = parse(a.end),
                      now <= t1 else { continue }
                let ring = pts.compactMap { p in
                    p.count >= 2 ? CLLocationCoordinate2D(latitude: p[0], longitude: p[1]) : nil
                }
                guard ring.count >= 3, boxOverlaps(ring, sw: sw, ne: ne) else { continue }
                let (color, rank) = afdHazards[(a.hazard ?? "").lowercased()]
                    ?? (UIColor(red: 0.54, green: 0.58, blue: 0.65, alpha: 1), 1)
                let live = now >= t0
                out.append(AfdArea(ring: ring, label: a.label ?? a.hazard ?? "",
                                   when: afdWhen(start: t0, end: t1, live: live, now: now),
                                   color: color, live: live, rank: rank))
            }
        }
        // Least serious first, so the worst hazard ends up on top; live over ahead.
        return out.sorted { ($0.live ? 1 : 0, $0.rank) < ($1.live ? 1 : 0, $1.rank) }
    }

    /// A surface observation, carrying enough for the full station model.
    ///
    /// Coverage across a national sample: temperature, dew point, wind and sky
    /// cover are on ~96% of ASOS sites, sea-level pressure on 40%, present
    /// weather on 9% (it is only reported when there is weather to report).
    /// Pressure tendency is not in this feed at all, so the trend arm of the
    /// classic plot is the one element that cannot be drawn.
    struct Station {
        let lat: Double
        let lon: Double
        let tempF: Double
        var dewF: Double? = nil
        var mslp: Double? = nil
        var windKt: Double? = nil
        var windDir: Double? = nil
        var sky: String? = nil      // CLR, FEW, SCT, BKN, OVC, VV
        var wx: String? = nil       // METAR present-weather codes
    }

    /// The ground each state's ASOS network covers, derived once from the
    /// station positions themselves so a state is only fetched when it can
    /// actually contribute a reading. State borders do not move, so this is a
    /// table rather than a lookup: resolving the states in view used to cost
    /// nine /points requests, and at the widest zoom that sample missed five of
    /// the eleven states on screen — it only probes the centre, corners and
    /// edges, so whole interior states fell through it.
    ///
    /// (DC has no ASOS network of its own; its stations sit in the VA and MD
    /// networks, which the box picks up anyway.)
    static let stateBounds: [String: (Double, Double, Double, Double)] = [
        "AK": (52.22, -174.21, 71.28, 174.12),
        "AL": (30.29, -88.25, 34.86, -85.13),
        "AR": (33.22, -94.49, 36.40, -89.83),
        "AZ": (31.42, -114.61, 36.96, -109.06),
        "CA": (32.56, -124.24, 41.78, -114.62),
        "CO": (37.15, -108.76, 40.75, -102.24),
        "CT": (41.16, -73.48, 41.94, -72.05),
        "DE": (38.69, -75.60, 39.67, -75.36),
        "FL": (24.56, -87.32, 30.84, -80.08),
        "GA": (30.78, -85.29, 34.85, -81.15),
        "HI": (19.72, -177.38, 28.21, -155.05),
        "IA": (40.63, -96.38, 43.40, -90.33),
        "ID": (42.25, -117.02, 48.73, -111.10),
        "IL": (37.06, -91.19, 42.43, -87.53),
        "IN": (38.04, -87.52, 41.72, -84.84),
        "KS": (37.00, -101.88, 39.90, -94.73),
        "KY": (36.61, -88.77, 39.04, -82.57),
        "LA": (26.93, -93.82, 32.76, -87.78),
        "MA": (41.25, -73.29, 42.72, -69.99),
        "MD": (38.15, -79.34, 39.71, -75.12),
        "ME": (43.39, -70.95, 47.29, -67.79),
        "MI": (41.74, -90.13, 47.47, -82.53),
        "MN": (43.62, -96.94, 49.32, -90.35),
        "MO": (36.23, -94.92, 40.35, -89.56),
        "MS": (30.37, -91.30, 34.98, -88.17),
        "MT": (44.69, -114.91, 48.81, -104.19),
        "NC": (33.93, -83.86, 36.46, -75.62),
        "ND": (46.01, -103.98, 48.94, -96.61),
        "NE": (40.08, -104.00, 42.86, -95.59),
        "NH": (42.78, -72.30, 44.58, -70.82),
        "NJ": (39.01, -75.08, 41.01, -74.06),
        "NM": (31.88, -108.93, 36.80, -103.08),
        "NV": (35.95, -119.88, 41.95, -114.85),
        "NY": (40.64, -79.27, 44.93, -71.92),
        "OH": (38.84, -84.78, 41.78, -80.67),
        "OK": (33.91, -101.51, 36.91, -94.62),
        "OR": (42.07, -124.42, 46.16, -117.01),
        "PA": (39.73, -80.41, 42.08, -75.01),
        "RI": (41.17, -71.80, 41.92, -71.41),
        "SC": (32.22, -82.89, 34.99, -78.72),
        "SD": (42.77, -103.78, 45.82, -96.57),
        "TN": (35.04, -90.05, 36.62, -82.17),
        "TX": (25.91, -106.38, 36.22, -92.03),
        "UT": (37.01, -114.03, 41.79, -109.34),
        "VA": (36.57, -83.22, 39.14, -75.46),
        "VT": (42.89, -73.25, 44.94, -72.02),
        "WA": (45.62, -124.56, 48.79, -117.11),
        "WI": (42.59, -92.69, 46.79, -86.92),
        "WV": (37.30, -82.56, 40.17, -77.98),
        "WY": (41.04, -111.04, 44.91, -104.13),
    ]

    /// Marine forecast areas — the Great Lakes and the coastal and offshore
    /// waters — with the ground each covers.
    ///
    /// Water is not in any state, so a marine warning is invisible to a query
    /// scoped by state codes: a Gale Watch over Lake Michigan carries LMZ zones
    /// and belongs to area LM, and asking for MI,IN,OH,WI,IL returns none of it.
    /// Bounds are sampled from the zone geometries and padded, since including
    /// an extra code costs nothing — the alert query is one request either way.
    static let marineBounds: [String: (Double, Double, Double, Double)] = [
        "AM": (10.27, -80.94, 36.18, -55.00),
        "AN": (31.00, -80.31, 43.91, -65.75),
        "GM": (18.38, -96.88, 30.43, -80.55),
        "LC": (42.01, -83.21, 43.00, -82.41),
        "LE": (41.38, -83.47, 42.91, -78.85),
        "LH": (43.00, -84.85, 46.05, -82.12),
        "LM": (41.61, -87.87, 46.10, -84.85),
        "LO": (43.08, -79.20, 44.20, -76.05),
        "LS": (46.41, -92.29, 48.31, -84.87),
        "PH": (14.91, -164.24, 26.23, -150.81),
        "PK": (52.34, -180.00, 71.10, -132.34),
        "PM": (-3.44, -119.47, 28.66, 167.33),
        "PS": (-15.21, -171.75, -10.38, -167.49),
        "PZ": (32.43, -129.25, 48.10, -117.33),
        "SL": (44.18, -76.27, 45.00, -74.87),
    ]

    /// The marine areas a view touches, padded so an alert at the edge of a
    /// sampled boundary is not missed.
    static func marineCovering(sw: CLLocationCoordinate2D, ne: CLLocationCoordinate2D) -> [String] {
        let pad = 2.0
        return marineBounds.filter { _, b in
            b.2 + pad >= sw.latitude && b.0 - pad <= ne.latitude &&
            b.3 + pad >= sw.longitude && b.1 - pad <= ne.longitude
        }.keys.sorted()
    }

    /// Every state whose stations could fall inside the view.
    static func statesCovering(sw: CLLocationCoordinate2D, ne: CLLocationCoordinate2D,
                               fallback: String?) -> [String] {
        var hits = stateBounds.filter { _, b in
            b.2 >= sw.latitude && b.0 <= ne.latitude &&
            b.3 >= sw.longitude && b.1 <= ne.longitude
        }.keys.map { $0 }
        if hits.isEmpty, let f = fallback { hits = [f.uppercased()] }
        // Ordered by how much of the view each covers, so if the cap bites it
        // drops the states contributing least.
        return hits.sorted { a, b in
            overlapArea(stateBounds[a]!, sw: sw, ne: ne) > overlapArea(stateBounds[b]!, sw: sw, ne: ne)
        }
    }

    private static func overlapArea(_ b: (Double, Double, Double, Double),
                                    sw: CLLocationCoordinate2D, ne: CLLocationCoordinate2D) -> Double {
        let dLat = min(b.2, ne.latitude) - max(b.0, sw.latitude)
        let dLon = min(b.3, ne.longitude) - max(b.1, sw.longitude)
        return max(0, dLat) * max(0, dLon)
    }

    /// Current temperatures across the states a view covers. The API takes one
    /// network per request — comma-joined and repeated values return one state or
    /// none, tested — so the states are fetched concurrently and merged. Five
    /// states is about 410 KB against 3.4 MB for the national feed.
    static func stations(states: [String], sw: CLLocationCoordinate2D, ne: CLLocationCoordinate2D) async -> [Station] {
        struct FC: Decodable {
            struct F: Decodable {
                struct G: Decodable { let coordinates: [Double] }
                struct P: Decodable {
                    let tmpf: Double?; let dwpf: Double?; let mslp: Double?
                    let sknt: Double?; let drct: Double?
                    let skyc1: String?; let wxcodes: WxCodes?
                }
                let geometry: G?; let properties: P
            }
            let features: [F]
        }
        // wxcodes comes back as a list of METAR groups on some sites and a
        // single string on others.
        struct WxCodes: Decodable {
            let joined: String?
            init(from decoder: Decoder) throws {
                let c = try decoder.singleValueContainer()
                if let s = try? c.decode(String.self) { joined = s }
                else if let a = try? c.decode([String].self) { joined = a.joined(separator: " ") }
                else { joined = nil }
            }
        }
        return await withTaskGroup(of: [Station].self) { group in
            for st in states where st.count == 2 {
                group.addTask {
                    guard let url = URL(string: "https://mesonet.agron.iastate.edu/api/1/currents.geojson?network=\(st)_ASOS&minutes=120")
                    else { return [] }
                    var req = URLRequest(url: url); req.timeoutInterval = 20; req.cachePolicy = .reloadIgnoringLocalCacheData
                    guard let data = try? await URLSession.shared.data(for: req).0,
                          let fc = try? JSONDecoder().decode(FC.self, from: data) else { return [] }
                    return fc.features.compactMap { f -> Station? in
                        let p = f.properties
                        guard let c = f.geometry?.coordinates, c.count >= 2, let t = p.tmpf,
                              c[1] >= sw.latitude, c[1] <= ne.latitude,
                              c[0] >= sw.longitude, c[0] <= ne.longitude else { return nil }
                        let sky = p.skyc1?.trimmingCharacters(in: .whitespaces)
                        let wx = p.wxcodes?.joined?.trimmingCharacters(in: .whitespaces)
                        return Station(lat: c[1], lon: c[0], tempF: t,
                                       dewF: p.dwpf, mslp: p.mslp,
                                       windKt: p.sknt, windDir: p.drct,
                                       sky: (sky?.isEmpty ?? true) ? nil : sky,
                                       wx: (wx?.isEmpty ?? true) ? nil : wx)
                    }
                }
            }
            var all: [Station] = []
            for await part in group { all.append(contentsOf: part) }
            return all
        }
    }

    /// Resolves the two-letter state for a point, so the station fetch can be
    /// one state instead of the nation.
    static func resolveState(lat: Double, lon: Double) async -> String? {
        // The API caps coordinate precision and answers anything finer with a 301
        // carrying a JSON error body, not a usable point. Four decimals is its limit.
        let pt = String(format: "%.4f,%.4f", lat, lon)
        guard let url = URL(string: "https://api.weather.gov/points/\(pt)") else { return nil }
        struct P: Decodable {
            struct Props: Decodable {
                struct Loc: Decodable { struct L: Decodable { let state: String? }; let properties: L? }
                let relativeLocation: Loc?
            }
            let properties: Props
        }
        var req = URLRequest(url: url); req.timeoutInterval = 15
        guard let data = try? await URLSession.shared.data(for: req).0,
              let p = try? JSONDecoder().decode(P.self, from: data) else { return nil }
        return p.properties.relativeLocation?.properties?.state
    }

    /// A radar render, and whether it actually contains any echo.
    ///
    /// The service answers a clear sky with a fully transparent PNG, which on a
    /// widget is indistinguishable from a failed fetch — both are an empty
    /// rectangle. An empty render compresses to a fraction of the size of one
    /// carrying weather (hundreds of bytes against tens of kilobytes), so size
    /// is a cheap and reliable stand-in for decoding and scanning the pixels.
    struct RadarRender {
        let data: Data
        let hasEcho: Bool
    }

    static func radarImage(sw: CLLocationCoordinate2D, ne: CLLocationCoordinate2D, pixelsWide: Int) async -> RadarRender? {
        // IEM first, since it is the current one. Only if it fails does the
        // slower NOAA service get asked, and that one must be pinned to an
        // instant or it renders its whole two-hour extent at once.
        if let r = radarWMSURL(sw: sw, ne: ne, pixelsWide: pixelsWide),
           let render = await fetchRadar(r) {
            return render
        }
        let sliceMs = await radarLatestSliceMs()
        guard let r = radarImageURL(sw: sw, ne: ne, pixelsWide: pixelsWide, sliceMs: sliceMs)
        else { return nil }
        return await fetchRadar(r)
    }

    private static func fetchRadar(_ r: (url: URL, width: Int, height: Int)) async -> RadarRender? {
        var req = URLRequest(url: r.url)
        req.timeoutInterval = 20
        req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              !data.isEmpty,
              // A WMS error comes back as XML with a 200, so check it is a PNG.
              data.starts(with: [0x89, 0x50, 0x4E, 0x47]) else { return nil }
        // Scaled by size: a blank 800px render is bigger than a blank 400px one.
        let blankCeiling = 12 * max(r.width, r.height)
        return RadarRender(data: data, hasEcho: data.count > blankCeiling)
    }

    /// The same box off IEM's WMS. Web Mercator metres in, one PNG out — no time
    /// parameter needed, because this endpoint serves the newest composite only.
    static func radarWMSURL(sw: CLLocationCoordinate2D, ne: CLLocationCoordinate2D,
                            pixelsWide: Int) -> (url: URL, width: Int, height: Int)? {
        let (x0, y0) = mercator(sw.longitude, sw.latitude)
        let (x1, y1) = mercator(ne.longitude, ne.latitude)
        let bw = x1 - x0, bh = y1 - y0
        guard bw > 0, bh > 0 else { return nil }
        let w = max(1, pixelsWide)
        let h = max(1, Int((Double(w) * bh / bw).rounded()))
        let stamp = Int(Date().timeIntervalSince1970 / 60)
        guard let url = URL(string:
            "\(radarWMS)?SERVICE=WMS&VERSION=1.1.1&REQUEST=GetMap&LAYERS=nexrad-n0q&STYLES=" +
            "&SRS=EPSG:3857&BBOX=\(Int(x0)),\(Int(y0)),\(Int(x1)),\(Int(y1))" +
            "&WIDTH=\(w)&HEIGHT=\(h)&FORMAT=image/png&TRANSPARENT=TRUE&t=\(stamp)")
        else { return nil }
        return (url, w, h)
    }
}
