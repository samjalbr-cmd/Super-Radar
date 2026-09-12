import Foundation

/// Where the widget is watching. The app writes this to the shared container so
/// the extension and the app agree without either having to ask the other.
struct WatchLocation: Codable {
    var lat: Double
    var lon: Double
    var name: String

    static let appGroup = "group.com.samjalbr.nightwatch"
    static let key = "watchLocation"
    static let fallback = WatchLocation(lat: 42.907058, lon: -85.763014, name: "Grand Rapids")

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

    /// A square radar render centred on a point. `halfDegrees` sets how much
    /// ground the tile covers — about 0.9 is a comfortable county-scale view.
    static func radarImageURL(lat: Double, lon: Double, halfDegrees: Double, pixels: Int) -> URL? {
        func mercator(_ lon: Double, _ lat: Double) -> (Double, Double) {
            let x = lon * 20037508.34 / 180
            let y = log(tan((90 + lat) * .pi / 360)) / (.pi / 180) * 20037508.34 / 180
            return (x, y)
        }
        let halfLat = halfDegrees * 0.72
        let (x0, y0) = mercator(lon - halfDegrees, lat - halfLat)
        let (x1, y1) = mercator(lon + halfDegrees, lat + halfLat)
        // Cache-bust per minute; the mosaic updates far more slowly than that.
        let stamp = Int(Date().timeIntervalSince1970 / 60)
        return URL(string: "\(radarService)/exportImage?bbox=\(Int(x0)),\(Int(y0)),\(Int(x1)),\(Int(y1))" +
                   "&bboxSR=3857&imageSR=3857&size=\(pixels),\(pixels)&format=png32&transparent=false" +
                   "&interpolation=RSP_BilinearInterpolation&f=image&t=\(stamp)")
    }

    static func radarImage(lat: Double, lon: Double, halfDegrees: Double, pixels: Int) async -> Data? {
        guard let url = radarImageURL(lat: lat, lon: lon, halfDegrees: halfDegrees, pixels: pixels) else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        return try? await URLSession.shared.data(for: req).0
    }
}
