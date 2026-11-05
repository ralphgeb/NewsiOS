import AppIntents
import WidgetKit

/// Which news a widget follows, chosen from the widget itself (touch and hold › Edit Widget).
enum WidgetSection: String, AppEnum {
    case forYou, tech, finance, world, fashion

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Section"
    static var caseDisplayRepresentations: [WidgetSection: DisplayRepresentation] = [
        .forYou: "For you", .tech: "Tech", .finance: "Finance", .world: "World", .fashion: "Fashion",
    ]

    var topic: Topic? {
        switch self {
        case .forYou: return nil
        case .tech: return .tech
        case .finance: return .finance
        case .world: return .world
        case .fashion: return .fashion
        }
    }

    var title: String { topic?.title ?? "For you" }

    /// Where a tap on the widget goes: that section in News.
    var url: URL { URL(string: "scout://news?section=\(topic?.rawValue ?? "For you")".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "scout://news")! }
}

/// The Briefing widget: one of the four sections' briefings.
enum BriefingSection: String, AppEnum {
    case tech, finance, world, fashion

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Briefing"
    static var caseDisplayRepresentations: [BriefingSection: DisplayRepresentation] = [
        .tech: "Tech", .finance: "Finance", .world: "World", .fashion: "Fashion",
    ]

    var topic: Topic {
        switch self {
        case .tech: return .tech
        case .finance: return .finance
        case .world: return .world
        case .fashion: return .fashion
        }
    }
}

struct BriefingConfig: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Briefing"
    static var description = IntentDescription("Choose which section's briefing to show.")

    @Parameter(title: "Section", default: .tech)
    var section: BriefingSection
}

struct HeadlinesConfig: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Headlines"
    static var description = IntentDescription("Choose which stories to show.")

    @Parameter(title: "Section", default: .forYou)
    var section: WidgetSection
}
