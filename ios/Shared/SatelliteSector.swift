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

    /// What the app asks for. The complication is downsampled to nothing, but
    /// a frame you can zoom six times into needs the pixels to be there.
    static let detailPixels = 1200

    static func imageURL(pixels: Int = pixels) -> URL {
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

    /// How much of the frame's width the circle spans. The sector is roughly
    /// 2400 km across, so this lands near 1100 km — Lake Michigan down one
    /// side, Huron and Erie down the other, and the peninsula between them
    /// filling the glass.
    ///
    /// Zooming in costs nothing in sharpness at this size: the complication is
    /// about fifty points, so even this crop is downsampled on the way in. It
    /// was the large preview that suffered from a tight crop, not the watch.
    static let spanFraction: CGFloat = 0.45

    /// The timestamps of the most recent `count` frames, newest last.
    ///
    /// Computed, not scraped. Every one of the 2881 files the archive holds is
    /// stamped at a minute ending 1, 6, 11 … 56 — checked against the whole
    /// listing — so the grid is known and an index fetch is pointless. A frame
    /// that is not published yet simply fails to download and is skipped.
    static func recentFrames(count: Int, lagMinutes: Int = 8) -> [Date] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let back = Date().addingTimeInterval(-Double(lagMinutes) * 60)
        var c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: back)
        let m = c.minute ?? 0
        c.minute = m - ((m - 1 + 5) % 5)
        guard let end = cal.date(from: c) else { return [] }
        return (0..<count).reversed().map { end.addingTimeInterval(-Double($0) * 300) }
    }

    /// The archive URL for one frame.
    static func frameURL(_ d: Date, pixels: Int = pixels) -> URL? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .hour, .minute], from: d)
        // ordinality rather than the .dayOfYear component, which needs
        // watchOS 11 and this deployment target is 10.
        guard let year = c.year, let hour = c.hour, let minute = c.minute,
              let doy = cal.ordinality(of: .day, in: .year, for: d) else { return nil }
        let stamp = String(format: "%04d%03d%02d%02d", year, doy, hour, minute)
        return URL(string: "https://cdn.star.nesdis.noaa.gov/\(satellite)/ABI/SECTOR/"
                 + "\(sector)/GEOCOLOR/\(stamp)_\(satellite)-ABI-\(sector)-GEOCOLOR-"
                 + "\(pixels)x\(pixels).jpg")
    }

    static func fetchFrame(_ d: Date, pixels: Int) async -> Data? {
        guard let url = frameURL(d, pixels: pixels) else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 25
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              data.count > 5000 else { return nil }
        return data
    }

    static func fetch(pixels: Int = pixels) async -> Data? {
        var req = URLRequest(url: imageURL(pixels: pixels))
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
    /// The whole sector with only the caption strip removed.
    ///
    /// For the app, where there is a screen to use and the crown to zoom with,
    /// so the framing is the wearer's to choose rather than one picked here.
    static func fullFrame(_ data: Data) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let h = Int((CGFloat(cg.height) * (1 - captionFraction)).rounded(.down))
        guard h > 0,
              let cropped = cg.cropping(to: CGRect(x: 0, y: 0, width: cg.width, height: h))
        else { return nil }
        return UIImage(cgImage: cropped, scale: 1, orientation: .up)
    }

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
        // As much as spanFraction asks for, bounded by the frame edge so an
        // off-centre crop never runs off the picture.
        let half = min(cx, cy, w - cx, h - cy, w * spanFraction / 2)
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
