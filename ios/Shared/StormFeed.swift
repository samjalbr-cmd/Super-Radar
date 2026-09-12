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
    var zoom: RadarZoom = .county
    /// Two-letter state, resolved by the app. The national station feed is
    /// 3.4 MB; one state's network is about 100 KB, and the API accepts only one.
    var state: String? = nil

    static let appGroup = "group.com.samjalbr.nightwatch"
    static let key = "watchLocation"
    static let fallback = WatchLocation(lat: 42.907058, lon: -85.763014, name: "Grand Rapids",
                                        showReports: true, showTemps: true, showAlerts: true,
                                        showTracks: true, showDiscussion: true,
                                        showOutlook: true, showFronts: true,
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
                              pixelsWide: Int) -> (url: URL, width: Int, height: Int)? {
        let (x0, y0) = mercator(sw.longitude, sw.latitude)
        let (x1, y1) = mercator(ne.longitude, ne.latitude)
        let bw = x1 - x0, bh = y1 - y0
        guard bw > 0, bh > 0 else { return nil }
        let w = max(1, pixelsWide)
        let h = max(1, Int((Double(w) * bh / bw).rounded()))
        // Cache-bust per minute; the mosaic updates far more slowly than that.
        let stamp = Int(Date().timeIntervalSince1970 / 60)
        guard let url = URL(string:
            "\(radarService)/exportImage?bbox=\(Int(x0)),\(Int(y0)),\(Int(x1)),\(Int(y1))" +
            "&bboxSR=3857&imageSR=3857&size=\(w),\(h)&format=png32&transparent=true" +
            "&interpolation=RSP_BilinearInterpolation&f=image&t=\(stamp)") else { return nil }
        return (url, w, h)
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
        var req = URLRequest(url: url); req.timeoutInterval = 15
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
        var str = "https://api.weather.gov/alerts/active?status=actual&message_type=alert"
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
        var req = URLRequest(url: url); req.timeoutInterval = 20
        guard let data = try? await URLSession.shared.data(for: req).0,
              let fc = try? JSONDecoder().decode(FC.self, from: data) else { return [] }

        // Gather the zones that still need fetching, so the cap applies to real
        // network work rather than to cache hits.
        var needed: [String] = []
        for f in fc.features where f.geometry == nil {
            let e = (f.properties.event ?? "").lowercased()
            guard e.contains("warning") || e.contains("watch") else { continue }
            for z in f.properties.affectedZones ?? [] where !needed.contains(z) { needed.append(z) }
        }
        // A single watch can span forty counties; bound the work per refresh and
        // let the permanent cache close the gap over subsequent ones.
        var zones: [String: [[CLLocationCoordinate2D]]] = [:]
        await withTaskGroup(of: (String, [[CLLocationCoordinate2D]]?).self) { group in
            for z in needed.prefix(40) {
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
        let color: UIColor
        let live: Bool          // inside its window now, rather than still ahead
        let rank: Int           // higher is more serious; drawn last so it sits on top
    }

    /// Colours and seriousness ranking, matching the dashboard's AFD_HAZARD table.
    private static let afdHazards: [String: (UIColor, Int)] = [
        "tornado":        (UIColor(red: 0.88, green: 0.02, blue: 0.00, alpha: 1), 6),
        "damaging wind":  (UIColor(red: 1.00, green: 0.48, blue: 0.00, alpha: 1), 5),
        "hail":           (UIColor(red: 0.23, green: 0.63, blue: 1.00, alpha: 1), 5),
        "severe storms":  (UIColor(red: 0.95, green: 0.72, blue: 0.02, alpha: 1), 4),
        "flash flooding": (UIColor(red: 0.18, green: 0.80, blue: 0.44, alpha: 1), 4),
        "heavy snow":     (UIColor(red: 0.81, green: 0.91, blue: 1.00, alpha: 1), 3),
        "ice":            (UIColor(red: 0.69, green: 0.31, blue: 1.00, alpha: 1), 3),
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
        var req = URLRequest(url: url); req.timeoutInterval = 20
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
                out.append(AfdArea(ring: ring, label: a.label ?? a.hazard ?? "",
                                   color: color, live: now >= t0, rank: rank))
            }
        }
        // Least serious first, so the worst hazard ends up on top; live over ahead.
        return out.sorted { ($0.live ? 1 : 0, $0.rank) < ($1.live ? 1 : 0, $1.rank) }
    }

    struct Station {
        let lat: Double
        let lon: Double
        let tempF: Double
    }

    /// Every state the view touches, so temperatures cover the radar rather than
    /// stopping at the home state's border. Sampled at the centre, corners and
    /// edge midpoints — the same trick the dashboard uses to find which forecast
    /// offices a view spans. Cached, since the answer only changes when the view
    /// does.
    static func statesCovering(sw: CLLocationCoordinate2D, ne: CLLocationCoordinate2D,
                               fallback: String?) async -> [String] {
        let key = String(format: "states.%.1f.%.1f.%.1f.%.1f",
                         sw.latitude, sw.longitude, ne.latitude, ne.longitude)
        let store = UserDefaults(suiteName: WatchLocation.appGroup)
        if let cached = store?.stringArray(forKey: key), !cached.isEmpty { return cached }

        let midLat = (sw.latitude + ne.latitude) / 2, midLon = (sw.longitude + ne.longitude) / 2
        let pts = [(midLat, midLon), (ne.latitude, sw.longitude), (ne.latitude, ne.longitude),
                   (sw.latitude, sw.longitude), (sw.latitude, ne.longitude),
                   (midLat, sw.longitude), (midLat, ne.longitude),
                   (ne.latitude, midLon), (sw.latitude, midLon)]

        var found = Set<String>()
        await withTaskGroup(of: String?.self) { group in
            for (la, lo) in pts {
                group.addTask { await resolveState(lat: la, lon: lo) }
            }
            for await st in group { if let st { found.insert(st.uppercased()) } }
        }
        if found.isEmpty, let f = fallback { found.insert(f.uppercased()) }
        // Bounded so a continental view cannot fan out into dozens of fetches.
        let list = Array(found).sorted().prefix(6).map { $0 }
        if !list.isEmpty { store?.set(list, forKey: key) }
        return list
    }

    /// Current temperatures across the states a view covers. The API takes one
    /// network per request — comma-joined and repeated values return one state or
    /// none, tested — so the states are fetched concurrently and merged. Five
    /// states is about 410 KB against 3.4 MB for the national feed.
    static func stations(states: [String], sw: CLLocationCoordinate2D, ne: CLLocationCoordinate2D) async -> [Station] {
        struct FC: Decodable {
            struct F: Decodable {
                struct G: Decodable { let coordinates: [Double] }
                struct P: Decodable { let tmpf: Double? }
                let geometry: G?; let properties: P
            }
            let features: [F]
        }
        return await withTaskGroup(of: [Station].self) { group in
            for st in states where st.count == 2 {
                group.addTask {
                    guard let url = URL(string: "https://mesonet.agron.iastate.edu/api/1/currents.geojson?network=\(st)_ASOS&minutes=120")
                    else { return [] }
                    var req = URLRequest(url: url); req.timeoutInterval = 20
                    guard let data = try? await URLSession.shared.data(for: req).0,
                          let fc = try? JSONDecoder().decode(FC.self, from: data) else { return [] }
                    return fc.features.compactMap { f in
                        guard let c = f.geometry?.coordinates, c.count >= 2, let t = f.properties.tmpf,
                              c[1] >= sw.latitude, c[1] <= ne.latitude,
                              c[0] >= sw.longitude, c[0] <= ne.longitude else { return nil }
                        return Station(lat: c[1], lon: c[0], tempF: t)
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
        guard let r = radarImageURL(sw: sw, ne: ne, pixelsWide: pixelsWide) else { return nil }
        var req = URLRequest(url: r.url)
        req.timeoutInterval = 20
        guard let data = try? await URLSession.shared.data(for: req).0, !data.isEmpty else { return nil }
        // Scaled by size: a blank 800px render is bigger than a blank 400px one.
        let blankCeiling = 12 * max(r.width, r.height)
        return RadarRender(data: data, hasEcho: data.count > blankCeiling)
    }
}
