import Foundation
import CoreLocation
import UIKit

/// The dashboard layers that are on by default but were missing from the
/// widget: the SPC convective outlook, mesoscale discussions, and the WPC
/// surface analysis.
enum MapLayers {

    /// The index of the hour nearest now in an Open-Meteo `hourly.time` array,
    /// matching the dashboard's currentHourIndex.
    ///
    /// Open-Meteo stamps hours to the minute — "2026-09-30T00:00" — and
    /// ISO8601DateFormatter's .withInternetDateTime insists on seconds, so it
    /// returned nil for every entry. The loop then never moved off index 0 and
    /// each of these layers was silently drawn from 00Z GMT rather than the
    /// current hour: up to a day stale, and wrong by a whole evening even at
    /// best. Seconds are appended before parsing, and a plain DateFormatter
    /// backs it up.
    static func currentHourIndex(_ times: [String]) -> Int {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withTimeZone]
        let plain = DateFormatter()
        plain.locale = Locale(identifier: "en_US_POSIX")
        plain.timeZone = TimeZone(identifier: "GMT")
        plain.dateFormat = "yyyy-MM-dd'T'HH:mm"
        let now = Date()
        var idx = 0, best = Double.greatestFiniteMagnitude
        for (i, t) in times.enumerated() {
            let d = iso.date(from: t + ":00Z") ?? iso.date(from: t + "Z")
                 ?? iso.date(from: t) ?? plain.date(from: t)
            guard let d else { continue }
            let gap = abs(d.timeIntervalSince(now))
            if gap < best { best = gap; idx = i }
        }
        return idx
    }

    // MARK: - SPC convective outlook

    /// A Day 1 categorical risk area, carrying the colours SPC ships with it
    /// rather than a palette of our own.
    struct OutlookArea {
        let rings: [[CLLocationCoordinate2D]]
        let stroke: UIColor
        let fill: UIColor
        let label: String       // TSTM, MRGL, SLGT, ENH, MDT, HIGH
        let rank: Int           // DN, so the more serious area draws on top
    }

    static func outlook(sw: CLLocationCoordinate2D, ne: CLLocationCoordinate2D) async -> [OutlookArea] {
        let u = "https://www.spc.noaa.gov/products/outlook/day1otlk_cat.nolyr.geojson"
        guard let url = URL(string: u) else { return [] }
        struct FC: Decodable {
            struct F: Decodable {
                struct P: Decodable {
                    let DN: Int?; let LABEL: String?
                    let stroke: String?; let fill: String?
                }
                let geometry: StormFeed.GeoJSONGeometry?
                let properties: P
            }
            let features: [F]
        }
        var req = URLRequest(url: url); req.timeoutInterval = 20
        guard let data = try? await URLSession.shared.data(for: req).0,
              let fc = try? JSONDecoder().decode(FC.self, from: data) else { return [] }

        let areas = fc.features.compactMap { f -> OutlookArea? in
            guard let g = f.geometry else { return nil }
            let rings = ringsIn(g, sw: sw, ne: ne)
            guard !rings.isEmpty else { return nil }
            return OutlookArea(rings: rings,
                               stroke: hexColor(f.properties.stroke) ?? .gray,
                               fill: hexColor(f.properties.fill) ?? .gray,
                               label: f.properties.LABEL ?? "",
                               rank: f.properties.DN ?? 0)
        }
        // Risk areas nest, so draw the broad ones first and the sharp ones last.
        return areas.sorted { $0.rank < $1.rank }
    }

    // MARK: - Mesoscale discussions

    struct Discussion {
        let rings: [[CLLocationCoordinate2D]]
        let number: Int
    }

    static func mesoscaleDiscussions(sw: CLLocationCoordinate2D, ne: CLLocationCoordinate2D) async -> [Discussion] {
        guard let url = URL(string: "https://mesonet.agron.iastate.edu/api/1/nws/spc_mcd.geojson")
        else { return [] }
        struct FC: Decodable {
            struct F: Decodable {
                struct P: Decodable { let num: Int? }
                let geometry: StormFeed.GeoJSONGeometry?
                let properties: P
            }
            let features: [F]
        }
        var req = URLRequest(url: url); req.timeoutInterval = 20
        guard let data = try? await URLSession.shared.data(for: req).0,
              let fc = try? JSONDecoder().decode(FC.self, from: data) else { return [] }
        return fc.features.compactMap { f in
            guard let g = f.geometry else { return nil }
            let rings = ringsIn(g, sw: sw, ne: ne)
            guard !rings.isEmpty else { return nil }
            return Discussion(rings: rings, number: f.properties.num ?? 0)
        }
    }

    // MARK: - Surface analysis

    enum FrontKind: String { case COLD, WARM, STNRY, OCFNT, TROF }

    struct Front {
        let kind: FrontKind
        let points: [CLLocationCoordinate2D]
    }

    struct PressureCenter {
        let isHigh: Bool
        let millibars: Int
        let point: CLLocationCoordinate2D
    }

    struct Surface {
        let fronts: [Front]
        let centers: [PressureCenter]
    }

    /// WPC's coded surface bulletin. Prefers the high-resolution ASUS02 and
    /// falls back to ASUS01, exactly as the dashboard does.
    static func surface() async -> Surface? {
        struct Graph: Decodable {
            struct P: Decodable { let id: String; let wmoCollectiveId: String? }
            let graph: [P]
            enum CodingKeys: String, CodingKey { case graph = "@graph" }
        }
        struct Product: Decodable { let productText: String? }

        guard let listURL = URL(string: "https://api.weather.gov/products/types/COD") else { return nil }
        var req = URLRequest(url: listURL); req.timeoutInterval = 20
        guard let data = try? await URLSession.shared.data(for: req).0,
              let list = try? JSONDecoder().decode(Graph.self, from: data) else { return nil }
        let pick = list.graph.first { $0.wmoCollectiveId == "ASUS02" }
            ?? list.graph.first { $0.wmoCollectiveId == "ASUS01" }
        guard let pick,
              let pURL = URL(string: "https://api.weather.gov/products/\(pick.id)") else { return nil }
        var pReq = URLRequest(url: pURL); pReq.timeoutInterval = 20
        guard let pData = try? await URLSession.shared.data(for: pReq).0,
              let prod = try? JSONDecoder().decode(Product.self, from: pData),
              let text = prod.productText else { return nil }
        return parse(text, highRes: pick.wmoCollectiveId == "ASUS02")
    }

    /// A coordinate token. High-res is lat*10 (3 digits) then lon*10 (4);
    /// low-res is lat (2) then lon (2 or 3). Longitude is west throughout.
    static func point(_ token: String, highRes: Bool) -> CLLocationCoordinate2D? {
        guard !token.isEmpty, token.allSatisfy(\.isNumber) else { return nil }
        let la: Double, lo: Double
        if highRes {
            guard token.count == 7 else { return nil }
            la = Double(token.prefix(3))! / 10
            lo = Double(token.dropFirst(3))! / 10
        } else {
            guard token.count >= 4, token.count <= 5 else { return nil }
            la = Double(token.prefix(2))!
            lo = Double(token.dropFirst(2))!
        }
        guard la >= 0, la <= 90, lo >= 0, lo <= 180 else { return nil }
        return CLLocationCoordinate2D(latitude: la, longitude: -lo)
    }

    /// Sections are a keyword line plus however many wrapped continuation lines
    /// of bare numbers follow it — the continuations carry no keyword, so they
    /// have to be accumulated onto the open section rather than parsed alone.
    static func parse(_ text: String, highRes: Bool) -> Surface {
        var fronts: [Front] = [], centers: [PressureCenter] = []
        var kind: String? = nil
        var tokens: [String] = []

        func flush() {
            defer { tokens = []; kind = nil }
            guard let k = kind else { return }
            if k == "HIGHS" || k == "LOWS" {
                var i = 0
                while i + 1 < tokens.count {
                    let mb = tokens[i]
                    if mb.count >= 3, mb.count <= 4, mb.allSatisfy(\.isNumber),
                       let p = point(tokens[i + 1], highRes: highRes), let v = Int(mb) {
                        centers.append(PressureCenter(isHigh: k == "HIGHS", millibars: v, point: p))
                    }
                    i += 2
                }
            } else if let fk = FrontKind(rawValue: k) {
                let pts = tokens.compactMap { point($0, highRes: highRes) }
                if pts.count >= 2 { fronts.append(Front(kind: fk, points: pts)) }
            }
        }

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line == "$$" { continue }
            let parts = line.split(separator: " ").map(String.init)
            if let head = parts.first,
               ["HIGHS", "LOWS", "COLD", "WARM", "STNRY", "OCFNT", "TROF"].contains(head) {
                flush()
                kind = head
                tokens = Array(parts.dropFirst())
            } else if kind != nil, parts.allSatisfy({ $0.allSatisfy(\.isNumber) }) {
                tokens.append(contentsOf: parts)     // wrapped continuation
            } else {
                flush()                              // prose or header ends the section
            }
        }
        flush()
        return Surface(fronts: fronts, centers: centers)
    }

    // MARK: - Upper-air winds

    /// One barb on the upper-air lattice: where it sits, and the wind there.
    struct UpperWind {
        let coord: CLLocationCoordinate2D
        let kt: Double
        let dir: Double         // degrees the wind is coming from
    }

    /// The pressure levels the dashboard offers, with the colour each is drawn
    /// in. Keyed by the same strings the dashboard stores, so a level chosen in
    /// the app arrives here unchanged.
    static let upperLevels: [String: (label: String, color: UIColor)] = [
        "850": ("850 hPa \u{00b7} 5,000 ft",  UIColor(red: 0.37, green: 0.85, blue: 0.54, alpha: 1)),
        "700": ("700 hPa \u{00b7} 10,000 ft", UIColor(red: 0.50, green: 0.83, blue: 1.00, alpha: 1)),
        "500": ("500 hPa \u{00b7} 18,000 ft", UIColor(red: 0.79, green: 0.63, blue: 1.00, alpha: 1)),
        "250": ("250 hPa \u{00b7} 35,000 ft", UIColor(red: 1.00, green: 0.62, blue: 0.82, alpha: 1)),
    ]

    /// Winds at one pressure level, on a coarse lattice across the view.
    ///
    /// Deliberately sparse — a barb every 90-odd miles reads as flow, and any
    /// denser is a hairball over the radar. Snapped to fixed degrees for the
    /// same reason the isobar grid is: sampling the view itself would shift
    /// every barb whenever the map moved a pixel.
    static func upperWinds(sw: CLLocationCoordinate2D, ne: CLLocationCoordinate2D,
                           level: String) async -> [UpperWind] {
        guard upperLevels[level] != nil else { return [] }
        let padLat = (ne.latitude - sw.latitude) * 0.08
        let padLon = (ne.longitude - sw.longitude) * 0.08
        let south = sw.latitude - padLat, north = ne.latitude + padLat
        let west = sw.longitude - padLon, east = ne.longitude + padLon
        guard north > south, east > west else { return [] }

        // The step comes from the longitude span alone, so a metro view and a
        // multi-state view both read as a field. Never from the point count:
        // latitude span varies with the centre latitude, because Mercator
        // degrees-per-pixel does, and letting that pick the step makes the
        // choice bistable — on the dashboard a 0.02° wobble from an ordinary pan
        // flipped it between 1° and 1.5° and relocated every barb. Snapping the
        // lattice is pointless if the thing it snaps to is not itself stable.
        let steps: [Double] = [0.25, 0.5, 1, 1.5, 2, 3, 5, 8, 12, 20]
        var step: Double = steps[steps.count - 1]
        for candidate in steps {
            if (east - west) / candidate <= 12 { step = candidate; break }
        }
        let c0 = Int((west / step).rounded(.down)), c1 = Int((east / step).rounded(.up))
        let r0 = Int((south / step).rounded(.down)), r1 = Int((north / step).rounded(.up))
        let cols = c1 - c0 + 1, rows = r1 - r0 + 1
        guard cols > 1, rows > 1, cols * rows <= 200 else { return [] }

        var lats: [String] = [], lons: [String] = []
        var centres: [CLLocationCoordinate2D] = []
        for r in 0..<rows {
            // Alternate rows sit half a step east. Sampling stays even, but the
            // ranks-and-files reading of a square lattice breaks up — which
            // matters here because these are model samples rather than stations,
            // and a perfect grid reads as texture instead of as data. The offset
            // moves the sample itself, so a barb still sits exactly where its
            // wind was read.
            let off = r % 2 == 1 ? step / 2 : 0
            for c in 0..<cols {
                let la = Double(r0 + r) * step, lo = Double(c0 + c) * step + off
                lats.append(String(format: "%.3f", la))
                lons.append(String(format: "%.3f", lo))
                centres.append(CLLocationCoordinate2D(latitude: la, longitude: lo))
            }
        }
        var comps = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        comps.queryItems = [
            .init(name: "latitude", value: lats.joined(separator: ",")),
            .init(name: "longitude", value: lons.joined(separator: ",")),
            .init(name: "hourly", value: "wind_speed_\(level)hPa,wind_direction_\(level)hPa"),
            .init(name: "models", value: "ncep_hrrr_conus"),
            .init(name: "timezone", value: "GMT"),
            .init(name: "forecast_days", value: "1"),
        ]
        guard let url = comps.url else { return [] }
        struct Point: Decodable {
            struct Hourly: Decodable {
                let time: [String]?
                let speed: [Double?]?
                let direction: [Double?]?
                // The wire names carry the level, so they cannot be static keys.
                init(from decoder: Decoder) throws {
                    let c = try decoder.container(keyedBy: Key.self)
                    var t: [String]? = nil, s: [Double?]? = nil, d: [Double?]? = nil
                    for k in c.allKeys {
                        if k.stringValue == "time" { t = try? c.decode([String].self, forKey: k) }
                        else if k.stringValue.hasPrefix("wind_speed_") { s = try? c.decode([Double?].self, forKey: k) }
                        else if k.stringValue.hasPrefix("wind_direction_") { d = try? c.decode([Double?].self, forKey: k) }
                    }
                    time = t; speed = s; direction = d
                }
                struct Key: CodingKey {
                    var stringValue: String
                    init?(stringValue: String) { self.stringValue = stringValue }
                    var intValue: Int? { nil }
                    init?(intValue: Int) { nil }
                }
            }
            let hourly: Hourly?
        }
        var req = URLRequest(url: url); req.timeoutInterval = 25
        guard var data = try? await URLSession.shared.data(for: req).0 else { return [] }
        // HRRR covers CONUS and a margin around it, and one point outside that
        // margin fails the entire request rather than coming back empty — so a
        // view reaching into Canada lost every barb, not just the ones over
        // Canada. Fall back to whichever model Open-Meteo has for the area.
        //
        // Only for that error. Retrying on any failure meant a rate-limit reply
        // — which is the API asking for less traffic — immediately bought a
        // second request that was going to be refused too.
        struct Failure: Decodable { let error: Bool?; let reason: String? }
        let failure = try? JSONDecoder().decode(Failure.self, from: data)
        if failure?.error == true,
           (failure?.reason ?? "").lowercased().contains("no data is available") {
            var fallback = comps
            fallback.queryItems = comps.queryItems?.filter { $0.name != "models" }
            guard let fbURL = fallback.url else { return [] }
            var fbReq = URLRequest(url: fbURL); fbReq.timeoutInterval = 25
            guard let d2 = try? await URLSession.shared.data(for: fbReq).0 else { return [] }
            data = d2
        }
        let points: [Point]
        if let many = try? JSONDecoder().decode([Point].self, from: data) { points = many }
        else if let one = try? JSONDecoder().decode(Point.self, from: data) { points = [one] }
        else { return [] }
        guard points.count == centres.count, let times = points.first?.hourly?.time else { return [] }

        let idx = currentHourIndex(times)
        var out: [UpperWind] = []
        for (i, p) in points.enumerated() {
            guard let h = p.hourly,
                  let sp = h.speed, idx < sp.count, let kmh = sp[idx],
                  let dr = h.direction, idx < dr.count, let deg = dr[idx] else { continue }
            out.append(UpperWind(coord: centres[i], kt: kmh * 0.539957, dir: deg))
        }
        return out
    }

    // MARK: - Isobars

    /// A mean-sea-level pressure contour: the line, and the level it traces.
    struct Isobar {
        let segments: [[CLLocationCoordinate2D]]
        let millibars: Int
    }

    /// Isobars across the view, on the 4 hPa analysis interval or tighter when flat.
    ///
    /// A coarse 14x10 grid sampled from Open-Meteo and traced with marching
    /// squares — the same grid size and the same tracer the dashboard uses, so
    /// the two draw the same lines. Pressure centres are deliberately not
    /// derived here: the surface analysis already places H and L from WPC's own
    /// bulletin, and a second set off a coarse model grid would disagree with
    /// them.
    static func isobars(sw: CLLocationCoordinate2D, ne: CLLocationCoordinate2D) async -> [Isobar] {
        // Sampled on a lattice snapped to fixed degrees and padded past the
        // view. Sampling the view itself moved every point whenever the map
        // moved, so the contours were re-interpolated from different places each
        // time and crawled; and because the samples stopped at the edge, so did
        // the lines. A fixed lattice re-samples the same points, and the padding
        // lets a contour run off the edge instead of ending at it.
        let padLat = (ne.latitude - sw.latitude) * 0.2
        let padLon = (ne.longitude - sw.longitude) * 0.2
        let west = sw.longitude - padLon, east = ne.longitude + padLon
        let south = sw.latitude - padLat, north = ne.latitude + padLat

        let choices: [Double] = [0.1, 0.2, 0.25, 0.5, 1, 2, 2.5, 5, 10]
        var step = choices.first { $0 >= (east - west) / 14 } ?? 10
        var c0 = 0, c1 = 0, r0 = 0, r1 = 0
        while true {
            c0 = Int((west / step).rounded(.down)); c1 = Int((east / step).rounded(.up))
            r0 = Int((south / step).rounded(.down)); r1 = Int((north / step).rounded(.up))
            if (c1 - c0 + 1) * (r1 - r0 + 1) <= 260 { break }
            guard let i = choices.firstIndex(of: step), i + 1 < choices.count else { break }
            step = choices[i + 1]
        }
        let cols = c1 - c0 + 1, rows = r1 - r0 + 1
        guard cols > 1, rows > 1 else { return [] }

        var lats: [String] = [], lons: [String] = []
        var centres: [CLLocationCoordinate2D] = []
        for r in 0..<rows {
            for c in 0..<cols {
                let la = Double(r0 + r) * step, lo = Double(c0 + c) * step
                lats.append(String(format: "%.3f", la))
                lons.append(String(format: "%.3f", lo))
                centres.append(CLLocationCoordinate2D(latitude: la, longitude: lo))
            }
        }
        var comps = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        comps.queryItems = [
            .init(name: "latitude", value: lats.joined(separator: ",")),
            .init(name: "longitude", value: lons.joined(separator: ",")),
            .init(name: "hourly", value: "pressure_msl"),
            .init(name: "timezone", value: "GMT"),
            .init(name: "forecast_days", value: "1"),
        ]
        guard let url = comps.url else { return [] }
        struct Point: Decodable {
            struct Hourly: Decodable { let time: [String]?; let pressure_msl: [Double?]? }
            let hourly: Hourly?
        }
        var req = URLRequest(url: url); req.timeoutInterval = 25
        guard let data = try? await URLSession.shared.data(for: req).0 else { return [] }
        // A multi-point request answers with an array; a single point with an object.
        let points: [Point]
        if let many = try? JSONDecoder().decode([Point].self, from: data) { points = many }
        else if let one = try? JSONDecoder().decode(Point.self, from: data) { points = [one] }
        else { return [] }
        guard points.count == centres.count, let times = points.first?.hourly?.time else { return [] }

        let idx = currentHourIndex(times)
        let vals: [Double?] = points.map { p in
            guard let arr = p.hourly?.pressure_msl, idx < arr.count else { return nil }
            return arr[idx]
        }
        let present = vals.compactMap { $0 }
        guard present.count > cols, let lo = present.min(), let hi = present.max() else { return [] }

        // Matches the dashboard: 4 hPa is the national surface-analysis interval,
        // but a widget frames a few degrees, where the whole field often spans
        // less than one contour — so nothing was drawn and the widget looked
        // like it had no isobars at all. Tighten the interval when the field is
        // flat; keep 4 once there is real gradient to show.
        let spread = hi - lo
        let interval: Double = spread >= 16 ? 4 : spread >= 8 ? 2 : 1
        var out: [Isobar] = []
        var level = (lo / interval).rounded(.up) * interval
        while level <= hi {
            let segs = contour(vals, centres, cols: cols, rows: rows, level: level)
            if !segs.isEmpty { out.append(Isobar(segments: segs, millibars: Int(level.rounded()))) }
            level += interval
        }
        return out
    }

    /// Marching squares over the sample grid — a direct port of the tracer the
    /// dashboard draws its isobars with.
    private static func contour(_ vals: [Double?], _ pts: [CLLocationCoordinate2D],
                                cols: Int, rows: Int, level: Double) -> [[CLLocationCoordinate2D]] {
        func interp(_ a: Int, _ b: Int) -> CLLocationCoordinate2D? {
            guard let va = vals[a], let vb = vals[b], va != vb else { return nil }
            let t = (level - va) / (vb - va)
            return CLLocationCoordinate2D(
                latitude: pts[a].latitude + (pts[b].latitude - pts[a].latitude) * t,
                longitude: pts[a].longitude + (pts[b].longitude - pts[a].longitude) * t)
        }
        var segs: [[CLLocationCoordinate2D]] = []
        for r in 0..<(rows - 1) {
            for c in 0..<(cols - 1) {
                let corner = [r * cols + c, r * cols + c + 1,
                              (r + 1) * cols + c + 1, (r + 1) * cols + c]
                if corner.contains(where: { vals[$0] == nil }) { continue }
                var cross: [CLLocationCoordinate2D] = []
                for e in 0..<4 {
                    let a = corner[e], b = corner[(e + 1) % 4]
                    if (vals[a]! < level) != (vals[b]! < level), let p = interp(a, b) { cross.append(p) }
                }
                if cross.count == 2 { segs.append([cross[0], cross[1]]) }
                else if cross.count == 4 {
                    segs.append([cross[0], cross[1]]); segs.append([cross[2], cross[3]])
                }
            }
        }
        return segs
    }

    // MARK: - Helpers

    static func ringsIn(_ g: StormFeed.GeoJSONGeometry,
                        sw: CLLocationCoordinate2D, ne: CLLocationCoordinate2D) -> [[CLLocationCoordinate2D]] {
        g.coordinates.rings.map { ring in
            ring.compactMap { p in
                p.count >= 2 ? CLLocationCoordinate2D(latitude: p[1], longitude: p[0]) : nil
            }
        }
        .filter { $0.count >= 3 && StormFeed.boxOverlaps($0, sw: sw, ne: ne) }
    }

    static func hexColor(_ hex: String?) -> UIColor? {
        guard var h = hex else { return nil }
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = Int(h, radix: 16) else { return nil }
        return UIColor(red: CGFloat((v >> 16) & 255) / 255,
                       green: CGFloat((v >> 8) & 255) / 255,
                       blue: CGFloat(v & 255) / 255, alpha: 1)
    }
}
