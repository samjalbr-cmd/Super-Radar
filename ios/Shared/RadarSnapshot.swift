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
    /// Station temperatures are only legible while the view is reasonably tight;
    /// past that they become a wall of overlapping numbers.
    var showsTemperatures: Bool { self != .multi }
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

enum RadarSnapshot {
    /// A dark basemap for the region, with radar drawn over it and a marker at
    /// the watched point. Returns nil only if the map itself fails; a clear sky
    /// still yields a usable map, with `hasEcho` false.
    @MainActor
    static func compose(lat: Double, lon: Double, zoom: RadarZoom, size: CGSize,
                        showReports: Bool, showTemps: Bool, showAlerts: Bool,
                        showTracks: Bool, showDiscussion: Bool,
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
        let px = Int(max(size.width, size.height) * 2)
        let render = await StormFeed.radarImage(sw: sw, ne: ne, pixels: px)
        let reports = showReports ? await StormFeed.recentReports(sw: sw, ne: ne) : []
        // Both temperatures and the alert query are scoped by the states in
        // view, so resolve the list once and share it.
        let wantTemps = showTemps && zoom.showsTemperatures
        var states: [String] = []
        if wantTemps || showAlerts {
            states = await StormFeed.statesCovering(sw: sw, ne: ne, fallback: state)
        }
        let temps: [StormFeed.Station] = wantTemps
            ? await StormFeed.stations(states: states, sw: sw, ne: ne) : []
        let alerts = showAlerts ? await StormFeed.alerts(states: states, sw: sw, ne: ne) : []
        let afd = showDiscussion ? await StormFeed.afdAreas(sw: sw, ne: ne) : []
        let cells: [StormCell] = showTracks ? ((try? await StormFeed.cells()) ?? []) : []

        let out = UIGraphicsImageRenderer(size: size).image { ctx in
            snap.image.draw(at: .zero)

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
            // and a sparse scatter of numbers looks like missing data.
            let cell: CGFloat = 26
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
