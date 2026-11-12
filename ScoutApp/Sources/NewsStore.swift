import SwiftUI
import WidgetKit

/// The four sections along the top of Briefings (For you lives on Today).
enum NewsSection: String, CaseIterable, Identifiable {
    case tech = "Tech", finance = "Finance", world = "World", fashion = "Fashion"

    var id: String { rawValue }
    var topic: Topic? { Topic(rawValue: rawValue) }
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
    @Published private(set) var stories: [Story] = [] { didSet { invalidate(); words.removeAll(); people.removeAll() } }
    @Published private(set) var briefing = Briefing() { didSet { invalidate() } }
    @Published private(set) var updated: Date?
    @Published private(set) var isLoading = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastFetch: Date?
    @Published private(set) var saved: [Story] = []
    /// Stories you've opened, newest first, kept even after they leave the news.
    @Published private(set) var history: [HistoryEntry] = []

    @Published var topic: Topic {
        didSet {
            invalidate()
            guard topic != oldValue else { return }
            Shared.topic = topic
        }
    }

    @Published var interests: Set<String> {
        didSet {
            guard interests != oldValue else { return }
            invalidate()
            // saved and the widget told a moment later, so ticking several topics stays instant
            widgetSave?.cancel()
            widgetSave = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(700))
                guard let self, !Task.isCancelled else { return }
                UserDefaults.standard.set(self.interests.sorted(), forKey: Self.interestsKey)
                Shared.defaults.set(self.interests.sorted(), forKey: Shared.interestsKey)   // for the Headlines widget
                WidgetCenter.shared.reloadTimelines(ofKind: Shared.headlinesKind)
            }
        }
    }
    private var widgetSave: Task<Void, Never>?

    // MARK: Remembered results
    // For you, the sections and the front page are worked out once and kept until the news, the
    // briefing or your choices change, instead of on every redraw (tab switches, opening a story).
    private var memoFront: [String: FrontPage?] = [:]
    private var memoItems: [NewsSection: [Story]] = [:]
    /// Each headline's words and names, worked out once per story.
    private var words: [String: Set<String>] = [:]
    private var people: [String: Set<String>] = [:]

    private func invalidate() {
        memoFront.removeAll()
        memoItems.removeAll()
    }

    /// The regions World and Finance (and For you's world and market stories) come from.
    @Published var regions: Set<String> {
        didSet {
            invalidate()
            UserDefaults.standard.set(regions.sorted(), forKey: Self.regionsKey)
            Shared.defaults.set(regions.sorted(), forKey: Shared.regionsKey)
            if regions.contains("US") != oldValue.contains("US") { rebuild() }
        }
    }
    /// The stories as the updater wrote them, before the US preference below.
    private var rawStories: [Story] = []
    static let allRegions = ["UK", "US", "Europe", "Asia"]
    private static let regionsKey = "news.regions"

    private(set) var byId: [String: Story] = [:]
    private static let interestsKey = "news.interests"
    private var cal: Calendar { Calendar.current }

    init() {
        topic = Shared.topic
        interests = Set(UserDefaults.standard.stringArray(forKey: Self.interestsKey) ?? [])
        regions = Set(UserDefaults.standard.stringArray(forKey: Self.regionsKey) ?? Self.allRegions)
        Shared.defaults.set(interests.sorted(), forKey: Shared.interestsKey)
        Shared.defaults.set(regions.sorted(), forKey: Shared.regionsKey)
        saved = Self.loadSaved()
        history = Self.loadHistory()
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
    }

    /// Fetches the latest news and briefing. The updater writes them twice a day, so this is cheap.
    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            async let newsData = Feed.fetchFresh(Feed.news)
            async let briefingData = Feed.fetchFresh(Feed.briefing)
            let (n, b) = try await (newsData, briefingData)
            let decoded = await Task.detached(priority: .userInitiated) { () -> (NewsFile?, Briefing?) in
                (try? Feed.decoder.decode(NewsFile.self, from: n), Feed.decodeBriefing(b))
            }.value
            if let file = decoded.0 { apply(file) }
            if let brief = decoded.1 { briefing = brief }
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
        rawStories = file.stories
        updated = file.updated
        rebuild()
        // keep saved copies fresh with the latest analysis
        var changed = false
        for i in saved.indices {
            if let s = byId[saved[i].id], s != saved[i] { saved[i] = s; changed = true }
        }
        if changed { persistSaved() }
    }

    /// With US news on, a story Al Jazeera led is shown from another outlet when one covered it too.
    private func rebuild() {
        let preferOthers = regions.contains("US")
        stories = rawStories.map { s in
            guard preferOthers, var list = s.sources, list.count > 1, Self.isDemoted(list[0].name) else { return s }
            let first = list.removeFirst()
            if let i = list.firstIndex(where: { !Self.isDemoted($0.name) }) {
                let lead = list.remove(at: i)
                var out = s
                out.sources = [lead] + list + [first]
                return out
            }
            return s
        }
        byId = Dictionary(stories.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// Outlets that rank lower when you follow US news.
    static func isDemoted(_ outlet: String?) -> Bool { (outlet ?? "").localizedCaseInsensitiveContains("al jazeera") }

    /// How much a story's lead outlet lowers it (Al Jazeera, with US news on).
    private func outletPenalty(_ s: Story) -> Double {
        regions.contains("US") && Self.isDemoted(s.lead?.name) ? 2.5 : 0
    }

    func story(_ id: String?) -> Story? {
        guard let id else { return nil }
        return byId[id] ?? saved.first { $0.id == id } ?? history.first { $0.story.id == id }?.story
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
        let base = imp * 1.6 + log2(Double(s.outletCount)) * 3 + Double(s.impactLevel) + liked - outletPenalty(s)
        return base * pow(0.5, hours / 30)   // loses half its weight every 30 hours
    }

    /// Only stories first published in the last 72 hours are shown in News.
    private static let maxAge: TimeInterval = 72 * 3600

    func newsItems(_ section: NewsSection) -> [Story] {
        if let hit = memoItems[section] { return hit }
        let out = computeItems(section)
        memoItems[section] = out
        return out
    }

    private func computeItems(_ section: NewsSection) -> [Story] {
        let now = Date.now
        let fresh = stories.filter { ($0.published == .distantPast || now.timeIntervalSince($0.published) <= Self.maxAge) && inRegions($0) }
        if let topic = section.topic {
            // newest first, leaning towards what you've asked for: stories on your topics count as
            // six hours newer, and in World and Finance ones from the places you follow three hours
            // newer and from elsewhere six hours older (nothing is hidden); with US news on,
            // Al Jazeera-only stories count as six hours older
            let all = stories.filter { $0.published == .distantPast || now.timeIntervalSince($0.published) <= Self.maxAge }
            let placed = topic == .world || topic == .finance
            let key = { (s: Story) -> Date in
                var shift: TimeInterval = self.outletPenalty(s) > 0 ? -6 * 3600 : 0
                if self.matchesInterests(s) { shift += 6 * 3600 }
                if placed, !self.regions.isEmpty, let r = s.region, Self.allRegions.contains(r) {
                    shift += self.regions.contains(r) ? 3 * 3600 : -6 * 3600
                }
                return s.published.addingTimeInterval(shift)
            }
            let newest = all.filter { $0.newsSection == topic }.sorted { key($0) > key($1) }
            return Self.varied(newest, byRegion: topic == .finance || topic == .world)
        }
        return forYou(fresh, now: now)
    }

    /// Still roughly newest first, but varied: never the same outlet twice in a row (nor three
    /// times in four), and in Finance and World never more than two of the last three from one
    /// region, so the top of the page mixes the US, the UK, Europe and Asia.
    static func varied(_ list: [Story], byRegion: Bool) -> [Story] {
        var queue = list
        var out: [Story] = []
        out.reserveCapacity(list.count)
        while !queue.isEmpty {
            let lastOutlets = out.suffix(3).map(\.outletName)
            let lastRegions = out.suffix(3).compactMap(\.region)
            let ok = { (s: Story) -> Bool in
                if s.outletName == out.last?.outletName { return false }
                if lastOutlets.filter({ $0 == s.outletName }).count >= 2 { return false }
                if byRegion, let r = s.region, r != "Global", lastRegions.filter({ $0 == r }).count >= 2 { return false }
                return true
            }
            let i = queue.prefix(12).firstIndex(where: ok) ?? 0
            out.append(queue.remove(at: i))
        }
        return out
    }

    /// World and Finance stories from the regions you follow; Global ones, and other sections, always.
    func inRegions(_ s: Story) -> Bool {
        guard s.newsSection == .world || s.newsSection == .finance,
              let r = s.region, Self.allRegions.contains(r) else { return true }
        return regions.isEmpty || regions.contains(r)
    }

    /// Whether a story is on one of your topics.
    func matchesInterests(_ s: Story) -> Bool {
        !interests.isEmpty && (s.topics ?? []).contains { interests.contains($0) }
    }

    /// For you: stories on your topics, ranked by importance, with the day's very biggest stories
    /// mixed in so nothing major passes you by, and never more than three in a row on one topic.
    /// Before any topics are picked it's simply the most important stories.
    func forYou(_ pool: [Story], now: Date = .now) -> [Story] {
        let picked = interests.isEmpty ? pool : pool.filter { matchesInterests($0) || ($0.importance ?? 0) >= 8 }
        let scores = Dictionary(picked.map { s in
            (s.id, rankScore(s, now: now) + (interests.isEmpty ? 0 : (matchesInterests(s) ? 4 : 0) + Self.regionWeight(s)))
        }, uniquingKeysWith: { a, _ in a })
        var queue = withoutRepeats(picked.sorted { (scores[$0.id] ?? 0) > (scores[$1.id] ?? 0) })
        // never two stories about the same thing in a row (two Jensen Huang stories, say), and
        // never more than three in a row on one topic: the next one waits its turn
        var out: [Story] = []
        while !queue.isEmpty {
            let recent = out.suffix(3).compactMap { $0.topics?.first }
            let crowded = { (s: Story) in recent.count == 3 && Set(recent).count == 1 && s.topics?.first == recent[0] }
            let i = queue.prefix(10).firstIndex { s in !crowded(s) && !(out.last.map { similar($0, s) } ?? false) } ?? 0
            out.append(queue.remove(at: i))
        }
        return out
    }

    // MARK: Telling stories apart

    private static let stopWords: Set<String> = ["the", "and", "for", "with", "from", "that", "this", "after", "over", "into",
        "about", "says", "said", "will", "would", "could", "amid", "more", "than", "what", "when", "their", "they", "have",
        "has", "its", "new", "news", "report", "reports", "reportedly"]

    /// The words that say what a story is about: the headline's longer words, and the companies it names.
    static func keywords(_ s: Story) -> Set<String> {
        let words = s.title.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
            .filter { $0.count >= 4 && !stopWords.contains($0) }
        return Set(words)
    }

    /// The people and companies a headline names: capitalised words after the first.
    static func names(_ s: Story) -> Set<String> {
        let words = s.title.split(separator: " ").dropFirst().map { $0.trimmingCharacters(in: .punctuationCharacters) }
        return Set(words.filter { $0.count >= 4 && ($0.first?.isUppercase ?? false) }.map { $0.lowercased() })
            .union((s.stocks ?? []).prefix(2).map { $0.ticker.lowercased() })
    }

    private func kw(_ s: Story) -> Set<String> {
        if let k = words[s.id] { return k }
        let k = Self.keywords(s); words[s.id] = k; return k
    }

    private func nm(_ s: Story) -> Set<String> {
        if let k = people[s.id] { return k }
        let k = Self.names(s); people[s.id] = k; return k
    }

    /// About the same thing: they share a name (a person, a company, a ticker) or much of the headline.
    func similar(_ a: Story, _ b: Story) -> Bool {
        if !nm(a).isDisjoint(with: nm(b)) { return true }
        let ka = kw(a), kb = kw(b)
        guard !ka.isEmpty, !kb.isEmpty else { return false }
        return Double(ka.intersection(kb).count) / Double(ka.union(kb).count) >= 0.3
    }

    /// Drops near-copies of a story higher up (the same event told by two outlets).
    func withoutRepeats(_ list: [Story]) -> [Story] {
        var out: [Story] = []
        var kept: [Set<String>] = []
        for s in list {
            let ks = kw(s)
            let copy = kept.contains { ko in
                guard !ks.isEmpty, !ko.isEmpty else { return false }
                return Double(ks.intersection(ko).count) / Double(ks.union(ko).count) >= 0.55
            }
            if !copy { out.append(s); kept.append(ks) }
        }
        return out
    }

    /// A small lift by where a story happens: the US first, then the UK, Europe and Asia.
    static func regionWeight(_ s: Story) -> Double {
        switch s.region {
        case "US": return 1.6
        case "UK": return 1.1
        case "Global": return 0.8
        case "Europe": return 0.5
        default: return 0
        }
    }

    /// The small line under a story on For you: none (it used to say which topic put it there).
    func reason(_ s: Story) -> String? {
        nil
    }

    /// Every story that names a company, newest first.
    func stories(mentioning ticker: String) -> [Story] {
        stories.filter { ($0.stocks ?? []).contains { $0.ticker == ticker } }.sorted { $0.published > $1.published }
    }

    // MARK: Front page

    /// The latest Tech edition and the other one from the same day (morning and evening), newest first.
    func latestEditions() -> [Edition] {
        guard let latest = briefing.editions.max(by: { $0.generated < $1.generated }) else { return [] }
        return briefing.editions.filter { cal.isDate($0.generated, inSameDayAs: latest.generated) }.sorted { $0.generated > $1.generated }
    }

    /// Today's front page: the latest briefing for your topic, or the biggest stories of the last
    /// 30 hours while the first one is being written.
    func frontPage(edition: String?) -> FrontPage? {
        let key = edition ?? ""
        if let hit = memoFront[key] { return hit }
        let out = computeFront(edition: edition)
        memoFront[key] = out
        return out
    }

    private func computeFront(edition: String?) -> FrontPage? {
        if !interests.isEmpty { return forYouPage() }
        let since = Date.now.addingTimeInterval(-30 * 3600)
        let pool = stories
            .filter { $0.newsSection == topic && $0.published >= since }
            .sorted { storyScore($0) > storyScore($1) }

        if topic == .tech {
            let eds = latestEditions()
            if let ed = eds.first(where: { $0.id == edition }) ?? eds.first {
                let items = ed.topStories.enumerated().map { i, t in
                    FrontPage.Item(id: "\(i)-\(t.storyId ?? t.title)", story: story(t.storyId), title: t.title, text: t.summary)
                }
                let cover = items.first { $0.story?.imageURL != nil }?.story ?? items.first?.story
                return FrontPage(
                    label: "Top stories", generated: ed.generated, title: ed.title,
                    intro: Self.paragraphs(ed.intro), cover: cover, items: items,
                    rumours: ed.rumourWatch.compactMap { r in story(r.storyId).map { FrontPage.RumourItem(story: $0, note: r.note) } },
                    movers: ed.stocksToWatch, moversTitle: topic.moversTitle,
                    brief: ed.inBrief.enumerated().map { i, b in
                        FrontPage.Item(id: "\(i)-\(b.storyId ?? b.line)", story: story(b.storyId), title: b.line, text: nil)
                    },
                    more: [], reviewed: ed.storyCount ?? pool.count, isWritten: true,
                    editions: eds, editionID: ed.id)
            }
        } else if let b = briefing.section(topic), let g = b.generated, g >= since {
            let points = b.points.enumerated().map { i, p in
                let s = story(p.storyId)
                return FrontPage.Item(id: "\(i)-\(p.storyId ?? p.line)", story: s, title: s?.title ?? p.line, text: p.line)
            }
            let cover = story(b.leadStoryId) ?? pool.first { $0.imageURL != nil }
            let used = Set([cover?.id].compactMap { $0} + b.points.compactMap(\.storyId))
            return FrontPage(
                label: "Top stories", generated: g, title: b.title,
                intro: Self.paragraphs(b.summary), cover: cover, items: points, rumours: [],
                movers: b.movers, moversTitle: topic.moversTitle, brief: [],
                more: Array(pool.filter { !used.contains($0.id) }.prefix(6)),
                reviewed: pool.count, isWritten: true, editions: [], editionID: nil)
        }

        // No recent briefing: the biggest stories instead.
        guard !pool.isEmpty else { return nil }
        let cover = pool.first { $0.imageURL != nil } ?? pool[0]
        let rest = pool.filter { $0.id != cover.id }
        return FrontPage(
            label: "Top stories",
            generated: nil, title: cover.title, intro: Self.paragraphs(cover.summary), cover: cover,
            items: rest.prefix(5).map { FrontPage.Item(id: $0.id, story: $0, title: $0.title, text: $0.summary) },
            rumours: [], movers: [], moversTitle: topic.moversTitle, brief: [],
            more: Array(rest.dropFirst(5).prefix(6)),
            reviewed: pool.count, isWritten: false, editions: [], editionID: nil)
    }

    /// Today when you've picked topics: your biggest story on the cover, then your top stories,
    /// the companies to watch from the briefings of your sections, and more on your topics.
    func forYouPage() -> FrontPage? {
        let since = Date.now.addingTimeInterval(-30 * 3600)
        let ranked = forYou(stories.filter { $0.published >= since && inRegions($0) })
        guard !ranked.isEmpty else { return nil }
        let cover = ranked.prefix(4).first { $0.imageURL != nil } ?? ranked[0]
        let rest = ranked.filter { $0.id != cover.id }
        // the sections your topics belong to, for their briefings' movers
        let sections = Topic.allCases.filter { t in t.interests.contains { interests.contains($0) } }
        var seen = Set<String>()
        let movers = sections.compactMap { briefing.section($0) }.flatMap(\.movers).filter { seen.insert($0.ticker).inserted }
        return FrontPage(
            label: "Top stories", generated: updated, title: cover.title, intro: [], cover: cover,
            items: rest.prefix(7).map { FrontPage.Item(id: $0.id, story: $0, title: $0.title, text: reason($0)) },
            rumours: [], movers: Array(movers.prefix(6)), moversTitle: "Companies to watch", brief: [],
            more: Array(rest.dropFirst(7).prefix(24)),   // For you lives on Today now, so it runs longer
            reviewed: ranked.count, isWritten: true, editions: [], editionID: nil)
    }

    static func paragraphs(_ text: String?) -> [String] {
        (text ?? "").components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    // MARK: History

    /// Puts a story at the top of History (once, however often it's opened).
    func remember(_ story: Story) {
        if history.first?.story.id == story.id { return }
        history.removeAll { $0.story.id == story.id }
        history.insert(HistoryEntry(story: story, opened: .now), at: 0)
        if history.count > 300 { history.removeLast(history.count - 300) }
        persistHistory()
    }

    func forget(_ id: String) {
        history.removeAll { $0.story.id == id }
        persistHistory()
    }

    func clearHistory() {
        history = []
        persistHistory()
    }

    private static var historyURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appending(path: "history.json")
    }

    private static func loadHistory() -> [HistoryEntry] {
        guard let data = try? Data(contentsOf: historyURL) else { return [] }
        return (try? Feed.decoder.decode([HistoryEntry].self, from: data)) ?? []
    }

    private static let saveQueue = DispatchQueue(label: "scout.history", qos: .utility)

    /// Written in the background, so opening a story never waits for the disk.
    private func persistHistory() {
        let snapshot = history, url = Self.historyURL
        Self.saveQueue.async {
            let e = JSONEncoder()
            e.keyEncodingStrategy = .convertToSnakeCase
            e.dateEncodingStrategy = .iso8601
            if let data = try? e.encode(snapshot) { try? data.write(to: url, options: .atomic) }
        }
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

/// A story you opened, and when.
struct HistoryEntry: Codable, Identifiable {
    var story: Story
    var opened: Date
    var id: String { story.id }

    init(story: Story, opened: Date) {
        self.story = story
        self.opened = opened
    }

    // dates as ISO text, like the news files (the shared decoder has no date strategy)
    enum CodingKeys: String, CodingKey { case story, opened }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        story = try c.decode(Story.self, forKey: .story)
        opened = ISODate.parse(try c.decode(String.self, forKey: .opened)) ?? .distantPast
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(story, forKey: .story)
        try c.encode(opened.ISO8601Format(), forKey: .opened)
    }
}
