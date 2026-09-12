import SwiftUI
import WebKit
import WidgetKit

/// The dashboard is a web app, so the iOS app hosts it rather than
/// reimplementing it: one codebase, and the phone gets a real icon, no browser
/// chrome, and a screen that stays awake.
private let dashboardURL = "https://samjalbr-cmd.github.io/Super-Radar/"

struct DashboardView: UIViewRepresentable {
    let location: WatchLocation

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        let web = WKWebView(frame: .zero, configuration: cfg)
        web.isOpaque = false
        web.backgroundColor = UIColor(red: 0.04, green: 0.055, blue: 0.10, alpha: 1)
        web.scrollView.bounces = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
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
                .statusBarHidden(true)
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
