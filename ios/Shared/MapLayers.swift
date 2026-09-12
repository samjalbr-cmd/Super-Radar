import Foundation
import CoreLocation
import UIKit

/// The dashboard layers that are on by default but were missing from the
/// widget: the SPC convective outlook, mesoscale discussions, and the WPC
/// surface analysis.
enum MapLayers {

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
