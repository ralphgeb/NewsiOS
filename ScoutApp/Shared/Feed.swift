import Foundation
import WidgetKit

/// Shared between the app and the widget: the App Group, the data address and the cache.
enum Shared {
    static let appGroup = "group.com.ralphgeb.scout"     // must match project.yml
    static let widgetKind = "ScoutBriefing"

    static var defaults: UserDefaults { UserDefaults(suiteName: appGroup) ?? .standard }

    /// The Today topic lives in the App Group so the widget follows it.
    static var topic: Topic {
        get { defaults.string(forKey: "today.topic").flatMap(Topic.init(rawValue:)) ?? .tech }
        set {
            defaults.set(newValue.rawValue, forKey: "today.topic")
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    /// Whether the topic has been chosen yet (the app asks on first launch).
    static var hasChosenTopic: Bool { defaults.string(forKey: "today.topic") != nil }
}

/// Fetches the updater's files and keeps the last good copy on the iPhone.
enum Feed {
    static let news = "news.json"
    static let briefing = "briefing.json"
    static let stocks = "stocks.json"
    static let symbols = "symbols.json"

    static var base: URL {
        let s = Bundle.main.object(forInfoDictionaryKey: "ScoutDataURL") as? String
        return URL(string: s ?? "") ?? URL(string: "https://raw.githubusercontent.com/ralphgeb/ScoutAI/main/data")!
    }

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    /// Downloads a file, saves it to the cache and returns it.
    static func fetch(_ name: String) async throws -> Data {
        var request = URLRequest(url: base.appending(path: name))
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw FeedError.status(http.statusCode)
        }
        try? data.write(to: cacheURL(name), options: .atomic)
        return data
    }

    static func cached(_ name: String) -> Data? {
        try? Data(contentsOf: cacheURL(name))
    }

    static func cacheURL(_ name: String) -> URL {
        let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Shared.appGroup)
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return dir.appending(path: name)
    }

    static func decodeBriefing(_ data: Data) -> Briefing? {
        try? decoder.decode(Briefing.self, from: data)
    }
}

enum FeedError: LocalizedError {
    case status(Int)

    var errorDescription: String? {
        switch self {
        case .status(404): return "The news files weren't found. Check the ScoutAI repository is public and has run its first update."
        case .status(let code): return "The news server answered \(code). Try again in a minute."
        }
    }
}

// MARK: - Digest

/// The latest briefing for one topic, boiled down for the widget and the morning notification.
struct BriefingDigest: Hashable {
    var topic: Topic
    var label: String          // "Morning tech briefing"
    var title: String
    var teaser: String?        // the one-line notification text
    var summary: String?
    var lines: [String]        // the top stories
    var generated: Date?
    var id: String             // changes whenever a new briefing is written

    init(topic: Topic, label: String, title: String, teaser: String?, summary: String?,
         lines: [String], generated: Date?, id: String) {
        self.topic = topic
        self.label = label
        self.title = title
        self.teaser = teaser
        self.summary = summary
        self.lines = lines
        self.generated = generated
        self.id = id
    }

    init?(briefing: Briefing, topic: Topic) {
        if topic == .tech, let ed = briefing.editions.max(by: { $0.generated < $1.generated }) {
            self.init(topic: topic, label: "\(ed.edition) tech briefing", title: ed.title,
                      teaser: ed.notification, summary: ed.intro, lines: ed.topStories.map(\.title),
                      generated: ed.generated, id: ed.id)
        } else if let s = briefing.section(topic) {
            let part = (s.generated.map { Calendar.current.component(.hour, from: $0) } ?? 6) < 12 ? "Morning" : "Evening"
            self.init(topic: topic, label: "\(part) \(topic.rawValue.lowercased()) briefing", title: s.title,
                      teaser: s.notification, summary: s.summary, lines: s.points.map(\.line),
                      generated: s.generated, id: "\(topic.rawValue)-\(s.generated?.timeIntervalSince1970 ?? 0)")
        } else {
            return nil
        }
    }

    static let sample = BriefingDigest(
        topic: .tech, label: "Morning tech briefing",
        title: "Your briefing arrives at 5:00 each morning",
        teaser: nil, summary: "The day's biggest stories, read and summarised for you.",
        lines: ["Top stories with pictures", "Rumour watch with the odds", "Companies to watch"],
        generated: .now, id: "sample")
}
