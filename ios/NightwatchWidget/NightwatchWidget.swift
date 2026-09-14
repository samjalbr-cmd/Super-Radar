import WidgetKit
import SwiftUI
import AppIntents

// MARK: - Shared timeline

struct RadarEntry: TimelineEntry {
    let date: Date
    let place: String
    let imageData: Data?
    /// False when the render came back blank — a clear sky, not a failure.
    let hasEcho: Bool
    let approach: Approach?
    /// True when the fetch failed, so a widget can say so rather than look calm.
    let stale: Bool
}

/// One provider feeds both widgets; `needsImage` keeps the text-only widget from
/// paying for a radar render it will never draw.
struct Provider: TimelineProvider {

    func placeholder(in context: Context) -> RadarEntry {
        RadarEntry(date: Date(), place: "—", imageData: nil, hasEcho: false, approach: nil, stale: false)
    }
    func getSnapshot(in context: Context, completion: @escaping (RadarEntry) -> Void) {
        Task { completion(await entry(for: context.family)) }
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<RadarEntry>) -> Void) {
        Task {
            let e = await entry(for: context.family)
            // Ask for sooner when something is close. iOS grants what its budget
            // allows, so this is a request rather than a promise.
            let mins = (e.approach?.minutes ?? 60) < 30 ? 10 : 15
            let next = Calendar.current.date(byAdding: .minute, value: mins, to: Date()) ?? Date()
            completion(Timeline(entries: [e], policy: .after(next)))
        }
    }

    private func entry(for family: WidgetFamily) async -> RadarEntry {
        _ = family
        let loc = WatchLocation.load()
        let cells = try? await StormFeed.cells()
        let approach = cells.flatMap { StormArrival.soonest(cells: $0, lat: loc.lat, lon: loc.lon) }
        return RadarEntry(date: Date(), place: loc.name, imageData: nil, hasEcho: false,
                          approach: approach, stale: cells == nil)
    }
}

private let panel = Color(red: 0.04, green: 0.055, blue: 0.10)

/// Named for the hazard, not `tint`, which collides with SwiftUI's View modifier.
private func hazardColor(_ a: Approach) -> Color {
    if a.cell.tvs { return Color(red: 1, green: 0.23, blue: 0.96) }
    if a.cell.meso { return Color(red: 0.88, green: 0.02, blue: 0) }
    if a.cell.hailInches >= 1 || a.cell.posh >= 50 { return Color(red: 1, green: 0.48, blue: 0) }
    return Color(red: 0.95, green: 0.72, blue: 0.02)
}

// MARK: - Radar widget (picture only)

struct RadarWidgetView: View {
    let entry: RadarEntry

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let d = entry.imageData, let ui = UIImage(data: d) {
                // The map is drawn whether or not there is weather on it, so a
                // quiet sky still looks like a map rather than a failure. A
                // genuine fetch failure falls through to the NO DATA panel below.
                Image(uiImage: ui).resizable().scaledToFill()
            } else {
                panel
                VStack(spacing: 3) {
                    Text("NO DATA").font(.system(size: 15, weight: .heavy))
                        .foregroundStyle(.white.opacity(0.55))
                    Text("couldn't reach the map")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.45))
                        .minimumScaleFactor(0.7).lineLimit(1)
                }
                .padding(.horizontal, 6)
            }
            // Date as well as time. A widget can hold a stale snapshot for a
            // while, and "10:26" alone gives no way to tell this morning's radar
            // from yesterday's.
            Text(entry.date, format: .dateTime.month(.abbreviated).day().hour().minute())
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.white.opacity(0.8))
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(.black.opacity(0.5), in: Capsule())
                .padding(6)
        }
        .containerBackground(panel, for: .widget)
    }
}

/// Renders the map itself, so the radar has ground under it.
struct RadarProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> RadarEntry {
        RadarEntry(date: Date(), place: "—", imageData: nil, hasEcho: false, approach: nil, stale: false)
    }
    func snapshot(for config: RadarConfig, in context: Context) async -> RadarEntry {
        await entry(config, context.displaySize)
    }
    func timeline(for config: RadarConfig, in context: Context) async -> Timeline<RadarEntry> {
        let e = await entry(config, context.displaySize)
        let mins = (e.approach?.minutes ?? 60) < 30 ? 10 : 15
        let next = Calendar.current.date(byAdding: .minute, value: mins, to: Date()) ?? Date()
        return Timeline(entries: [e], policy: .after(next))
    }

    private func entry(_ config: RadarConfig, _ displaySize: CGSize) async -> RadarEntry {
        let loc = WatchLocation.load()
        // The real size of this widget on this device. The hardcoded guesses it
        // replaced matched almost no device, and any mismatch is cropped away by
        // scaledToFill — which is what was clipping the edge temperatures.
        let size = displaySize
        let zoom = config.zoom.resolve(loc.zoom)
        // The app's own setting is the default; the widget parameter can override
        // it so two widgets can differ without changing the app.
        let reports = config.showReports && loc.showReports
        let temps = config.showTemps && loc.showTemps
        let composed = await RadarSnapshot.compose(lat: loc.lat, lon: loc.lon, zoom: zoom, size: size,
                                                   showReports: reports, showTemps: temps,
                                                   showAlerts: config.showAlerts && loc.showAlerts,
                                                   showTracks: config.showTracks && loc.showTracks,
                                                   showDiscussion: config.showDiscussion && loc.showDiscussion,
                                                   showOutlook: config.showOutlook && loc.showOutlook,
                                                   showFronts: config.showFronts && loc.showFronts,
                                                   stationModel: config.stationModel || loc.stationModel,
                                                   showIsobars: config.showIsobars && loc.showIsobars,
                                                   showMarine: config.showMarine || loc.showMarine,
                                                   state: loc.state)
        let cells = try? await StormFeed.cells()
        let approach = cells.flatMap { StormArrival.soonest(cells: $0, lat: loc.lat, lon: loc.lon) }
        return RadarEntry(date: Date(), place: loc.name,
                          imageData: composed?.image.pngData(), hasEcho: composed?.hasEcho ?? false,
                          approach: approach, stale: composed == nil)
    }
}

struct RadarWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "NightwatchRadar", intent: RadarConfig.self, provider: RadarProvider()) { entry in
            RadarWidgetView(entry: entry)
        }
        .configurationDisplayName("Radar")
        .description("Live radar on a map around your location.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        // The map is the widget; without this iOS insets it by the default
        // content margins and leaves a border of background around the edge.
        .contentMarginsDisabled()
    }
}

// MARK: - Arrival widget (text only)

struct ArrivalWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: RadarEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let a = entry.approach {
                Text(a.headline)
                    .font(.system(size: family == .systemSmall ? 11 : 13, weight: .heavy))
                    .foregroundStyle(hazardColor(a))
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(a.minutes <= 0 ? "now" : "\(Int(a.minutes.rounded()))")
                        .font(.system(size: family == .systemSmall ? 40 : 52, weight: .bold))
                        .foregroundStyle(.white)
                    if a.minutes > 0 {
                        Text("min").font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                Text(a.detail)
                    .font(.system(size: family == .systemSmall ? 9.5 : 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.72))
                    .minimumScaleFactor(0.7)
                    .lineLimit(family == .systemSmall ? 2 : 1)
                Spacer(minLength: 0)
                Text(a.missMiles <= 3 ? "tracking over you" : "~\(a.missMiles) mi away")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            } else {
                Text(entry.place.uppercased())
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(.white.opacity(0.5))
                    .minimumScaleFactor(0.7).lineLimit(1)
                Spacer(minLength: 0)
                Text(entry.stale ? "No data" : "All clear")
                    .font(.system(size: family == .systemSmall ? 26 : 32, weight: .bold))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.6).lineLimit(1)
                Text(entry.stale ? "couldn't reach the feed" : "nothing inbound")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
                    .minimumScaleFactor(0.7).lineLimit(1)
                Spacer(minLength: 0)
                Text(entry.date, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .containerBackground(panel, for: .widget)
    }
}

struct ArrivalWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NightwatchArrival", provider: Provider()) { entry in
            ArrivalWidgetView(entry: entry)
        }
        .configurationDisplayName("Storm Arrival")
        .description("How long until the next storm reaches you.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct NightwatchWidgets: WidgetBundle {
    var body: some Widget {
        RadarWidget()
        ArrivalWidget()
    }
}
