import SwiftUI
import WidgetKit

/// The sections along the top of News.
enum NewsSection: String, CaseIterable, Identifiable {
    case all = "All", tech = "Tech", finance = "Finance", world = "World", fashion = "Fashion"

    var id: String { rawValue }
    var topic: Topic? { Topic(rawValue: rawValue) }
}

enum RumourSort: String, CaseIterable, Identifiable {
    case latest, likely, unlikely, impact

    var id: String { rawValue }
    var title: String {
        switch self {
        case .latest: return "Latest"
        case .likely: return "Most likely"
        case .unlikely: return "Least likely"
        case .impact: return "Biggest impact"
        }
    }
}

/// Today's front page for one day: a written briefing when there is one, or else the day's
/// biggest stories in your topic.
struct FrontPage {
    struct Item: Identifiable {
        let id: String
        let story: Story?
        let title: String
        let text: String?
    }

    struct RumourItem: Identifiable {
        let story: Story
        let note: String?
        var id: String { story.id }
    }

    var label: String
    var generated: Date?
    var title: String
    var intro: [String]
    var cover: Story?
    var items: [Item]
    var rumours: [RumourItem]
    var movers: [Mover]
    var moversTitle: String
    var brief: [Item]
    var more: [Story]
    var reviewed: Int
    var isWritten: Bool
    /// The day's Tech editions (morning and evening), newest first.
    var editions: [Edition]
    var editionID: String?
}

@MainActor
final class NewsStore: ObservableObject {
    @Published private(set) var stories: [Story] = []
    @Published private(set) var briefing = Briefing()
    @Published private(set) var updated: Date?
    @Published private(set) var isLoading = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastFetch: Date?
    @Published private(set) var selectedDate: Date = Calendar.current.startOfDay(for: .now)
    @Published private(set) var saved: [Story] = []
    /// Stories per day in the Today topic, for the calendar.
    @Published private(set) var dayCounts: [Date: Int] = [:]

    @Published var topic: Topic {
        didSet {
            guard topic != oldValue else { return }
            Shared.topic = topic
            recountDays()
        }
    }

    @Published var interests: Set<String> {
        didSet { UserDefaults.standard.set(interests.sorted(), forKey: Self.interestsKey) }
    }

    private(set) var byId: [String: Story] = [:]
    private static let interestsKey = "news.interests"
    private var cal: Calendar { Calendar.current }

    init() {
        topic = Shared.topic
        interests = Set(UserDefaults.standard.stringArray(forKey: Self.interestsKey) ?? [])
        saved = Self.loadSaved()
        loadCache()
    }

    var hasChosenInterests: Bool { UserDefaults.standard.object(forKey: Self.interestsKey) != nil }

    // MARK: Loading

    private func loadCache() {
        if let data = Feed.cached(Feed.news), let file = try? Feed.decoder.decode(NewsFile.self, from: data) {
            apply(file)
        }
        if let data = Feed.cached(Feed.briefing), let b = Feed.decodeBriefing(data) {
            briefing = b
        }
        recountDays()
    }

    /// Fetches the latest news and briefing. The updater writes them twice a day, so this is cheap.
    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            async let newsData = Feed.fetch(Feed.news)
            async let briefingData = Feed.fetch(Feed.briefing)
            let (n, b) = try await (newsData, briefingData)
            let decoded = await Task.detached(priority: .userInitiated) { () -> (NewsFile?, Briefing?) in
                (try? Feed.decoder.decode(NewsFile.self, from: n), Feed.decodeBriefing(b))
            }.value
            if let file = decoded.0 { apply(file) }
            if let brief = decoded.1 { briefing = brief }
            recountDays()
            lastFetch = .now
            lastError = decoded.0 == nil ? "The news file couldn't be read. It may be mid-update; try again shortly." : nil
            WidgetCenter.shared.reloadTimelines(ofKind: Shared.widgetKind)
        } catch {
            if (error as? URLError)?.code == .cancelled { return }
            lastError = error.localizedDescription
        }
    }

    /// Refreshes when the last fetch is more than a few minutes old.
    func refreshIfStale() async {
        if (lastFetch?.timeIntervalSinceNow ?? -.infinity) < -5 * 60 { await refresh() }
    }

    private func apply(_ file: NewsFile) {
        stories = file.stories
        updated = file.updated
        byId = Dictionary(file.stories.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // keep saved copies fresh with the latest analysis
        var changed = false
        for i in saved.indices {
            if let s = byId[saved[i].id], s != saved[i] { saved[i] = s; changed = true }
        }
        if changed { persistSaved() }
    }

    func story(_ id: String?) -> Story? {
        guard let id else { return nil }
        return byId[id] ?? saved.first { $0.id == id }
    }

    // MARK: Days

    var isTodaySelected: Bool { cal.isDateInToday(selectedDate) }

    func select(_ date: Date) {
        selectedDate = cal.startOfDay(for: min(date, .now))
    }

    /// The first day the calendar offers.
    var firstDate: Date {
        let earliest = dayCounts.keys.min() ?? .now
        let monthAgo = cal.date(byAdding: .day, value: -60, to: .now) ?? .now
        return cal.startOfDay(for: max(earliest, monthAgo))
    }

    func hasContent(on date: Date) -> Bool {
        let day = cal.startOfDay(for: date)
        return (dayCounts[day] ?? 0) > 0 || isBriefed(day)
    }

    func isBriefed(_ date: Date) -> Bool {
        if topic == .tech { return briefing.editions.contains { cal.isDate($0.generated, inSameDayAs: date) } }
        guard let g = briefing.section(topic)?.generated else { return false }
        return cal.isDate(g, inSameDayAs: date)
    }

    private func recountDays() {
        var counts: [Date: Int] = [:]
        for s in stories where s.newsSection == topic && s.published != .distantPast {
            counts[cal.startOfDay(for: s.published), default: 0] += 1
        }
        dayCounts = counts
    }

    // MARK: Ranking (the same as the web app)

    /// How big a story is, for the front pages.
    func storyScore(_ s: Story) -> Double {
        Double(s.outletCount) * 2 + Double(s.impactLevel) * 2 + (s.imageURL == nil ? 0 : 1)
    }

    /// "All" is ranked by importance: the AI's 1-10 score and market impact, how many outlets
    /// cover it, how recent it is, and a small boost for your interests.
    func rankScore(_ s: Story, now: Date = .now) -> Double {
        let imp = s.importance ?? Double(s.impactLevel * 2 + 3)
        let hours = max(0, now.timeIntervalSince(s.published) / 3600)
        let liked: Double = (!interests.isEmpty && (s.topics ?? []).contains(where: { interests.contains($0) })) ? 1.5 : 0
        let base = imp * 1.6 + log2(Double(s.outletCount)) * 3 + Double(s.impactLevel) + (s.isRumour ? 0.5 : 0) + liked
        return base * pow(0.5, hours / 30)   // loses half its weight every 30 hours
    }

    /// Only stories first published in the last 72 hours are shown in News.
    private static let maxAge: TimeInterval = 72 * 3600

    func newsItems(_ section: NewsSection) -> [Story] {
        let now = Date.now
        let fresh = stories.filter { $0.published == .distantPast || now.timeIntervalSince($0.published) <= Self.maxAge }
        if let topic = section.topic {
            return fresh.filter { $0.newsSection == topic }.sorted { $0.published > $1.published }
        }
        let scores = Dictionary(fresh.map { ($0.id, rankScore($0, now: now)) }, uniquingKeysWith: { a, _ in a })
        return fresh.sorted { (scores[$0.id] ?? 0) > (scores[$1.id] ?? 0) }
    }

    func rumours(_ status: RumourStatus, sort: RumourSort) -> [Story] {
        let list = stories.filter { $0.status == status.rawValue }
        switch sort {
        case .latest: return list.sorted { $0.updated > $1.updated }
        case .likely: return list.sorted { ($0.likelihood ?? 0) > ($1.likelihood ?? 0) }
        case .unlikely: return list.sorted { ($0.likelihood ?? 100) < ($1.likelihood ?? 100) }
        case .impact:
            return list.sorted { ($0.impactLevel, $0.updated) > ($1.impactLevel, $1.updated) }
        }
    }

    var openRumourCount: Int { stories.filter(\.isRumour).count }

    /// Every story that names a company, newest first.
    func stories(mentioning ticker: String) -> [Story] {
        stories.filter { ($0.stocks ?? []).contains { $0.ticker == ticker } }.sorted { $0.published > $1.published }
    }

    // MARK: Front page

    func editions(on date: Date) -> [Edition] {
        briefing.editions.filter { cal.isDate($0.generated, inSameDayAs: date) }.sorted { $0.generated > $1.generated }
    }

    func frontPage(on date: Date, edition: String?) -> FrontPage? {
        let isToday = cal.isDateInToday(date)
        let since = Date.now.addingTimeInterval(-30 * 3600)
        let pool = stories
            .filter { $0.newsSection == topic && (isToday ? $0.published >= since : cal.isDate($0.published, inSameDayAs: date)) }
            .sorted { storyScore($0) > storyScore($1) }
        let name = topic.rawValue.lowercased()

        if topic == .tech {
            let eds = editions(on: date)
            if let ed = eds.first(where: { $0.id == edition }) ?? eds.first {
                let items = ed.topStories.enumerated().map { i, t in
                    FrontPage.Item(id: "\(i)-\(t.storyId ?? t.title)", story: story(t.storyId), title: t.title, text: t.summary)
                }
                let cover = items.first { $0.story?.imageURL != nil }?.story ?? items.first?.story
                return FrontPage(
                    label: "\(ed.edition) tech briefing", generated: ed.generated, title: ed.title,
                    intro: Self.paragraphs(ed.intro), cover: cover, items: items,
                    rumours: ed.rumourWatch.compactMap { r in story(r.storyId).map { FrontPage.RumourItem(story: $0, note: r.note) } },
                    movers: ed.stocksToWatch, moversTitle: topic.moversTitle,
                    brief: ed.inBrief.enumerated().map { i, b in
                        FrontPage.Item(id: "\(i)-\(b.storyId ?? b.line)", story: story(b.storyId), title: b.line, text: nil)
                    },
                    more: [], reviewed: ed.storyCount ?? pool.count, isWritten: true,
                    editions: eds, editionID: ed.id)
            }
        } else if let b = briefing.section(topic), let g = b.generated,
                  isToday ? g >= since : cal.isDate(g, inSameDayAs: date) {
            let points = b.points.enumerated().map { i, p in
                let s = story(p.storyId)
                return FrontPage.Item(id: "\(i)-\(p.storyId ?? p.line)", story: s, title: s?.title ?? p.line, text: p.line)
            }
            let cover = story(b.leadStoryId) ?? pool.first { $0.imageURL != nil }
            let used = Set([cover?.id].compactMap { $0} + b.points.compactMap(\.storyId))
            let hour = cal.component(.hour, from: g)
            return FrontPage(
                label: "\(hour < 12 ? "Morning" : "Evening") \(name) briefing", generated: g, title: b.title,
                intro: Self.paragraphs(b.summary), cover: cover, items: points, rumours: [],
                movers: b.movers, moversTitle: topic.moversTitle, brief: [],
                more: Array(pool.filter { !used.contains($0.id) }.prefix(6)),
                reviewed: pool.count, isWritten: true, editions: [], editionID: nil)
        }

        // No briefing written for that day: its biggest stories instead.
        guard !pool.isEmpty else { return nil }
        let cover = pool.first { $0.imageURL != nil } ?? pool[0]
        let rest = pool.filter { $0.id != cover.id }
        return FrontPage(
            label: isToday ? "Biggest \(name) stories so far" : "Biggest \(name) stories",
            generated: nil, title: cover.title, intro: Self.paragraphs(cover.summary), cover: cover,
            items: rest.prefix(5).map { FrontPage.Item(id: $0.id, story: $0, title: $0.title, text: $0.summary) },
            rumours: [], movers: [], moversTitle: topic.moversTitle, brief: [],
            more: Array(rest.dropFirst(5).prefix(6)),
            reviewed: pool.count, isWritten: false, editions: [], editionID: nil)
    }

    static func paragraphs(_ text: String?) -> [String] {
        (text ?? "").components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    // MARK: Saved

    func isSaved(_ id: String) -> Bool { saved.contains { $0.id == id } }

    func toggleSaved(_ story: Story) {
        if let i = saved.firstIndex(where: { $0.id == story.id }) {
            saved.remove(at: i)
        } else {
            saved.insert(story, at: 0)
        }
        persistSaved()
    }

    func unsave(_ id: String) {
        saved.removeAll { $0.id == id }
        persistSaved()
    }

    private static var savedURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appending(path: "saved.json")
    }

    private static func loadSaved() -> [Story] {
        guard let data = try? Data(contentsOf: savedURL) else { return [] }
        return (try? Feed.decoder.decode([Story].self, from: data)) ?? []
    }

    private func persistSaved() {
        if let data = try? Feed.encoder.encode(saved) { try? data.write(to: Self.savedURL, options: .atomic) }
    }
}
