import WidgetKit
import SwiftUI

struct SectorEntry: TimelineEntry {
    let date: Date
    let imageData: Data?
    /// True when the fetch failed, so the face can say so rather than show a
    /// stale picture as though it were current.
    let stale: Bool
}

struct SectorProvider: TimelineProvider {

    func placeholder(in context: Context) -> SectorEntry {
        SectorEntry(date: Date(), imageData: nil, stale: false)
    }

    func getSnapshot(in context: Context, completion: @escaping (SectorEntry) -> Void) {
        Task { completion(await current()) }
    }

    private func current() async -> SectorEntry {
        let d = await SatelliteSector.fetch()
        return SectorEntry(date: Date(), imageData: d, stale: d == nil)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SectorEntry>) -> Void) {
        Task {
            let entry = await current()
            let d = entry.imageData
            // The sector is republished every few minutes, but a watch
            // complication is given a small budget of refreshes a day and
            // spends battery on each one. Twenty minutes is frequent enough
            // that the cloud field on the wrist matches the sky; a failed
            // fetch tries again sooner rather than leaving the face wrong
            // for a full cycle.
            let next = Date().addingTimeInterval(d == nil ? 5 * 60 : 20 * 60)
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
    }
}

struct SectorComplicationView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var mode
    let entry: SectorEntry

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            // A photograph only survives the full-colour faces. Where the face
            // tints everything to one hue the picture would come through as
            // grey mush, so those get the outline and a label instead of a
            // smear that looks like a rendering fault.
            if mode == .fullColor, let data = entry.imageData,
               let img = SatelliteSector.circular(data, side: side) {
                Image(uiImage: img)
                    .resizable()
                    .frame(width: side, height: side)
                    .clipShape(Circle())
            } else {
                ZStack {
                    AccessoryWidgetBackground().clipShape(Circle())
                    Image(systemName: entry.stale ? "cloud.slash" : "cloud.sun")
                        .font(.system(size: side * 0.42))
                }
                .frame(width: side, height: side)
            }
        }
    }
}

@main
struct NightwatchComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NightwatchSector", provider: SectorProvider()) { entry in
            SectorComplicationView(entry: entry)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("Satellite")
        .description("The live GOES view of the Great Lakes.")
        .supportedFamilies([.accessoryCircular])
    }
}
