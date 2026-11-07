import SwiftUI

/// The watch app exists because a complication cannot be installed without
/// one. It shows the same picture at a size worth looking at, so opening it
/// from the face is a step up rather than a dead end.
@main
struct NightwatchWatchApp: App {
    var body: some Scene {
        WindowGroup { SectorView() }
    }
}

struct SectorView: View {
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
            let d = await SatelliteSector.fetch()
            await MainActor.run {
                if let d { data = d; failed = false } else { failed = true }
            }
        }
    }
}
