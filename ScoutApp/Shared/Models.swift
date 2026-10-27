import Foundation

// The shapes of data/news.json and data/briefing.json, written by the ScoutAI updater.
// Every field is read leniently: older stories miss newer fields, and one odd story
// should never stop the rest from loading.

struct Story: Codable, Identifiable, Hashable {
    var id: String
    var headline: String?
    var section: String?
    var image: String?
    var imageCredit: String?
    var status: String?
    var claim: String?
    var summary: String?
    var keyPoints: [String]?
    var likelihood: Double?
    var likelihoodReason: String?
    var signals: [String]?
    var topics: [String]?
    var overallImpact: String?
    var importance: Double?
    var marketTake: String?
    var stocks: [StockImpact]?
    var sources: [Source]?
    var firstSeen: Date?
    var firstPublished: Date?
    var lastUpdated: Date?

    enum CodingKeys: String, CodingKey {
        case id, headline, section, image, imageCredit, status, claim, summary, keyPoints, likelihood,
             likelihoodReason, signals, topics, overallImpact, importance, marketTake, stocks, sources,
             firstSeen, firstPublished, lastUpdated
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        headline = c.lenient(.headline)
        section = c.lenient(.section)
        image = c.lenient(.image)
        imageCredit = c.lenient(.imageCredit)
        status = c.lenient(.status)
        claim = c.lenient(.claim)
        summary = c.lenient(.summary)
        keyPoints = c.lenient(.keyPoints)
        likelihood = c.lenient(.likelihood)
        likelihoodReason = c.lenient(.likelihoodReason)
        signals = c.lenient(.signals)
        topics = c.lenient(.topics)
        overallImpact = c.lenient(.overallImpact)
        importance = c.lenient(.importance)
        marketTake = c.lenient(.marketTake)
        stocks = c.lenientArray(.stocks)
        sources = c.lenientArray(.sources)
        firstSeen = c.date(.firstSeen)
        firstPublished = c.date(.firstPublished)
        lastUpdated = c.date(.lastUpdated)
    }

    static func == (a: Story, b: Story) -> Bool { a.id == b.id && a.lastUpdated == b.lastUpdated }
    func hash(into h: inout Hasher) { h.combine(id) }

    // MARK: Accessors (mirroring the web app)

    var title: String { headline ?? sources?.first?.title ?? claim ?? "" }

    var lead: Source? { sources?.first }
    var outletName: String { lead?.name ?? newsSection.title }
    var outletCount: Int { max(1, sources?.count ?? 1) }

    var newsSection: Topic {
        switch (section ?? "").lowercased() {
        case "markets", "finance": return .finance
        case "world": return .world
        case "fashion": return .fashion
        default: return .tech
        }
    }

    /// When the story first appeared anywhere.
    var published: Date { firstPublished ?? firstSeen ?? lastUpdated ?? .distantPast }
    var updated: Date { lastUpdated ?? firstSeen ?? .distantPast }

    var imageURL: URL? {
        if let u = Self.web(image) { return u }
        return sources?.lazy.compactMap { Self.web($0.image) }.first
    }

    var isRumour: Bool { status == "rumour" }

    /// 0...100, with confirmed stories at 100.
    var odds: Int? {
        if status == "confirmed" { return 100 }
        if status == "denied" { return 0 }
        return likelihood.map { Int($0.rounded()) }
    }

    var verdict: String {
        switch status {
        case "confirmed": return "Confirmed"
        case "denied": return "Denied"
        default:
            let p = likelihood ?? 50
            return p >= 80 ? "Very likely" : p >= 65 ? "Likely" : p >= 35 ? "Toss-up" : p >= 15 ? "Unlikely" : "Very unlikely"
        }
    }

    var impactLevel: Int { Impact.level(overallImpact) }

    static func web(_ s: String?) -> URL? {
        guard let s, s.lowercased().hasPrefix("http"), let u = URL(string: s) else { return nil }
        return u
    }
}

enum Impact {
    static func level(_ s: String?) -> Int {
        switch s {
        case "low": return 1
        case "medium": return 2
        case "high": return 3
        default: return 0
        }
    }
}

struct Source: Codable, Hashable {
    var name: String
    var title: String?
    var link: String?
    var published: Date?
    var image: String?

    enum CodingKeys: String, CodingKey { case name, title, link, published, image }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = c.lenient(.name) ?? ""
        title = c.lenient(.title)
        link = c.lenient(.link)
        published = c.date(.published)
        image = c.lenient(.image)
    }

    var url: URL? { Story.web(link) }
    var host: String? { url?.host()?.replacingOccurrences(of: "www.", with: "") }
}

/// A company a story could move.
struct StockImpact: Codable, Hashable {
    var ticker: String
    var name: String?
    var direction: String?
    var impact: String?
    var reason: String?

    enum CodingKeys: String, CodingKey { case ticker, name, direction, impact, reason }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ticker = try c.decode(String.self, forKey: .ticker)
        name = c.lenient(.name)
        direction = c.lenient(.direction)
        impact = c.lenient(.impact)
        reason = c.lenient(.reason)
    }
}

/// A company, index or brand to watch in a briefing.
struct Mover: Codable, Hashable, Identifiable {
    var ticker: String
    var name: String?
    var direction: String?
    var note: String?
    var id: String { ticker }

    enum CodingKeys: String, CodingKey { case ticker, name, direction, note }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ticker = c.lenient(.ticker) ?? ""
        name = c.lenient(.name)
        direction = c.lenient(.direction)
        note = c.lenient(.note)
    }
}

enum Direction {
    static func arrow(_ d: String?) -> String {
        switch d {
        case "up": return "arrow.up.right"
        case "down": return "arrow.down.right"
        default: return "arrow.left.and.right"
        }
    }

    static func word(_ d: String?) -> String {
        switch d {
        case "up": return "Up"
        case "down": return "Down"
        default: return "Mixed"
        }
    }
}

struct NewsFile: Decodable {
    var updated: Date?
    var stories: [Story]

    enum CodingKeys: String, CodingKey { case updated, stories }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        updated = c.date(.updated)
        stories = c.lenientArray(.stories) ?? []
    }
}

// MARK: - Briefing

struct Briefing: Decodable {
    var editions: [Edition]
    var updated: Date?
    var sections: [String: SectionBrief]

    enum CodingKeys: String, CodingKey { case editions, updated, sections }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        editions = c.lenientArray(.editions) ?? []
        updated = c.date(.updated)
        sections = c.lenient(.sections) ?? [:]
    }

    init() {
        editions = []
        sections = [:]
    }

    func section(_ topic: Topic) -> SectionBrief? { sections[topic.rawValue] }
}

/// A morning or evening Tech briefing.
struct Edition: Decodable, Identifiable, Hashable {
    var id: String
    var edition: String
    var generated: Date
    var storyCount: Int?
    var title: String
    var notification: String?
    var intro: String?
    var topStories: [TopStory]
    var rumourWatch: [RumourNote]
    var stocksToWatch: [Mover]
    var inBrief: [BriefLine]

    enum CodingKeys: String, CodingKey {
        case id, edition, generated, storyCount, title, notification, intro, topStories, rumourWatch, stocksToWatch, inBrief
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        edition = c.lenient(.edition) ?? "Morning"
        guard let g = c.date(.generated) else {
            throw DecodingError.dataCorruptedError(forKey: .generated, in: c, debugDescription: "No date")
        }
        generated = g
        storyCount = c.lenient(.storyCount)
        title = c.lenient(.title) ?? ""
        notification = c.lenient(.notification)
        intro = c.lenient(.intro)
        topStories = c.lenientArray(.topStories) ?? []
        rumourWatch = c.lenientArray(.rumourWatch) ?? []
        stocksToWatch = c.lenientArray(.stocksToWatch) ?? []
        inBrief = c.lenientArray(.inBrief) ?? []
    }

    static func == (a: Edition, b: Edition) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    var isEvening: Bool { edition.lowercased() == "evening" }
}

struct TopStory: Decodable, Hashable {
    var storyId: String?
    var title: String
    var summary: String?

    enum CodingKeys: String, CodingKey { case storyId, title, summary }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        storyId = c.lenient(.storyId)
        title = c.lenient(.title) ?? ""
        summary = c.lenient(.summary)
    }
}

struct RumourNote: Decodable, Hashable {
    var storyId: String
    var note: String?

    enum CodingKeys: String, CodingKey { case storyId, note }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        storyId = try c.decode(String.self, forKey: .storyId)
        note = c.lenient(.note)
    }
}

struct BriefLine: Decodable, Hashable {
    var storyId: String?
    var line: String

    enum CodingKeys: String, CodingKey { case storyId, line, text }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        storyId = c.lenient(.storyId)
        line = (c.lenient(.line) as String?) ?? (c.lenient(.text) as String?) ?? ""
    }
}

/// The front page of Tech, Finance, World or Fashion, written each morning.
struct SectionBrief: Decodable, Hashable {
    var generated: Date?
    var leadStoryId: String?
    var title: String
    var notification: String?
    var summary: String?
    var points: [BriefLine]
    var movers: [Mover]

    enum CodingKeys: String, CodingKey { case generated, leadStoryId, title, notification, summary, points, movers }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        generated = c.date(.generated)
        leadStoryId = c.lenient(.leadStoryId)
        title = c.lenient(.title) ?? ""
        notification = c.lenient(.notification)
        summary = c.lenient(.summary)
        points = c.lenientArray(.points) ?? []
        movers = c.lenientArray(.movers) ?? []
    }
}

// MARK: - Topics

/// The four sections, and the topic of the Today page.
enum Topic: String, CaseIterable, Identifiable, Codable {
    case tech = "Tech", finance = "Finance", world = "World", fashion = "Fashion"

    var id: String { rawValue }
    var title: String { rawValue }

    var detail: String {
        switch self {
        case .tech: return "Gadgets, AI, big tech and startups"
        case .finance: return "Markets, companies and the economy"
        case .world: return "The big stories around the world"
        case .fashion: return "Designers, shows, luxury and beauty"
        }
    }

    var symbol: String {
        switch self {
        case .tech: return "bolt"
        case .finance: return "chart.line.uptrend.xyaxis"
        case .world: return "globe.europe.africa"
        case .fashion: return "sparkle"
        }
    }

    /// The heading over a section's companies in its briefing.
    var moversTitle: String {
        switch self {
        case .tech: return "Companies to watch"
        case .finance: return "Movers to watch"
        case .world: return "Market impact"
        case .fashion: return "Brands to watch"
        }
    }

    var coverLabel: String {
        switch self {
        case .finance: return "Markets today"
        default: return "\(rawValue) today"
        }
    }

    /// News interests, grouped as in Settings.
    var interests: [String] {
        switch self {
        case .tech:
            return ["AI", "Apple", "Google", "Microsoft", "Amazon", "Meta", "Nvidia", "Tesla & EVs", "Chips",
                    "Phones & Gadgets", "Computers", "Gaming", "Software & Apps", "Cybersecurity",
                    "Streaming & Media", "Social media", "Startups & VC", "Telecoms", "Space", "Science"]
        case .fashion:
            return ["Fashion & Luxury", "Designers & Shows", "Beauty", "Retail"]
        case .finance:
            return ["Markets & Economy", "Banks & Finance", "Deals & Mergers", "Crypto", "Central banks",
                    "Commodities", "Energy", "Cars", "Health & Biotech", "UK business"]
        case .world:
            return ["World politics", "Conflict & security", "Elections", "Trade & tariffs", "Policy & Regulation", "Climate"]
        }
    }
}

// MARK: - Lenient decoding

private struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

extension KeyedDecodingContainer {
    /// The value, or nil when it's missing, null or the wrong type.
    func lenient<T: Decodable>(_ key: Key) -> T? {
        (try? decodeIfPresent(T.self, forKey: key)) ?? nil
    }

    /// The array, skipping any element that doesn't decode.
    func lenientArray<T: Decodable>(_ key: Key) -> [T]? {
        guard let list = (try? decodeIfPresent([Lossy<T>].self, forKey: key)) ?? nil else { return nil }
        return list.compactMap(\.value)
    }

    func date(_ key: Key) -> Date? {
        guard let s: String = lenient(key) else { return nil }
        return ISODate.parse(s)
    }
}

enum ISODate {
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let plain = ISO8601DateFormatter()

    static func parse(_ s: String) -> Date? {
        fractional.date(from: s) ?? plain.date(from: s)
    }
}
