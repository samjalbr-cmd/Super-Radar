import SwiftUI
import CoreLocation

/// The watch app exists because a complication cannot be installed without
/// one, and it earns its place by showing the radar — the same composite the
/// phone widget draws, from the same shared code, rather than a second,
/// lesser rendering of the same data.
@main
struct NightwatchWatchApp: App {
    var body: some Scene {
        WindowGroup {
            // Two pages, swiped between. The crown is left free for zooming,
            // which rules out the vertical page style — that spends it on
            // moving between the pages instead.
            TabView {
                RadarView()
                SectorView()
            }
            .tabViewStyle(.page)
        }
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


/// The satellite sector, zoomable with the crown.
///
/// The complication has to choose a framing and live with it. Here there is a
/// screen and an input, so the whole sector is shown and the wearer picks:
/// crown to zoom, drag to pan.
struct SectorView: View {
    @State private var image: UIImage?
    @State private var failed = false
    @State private var zoom: Double = 1.6
    @State private var pan: CGSize = .zero
    @GestureState private var drag: CGSize = .zero
    @FocusState private var focused: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                        // Zoom about the hand-placed centre rather than the
                        // middle of the frame, so winding the crown homes in
                        // on home instead of on Ohio.
                        .scaleEffect(zoom, anchor: UnitPoint(x: SatelliteSector.centerX,
                                                             y: SatelliteSector.centerY))
                        .offset(x: pan.width + drag.width, y: pan.height + drag.height)
                        .clipped()
                        .gesture(
                            DragGesture()
                                .updating($drag) { v, st, _ in st = v.translation }
                                .onEnded { v in
                                    pan.width += v.translation.width
                                    pan.height += v.translation.height
                                    clamp(geo.size)
                                }
                        )
                } else if failed {
                    VStack(spacing: 4) {
                        Image(systemName: "cloud.slash")
                        Text("No signal").font(.caption2)
                    }.foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            }
            .ignoresSafeArea()
            .focusable(true)
            .focused($focused)
            .digitalCrownRotation($zoom, from: 1, through: 6, by: 0.05,
                                  sensitivity: .medium, isContinuous: false,
                                  isHapticFeedbackEnabled: true)
            .onChange(of: zoom) { _, _ in clamp(geo.size) }
            .onAppear { focused = true }
        }
        .task {
            // The detail size, not the complication's: there is no point
            // offering six times zoom into an image that has not got it.
            let d = await SatelliteSector.fetch(pixels: SatelliteSector.detailPixels)
            await MainActor.run {
                if let d, let img = SatelliteSector.fullFrame(d) { image = img }
                else { failed = true }
            }
        }
    }

    /// Keep the picture over the screen. Panning past its edge leaves black
    /// bars and no way to tell you have run out of map rather than run out of
    /// weather.
    private func clamp(_ size: CGSize) {
        let slackX = max(0, (size.width  * zoom - size.width)  / 2)
        let slackY = max(0, (size.height * zoom - size.height) / 2)
        pan.width  = min(max(pan.width,  -slackX), slackX)
        pan.height = min(max(pan.height, -slackY), slackY)
    }
}
