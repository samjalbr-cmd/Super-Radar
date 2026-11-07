import Foundation
import CoreGraphics
import ImageIO
#if canImport(UIKit)
import UIKit
#endif

/// The live satellite view, cut to a circle for a watch face.
///
/// Straight from the NESDIS file, which is three minutes old and as sharp as
/// GOES gets. The alternative was NASA GIBS, which serves the same GeoColor
/// imagery properly georeferenced — a bounding box in metres, centred wherever
/// you ask — but runs twenty to thirty-five minutes behind. Fresh won.
///
/// The cost of that choice is that this file carries no georeferencing at all:
/// no GeoTIFF, no world file, nothing in the directory beside it. Four
/// attempts to recover the mapping by registering it against GIBS — cloud
/// cross-correlation, iterated phase correlation, a shoreline IoU fit, and a
/// water-centroid offset — returned four answers disagreeing by up to 150 km,
/// and an overlay of the reference coastlines showed the error was in scale as
/// well as position. None of that is good enough to point at a town.
///
/// So the frame is placed by eye instead, from that same overlay: the centre
/// below sits on Michigan's Lower Peninsula just east of the lake shore. That
/// is honest about what it is — a hand-placed crop, not a projection — and at
/// this width being fifty kilometres out is three per cent of the picture.
///
/// GEOCOLOR rather than a single band: true colour while the sun is up, and it
/// switches itself to infrared with city lights after dark, so the face keeps
/// showing something legible instead of going black for twelve hours.
enum SatelliteSector {

    static let sector = "cgl"           // Central Great Lakes
    static let satellite = "GOES19"

    /// The published sizes are 300, 600, 1200 and 2400 square, at roughly 84 KB,
    /// 260 KB, 840 KB and 3.5 MB. A circular complication is about fifty points
    /// across; 600 already carries four times the detail it can show, and the
    /// larger files only cost the watch battery.
    static let pixels = 600

    static var imageURL: URL {
        URL(string: "https://cdn.star.nesdis.noaa.gov/\(satellite)/ABI/SECTOR/"
                  + "\(sector)/GEOCOLOR/\(pixels)x\(pixels).jpg")!
    }

    /// The caption strip NESDIS burns along the bottom — the timestamp and
    /// "NOAA/NESDIS/STAR - CGL - GEOCOLOR Composite" in black on white. Sixteen
    /// rows of six hundred, measured as a fraction so it holds at any published
    /// size. Unreadable at this scale and bright enough to pull the eye.
    ///
    /// The NOAA roundel in the bottom-left corner needs no handling of its own:
    /// the corners fall outside the circle.
    static let captionFraction: CGFloat = 0.0267

    /// Where to centre the circle, as a fraction of the frame. Placed by eye
    /// against the drawn state borders; see the note above for why it is not
    /// computed.
    static let centerX: CGFloat = 0.411
    static let centerY: CGFloat = 0.372

    static func fetch() async -> Data? {
        var req = URLRequest(url: imageURL)
        req.timeoutInterval = 25
        // The file is overwritten in place under one name, so a cached copy is
        // indistinguishable from the current one and would quietly freeze the
        // complication at whatever it first saw.
        req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              data.count > 5000 else { return nil }
        return data
    }

#if canImport(UIKit)
    /// Caption removed, cropped about the centre above, masked to a circle.
    ///
    /// Core Graphics rather than UIGraphicsImageRenderer, which does not exist
    /// on watchOS, and ImageIO rather than UIImage for the decode for the same
    /// reason.
    static func circular(_ data: Data, side: CGFloat, scale: CGFloat = 2) -> UIImage? {
        guard side > 0,
              let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let w = CGFloat(cg.width), h = CGFloat(cg.height) * (1 - captionFraction)
        let cx = w * centerX, cy = h * centerY
        // The largest square that stays inside the frame. Widest is best: GOES
        // resolves about two kilometres a pixel, so cropping tighter than that
        // enlarges pixels instead of adding detail, which is what made the
        // first attempt look blurry. This lands near 1700 km across.
        let half = min(cx, cy, w - cx, h - cy)
        guard half > 1 else { return nil }
        // CGImage crop rects are measured from the top left, so excluding the
        // bottom caption strip is simply a shorter usable height.
        let rect = CGRect(x: cx - half, y: cy - half, width: half * 2, height: half * 2)
        guard let cropped = cg.cropping(to: rect) else { return nil }

        let px = Int((side * scale).rounded())
        guard px > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        let box = CGRect(x: 0, y: 0, width: CGFloat(px), height: CGFloat(px))
        ctx.addEllipse(in: box)
        ctx.clip()
        ctx.draw(cropped, in: box)
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
