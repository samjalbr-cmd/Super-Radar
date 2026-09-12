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
        .area:   "Area · ~215 km",
        .region: "Region · ~300 km",
        .wide:   "Wide · ~415 km",
        .state:  "State · ~530 km",
        .multi:  "Multi-state · ~900 km",
    ]
    case followApp, metro, county, area, region, wide, state, multi

    func resolve(_ appSetting: RadarZoom) -> RadarZoom {
        switch self {
        case .followApp: return appSetting
        case .metro:  return .metro
        case .county: return .county
        case .area:   return .area
        case .region: return .region
        case .wide:   return .wide
        case .state:  return .state
        case .multi:  return .multi
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

    @Parameter(title: "Show temperatures", default: true)
    var showTemps: Bool

    @Parameter(title: "Show watches & warnings", default: true)
    var showAlerts: Bool

    @Parameter(title: "Show storm tracks", default: true)
    var showTracks: Bool

    @Parameter(title: "Show discussion areas", default: true)
    var showDiscussion: Bool

    @Parameter(title: "Show SPC outlook", default: true)
    var showOutlook: Bool

    @Parameter(title: "Show fronts & pressure", default: true)
    var showFronts: Bool

    @Parameter(title: "Full station model", default: false)
    var stationModel: Bool
}
