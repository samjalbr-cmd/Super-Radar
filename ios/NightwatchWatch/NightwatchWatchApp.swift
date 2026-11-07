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


/// The satellite sector: the last hour, looping, zoomable with the crown.
///
/// Frames arrive one at a time and the loop starts as soon as the second one
/// lands, because over a watch relayed through a phone twelve downloads can
/// take the better part of a minute and a spinner that long reads as broken.
///
/// 300 px rather than the app's usual 1200: twelve of those is a megabyte
/// against nine, and the difference is invisible on a 400-point screen until
/// you zoom a long way in.
struct SectorView: View {
    @State private var frames: [UIImage] = []
    @State private var times: [Date] = []
    @State private var idx = 0
    @State private var done = false
    @State private var playing = true
    @State private var zoom: Double = 1.6
    @State private var pan: CGSize = .zero
    @GestureState private var drag: CGSize = .zero
    @FocusState private var focused: Bool

    // Three hours at ten minutes, matching the dashboard's default. Eighteen
    // 300-px frames is about 1.7 MB — three times the window the first cut
    // had, for about half again the download.
    private let frameCount = 18
    private let stepMinutes = 10
    private let tick = Timer.publish(every: 0.42, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                if let img = frames.indices.contains(idx) ? frames[idx] : frames.last {
                    Image(uiImage: img)
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
                        .onTapGesture { playing.toggle() }
                    VStack {
                        Spacer()
                        HStack(spacing: 5) {
                            if !playing {
                                Image(systemName: "pause.fill").font(.system(size: 9))
                            }
                            Text(times.indices.contains(idx) ? stamp(times[idx]) : "")
                                .font(.system(size: 11, design: .monospaced))
                            if !done {
                                // Says the loop is still filling in, so a short
                                // loop does not look like a broken one.
                                Text("\(frames.count)/\(frameCount)")
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(.black.opacity(0.55), in: Capsule())
                        .padding(.bottom, 4)
                    }
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
            .onReceive(tick) { _ in
                guard playing, frames.count > 1 else { return }
                idx = (idx + 1) % frames.count
            }
        }
        .task { await load() }
    }

    private func stamp(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "h:mm a"; return f.string(from: d)
    }

    private func load() async {
        let wanted = SatelliteSector.recentFrames(count: frameCount, stepMinutes: stepMinutes)
        for t in wanted {
            guard let data = await SatelliteSector.fetchFrame(t, pixels: 300),
                  let img = SatelliteSector.fullFrame(data) else { continue }
            await MainActor.run { frames.append(img); times.append(t) }
        }
        await MainActor.run { done = true }
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
