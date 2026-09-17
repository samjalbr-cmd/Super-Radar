import Foundation
import MapKit
import UIKit

/// How much ground a widget covers. Radar without a basemap has no geographic
/// context — it was the missing half of the picture — so the map is rendered by
/// MapKit and the radar composited on top of it, aligned by projecting the
/// region's own corners rather than trusting two services to agree.
enum RadarZoom: String, CaseIterable, Codable, Sendable {
    case metro, county, area, region, wide, state, multi

    /// Half-width in degrees of longitude.
    var halfDegrees: Double {
        switch self {
        case .metro:  return 0.35   // ~ 60 km across
        case .county: return 0.9    // ~150 km
        case .area:   return 1.3    // ~215 km
        case .region: return 1.8    // ~300 km
        case .wide:   return 2.5    // ~415 km
        case .state:  return 3.2    // ~530 km
        case .multi:  return 5.5    // ~900 km
        }
    }
    var label: String {
        switch self {
        case .metro:  return "Metro"
        case .county: return "County"
        case .area:   return "Area"
        case .region: return "Region"
        case .wide:   return "Wide"
        case .state:  return "State"
        case .multi:  return "Multi-state"
        }
    }
    /// Temperatures are drawn at every zoom. The screen-space declutter is what
    /// keeps them legible, so a wider view simply shows fewer, further apart,
    /// rather than a wall of overlapping numbers.
    var showsTemperatures: Bool { true }

    /// Labels are spaced in screen points, so a wide view wants them further
    /// apart — at multi-state scale adjacent stations are only a few points
    /// apart on the map and a tight grid would read as noise.
    var labelSpacing: CGFloat {
        switch self {
        case .metro, .county, .area: return 26
        case .region, .wide:         return 30
        case .state, .multi:         return 34
        }
    }

    /// How many state networks to fetch. A wide view genuinely spans a dozen,
    /// and each is around 80 KB — still far below the 3.4 MB national feed.
    var maxStates: Int {
        switch self {
        case .metro, .county, .area: return 6
        case .region, .wide:         return 9
        case .state, .multi:         return 14
        }
    }
}

/// The dashboard's temperature ramp, so a number means the same thing in both.
///
/// Interpolated between its stops rather than stepped, so a view spanning only a
/// few degrees still shows a gradient instead of one flat colour.
private let tempStops: [(Double, CGFloat, CGFloat, CGFloat)] = [
    (0, 0xA0, 0x20, 0xF0), (20, 0xAD, 0xD8, 0xE6), (30, 0xE0, 0xFF, 0xFF),
    (40, 0x00, 0xFF, 0xFF), (50, 0xB0, 0xE5, 0x7C), (60, 0x00, 0x80, 0x00),
    (70, 0xFF, 0xFF, 0x00), (80, 0xFF, 0xA5, 0x00), (90, 0xFF, 0x45, 0x00),
    (100, 0xFF, 0x00, 0x00), (110, 0x8B, 0x00, 0x00),
]

private func tempColor(_ f: Double) -> UIColor {
    func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> UIColor {
        UIColor(red: r / 255, green: g / 255, blue: b / 255, alpha: 1)
    }
    guard let first = tempStops.first, let last = tempStops.last else { return .white }
    if f <= first.0 { return rgb(first.1, first.2, first.3) }
    if f >= last.0 { return rgb(last.1, last.2, last.3) }
    for i in 0..<(tempStops.count - 1) {
        let a = tempStops[i], b = tempStops[i + 1]
        guard f <= b.0 else { continue }
        let t = CGFloat((f - a.0) / (b.0 - a.0))
        return rgb(a.1 + (b.1 - a.1) * t, a.2 + (b.2 - a.2) * t, a.3 + (b.3 - a.3) * t)
    }
    return .white
}

/// The barb, the sky circle and every figure in the plot take the temperature
/// colour. The black halo behind them carries the contrast, so the palette is
/// used exactly as specified rather than being lightened.
private func barbColor(_ f: Double) -> UIColor { tempColor(f) }

/// Which side of a front its symbols go on. WPC digitises fronts so that the
/// left of the digitised direction is the leading edge.
///
/// Checked against a live bulletin: with the pips on the left, today's six North
/// American cold fronts point SE/SW/S and its three warm fronts NE/N — the
/// directions those fronts actually advance. On the right they point exactly
/// backwards. Flip this only if a future bulletin disagrees.
private let pipOnLeft = true

private enum PipShape { case triangle, arc, alternating, both }

private struct FrontStyle {
    let color: UIColor
    let weight: CGFloat
    let pip: PipShape?
    let dash: [CGFloat]?
}

private func frontStyle(_ k: MapLayers.FrontKind) -> FrontStyle {
    switch k {
    case .COLD:  return FrontStyle(color: UIColor(red: 0.23, green: 0.63, blue: 1.00, alpha: 1),
                                   weight: 2.4, pip: .triangle, dash: nil)
    case .WARM:  return FrontStyle(color: UIColor(red: 0.88, green: 0.02, blue: 0.00, alpha: 1),
                                   weight: 2.4, pip: .arc, dash: nil)
    case .STNRY: return FrontStyle(color: UIColor(red: 0.23, green: 0.63, blue: 1.00, alpha: 1),
                                   weight: 2.4, pip: .alternating, dash: nil)
    case .OCFNT: return FrontStyle(color: UIColor(red: 0.69, green: 0.31, blue: 1.00, alpha: 1),
                                   weight: 2.4, pip: .both, dash: nil)
    case .TROF:  return FrontStyle(color: UIColor(red: 0.85, green: 0.60, blue: 0.25, alpha: 1),
                                   weight: 1.6, pip: nil, dash: [7, 5])
    }
}

private func inFrame(_ p: CGPoint, _ size: CGSize) -> Bool {
    p.x > -20 && p.y > -20 && p.x < size.width + 20 && p.y < size.height + 20
}

private func ringPath(_ ring: [CLLocationCoordinate2D], _ snap: MKMapSnapshotter.Snapshot) -> UIBezierPath {
    let path = UIBezierPath()
    for (i, c) in ring.enumerated() {
        let p = snap.point(for: c)
        i == 0 ? path.move(to: p) : path.addLine(to: p)
    }
    path.close()
    return path
}

/// Walk a polyline in screen space and drop a mark every `gap` points, so the
/// symbols stay evenly spaced regardless of how the front is digitised.
private func pipMarks(_ pts: [CGPoint], every gap: CGFloat) -> [(at: CGPoint, angle: CGFloat)] {
    var out: [(CGPoint, CGFloat)] = []
    var carry = gap * 0.55          // start part-way in, not on the end
    for i in 0..<(pts.count - 1) {
        let a = pts[i], b = pts[i + 1]
        let dx = b.x - a.x, dy = b.y - a.y
        let len = (dx * dx + dy * dy).squareRoot()
        if len < 0.5 { continue }
        let ang = atan2(dy, dx)
        var d = carry
        while d < len {
            let t = d / len
            out.append((CGPoint(x: a.x + dx * t, y: a.y + dy * t), ang))
            d += gap
        }
        carry = max(0, carry - len)
        if carry == 0 { carry = gap - (len - carry).truncatingRemainder(dividingBy: gap) }
    }
    return out
}

/// A front symbol, rotated to the direction of travel so it always lands on the
/// same side of the line.
private func drawPip(at p: CGPoint, angle: CGFloat, shape: PipShape,
                     color: UIColor, flip: Bool = false) {
    guard let ctx = UIGraphicsGetCurrentContext() else { return }
    ctx.saveGState()
    ctx.translateBy(x: p.x, y: p.y)
    // The symbol is built pointing up the -y axis, which after rotating the
    // frame to the direction of travel lands on its left. So the left side —
    // the one we want — needs no further turn; half a turn is what puts it on
    // the wrong side, and is only used to alternate a stationary front.
    ctx.rotate(by: angle + ((pipOnLeft != flip) ? 0 : .pi))
    let w: CGFloat = 11, h: CGFloat = 7
    let path = UIBezierPath()
    if shape == .arc {
        path.move(to: CGPoint(x: -w / 2, y: 0))
        path.addArc(withCenter: .zero, radius: w / 2,
                    startAngle: .pi, endAngle: 0, clockwise: true)
        path.close()
    } else {
        path.move(to: CGPoint(x: -w / 2, y: 0))
        path.addLine(to: CGPoint(x: 0, y: -h))
        path.addLine(to: CGPoint(x: w / 2, y: 0))
        path.close()
    }
    color.setFill()
    path.fill()
    ctx.restoreGState()
}

/// The classic surface station model, laid out around the sky-cover circle:
/// temperature upper left, dew point lower left, coded sea-level pressure upper
/// right, present weather to the left, and the wind barb pointing into the wind.
///
/// Pressure tendency, the lower-right arm of the textbook plot, is not carried
/// by this feed and is the one element omitted.
/// The plot's drawn extent, measured from the offsets above: text reaches
/// ±9.6pt horizontally and the staff ~11pt above the centre.
private let stationPlotSize = CGSize(width: 19, height: 20)

private func drawStationModel(_ st: StormFeed.Station, at p: CGPoint) {
    guard let ctx = UIGraphicsGetCurrentContext() else { return }
    let r: CGFloat = 2.8
    // Every figure in the plot carries the temperature, so the field reads as
    // colour before it reads as digits. Sky cover is still the fill fraction,
    // and dew point and pressure are still told apart by their position — the
    // station model's own convention — rather than by colour.
    let tint = tempColor(st.tempF)
    ctx.setShadow(offset: .zero, blur: 2.2, color: UIColor.black.withAlphaComponent(0.9).cgColor)

    // Sky cover: the circle is filled in proportion to the reported coverage.
    let ring = UIBezierPath(arcCenter: p, radius: r, startAngle: 0, endAngle: .pi * 2, clockwise: true)
    UIColor.black.withAlphaComponent(0.55).setFill()
    ring.fill()
    let sky = (st.sky ?? "").uppercased()
    let fraction: CGFloat
    switch sky {
    case "CLR", "SKC", "NSC": fraction = 0
    case "FEW":               fraction = 0.25
    case "SCT":               fraction = 0.5
    case "BKN":               fraction = 0.75
    case "OVC":               fraction = 1
    default:                  fraction = -1      // VV — obscured
    }
    tint.setStroke()
    ring.lineWidth = 0.9
    ring.stroke()
    if fraction > 0 {
        let wedge = UIBezierPath()
        wedge.move(to: p)
        wedge.addArc(withCenter: p, radius: r,
                     startAngle: -.pi / 2, endAngle: -.pi / 2 + .pi * 2 * fraction, clockwise: true)
        wedge.close()
        tint.setFill()
        wedge.fill()
    } else if fraction < 0 {
        let x = UIBezierPath()
        x.move(to: CGPoint(x: p.x - r * 0.7, y: p.y - r * 0.7))
        x.addLine(to: CGPoint(x: p.x + r * 0.7, y: p.y + r * 0.7))
        x.move(to: CGPoint(x: p.x + r * 0.7, y: p.y - r * 0.7))
        x.addLine(to: CGPoint(x: p.x - r * 0.7, y: p.y + r * 0.7))
        x.lineWidth = 1.2
        tint.setStroke()
        x.stroke()
    }

    // Wind barb. Meteorological convention: the staff points towards the
    // direction the wind is coming from, and in the northern hemisphere the
    // barbs sit on its left when sighted from the station outward — which is
    // -x here, with the staff drawn up the -y axis before rotation.
    if let kt = st.windKt, let dir = st.windDir, kt >= 3 {
        ctx.saveGState()
        // The barbs already carry the speed, so the colour is free to carry the
        // temperature — which makes the field readable at a glance from the
        // barbs alone, rather than from 6pt digits.
        let wind = tint
        ctx.translateBy(x: p.x, y: p.y)
        ctx.rotate(by: CGFloat(dir) * .pi / 180)
        let staff = UIBezierPath()
        staff.move(to: CGPoint(x: 0, y: -r))
        staff.addLine(to: CGPoint(x: 0, y: -r - 8))
        staff.lineWidth = 1.0
        wind.setStroke()
        staff.stroke()

        var speed = Int((kt / 5).rounded() * 5)
        var y: CGFloat = -r - 8             // barbs start at the far end of the staff
        let step: CGFloat = 2.2, len: CGFloat = 4.6
        let flags = speed / 50; speed -= flags * 50
        let tens  = speed / 10; speed -= tens * 10
        let fives = speed / 5
        for _ in 0..<flags {
            let t = UIBezierPath()
            t.move(to: CGPoint(x: 0, y: y))
            t.addLine(to: CGPoint(x: -len, y: y + step * 0.5))
            t.addLine(to: CGPoint(x: 0, y: y + step))
            t.close()
            wind.setFill(); t.fill()
            y += step + 1.5
        }
        for _ in 0..<tens {
            let b = UIBezierPath()
            b.move(to: CGPoint(x: 0, y: y))
            b.addLine(to: CGPoint(x: -len, y: y + step * 0.7))
            b.lineWidth = 1.1
            wind.setStroke(); b.stroke()
            y += step
        }
        for _ in 0..<fives {
            // A lone half-barb sits in from the end, not on it.
            let off: CGFloat = (tens == 0 && flags == 0) ? step : 0
            let b = UIBezierPath()
            b.move(to: CGPoint(x: 0, y: y + off))
            b.addLine(to: CGPoint(x: -len * 0.5, y: y + off + step * 0.35))
            b.lineWidth = 1.3
            wind.setStroke(); b.stroke()
            y += step
        }
        ctx.restoreGState()
    }

    func label(_ text: String, _ color: UIColor, _ at: CGPoint, size: CGFloat = 6) {
        let ns = text as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: size, weight: .bold),
            .foregroundColor: color,
            .strokeColor: UIColor.black, .strokeWidth: -3.0,
        ]
        let sz = ns.size(withAttributes: attrs)
        ns.draw(at: CGPoint(x: at.x - sz.width / 2, y: at.y - sz.height / 2), withAttributes: attrs)
    }

    label("\(Int(st.tempF.rounded()))", tint, CGPoint(x: p.x - 6.5, y: p.y - 5))
    if let d = st.dewF {
        label("\(Int(d.rounded()))", tint,
              CGPoint(x: p.x - 6.5, y: p.y + 5))
    }
    if let mb = st.mslp {
        // The standard three-digit code: tenths of a millibar, hundreds dropped.
        let code = String(format: "%03d", Int((mb * 10).rounded()) % 1000)
        label(code, tint, CGPoint(x: p.x + 6.5, y: p.y - 5))
    }
    if let wx = st.wx, !wx.isEmpty {
        let short = wx.count > 5 ? String(wx.prefix(5)) : wx
        label(short, tint,
              CGPoint(x: p.x - 9, y: p.y), size: 5.5)
    }
}

enum RadarSnapshot {
    /// A dark basemap for the region, with radar drawn over it. The watched
    /// point frames the view but is not marked — the picture is the subject,
    /// not the pin. Returns nil only if the map itself fails; a clear sky
    /// still yields a usable map, with `hasEcho` false.
    @MainActor
    static func compose(lat: Double, lon: Double, zoom: RadarZoom, size: CGSize,
                        showReports: Bool, showTemps: Bool, showAlerts: Bool,
                        showDiscussion: Bool,
                        showOutlook: Bool, showFronts: Bool, stationModel: Bool,
                        showIsobars: Bool, showMarine: Bool, showLake: Bool,
                        state: String?) async -> (image: UIImage, hasEcho: Bool)? {
        let half = zoom.halfDegrees

        // Framed as a projected rect, not a coordinate span. A degree of
        // longitude covers less ground than a degree of latitude, by cos(lat),
        // so a span whose deltas are in the widget's width:height ratio is not
        // the widget's shape on screen — at 43°N it asks for something 1.37x
        // too tall. MKMapSnapshotter answers by widening the region to fit,
        // which left the radar covering only ~73% of the width with bare
        // basemap either side. Map points are Mercator and linear in screen
        // space, so a rect in the widget's exact proportions stays that shape.
        let centre = MKMapPoint(CLLocationCoordinate2D(latitude: lat, longitude: lon))
        let pointsPerDegreeLon = MKMapSize.world.width / 360
        let rectW = half * 2 * pointsPerDegreeLon
        let rectH = rectW * (size.height / max(size.width, 1))
        let mapRect = MKMapRect(x: centre.x - rectW / 2, y: centre.y - rectH / 2,
                                width: rectW, height: rectH)

        let opts = MKMapSnapshotter.Options()
        opts.mapRect = mapRect
        opts.size = size
        opts.mapType = .mutedStandard
        opts.pointOfInterestFilter = .excludingAll
        opts.showsBuildings = false
        opts.traitCollection = UITraitCollection(userInterfaceStyle: .dark)

        guard let snap = try? await MKMapSnapshotter(options: opts).start() else { return nil }

        // The rect is already the snapshot's exact footprint, so radar is asked
        // for precisely the ground under the image and fills it corner to corner.
        // In map points y increases southward, so maxY is the southern edge.
        let sw = MKMapPoint(x: mapRect.minX, y: mapRect.maxY).coordinate
        let ne = MKMapPoint(x: mapRect.maxX, y: mapRect.minY).coordinate
        // Height follows from the box's aspect, so the returned extent is the
        // box asked for rather than one ArcGIS has reshaped.
        let render = await StormFeed.radarImage(sw: sw, ne: ne, pixelsWide: Int(size.width * 2))
        let reports = showReports ? await StormFeed.recentReports(sw: sw, ne: ne) : []
        // Both temperatures and the alert query are scoped by the states in
        // view, so resolve the list once and share it.
        let wantTemps = showTemps && zoom.showsTemperatures
        var states: [String] = []
        if wantTemps || showAlerts {
            // A table lookup now, so it costs nothing to ask for every state the
            // view touches — capped only to bound the station fetches that follow.
            states = Array(StormFeed.statesCovering(sw: sw, ne: ne, fallback: state)
                .prefix(zoom.maxStates))
        }
        let temps: [StormFeed.Station] = wantTemps
            ? await StormFeed.stations(states: states, sw: sw, ne: ne) : []
        // Marine areas go in alongside the states, or warnings over water — a
        // gale on the lakes, say — never appear at all.
        let alertAreas = showAlerts
            ? states + (showMarine ? StormFeed.marineCovering(sw: sw, ne: ne) : []) : []
        let alerts = showAlerts
            ? await StormFeed.alerts(states: alertAreas, sw: sw, ne: ne, marine: showMarine) : []
        let afd = showDiscussion ? await StormFeed.afdAreas(sw: sw, ne: ne) : []
        let outlook = showOutlook ? await MapLayers.outlook(sw: sw, ne: ne) : []
        let mcds = showOutlook ? await MapLayers.mesoscaleDiscussions(sw: sw, ne: ne) : []
        let sfc = showFronts ? await MapLayers.surface() : nil
        let isobars = showIsobars ? await MapLayers.isobars(sw: sw, ne: ne) : []
        let lake = showLake ? await StormFeed.lakeTemps(sw: sw, ne: ne) : []

        let out = UIGraphicsImageRenderer(size: size).image { ctx in
            snap.image.draw(at: .zero)

            // The SPC outlook is the broadest context on the map, so it sits
            // furthest back. Fill stays very light because the risk areas nest
            // and their opacity would otherwise compound.
            for o in outlook {
                for ring in o.rings {
                    let path = ringPath(ring, snap)
                    o.fill.withAlphaComponent(0.16).setFill()
                    path.fill()
                    o.stroke.setStroke()
                    path.lineWidth = 2
                    path.stroke()
                }
            }

            // Mesoscale discussions: short-fuse "something is developing here".
            for m in mcds {
                for ring in m.rings {
                    let path = ringPath(ring, snap)
                    UIColor(red: 0.95, green: 0.72, blue: 0.02, alpha: 0.07).setFill()
                    path.fill()
                    UIColor(red: 0.95, green: 0.72, blue: 0.02, alpha: 1).setStroke()
                    path.lineWidth = 2
                    path.setLineDash([4, 3], count: 2, phase: 0)
                    path.stroke()
                }
            }

            // Warnings sit under the radar, as they do on the dashboard.
            for a in alerts {
                for ring in a.rings {
                    let path = UIBezierPath()
                    for (i, c) in ring.enumerated() {
                        let p = snap.point(for: c)
                        i == 0 ? path.move(to: p) : path.addLine(to: p)
                    }
                    path.close()
                    // Marine zones are drawn as outlines. A gale covers the open
                    // water zone by zone, so filling them paints over the lake
                    // and whatever radar is on it; the boundary is the useful
                    // part, and a land warning should still read as the louder
                    // thing on the map.
                    if a.isMarine {
                        a.color.withAlphaComponent(0.06).setFill()
                        path.fill()
                        a.color.withAlphaComponent(0.85).setStroke()
                        path.lineWidth = 1
                        if a.isWatch { path.setLineDash([5, 4], count: 2, phase: 0) }
                    } else {
                        a.color.withAlphaComponent(a.isWatch ? 0.10 : 0.22).setFill()
                        path.fill()
                        a.color.setStroke()
                        path.lineWidth = a.isWatch ? 1.5 : 2.5
                        if a.isWatch { path.setLineDash([6, 4], count: 2, phase: 0) }
                    }
                    path.stroke()
                }
            }

            if let d = render?.data, render?.hasEcho == true, let radar = UIImage(data: d) {
                let p0 = snap.point(for: sw), p1 = snap.point(for: ne)
                let rect = CGRect(x: min(p0.x, p1.x), y: min(p0.y, p1.y),
                                  width: abs(p1.x - p0.x), height: abs(p1.y - p0.y))
                radar.draw(in: rect, blendMode: .normal, alpha: 0.75)
            }

            // Isobars sit under the fronts: they are the background field the
            // fronts are drawn on, and a front should read over the top of them.
            for iso in isobars {
                let path = UIBezierPath()
                for seg in iso.segments {
                    guard seg.count >= 2 else { continue }
                    path.move(to: snap.point(for: seg[0]))
                    for c in seg.dropFirst() { path.addLine(to: snap.point(for: c)) }
                }
                path.lineWidth = 1
                UIColor(red: 0.87, green: 0.90, blue: 0.94, alpha: 0.55).setStroke()
                path.stroke()
                // Label the level once per contour, on a segment well inside the
                // frame so the number is not clipped.
                // Label along the line, not once per contour. Most of a contour
                // now lies in the padded area off screen, so a single label
                // picked from the first segment usually fell outside the frame
                // and the value was never visible.
                let onScreen = iso.segments.compactMap { seg -> CGPoint? in
                    guard seg.count >= 2 else { return nil }
                    let a = snap.point(for: seg[0]), b = snap.point(for: seg[1])
                    let m = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
                    return (m.x > 18 && m.y > 12 && m.x < size.width - 18 && m.y < size.height - 12) ? m : nil
                }
                let every = max(1, onScreen.count / 2)
                for (i, mark) in onScreen.enumerated() where i % every == 0 {
                    let text = "\(iso.millibars)" as NSString
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: UIFont.monospacedDigitSystemFont(ofSize: 7, weight: .semibold),
                        .foregroundColor: UIColor(red: 0.87, green: 0.90, blue: 0.94, alpha: 0.95),
                        .strokeColor: UIColor.black, .strokeWidth: -3.0,
                    ]
                    let sz = text.size(withAttributes: attrs)
                    text.draw(at: CGPoint(x: mark.x - sz.width / 2, y: mark.y - sz.height / 2),
                              withAttributes: attrs)
                }
            }

            // Surface analysis: fronts with their pips, and pressure centres.
            if let sfc {
                for f in sfc.fronts {
                    let pts = f.points.map { snap.point(for: $0) }
                    guard pts.count >= 2, pts.contains(where: { inFrame($0, size) }) else { continue }
                    let style = frontStyle(f.kind)
                    let line = UIBezierPath()
                    line.move(to: pts[0])
                    for p in pts.dropFirst() { line.addLine(to: p) }
                    line.lineWidth = style.weight
                    line.lineJoinStyle = .round
                    style.color.setStroke()
                    if let dash = style.dash { line.setLineDash(dash, count: dash.count, phase: 0) }
                    line.stroke()
                    // A stationary front is blue one way and red the other;
                    // a red dash laid over the blue line gives that in one pass.
                    if f.kind == .STNRY {
                        let over = line.copy() as! UIBezierPath
                        UIColor(red: 0.88, green: 0.02, blue: 0, alpha: 1).setStroke()
                        over.setLineDash([10, 10], count: 2, phase: 0)
                        over.stroke()
                    }
                    guard let pip = style.pip else { continue }
                    for (i, m) in pipMarks(pts, every: 30).enumerated() where inFrame(m.at, size) {
                        var shape = pip
                        var color = style.color
                        var flip = false
                        if pip == .alternating {
                            // Stationary: cold pips one side, warm the other.
                            shape = i % 2 == 1 ? .arc : .triangle
                            color = i % 2 == 1 ? UIColor(red: 0.88, green: 0.02, blue: 0, alpha: 1)
                                               : UIColor(red: 0.23, green: 0.63, blue: 1, alpha: 1)
                            flip = i % 2 == 1
                        } else if pip == .both {
                            // Occluded: both symbols, same side.
                            shape = i % 2 == 1 ? .arc : .triangle
                        }
                        drawPip(at: m.at, angle: m.angle, shape: shape, color: color, flip: flip)
                    }
                }
                for c in sfc.centers {
                    let p = snap.point(for: c.point)
                    guard inFrame(p, size) else { continue }
                    let isH = c.isHigh
                    let color = isH ? UIColor(red: 0.23, green: 0.44, blue: 0.88, alpha: 1)
                                    : UIColor(red: 0.88, green: 0.02, blue: 0, alpha: 1)
                    let letter = (isH ? "H" : "L") as NSString
                    let lAttrs: [NSAttributedString.Key: Any] = [
                        .font: UIFont.systemFont(ofSize: 19, weight: .heavy),
                        .foregroundColor: color,
                        .strokeColor: UIColor.black, .strokeWidth: -3.0,
                    ]
                    let lz = letter.size(withAttributes: lAttrs)
                    letter.draw(at: CGPoint(x: p.x - lz.width / 2, y: p.y - lz.height / 2),
                                withAttributes: lAttrs)
                    let mb = "\(c.millibars)" as NSString
                    let mAttrs: [NSAttributedString.Key: Any] = [
                        .font: UIFont.monospacedDigitSystemFont(ofSize: 8, weight: .bold),
                        .foregroundColor: UIColor.white.withAlphaComponent(0.85),
                        .strokeColor: UIColor.black, .strokeWidth: -3.0,
                    ]
                    let mz = mb.size(withAttributes: mAttrs)
                    mb.draw(at: CGPoint(x: p.x - mz.width / 2, y: p.y + lz.height / 2 - 2),
                            withAttributes: mAttrs)
                }
            }

            var afdLabels: [(bounds: CGRect, label: String, when: String, color: UIColor)] = []
            // Forecast-discussion areas sit above the radar, since the point is
            // the forecaster's outline against the echoes it refers to. Live
            // areas are solid, ones still ahead of their window are dashed —
            // the same distinction the dashboard draws.
            for a in afd {
                let path = UIBezierPath()
                for (i, c) in a.ring.enumerated() {
                    let p = snap.point(for: c)
                    i == 0 ? path.move(to: p) : path.addLine(to: p)
                }
                path.close()
                a.color.withAlphaComponent(a.live ? 0.12 : 0.06).setFill()
                path.fill()
                a.color.setStroke()
                path.lineWidth = a.live ? 2.0 : 1.4
                if !a.live { path.setLineDash([7, 5], count: 2, phase: 0) }
                path.stroke()

                // The outline belongs here in the stack, but its text does not:
                // it is the one label that has to survive whatever is drawn over
                // the area, so it is held back and painted last.
                let bounds = path.bounds
                guard bounds.width > 44, bounds.height > 22, !a.label.isEmpty else { continue }
                afdLabels.append((bounds, a.label, a.when, a.color))
            }

            // Every report keeps its dot; the labels are packed. On a busy day
            // in the Plains 52 reports landed in one state-zoom view and 88% of
            // the labels overlapped another, which reads as a smear rather than
            // as data. Reports arrive worst-first, so what survives a contest is
            // the tornado rather than whichever gust happened to be drawn last.
            var labelBoxes: [CGRect] = []
            for r in reports {
                let p = snap.point(for: CLLocationCoordinate2D(latitude: r.lat, longitude: r.lon))
                guard size.width > 0, p.x.isFinite, p.y.isFinite else { continue }
                let dot = CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)
                ctx.cgContext.setFillColor(r.color.cgColor)
                ctx.cgContext.setStrokeColor(UIColor.black.withAlphaComponent(0.8).cgColor)
                ctx.cgContext.setLineWidth(1)
                ctx.cgContext.addEllipse(in: dot)
                ctx.cgContext.drawPath(using: .fillStroke)

                guard !r.label.isEmpty, p.x > 2, p.y > 8, p.y < size.height - 8 else { continue }
                let text = r.label as NSString
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.monospacedDigitSystemFont(ofSize: 7, weight: .bold),
                    .foregroundColor: r.color,
                    .strokeColor: UIColor.black, .strokeWidth: -3.0,
                ]
                let sz = text.size(withAttributes: attrs)
                let x = min(p.x + 5, size.width - sz.width - 1)
                let box = CGRect(x: x - 1, y: p.y - sz.height / 2 - 1,
                                 width: sz.width + 2, height: sz.height + 2)
                // Clear of other labels, and of the dots themselves, so a number
                // never sits on top of another report's marker.
                if labelBoxes.contains(where: { $0.intersects(box) }) { continue }
                labelBoxes.append(box)
                text.draw(at: CGPoint(x: x, y: p.y - sz.height / 2), withAttributes: attrs)
            }

            // Temperatures, thinned in screen space so the labels stay readable —
            // the same trick the dashboard uses for its station layer.
            var claimed = Set<Int64>()
            var placed: [CGRect] = []      // station-model footprints already drawn
            // Tighter than the dashboard's 40px, because a widget is read closer
            // and a sparse scatter of numbers looks like missing data. Widens
            // with the view, where stations crowd together on screen.
            let cell: CGFloat = stationModel ? zoom.labelSpacing * 1.5 : zoom.labelSpacing
            // Water readings first, and into the same claimed-cell grid as the
            // land temperatures, so a buoy just offshore and a station on the
            // beach cannot print over each other.
            for w in lake {
                let p = snap.point(for: CLLocationCoordinate2D(latitude: w.lat, longitude: w.lon))
                guard p.x > 0, p.y > 0, p.x < size.width, p.y < size.height else { continue }
                let key = Int64(p.x / cell) &* 1000 &+ Int64(p.y / cell)
                if claimed.contains(key) { continue }
                // A wave marks it as water. The colour is the same ramp as the
                // air temperatures, so a number means the same thing either way.
                var label = "\u{2248}\(Int(w.waterF.rounded()))"
                if let air = w.airF, w.waterF - air >= 4 { label += " +\(Int((w.waterF - air).rounded()))" }
                let text = label as NSString
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold),
                    .foregroundColor: tempColor(w.waterF),
                    .strokeColor: UIColor.black, .strokeWidth: -3.0,
                ]
                let sz = text.size(withAttributes: attrs)
                let x = min(max(p.x - sz.width / 2, 1), size.width - sz.width - 1)
                let y = min(max(p.y - sz.height / 2, 1), size.height - sz.height - 1)
                claimed.insert(key)
                text.draw(at: CGPoint(x: x, y: y), withAttributes: attrs)
            }

            for st in temps {
                let p = snap.point(for: CLLocationCoordinate2D(latitude: st.lat, longitude: st.lon))
                guard p.x > 0, p.y > 0, p.x < size.width, p.y < size.height else { continue }
                let key = Int64(p.x / cell) &* 1000 &+ Int64(p.y / cell)
                if !stationModel && claimed.contains(key) { continue }
                if stationModel {
                    // The plot needs room on every side, so keep it clear of the
                    // frame rather than nudging it inwards like a bare number.
                    guard p.x > 11, p.y > 12, p.x < size.width - 11, p.y < size.height - 12
                    else { continue }
                    // Packed against what is already drawn rather than bucketed
                    // into a grid. A grid reserves a whole cell for a plot sitting
                    // anywhere inside it, so a station near a corner blocks the
                    // space its neighbour could have used; testing the actual
                    // footprint fits appreciably more in without overlap.
                    let rect = CGRect(x: p.x - stationPlotSize.width / 2 - 1,
                                      y: p.y - stationPlotSize.height / 2 - 1,
                                      width: stationPlotSize.width + 2,
                                      height: stationPlotSize.height + 2)
                    if placed.contains(where: { $0.intersects(rect) }) { continue }
                    placed.append(rect)
                    drawStationModel(st, at: p)
                    continue
                }
                let text = "\(Int(st.tempF.rounded()))" as NSString
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold),
                    .foregroundColor: tempColor(st.tempF),
                    .strokeColor: UIColor.black, .strokeWidth: -3.0,
                ]
                // Nudged inside the frame rather than dropped, so a station near
                // the edge still shows its value instead of half a digit. Sub-zero
                // and three-digit readings are wider, so measure rather than guess.
                let sz = text.size(withAttributes: attrs)
                let x = min(max(p.x - sz.width / 2, 1), size.width - sz.width - 1)
                let y = min(max(p.y - sz.height / 2, 1), size.height - sz.height - 1)
                claimed.insert(key)
                text.draw(at: CGPoint(x: x, y: y), withAttributes: attrs)
            }

            // Discussion text last, over everything: the hazard over the window
            // it applies to, as two centred lines in the middle of the outline.
            // The window line is dropped before the hazard when only one fits.
            for l in afdLabels {
                let text = l.label.uppercased() as NSString
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 6.5, weight: .heavy),
                    .foregroundColor: l.color,
                    .strokeColor: UIColor.black, .strokeWidth: -3.0,
                ]
                let whenAttrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 5.5, weight: .bold),
                    .foregroundColor: UIColor.white.withAlphaComponent(0.92),
                    .strokeColor: UIColor.black, .strokeWidth: -3.0,
                ]
                let sz = text.size(withAttributes: attrs)
                let when = l.when.isEmpty ? nil : l.when as NSString
                let wz = when?.size(withAttributes: whenAttrs) ?? .zero
                let gap: CGFloat = 1
                let showWhen = when != nil && l.bounds.height > sz.height + wz.height + gap + 8
                let block = showWhen ? sz.height + gap + wz.height : sz.height
                let top = l.bounds.midY - block / 2
                let at = CGPoint(x: l.bounds.midX - sz.width / 2, y: top)
                guard at.x > 2, at.x + sz.width < size.width - 2, at.y > 2 else { continue }
                text.draw(at: at, withAttributes: attrs)
                if showWhen, let when {
                    when.draw(at: CGPoint(x: l.bounds.midX - wz.width / 2,
                                          y: top + sz.height + gap),
                              withAttributes: whenAttrs)
                }
            }
        }
        return (out, render?.hasEcho ?? false)
    }
}
