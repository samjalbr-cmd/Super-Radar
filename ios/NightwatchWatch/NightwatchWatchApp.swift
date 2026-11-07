import SwiftUI
import CoreLocation
import WidgetKit

/// The watch app exists because a complication cannot be installed without
/// one, and it earns its place by being where location is asked for: a widget
/// extension cannot put up a permission prompt, so the app asks once and
/// leaves the answer where the complication can read it.
@main
struct NightwatchWatchApp: App {
    var body: some Scene {
        WindowGroup { SectorView() }
    }
}

/// Asks once, writes the answer to the shared group, and nudges the
/// complication so the face stops showing the fallback view.
final class Locator: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let mgr = CLLocationManager()
    @Published var center: (lat: Double, lon: Double)?

    override init() {
        super.init()
        mgr.delegate = self
        mgr.desiredAccuracy = kCLLocationAccuracyKilometer   // a 1600 km frame
    }

    func request() {
        switch mgr.authorizationStatus {
        case .notDetermined: mgr.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways: mgr.requestLocation()
        default: break
        }
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        if m.authorizationStatus == .authorizedWhenInUse ||
           m.authorizationStatus == .authorizedAlways { m.requestLocation() }
    }

    func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        guard let c = locs.last?.coordinate else { return }
        center = (lat: c.latitude, lon: c.longitude)
        // The complication is a separate process and will not notice on its own.
        WidgetCenter.shared.reloadAllTimelines()
    }

    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) { }
}

struct SectorView: View {
    @StateObject private var loc = Locator()
    @State private var data: Data?
    @State private var failed = false

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            ZStack {
                if let data, let img = SatelliteSector.circular(data, side: side) {
                    Image(uiImage: img).resizable().frame(width: side, height: side)
                } else {
                    Circle().fill(Color.white.opacity(0.07))
                        .frame(width: side, height: side)
                        .overlay(Text(failed ? "No signal" : "…")
                                    .font(.caption2).foregroundStyle(.secondary))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task {
            loc.request()
            await load()
        }
        // A fix arriving after the first draw re-centres the picture.
        .onChange(of: loc.center?.lat) { _, _ in Task { await load() } }
    }

    private func load() async {
        let c = SatelliteSector.center
        let d = await SatelliteSector.fetch(lat: c.lat, lon: c.lon, pixels: 400)
        await MainActor.run {
            if let d { data = d; failed = false } else { failed = true }
        }
    }
}
