import WidgetKit
import SwiftUI

// MARK: - Shared timeline

struct RadarEntry: TimelineEntry {
    let date: Date
    let place: String
    let imageData: Data?
    let approach: Approach?
    /// True when the fetch failed, so a widget can say so rather than look calm.
    let stale: Bool
}

/// One provider feeds both widgets; `needsImage` keeps the text-only widget from
/// paying for a radar render it will never draw.
struct Provider: TimelineProvider {
    let needsImage: Bool

    func placeholder(in context: Context) -> RadarEntry {
        RadarEntry(date: Date(), place: "—", imageData: nil, approach: nil, stale: false)
    }
    func getSnapshot(in context: Context, completion: @escaping (RadarEntry) -> Void) {
        Task { completion(await entry(for: context.family)) }
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<RadarEntry>) -> Void) {
        Task {
            let e = await entry(for: context.family)
            // Ask for sooner when something is close. iOS grants what its budget
            // allows, so this is a request rather than a promise.
            let mins = (e.approach?.minutes ?? 60) < 30 ? 10 : 20
            let next = Calendar.current.date(byAdding: .minute, value: mins, to: Date()) ?? Date()
            completion(Timeline(entries: [e], policy: .after(next)))
        }
    }

    private func entry(for family: WidgetFamily) async -> RadarEntry {
        let loc = WatchLocation.load()
        let pixels: Int
        switch family {
        case .systemSmall:  pixels = 400
        case .systemMedium: pixels = 700
        default:            pixels = 800
        }
        // A large widget covers more ground than a small one usefully can.
        let half: Double = family == .systemLarge ? 1.4 : 0.9
        async let img = needsImage
            ? StormFeed.radarImage(lat: loc.lat, lon: loc.lon, halfDegrees: half, pixels: pixels)
            : nil
        async let list = try? await StormFeed.cells()
        let (image, cells) = await (img, list)
        let approach = cells.flatMap { StormArrival.soonest(cells: $0, lat: loc.lat, lon: loc.lon) }
        return RadarEntry(date: Date(), place: loc.name, imageData: image,
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
                Image(uiImage: ui).resizable().scaledToFill()
            } else {
                panel
                Text(entry.stale ? "No data" : "…")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
            }
            // Your location, so the picture has an anchor.
            Circle()
                .fill(Color(red: 0.95, green: 0.72, blue: 0.02))
                .frame(width: 7, height: 7)
                .shadow(color: .black, radius: 2)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            Text(entry.date, style: .time)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.white.opacity(0.75))
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(.black.opacity(0.45), in: Capsule())
                .padding(6)
        }
        .containerBackground(panel, for: .widget)
    }
}

struct RadarWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NightwatchRadar", provider: Provider(needsImage: true)) { entry in
            RadarWidgetView(entry: entry)
        }
        .configurationDisplayName("Radar")
        .description("Live radar around your location.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
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
                Text(entry.date, style: .time)
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
        StaticConfiguration(kind: "NightwatchArrival", provider: Provider(needsImage: false)) { entry in
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
