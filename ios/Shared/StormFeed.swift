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
    var zoom: RadarZoom = .county
    /// Two-letter state, resolved by the app. The national station feed is
    /// 3.4 MB; one state's network is about 100 KB, and the API accepts only one.
    var state: String? = nil

    static let appGroup = "group.com.samjalbr.nightwatch"
    static let key = "watchLocation"
    static let fallback = WatchLocation(lat: 42.907058, lon: -85.763014, name: "Grand Rapids",
                                        showReports: true, showTemps: true, showAlerts: true,
                                        showTracks: true, zoom: .county, state: "MI")

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
    static func radarImageURL(sw: CLLocationCoordinate2D, ne: CLLocationCoordinate2D, pixels: Int) -> URL? {
        let (x0, y0) = mercator(sw.longitude, sw.latitude)
        let (x1, y1) = mercator(ne.longitude, ne.latitude)
        // Cache-bust per minute; the mosaic updates far more slowly than that.
        let stamp = Int(Date().timeIntervalSince1970 / 60)
        return URL(string: "\(radarService)/exportImage?bbox=\(Int(x0)),\(Int(y0)),\(Int(x1)),\(Int(y1))" +
                   "&bboxSR=3857&imageSR=3857&size=\(pixels),\(pixels)&format=png32&transparent=true" +
                   "&interpolation=RSP_BilinearInterpolation&f=image&t=\(stamp)")
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

    /// Active warnings and watches overlapping the box. The national feed is
    /// filtered client-side; alerts without geometry are skipped rather than
    /// approximated, since a wrong polygon is worse than a missing one.
    static func alerts(sw: CLLocationCoordinate2D, ne: CLLocationCoordinate2D) async -> [AlertArea] {
        guard let url = URL(string: "https://api.weather.gov/alerts/active?status=actual&message_type=alert")
        else { return [] }
        struct FC: Decodable {
            struct F: Decodable {
                struct P: Decodable { let event: String? }
                let geometry: Geo?
                let properties: P
            }
            struct Geo: Decodable {
                let type: String
                let coordinates: Coords
            }
            let features: [F]
        }
        // Polygon and MultiPolygon differ by one level of nesting.
        struct Coords: Decodable {
            var rings: [[[Double]]] = []
            init(from decoder: Decoder) throws {
                let c = try decoder.singleValueContainer()
                if let poly = try? c.decode([[[Double]]].self) { rings = poly }
                else if let multi = try? c.decode([[[[Double]]]].self) { rings = multi.flatMap { $0 } }
            }
        }
        var req = URLRequest(url: url); req.timeoutInterval = 20
        guard let data = try? await URLSession.shared.data(for: req).0,
              let fc = try? JSONDecoder().decode(FC.self, from: data) else { return [] }

        return fc.features.compactMap { f -> AlertArea? in
            guard let g = f.geometry, g.type == "Polygon" || g.type == "MultiPolygon" else { return nil }
            let rings: [[CLLocationCoordinate2D]] = g.coordinates.rings.map { ring in
                ring.compactMap { p in
                    p.count >= 2 ? CLLocationCoordinate2D(latitude: p[1], longitude: p[0]) : nil
                }
            }.filter { $0.count >= 3 }
            guard !rings.isEmpty else { return nil }
            let hits = rings.contains { ring in
                ring.contains { c in
                    c.latitude >= sw.latitude && c.latitude <= ne.latitude &&
                    c.longitude >= sw.longitude && c.longitude <= ne.longitude
                }
            }
            guard hits else { return nil }
            let event = f.properties.event ?? ""
            return AlertArea(rings: rings, color: alertColor(event),
                             isWatch: event.lowercased().contains("watch"))
        }
    }

    struct Station {
        let lat: Double
        let lon: Double
        let tempF: Double
    }

    /// Current temperatures from one state's ASOS network. The API takes a single
    /// network — repeated or comma-joined values silently return one or none — so
    /// the app resolves the state once and stores it.
    static func stations(state: String?, sw: CLLocationCoordinate2D, ne: CLLocationCoordinate2D) async -> [Station] {
        guard let st = state, st.count == 2,
              let url = URL(string: "https://mesonet.agron.iastate.edu/api/1/currents.geojson?network=\(st.uppercased())_ASOS&minutes=120")
        else { return [] }
        struct FC: Decodable {
            struct F: Decodable {
                struct G: Decodable { let coordinates: [Double] }
                struct P: Decodable { let tmpf: Double? }
                let geometry: G?; let properties: P
            }
            let features: [F]
        }
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

    static func radarImage(sw: CLLocationCoordinate2D, ne: CLLocationCoordinate2D, pixels: Int) async -> RadarRender? {
        guard let url = radarImageURL(sw: sw, ne: ne, pixels: pixels) else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        guard let data = try? await URLSession.shared.data(for: req).0, !data.isEmpty else { return nil }
        // Scaled by area: a blank 800px render is bigger than a blank 400px one.
        let blankCeiling = 12 * pixels
        return RadarRender(data: data, hasEcho: data.count > blankCeiling)
    }
}
