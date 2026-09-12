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
private func tempColor(_ f: Double) -> UIColor {
    switch f {
    case 105...: return UIColor(red: 1.00, green: 0.00, blue: 0.00, alpha: 1)
    case 95..<105: return UIColor(red: 1.00, green: 0.40, blue: 0.00, alpha: 1)
    case 85..<95:  return UIColor(red: 1.00, green: 0.60, blue: 0.00, alpha: 1)
    case 75..<85:  return UIColor(red: 1.00, green: 0.90, blue: 0.00, alpha: 1)
    case 65..<75:  return UIColor(red: 0.60, green: 1.00, blue: 0.20, alpha: 1)
    case 55..<65:  return UIColor(red: 0.20, green: 0.90, blue: 0.20, alpha: 1)
    case 45..<55:  return UIColor(red: 0.00, green: 0.80, blue: 0.80, alpha: 1)
    case 35..<45:  return UIColor(red: 0.00, green: 0.60, blue: 1.00, alpha: 1)
    case 25..<35:  return UIColor(red: 0.20, green: 0.40, blue: 1.00, alpha: 1)
    case 15..<25:  return UIColor(red: 0.40, green: 0.20, blue: 0.60, alpha: 1)
    default:       return UIColor(red: 0.50, green: 0.00, blue: 0.50, alpha: 1)
    }
}

/// Which side of a front its symbols go on. WPC digitises fronts so the left of
/// the direction of travel is the leading edge, matching the dashboard.
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
private func drawPip(at p: CGPoint, angle: CGFloat, shape: PipShape, color: UIColor) {
    guard let ctx = UIGraphicsGetCurrentContext() else { return }
    ctx.saveGState()
    ctx.translateBy(x: p.x, y: p.y)
    ctx.rotate(by: angle + (pipOnLeft ? .pi : 0))
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

enum RadarSnapshot {
    /// A dark basemap for the region, with radar drawn over it and a marker at
    /// the watched point. Returns nil only if the map itself fails; a clear sky
    /// still yields a usable map, with `hasEcho` false.
    @MainActor
    static func compose(lat: Double, lon: Double, zoom: RadarZoom, size: CGSize,
                        showReports: Bool, showTemps: Bool, showAlerts: Bool,
                        showTracks: Bool, showDiscussion: Bool,
                        showOutlook: Bool, showFronts: Bool,
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
        let alerts = showAlerts ? await StormFeed.alerts(states: states, sw: sw, ne: ne) : []
        let afd = showDiscussion ? await StormFeed.afdAreas(sw: sw, ne: ne) : []
        let outlook = showOutlook ? await MapLayers.outlook(sw: sw, ne: ne) : []
        let mcds = showOutlook ? await MapLayers.mesoscaleDiscussions(sw: sw, ne: ne) : []
        let sfc = showFronts ? await MapLayers.surface() : nil
        let cells: [StormCell] = showTracks ? ((try? await StormFeed.cells()) ?? []) : []

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
                    a.color.withAlphaComponent(a.isWatch ? 0.10 : 0.22).setFill()
                    path.fill()
                    a.color.setStroke()
                    path.lineWidth = a.isWatch ? 1.5 : 2.5
                    if a.isWatch { path.setLineDash([6, 4], count: 2, phase: 0) }
                    path.stroke()
                }
            }

            if let d = render?.data, render?.hasEcho == true, let radar = UIImage(data: d) {
                let p0 = snap.point(for: sw), p1 = snap.point(for: ne)
                let rect = CGRect(x: min(p0.x, p1.x), y: min(p0.y, p1.y),
                                  width: abs(p1.x - p0.x), height: abs(p1.y - p0.y))
                radar.draw(in: rect, blendMode: .normal, alpha: 0.75)
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
                        if pip == .alternating {
                            shape = i % 2 == 1 ? .arc : .triangle
                            color = i % 2 == 1 ? UIColor(red: 0.88, green: 0.02, blue: 0, alpha: 1)
                                               : UIColor(red: 0.23, green: 0.63, blue: 1, alpha: 1)
                        } else if pip == .both {
                            shape = i % 2 == 1 ? .arc : .triangle
                        }
                        drawPip(at: m.at, angle: m.angle, shape: shape, color: color)
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

                // Label the area at the top of its outline, where the dashboard
                // puts it. Skipped when the shape is too small to read.
                let bounds = path.bounds
                guard bounds.width > 54, bounds.height > 26, !a.label.isEmpty else { continue }
                let text = a.label.uppercased() as NSString
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 8, weight: .heavy),
                    .foregroundColor: a.color,
                    .strokeColor: UIColor.black, .strokeWidth: -3.0,
                ]
                let sz = text.size(withAttributes: attrs)
                let at = CGPoint(x: bounds.midX - sz.width / 2,
                                 y: bounds.minY + bounds.height * 0.12)
                if at.x > 2, at.x + sz.width < size.width - 2, at.y > 2 {
                    text.draw(at: at, withAttributes: attrs)
                }
            }

            for r in reports {
                let p = snap.point(for: CLLocationCoordinate2D(latitude: r.lat, longitude: r.lon))
                guard size.width > 0, p.x.isFinite, p.y.isFinite else { continue }
                let dot = CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)
                ctx.cgContext.setFillColor(r.color.cgColor)
                ctx.cgContext.setStrokeColor(UIColor.black.withAlphaComponent(0.8).cgColor)
                ctx.cgContext.setLineWidth(1)
                ctx.cgContext.addEllipse(in: dot)
                ctx.cgContext.drawPath(using: .fillStroke)
            }

            // Projected cell tracks, over the radar as on the dashboard.
            for cell in cells where cell.notable && cell.speedKt >= 5 {
                guard cell.lat >= sw.latitude, cell.lat <= ne.latitude,
                      cell.lon >= sw.longitude, cell.lon <= ne.longitude else { continue }
                let color: UIColor = cell.tvs ? UIColor(red: 1, green: 0.23, blue: 0.96, alpha: 1)
                          : cell.meso ? UIColor(red: 0.88, green: 0.02, blue: 0, alpha: 1)
                          : (cell.hailInches >= 1 || cell.posh >= 50)
                            ? UIColor(red: 1, green: 0.48, blue: 0, alpha: 1)
                            : UIColor(red: 1.0, green: 0.83, blue: 0, alpha: 1)
                let start = snap.point(for: CLLocationCoordinate2D(latitude: cell.lat, longitude: cell.lon))
                let nm = cell.speedKt          // one hour ahead
                let r = cell.heading * .pi / 180
                let dLat = (nm / 60) * cos(r)
                let dLon = (nm / 60) * sin(r) / cos(cell.lat * .pi / 180)
                let end = snap.point(for: CLLocationCoordinate2D(latitude: cell.lat + dLat, longitude: cell.lon + dLon))
                let track = UIBezierPath()
                track.move(to: start); track.addLine(to: end)
                color.setStroke()
                track.lineWidth = 1.6
                track.setLineDash([5, 4], count: 2, phase: 0)
                track.stroke()
                // The cell itself, as a diamond like the dashboard uses.
                let d = UIBezierPath()
                d.move(to: CGPoint(x: start.x, y: start.y - 4))
                d.addLine(to: CGPoint(x: start.x + 4, y: start.y))
                d.addLine(to: CGPoint(x: start.x, y: start.y + 4))
                d.addLine(to: CGPoint(x: start.x - 4, y: start.y))
                d.close()
                color.setStroke(); d.lineWidth = 1.8; d.setLineDash([], count: 0, phase: 0); d.stroke()
            }

            // Temperatures, thinned in screen space so the labels stay readable —
            // the same trick the dashboard uses for its station layer.
            var claimed = Set<Int64>()
            // Tighter than the dashboard's 40px, because a widget is read closer
            // and a sparse scatter of numbers looks like missing data. Widens
            // with the view, where stations crowd together on screen.
            let cell: CGFloat = zoom.labelSpacing
            for st in temps {
                let p = snap.point(for: CLLocationCoordinate2D(latitude: st.lat, longitude: st.lon))
                guard p.x > 0, p.y > 0, p.x < size.width, p.y < size.height else { continue }
                let key = Int64(p.x / cell) &* 1000 &+ Int64(p.y / cell)
                if claimed.contains(key) { continue }
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

            // The watched point, so the picture has an anchor.
            let c = snap.point(for: CLLocationCoordinate2D(latitude: lat, longitude: lon))
            let ring = CGRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10)
            ctx.cgContext.setFillColor(UIColor(red: 0.95, green: 0.72, blue: 0.02, alpha: 1).cgColor)
            ctx.cgContext.setStrokeColor(UIColor.black.cgColor)
            ctx.cgContext.setLineWidth(1.5)
            ctx.cgContext.addEllipse(in: ring)
            ctx.cgContext.drawPath(using: .fillStroke)
        }
        return (out, render?.hasEcho ?? false)
    }
}
