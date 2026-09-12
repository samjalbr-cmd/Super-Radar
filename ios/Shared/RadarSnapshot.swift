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
                        showTracks: Bool, state: String?) async -> (image: UIImage, hasEcho: Bool)? {
        let half = zoom.halfDegrees
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: lat, longitude: lon),
            span: MKCoordinateSpan(latitudeDelta: half * 2 * (size.height / max(size.width, 1)),
                                   longitudeDelta: half * 2))

        let opts = MKMapSnapshotter.Options()
        opts.region = region
        opts.size = size
        opts.mapType = .mutedStandard
        opts.pointOfInterestFilter = .excludingAll
        opts.showsBuildings = false
        opts.traitCollection = UITraitCollection(userInterfaceStyle: .dark)

        guard let snap = try? await MKMapSnapshotter(options: opts).start() else { return nil }

        // Ask for radar over exactly the ground the snapshot ended up covering —
        // MapKit adjusts the requested span to fit the aspect ratio, so using the
        // requested region would misregister the overlay.
        let sw = CLLocationCoordinate2D(latitude: region.center.latitude - region.span.latitudeDelta / 2,
                                        longitude: region.center.longitude - region.span.longitudeDelta / 2)
        let ne = CLLocationCoordinate2D(latitude: region.center.latitude + region.span.latitudeDelta / 2,
                                        longitude: region.center.longitude + region.span.longitudeDelta / 2)
        let px = Int(max(size.width, size.height) * 2)
        let render = await StormFeed.radarImage(sw: sw, ne: ne, pixels: px)
        let reports = showReports ? await StormFeed.recentReports(sw: sw, ne: ne) : []
        let temps: [StormFeed.Station] = (showTemps && zoom.showsTemperatures)
            ? await StormFeed.stations(state: state, sw: sw, ne: ne) : []
        let alerts = showAlerts ? await StormFeed.alerts(sw: sw, ne: ne) : []
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
            let cell: CGFloat = 34
            for st in temps {
                let p = snap.point(for: CLLocationCoordinate2D(latitude: st.lat, longitude: st.lon))
                guard p.x > 4, p.y > 4, p.x < size.width - 4, p.y < size.height - 4 else { continue }
                let key = Int64(p.x / cell) &* 1000 &+ Int64(p.y / cell)
                if claimed.contains(key) { continue }
                claimed.insert(key)
                let text = "\(Int(st.tempF.rounded()))" as NSString
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold),
                    .foregroundColor: tempColor(st.tempF),
                    .strokeColor: UIColor.black, .strokeWidth: -3.0,
                ]
                text.draw(at: CGPoint(x: p.x - 7, y: p.y - 6), withAttributes: attrs)
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
