import Foundation
import MapKit
import UIKit

/// How much ground a widget covers. Radar without a basemap has no geographic
/// context — it was the missing half of the picture — so the map is rendered by
/// MapKit and the radar composited on top of it, aligned by projecting the
/// region's own corners rather than trusting two services to agree.
enum RadarZoom: String, CaseIterable, Codable, Sendable {
    case metro, county, region, state

    /// Half-width in degrees of longitude.
    var halfDegrees: Double {
        switch self {
        case .metro:  return 0.35   // ~ 60 km across
        case .county: return 0.9    // ~150 km
        case .region: return 1.8    // ~300 km
        case .state:  return 3.2    // ~530 km
        }
    }
    var label: String {
        switch self {
        case .metro:  return "Metro"
        case .county: return "County"
        case .region: return "Region"
        case .state:  return "State"
        }
    }
}

enum RadarSnapshot {
    /// A dark basemap for the region, with radar drawn over it and a marker at
    /// the watched point. Returns nil only if the map itself fails; a clear sky
    /// still yields a usable map, with `hasEcho` false.
    @MainActor
    static func compose(lat: Double, lon: Double, zoom: RadarZoom,
                        size: CGSize, showReports: Bool) async -> (image: UIImage, hasEcho: Bool)? {
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

        let out = UIGraphicsImageRenderer(size: size).image { ctx in
            snap.image.draw(at: .zero)

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
