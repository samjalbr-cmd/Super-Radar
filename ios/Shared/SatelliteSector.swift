import Foundation
import CoreGraphics
import ImageIO
import CoreLocation
#if canImport(UIKit)
import UIKit
#endif

/// The live satellite view of wherever you are, cut to a circle for a watch face.
///
/// The obvious source is the NESDIS sector JPEG — the Central Great Lakes frame
/// is three minutes old and perfectly sharp. It is also unusable for this: the
/// file carries no georeferencing of any kind (no GeoTIFF, no world file,
/// nothing in the directory beside it), so there is no honest way to work out
/// which pixel is your house. Its centre is Ohio, and everyone who does not
/// live in Ohio gets someone else's weather.
///
/// NASA GIBS serves the same GOES GeoColor imagery through a WMS in Web
/// Mercator, which means a bounding box in metres and an image centred exactly
/// where you ask. The cost is latency: GIBS runs twenty to thirty-five minutes
/// behind the direct NESDIS file. For a cloud field on a wrist that is a fair
/// trade for being pointed at the right place.
///
/// GEOCOLOR rather than a single band: true colour while the sun is up, and it
/// switches itself to infrared with city lights after dark, so the face keeps
/// showing something legible instead of going black for twelve hours.
enum SatelliteSector {

    static let layer = "GOES-East_ABI_GeoColor"
    static let endpoint = "https://gibs.earthdata.nasa.gov/wms/epsg3857/best/wms.cgi"

    /// How much ground the circle covers, corner to corner.
    ///
    /// GOES resolves about two kilometres at nadir and nearer four up here, so
    /// asking for a tighter view than that does not add detail — it enlarges
    /// pixels, which is exactly what a close crop looked like. At 1600 km
    /// across a complication lands near four kilometres per pixel, which is
    /// the sensor's own resolution: the sharpest this can be, and wide enough
    /// to show weather that has not arrived yet.
    static let defaultSpanKm: Double = 1600

    /// Where to centre when nothing better is known — the middle of the Great
    /// Lakes, matching the sector this started from. Replaced by the real
    /// location as soon as the watch app has been opened once.
    static let fallback = (lat: 43.0, lon: -84.5)

    /// Where the wearer is, or nil.
    ///
    /// Read straight from CoreLocation rather than passed between the app and
    /// the complication. Sharing it would need an App Group, and an App Group
    /// needs a provisioning profile that carries the capability — whereas a
    /// widget extension already inherits its app's location authorization, so
    /// the last known fix is simply there to be read. The watch app is what
    /// puts the permission prompt up; this only reads the answer.
    static var deviceCenter: (lat: Double, lon: Double)? {
        let m = CLLocationManager()
        let ok = m.authorizationStatus == .authorizedWhenInUse ||
                 m.authorizationStatus == .authorizedAlways
        guard ok, let c = m.location?.coordinate,
              CLLocationCoordinate2DIsValid(c) else { return nil }
        return (c.latitude, c.longitude)
    }

    static var center: (lat: Double, lon: Double) { deviceCenter ?? fallback }

    /// Web Mercator metres, which is what the WMS bounding box is in.
    static func mercator(lat: Double, lon: Double) -> (x: Double, y: Double) {
        let x = lon * 20_037_508.34 / 180
        let clamped = min(max(lat, -85), 85)
        let y = log(tan((90 + clamped) * .pi / 360)) / (.pi / 180) * 20_037_508.34 / 180
        return (x, y)
    }

    static func imageURL(lat: Double, lon: Double,
                         spanKm: Double = defaultSpanKm, pixels: Int) -> URL? {
        let c = mercator(lat: lat, lon: lon)
        let half = spanKm * 1000 / 2
        var u = URLComponents(string: endpoint)!
        u.queryItems = [
            .init(name: "SERVICE", value: "WMS"),
            .init(name: "VERSION", value: "1.3.0"),
            .init(name: "REQUEST", value: "GetMap"),
            .init(name: "LAYERS", value: layer),
            // JPEG, not PNG: the same 256-pixel frame is about 9 KB as JPEG and
            // 140 KB as PNG, and a watch pays for every byte.
            .init(name: "FORMAT", value: "image/jpeg"),
            .init(name: "CRS", value: "EPSG:3857"),
            .init(name: "BBOX", value: "\(c.x - half),\(c.y - half),\(c.x + half),\(c.y + half)"),
            .init(name: "WIDTH", value: String(pixels)),
            .init(name: "HEIGHT", value: String(pixels)),
            // No TIME. Asking for a specific minute gets a black frame whenever
            // that minute was not ingested at the zoom level the span resolves
            // to; the default is whatever is newest and always has data.
        ]
        return u.url
    }

    static func fetch(lat: Double, lon: Double,
                      spanKm: Double = defaultSpanKm, pixels: Int) async -> Data? {
        guard let url = imageURL(lat: lat, lon: lon, spanKm: spanKm, pixels: pixels) else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 25
        req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              // A frame with no imagery behind it comes back as a few hundred
              // bytes of black rather than as an error.
              data.count > 2500 else { return nil }
        return data
    }

#if canImport(UIKit)
    /// Masked to a circle at `side` points.
    ///
    /// Core Graphics rather than UIGraphicsImageRenderer, which does not exist
    /// on watchOS, and ImageIO rather than UIImage for the decode for the same
    /// reason. The frame arrives square and already centred, so there is
    /// nothing to crop — unlike the NESDIS sector, which had a caption strip
    /// burnt along the bottom.
    static func circular(_ data: Data, side: CGFloat, scale: CGFloat = 2) -> UIImage? {
        guard side > 0,
              let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let px = Int((side * scale).rounded())
        guard px > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let box = CGRect(x: 0, y: 0, width: CGFloat(px), height: CGFloat(px))
        ctx.addEllipse(in: box)
        ctx.clip()
        ctx.draw(cg, in: box)
        ctx.resetClip()
        // A hairline rim. Against a black watch face the dark water and the
        // face itself are the same colour, and without it the picture has no
        // edge at all.
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.28))
        ctx.setLineWidth(scale)
        ctx.strokeEllipse(in: box.insetBy(dx: scale / 2, dy: scale / 2))
        guard let out = ctx.makeImage() else { return nil }
        return UIImage(cgImage: out, scale: scale, orientation: .up)
    }
#endif
}
