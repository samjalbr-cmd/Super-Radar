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
        .tristate: "Tri-state · ~680 km",
        .multi:  "Multi-state · ~900 km",
    ]
    case followApp, metro, county, area, region, wide, state, tristate, multi

    func resolve(_ appSetting: RadarZoom) -> RadarZoom {
        switch self {
        case .followApp: return appSetting
        case .metro:  return .metro
        case .county: return .county
        case .area:   return .area
        case .region: return .region
        case .wide:   return .wide
        case .state:  return .state
        case .tristate: return .tristate
        case .multi:  return .multi
        }
    }
}

/// Upper-air level, same four the dashboard offers plus "match the app", so a
/// widget can hold the jet stream while the map is set to the low-level jet.
enum UpperLevelOption: String, AppEnum {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Upper-air winds")
    static var caseDisplayRepresentations: [UpperLevelOption: DisplayRepresentation] = [
        .followApp: "Match the app",
        .off:  "Off",
        .l850: "850 hPa · 5,000 ft",
        .l700: "700 hPa · 10,000 ft",
        .l500: "500 hPa · 18,000 ft",
        .l250: "250 hPa · 35,000 ft",
    ]
    case followApp, off, l850, l700, l500, l250

    func resolve(_ appSetting: String?) -> String? {
        switch self {
        case .followApp: return appSetting
        case .off:  return nil
        case .l850: return "850"
        case .l700: return "700"
        case .l500: return "500"
        case .l250: return "250"
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


    @Parameter(title: "Show discussion areas", default: true)
    var showDiscussion: Bool

    @Parameter(title: "Show SPC outlook", default: true)
    var showOutlook: Bool

    @Parameter(title: "Show fronts & pressure", default: true)
    var showFronts: Bool

    @Parameter(title: "Full station model", default: false)
    var stationModel: Bool

    @Parameter(title: "Show isobars", default: true)
    var showIsobars: Bool

    // Off by default: on the Great Lakes a single gale episode is issued zone by
    // zone, and dozens of them bury the map.
    @Parameter(title: "Show marine warnings", default: false)
    var showMarine: Bool

    @Parameter(title: "Lake water temperature", default: true)
    var showLake: Bool

    @Parameter(title: "Spotter report dots", default: true)
    var showSpotter: Bool

    @Parameter(title: "Upper-air winds", default: .followApp)
    var upperLevel: UpperLevelOption
}
