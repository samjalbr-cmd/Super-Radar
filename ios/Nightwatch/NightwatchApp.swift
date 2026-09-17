import SwiftUI
import WebKit
import WidgetKit

/// The dashboard is a web app, so the iOS app hosts it rather than
/// reimplementing it: one codebase, and the phone gets a real icon, no browser
/// chrome, and a screen that stays awake.
private let dashboardURL = "https://samjalbr-cmd.github.io/Super-Radar/"

/// Receives the dashboard's settings and stores them where the widget reads
/// them, so the two cannot drift apart. Without this the widget kept its own
/// preferences and quietly disagreed with the app.
final class SettingsBridge: NSObject, WKScriptMessageHandler {
    static let name = "nightwatch"

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == Self.name, let d = message.body as? [String: Any] else { return }
        var loc = WatchLocation.load()
        var moved = false

        if let la = d["lat"] as? Double, let lo = d["lon"] as? Double,
           la.isFinite, lo.isFinite, abs(la) <= 90, abs(lo) <= 180 {
            // A move invalidates the cached state, which scopes the station fetch.
            if abs(la - loc.lat) > 0.02 || abs(lo - loc.lon) > 0.02 { moved = true }
            loc.lat = la; loc.lon = lo
        }
        if let n = (d["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty {
            loc.name = n
        }
        if let z = d["zoom"] as? String, let parsed = RadarZoom(rawValue: z) { loc.zoom = parsed }
        if let t = d["showTemps"] as? Bool { loc.showTemps = t }
        if let r = d["showReports"] as? Bool { loc.showReports = r }
        if let a = d["showAlerts"] as? Bool { loc.showAlerts = a }
        if let a = d["showDiscussion"] as? Bool { loc.showDiscussion = a }
        if let o = d["showOutlook"] as? Bool { loc.showOutlook = o }
        if let f = d["showFronts"] as? Bool { loc.showFronts = f }
        if let m = d["stationModel"] as? Bool { loc.stationModel = m }
        if let i = d["showIsobars"] as? Bool { loc.showIsobars = i }
        if let l = d["showLake"] as? Bool { loc.showLake = l }
        if moved { loc.state = nil }
        loc.save()

        Task {
            if loc.state == nil,
               let st = await StormFeed.resolveState(lat: loc.lat, lon: loc.lon) {
                var updated = WatchLocation.load()
                updated.state = st
                updated.save()
            }
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}

struct DashboardView: UIViewRepresentable {
    let location: WatchLocation

    func makeCoordinator() -> SettingsBridge { SettingsBridge() }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.userContentController.add(context.coordinator, name: SettingsBridge.name)
        let web = WKWebView(frame: .zero, configuration: cfg)
        web.isOpaque = false
        web.backgroundColor = UIColor(red: 0.04, green: 0.055, blue: 0.10, alpha: 1)
        web.scrollView.bounces = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        // A map is a direct-manipulation surface, so the web view must not add
        // its own gestures on top of Leaflet's. Long-press previews are for
        // links and documents, and the scroll view's pinch zooms the whole
        // document — both fight the map rather than helping it.
        web.allowsLinkPreview = false
        web.scrollView.minimumZoomScale = 1
        web.scrollView.maximumZoomScale = 1
        web.scrollView.bouncesZoom = false
        // The page fills the view; nothing below it should scroll.
        web.scrollView.showsVerticalScrollIndicator = false
        web.scrollView.showsHorizontalScrollIndicator = false
        // Hand the page the same location the widget watches, so the arrival
        // countdown in both places is answering about the same spot.
        var c = URLComponents(string: dashboardURL)!
        c.queryItems = [
            .init(name: "lat", value: String(location.lat)),
            .init(name: "lon", value: String(location.lon)),
        ]
        web.load(URLRequest(url: c.url!))
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

@main
struct NightwatchApp: App {
    @Environment(\.scenePhase) private var phase
    private let location = WatchLocation.load()

    var body: some Scene {
        WindowGroup {
            DashboardView(location: location)
                .ignoresSafeArea()
                // The status bar stays visible. Hiding it while the web view
                // also ignores the safe area leaves the page no way to know
                // where the display cutout is, so the top row ends up under the
                // Dynamic Island — and on a weather dashboard the clock and
                // battery are worth having anyway.
                .onAppear {
                    // Keep the default written where the widget can read it, and
                    // stop the phone dimming while the radar is being watched.
                    location.save()
                    UIApplication.shared.isIdleTimerDisabled = true
                    Task {
                        // The widget can only fetch one state's stations, so the
                        // app resolves which one and stores it alongside.
                        if location.state == nil,
                           let st = await StormFeed.resolveState(lat: location.lat, lon: location.lon) {
                            var updated = location
                            updated.state = st
                            updated.save()
                        }
                        WidgetCenter.shared.reloadAllTimelines()
                    }
                }
                .onChange(of: phase) { _, new in
                    UIApplication.shared.isIdleTimerDisabled = (new == .active)
                    if new == .background { WidgetCenter.shared.reloadAllTimelines() }
                }
        }
    }
}
