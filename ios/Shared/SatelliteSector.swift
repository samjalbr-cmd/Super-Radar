import Foundation
import CoreGraphics
import ImageIO
#if canImport(UIKit)
import UIKit
#endif

/// The GOES sector image, cut to a circle for a watch face.
///
/// NESDIS STAR publishes each ABI sector as a plain JPEG that is replaced in
/// place every few minutes — there is no API around it, just the file. The
/// Central Great Lakes sector is the one that covers Michigan.
///
/// GEOCOLOR rather than a single band: it is true colour while the sun is up
/// and switches itself to infrared with city lights after dark, so the
/// complication keeps showing something legible all night instead of going
/// black for twelve hours.
enum SatelliteSector {

    /// The published sizes are 300, 600, 1200 and 2400 square, at roughly 84 KB,
    /// 260 KB, 840 KB and 3.5 MB. A circular complication is about 50 points
    /// across, so even 600 is far more than it can show; the extra pixels only
    /// buy a cleaner downsample. 600 is the compromise a watch on a cellular
    /// connection can afford every refresh.
    static let pixels = 600

    static let sector = "cgl"
    static let satellite = "GOES19"

    static var imageURL: URL {
        URL(string: "https://cdn.star.nesdis.noaa.gov/\(satellite)/ABI/SECTOR/"
                  + "\(sector)/GEOCOLOR/\(pixels)x\(pixels).jpg")!
    }

    /// The caption strip NESDIS burns along the bottom — the timestamp and
    /// "NOAA/NESDIS/STAR - CGL - GEOCOLOR Composite" in black on white. It is
    /// 16 rows of 600, and measured as a fraction so it holds at any published
    /// size. Unread at this scale and bright enough to pull the eye, so it is
    /// cut before anything else.
    ///
    /// The NOAA roundel sits in the bottom-left corner and needs no special
    /// handling: the corners fall outside the inscribed circle.
    static let captionFraction: CGFloat = 0.0267

    /// The image as published, or nil. No caching here — WidgetKit decides when
    /// a timeline is rebuilt, and that is the only clock worth obeying.
    static func fetch() async -> Data? {
        var req = URLRequest(url: imageURL)
        req.timeoutInterval = 20
        // The file is overwritten in place under one name, so a cached copy is
        // indistinguishable from the current one and would quietly freeze the
        // complication at whatever it first saw.
        req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              !data.isEmpty else { return nil }
        return data
    }

#if canImport(UIKit)
    /// Square, caption removed, masked to a circle.
    ///
    /// Core Graphics rather than UIGraphicsImageRenderer, which does not exist
    /// on watchOS, and ImageIO rather than UIImage for the decode so the whole
    /// path is one that watchOS actually has.
    ///
    /// `side` is in points and `zoom` is a straight magnification about the
    /// centre of the frame: 1 is the whole sector, 2 the middle quarter of it.
    /// The default is 1 because the centre of this sector is Ohio — zooming in
    /// walks away from Michigan rather than towards it.
    static func circular(_ data: Data, side: CGFloat, zoom: CGFloat = 1,
                         scale: CGFloat = 2) -> UIImage? {
        guard side > 0,
              let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        // Drop the caption, then take the largest square of what is left. The
        // sector is published square, so this trims a sliver off the sides
        // rather than losing anything that matters. CGImage crop rects are
        // measured from the top left, so excluding the bottom strip is simply
        // a shorter height.
        let usable = h * (1 - captionFraction)
        let sq = min(w, usable) / max(zoom, 1)
        let rect = CGRect(x: (w - sq) / 2, y: (usable - sq) / 2, width: sq, height: sq)
        guard let cropped = cg.cropping(to: rect) else { return nil }

        let px = Int((side * scale).rounded())
        guard px > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let box = CGRect(x: 0, y: 0, width: CGFloat(px), height: CGFloat(px))
        ctx.addEllipse(in: box)
        ctx.clip()
        ctx.draw(cropped, in: box)
        ctx.resetClip()
        // A hairline rim. Against a black watch face the dark corners of the
        // image and the face itself are the same colour, and without it the
        // picture has no edge at all.
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.28))
        ctx.setLineWidth(scale)
        ctx.strokeEllipse(in: box.insetBy(dx: scale / 2, dy: scale / 2))
        guard let out = ctx.makeImage() else { return nil }
        return UIImage(cgImage: out, scale: scale, orientation: .up)
    }
#endif
}
