import WidgetKit
import SwiftUI

struct RadarEntry: TimelineEntry {
    let date: Date
    let place: String
    let imageData: Data?
    let approach: Approach?
    /// Set when the fetch failed, so the widget can say so rather than look calm.
    let stale: Bool
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> RadarEntry {
        RadarEntry(date: Date(), place: "—", imageData: nil, approach: nil, stale: false)
    }

    func getSnapshot(in context: Context, completion: @escaping (RadarEntry) -> Void) {
        Task { completion(await entry(pixels: context.family == .systemSmall ? 320 : 600)) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<RadarEntry>) -> Void) {
        Task {
            let e = await entry(pixels: context.family == .systemSmall ? 320 : 600)
            // Ask for 10 minutes; iOS will grant what its budget allows. When a
            // storm is inbound the number on screen is worth refreshing sooner.
            let minutes = (e.approach?.minutes ?? 60) < 30 ? 10 : 20
            let next = Calendar.current.date(byAdding: .minute, value: minutes, to: Date()) ?? Date()
            completion(Timeline(entries: [e], policy: .after(next)))
        }
    }

    private func entry(pixels: Int) async -> RadarEntry {
        let loc = WatchLocation.load()
        async let image = StormFeed.radarImage(lat: loc.lat, lon: loc.lon, halfDegrees: 0.9, pixels: pixels)
        async let cells = try? await StormFeed.cells()
        let (img, list) = await (image, cells)
        let approach = list.flatMap { StormArrival.soonest(cells: $0, lat: loc.lat, lon: loc.lon) }
        return RadarEntry(date: Date(), place: loc.name, imageData: img,
                          approach: approach, stale: img == nil && list == nil)
    }
}

/// Named for the hazard, not `tint`, which collides with SwiftUI's View modifier.
private func hazardColor(_ a: Approach) -> Color {
    if a.cell.tvs { return Color(red: 1, green: 0.23, blue: 0.96) }
    if a.cell.meso { return Color(red: 0.88, green: 0.02, blue: 0) }
    if a.cell.hailInches >= 1 || a.cell.posh >= 50 { return Color(red: 1, green: 0.48, blue: 0) }
    return Color(red: 0.95, green: 0.72, blue: 0.02)
}

struct NightwatchWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: RadarEntry

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let d = entry.imageData, let ui = UIImage(data: d) {
                Image(uiImage: ui).resizable().scaledToFill()
            } else {
                Color(red: 0.04, green: 0.055, blue: 0.10)
            }
            LinearGradient(colors: [.black.opacity(0.85), .clear],
                           startPoint: .bottom, endPoint: .center)
            content
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
        }
        .containerBackground(Color(red: 0.04, green: 0.055, blue: 0.10), for: .widget)
    }

    @ViewBuilder private var content: some View {
        if let a = entry.approach {
            VStack(alignment: .leading, spacing: 1) {
                Text(a.headline)
                    .font(.system(size: family == .systemSmall ? 10 : 12, weight: .heavy))
                    .foregroundStyle(hazardColor(a))
                Text(a.minutes <= 0 ? "now" : "\(Int(a.minutes.rounded())) min")
                    .font(.system(size: family == .systemSmall ? 22 : 28, weight: .bold))
                    .foregroundStyle(.white)
                if family != .systemSmall {
                    Text(a.detail).font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.7))
                }
                Text(a.missMiles <= 3 ? "tracking over you" : "~\(a.missMiles) mi away")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
            }
        } else {
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.place.uppercased())
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(.white.opacity(0.55))
                Text(entry.stale ? "No data" : "Nothing inbound")
                    .font(.system(size: family == .systemSmall ? 15 : 19, weight: .bold))
                    .foregroundStyle(.white)
                Text(entry.date, style: .time)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }
}

@main
struct NightwatchWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NightwatchRadar", provider: Provider()) { entry in
            NightwatchWidgetView(entry: entry)
        }
        .configurationDisplayName("Storm Arrival")
        .description("Radar near you, and the next storm heading your way.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
