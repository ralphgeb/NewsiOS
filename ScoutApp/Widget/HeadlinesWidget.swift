import SwiftUI
import WidgetKit

/// Your For you headlines on the Home Screen: the top stories on your topics, with the day's
/// biggest mixed in, ranked like the app. Large shows four, medium two, each with the opening of the story.
struct HeadlinesEntry: TimelineEntry {
    let date: Date
    let stories: [Line]
    let updated: Date?
    var section: WidgetSection = .forYou
    var appearance: Appearance = Appearance.load()

    struct Line: Identifiable {
        let id: String
        let title: String
        let outlet: String
        let published: Date
        /// The first sentences of the story's summary.
        var lead: String = ""
    }

    static var sample: HeadlinesEntry { HeadlinesEntry(date: .now, stories: [
        Line(id: "1", title: "Your top stories appear here every morning", outlet: "Scout", published: .now),
        Line(id: "2", title: "Ranked by how big they are and the topics you follow", outlet: "Scout", published: .now),
        Line(id: "3", title: "Tap one to open News", outlet: "Scout", published: .now),
    ], updated: .now) }
}

struct HeadlinesProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> HeadlinesEntry {
        Appearance.current = Appearance.load()
        return .sample
    }

    func snapshot(for config: HeadlinesConfig, in context: Context) async -> HeadlinesEntry {
        Appearance.current = Appearance.load()
        if context.isPreview { return .sample }
        return Self.entry(from: Feed.cached(Feed.news), section: config.section) ?? .sample
    }

    func timeline(for config: HeadlinesConfig, in context: Context) async -> Timeline<HeadlinesEntry> {
        Appearance.current = Appearance.load()
        let data = (try? await Feed.fetchFresh(Feed.news)) ?? Feed.cached(Feed.news)
        let entry = Self.entry(from: data, section: config.section) ?? .sample
        return Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(60 * 60)))
    }

    /// The first `n` sentences of a summary.
    static func sentences(_ text: String, _ n: Int) -> String {
        var out: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { sub, _, _, stop in
            if let sub { out.append(sub.trimmingCharacters(in: .whitespaces)) }
            if out.count >= n { stop = true }
        }
        return out.joined(separator: " ")
    }

    /// The same idea as For you in the app: importance, outlets, market impact and freshness,
    /// with a lift for your topics, and World and Finance only from your regions.
    static func entry(from data: Data?, section: WidgetSection) -> HeadlinesEntry? {
        guard let data, let file = try? Feed.decoder.decode(NewsFile.self, from: data) else { return nil }
        let interests = Set(Shared.defaults.stringArray(forKey: Shared.interestsKey) ?? [])
        let regions = Set(Shared.defaults.stringArray(forKey: Shared.regionsKey) ?? ["UK", "US", "Europe", "Asia"])
        let now = Date.now
        func score(_ s: Story) -> Double {
            let hours = max(0, now.timeIntervalSince(s.published) / 3600)
            let liked = (s.topics ?? []).contains { interests.contains($0) } ? 4.0 : 0
            let base = (s.importance ?? 4) * 1.6 + log2(Double(s.outletCount)) * 3 + Double(s.impactLevel) + liked
            return base * pow(0.5, hours / 30)
        }
        let pool = file.stories.filter { s in
            guard now.timeIntervalSince(s.published) < 36 * 3600 else { return false }
            if let topic = section.topic, s.newsSection != topic { return false }
            if s.newsSection == .world || s.newsSection == .finance, let r = s.region, ["UK", "US", "Europe", "Asia"].contains(r) {
                return regions.contains(r)
            }
            return true
        }
        let top = pool.sorted { score($0) > score($1) }.prefix(7)
        return HeadlinesEntry(date: now,
                              stories: top.map { .init(id: $0.id, title: $0.title, outlet: $0.outletName, published: $0.published,
                                                     lead: Self.sentences($0.summary ?? $0.claim ?? "", 2)) },
                              updated: file.updated, section: section)
    }
}

struct HeadlinesWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: Shared.headlinesKind, intent: HeadlinesConfig.self, provider: HeadlinesProvider()) { entry in
            HeadlinesView(entry: entry)
        }
        .configurationDisplayName("Headlines")
        .description("The top stories for you, or for one section. Touch and hold, then Edit Widget, to pick it.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct HeadlinesView: View {
    let entry: HeadlinesEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var scheme

    private var palette: PaletteColors { entry.appearance.colors(for: scheme == .dark ? .dark : .light) }
    private var text: Color { palette.textColor.color }
    private var accent: Color { entry.appearance.accent.color }

    var body: some View {
        Group {
            if family == .systemSmall { small } else { list }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(for: .widget) { palette.background.color }
    }

    private var label: some View {
        HStack(spacing: 6) {
            Circle().fill(accent).frame(width: 6, height: 6)
            Text(entry.section.title + (entry.updated.map { " · \(Format.time($0))" } ?? ""))
                .font(.system(size: 10, weight: .semibold))
                .tracking(1)
                .textCase(.uppercase)
                .foregroundStyle(text.opacity(0.5))
                .lineLimit(1)
        }
    }

    /// 2x2: the top story, which it opens.
    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            label
            if let s = entry.stories.first {
                Text(s.title)
                    .font(Theme.headline(15, weight: .bold))
                    .foregroundStyle(text)
                    .lineLimit(4)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 0)
                Text(s.outlet).font(.system(size: 10.5, weight: .medium)).foregroundStyle(text.opacity(0.45)).lineLimit(1)
            }
        }
        .widgetURL(entry.stories.first.map { Self.storyURL($0.id) } ?? entry.section.url)
    }

    /// 4x2: two stories, each a headline with two lines of the story under it. 4x4: four.
    private var list: some View {
        let large = family == .systemLarge
        let count = large ? 4 : 2
        let shown = Array(entry.stories.prefix(count))
        return VStack(alignment: .leading, spacing: large ? 12 : 8) {
            label
            ForEach(Array(shown.enumerated()), id: \.element.id) { i, s in
                // each story opens itself
                Link(destination: Self.storyURL(s.id)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.title)
                            .font(Theme.headline(large ? 15 : 13.5, weight: .bold))
                            .foregroundStyle(text)
                            .lineLimit(large ? 2 : 1)
                        if !s.lead.isEmpty {
                            Text(s.lead)
                                .font(.system(size: large ? 12.5 : 11.5))
                                .foregroundStyle(text.opacity(0.62))
                                .lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if i < shown.count - 1 {
                    Rectangle().fill(palette.ink.color.opacity(0.08)).frame(height: 0.5)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .widgetURL(entry.section.url)
    }

    static func storyURL(_ id: String) -> URL { URL(string: "scout://story/\(id)")! }
}
