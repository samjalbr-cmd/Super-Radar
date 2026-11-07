import SwiftUI
import CoreLocation

/// The watch app exists because a complication cannot be installed without
/// one, and it earns its place by showing the radar — the same composite the
/// phone widget draws, from the same shared code, rather than a second,
/// lesser rendering of the same data.
@main
struct NightwatchWatchApp: App {
    var body: some Scene {
        WindowGroup { RadarView() }
    }
}

/// Asks for location once so the map is centred on the wearer. The radar
/// compositor takes a coordinate, unlike the satellite sector, so here the
/// centring is real rather than placed by eye.
final class Locator: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let mgr = CLLocationManager()
    @Published var coord: CLLocationCoordinate2D?

    override init() {
        super.init()
        mgr.delegate = self
        mgr.desiredAccuracy = kCLLocationAccuracyKilometer
    }
    func request() {
        switch mgr.authorizationStatus {
        case .notDetermined: mgr.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways: mgr.requestLocation()
        default: break
        }
    }
    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        let s = m.authorizationStatus
        if s == .authorizedWhenInUse || s == .authorizedAlways { m.requestLocation() }
    }
    func locationManager(_ m: CLLocationManager, didUpdateLocations l: [CLLocation]) {
        if let c = l.last?.coordinate { coord = c }
    }
    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) { }
}

struct RadarView: View {
    @StateObject private var loc = Locator()
    @State private var image: UIImage?
    @State private var hasEcho = false
    @State private var loading = true
    @State private var failed = false
    /// Where to look when location has not arrived or was refused. The sector
    /// this project started from, so the picture is never empty.
    private let fallback = CLLocationCoordinate2D(latitude: 43.0, longitude: -85.5)

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                    if !hasEcho {
                        // A blank map and a failed map look identical, so the
                        // quiet case says which it is.
                        Text("No echoes")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(.black.opacity(0.55), in: Capsule())
                            .frame(maxHeight: .infinity, alignment: .bottom)
                            .padding(.bottom, 6)
                    }
                } else {
                    Color.black
                    if loading { ProgressView() }
                    else if failed {
                        VStack(spacing: 4) {
                            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                            Text("No signal").font(.caption2)
                        }.foregroundStyle(.secondary)
                    }
                }
            }
            .ignoresSafeArea()
            .task(id: geo.size.width) { await load(size: geo.size) }
        }
        .onAppear { loc.request() }
        .onChange(of: loc.coord?.latitude) { _, _ in
            Task { await load(size: WKInterfaceDeviceSize()) }
        }
    }

    private func WKInterfaceDeviceSize() -> CGSize {
        WKInterfaceDevice.current().screenBounds.size
    }

    private func load(size: CGSize) async {
        guard size.width > 0 else { return }
        await MainActor.run { loading = image == nil }
        let c = loc.coord ?? fallback
        // County is the widest view that still shows a storm as a shape rather
        // than a speck on a screen this size.
        let r = await RadarSnapshot.compose(
            lat: c.latitude, lon: c.longitude, zoom: .county, size: size,
            showReports: false, showTemps: true, showAlerts: true,
            showOutlook: false, showFronts: false, stationModel: false,
            showIsobars: false, showMarine: false, showLake: false,
            showSpotter: false, upperLevel: nil, showSpark: false,
            showRoads: false, state: nil)
        await MainActor.run {
            loading = false
            if let r { image = r.image; hasEcho = r.hasEcho; failed = false }
            else { failed = image == nil }
        }
    }
}
