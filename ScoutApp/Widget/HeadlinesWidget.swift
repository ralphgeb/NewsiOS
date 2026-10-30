import SwiftUI
import WidgetKit

/// Your For you headlines on the Home Screen: the top stories on your topics, with the day's
/// biggest mixed in, ranked like the app. Large shows seven, medium three.
struct HeadlinesEntry: TimelineEntry {
    let date: Date
    let stories: [Line]
    let updated: Date?
    var appearance: Appearance = Appearance.load()

    struct Line: Identifiable {
        let id: String
        let title: String
        let outlet: String
        let published: Date
    }

    static let sample = HeadlinesEntry(date: .now, stories: [
        Line(id: "1", title: "Your top stories appear here every morning", outlet: "Scout", published: .now),
        Line(id: "2", title: "Ranked by how big they are and the topics you follow", outlet: "Scout", published: .now),
        Line(id: "3", title: "Tap one to open News", outlet: "Scout", published: .now),
    ], updated: .now)
}

struct HeadlinesProvider: TimelineProvider {
    func placeholder(in context: Context) -> HeadlinesEntry { .sample }

    func getSnapshot(in context: Context, completion: @escaping (HeadlinesEntry) -> Void) {
        Appearance.current = Appearance.load()
        completion(context.isPreview ? .sample : (Self.entry(from: Feed.cached(Feed.news)) ?? .sample))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<HeadlinesEntry>) -> Void) {
        Appearance.current = Appearance.load()
        Task {
            let data = (try? await Feed.fetchFresh(Feed.news)) ?? Feed.cached(Feed.news)
            let entry = Self.entry(from: data) ?? .sample
            completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(60 * 60))))
        }
    }

    /// The same idea as For you in the app: importance, outlets, market impact and freshness,
    /// with a lift for your topics, and World and Finance only from your regions.
    static func entry(from data: Data?) -> HeadlinesEntry? {
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
            if s.newsSection == .world || s.newsSection == .finance, let r = s.region, ["UK", "US", "Europe", "Asia"].contains(r) {
                return regions.contains(r)
            }
            return true
        }
        let top = pool.sorted { score($0) > score($1) }.prefix(7)
        return HeadlinesEntry(date: now,
                              stories: top.map { .init(id: $0.id, title: $0.title, outlet: $0.outletName, published: $0.published) },
                              updated: file.updated)
    }
}

struct HeadlinesWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Shared.headlinesKind, provider: HeadlinesProvider()) { entry in
            HeadlinesView(entry: entry)
                .widgetURL(URL(string: "scout://news"))
        }
        .configurationDisplayName("Headlines")
        .description("Your top stories, on the topics you follow.")
        .supportedFamilies([.systemMedium, .systemLarge])
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
        let count = family == .systemLarge ? 7 : 3
        VStack(alignment: .leading, spacing: family == .systemLarge ? 9 : 7) {
            HStack(spacing: 6) {
                Circle().fill(accent).frame(width: 6, height: 6)
                Text("For you" + (entry.updated.map { " · \(Format.time($0))" } ?? ""))
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1)
                    .textCase(.uppercase)
                    .foregroundStyle(text.opacity(0.5))
            }
            ForEach(Array(entry.stories.prefix(count).enumerated()), id: \.element.id) { i, s in
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Text("\(i + 1)")
                        .font(.system(size: 13, weight: .bold).monospacedDigit())
                        .foregroundStyle(i == 0 ? accent : text.opacity(0.3))
                        .frame(width: 14, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.title)
                            .font(Theme.headline(i == 0 && family == .systemLarge ? 15 : 13.5, weight: .semibold))
                            .foregroundStyle(text)
                            .lineLimit(2)
                        Text("\(s.outlet) · \(s.published.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(text.opacity(0.45))
                            .lineLimit(1)
                    }
                }
                if family == .systemLarge, i < count - 1 {
                    Rectangle().fill(palette.ink.color.opacity(0.08)).frame(height: 0.5).padding(.leading, 23)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(for: .widget) { palette.background.color }
    }
}
