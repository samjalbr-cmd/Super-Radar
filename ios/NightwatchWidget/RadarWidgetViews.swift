import WidgetKit
import SwiftUI
import AppIntents

/// Zoom is a widget parameter, so you can put two radar widgets side by side at
/// different scales — long-press the widget and choose Edit Widget.
enum RadarZoomOption: String, AppEnum {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Zoom")
    static var caseDisplayRepresentations: [RadarZoomOption: DisplayRepresentation] = [
        .followApp: "Match the app",
        .metro:  "Metro · ~60 km",
        .county: "County · ~150 km",
        .region: "Region · ~300 km",
        .state:  "State · ~530 km",
    ]
    case followApp, metro, county, region, state

    func resolve(_ appSetting: RadarZoom) -> RadarZoom {
        switch self {
        case .followApp: return appSetting
        case .metro:  return .metro
        case .county: return .county
        case .region: return .region
        case .state:  return .state
        }
    }
}

struct RadarConfig: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Radar"
    static var description = IntentDescription("Live radar around your location.")

    @Parameter(title: "Zoom", default: .followApp)
    var zoom: RadarZoomOption

    @Parameter(title: "Show storm reports", default: true)
    var showReports: Bool
}
