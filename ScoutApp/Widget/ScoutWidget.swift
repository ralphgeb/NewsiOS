import SwiftUI
import WidgetKit

@main
struct ScoutWidgets: WidgetBundle {
    var body: some Widget {
        BriefingWidget()
    }
}

struct BriefingEntry: TimelineEntry {
    let date: Date
    let digest: BriefingDigest
}

struct BriefingProvider: TimelineProvider {
    func placeholder(in context: Context) -> BriefingEntry {
        BriefingEntry(date: .now, digest: .sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (BriefingEntry) -> Void) {
        Appearance.current = Appearance.load()
        completion(BriefingEntry(date: .now, digest: context.isPreview ? .sample : (cachedDigest() ?? .sample)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<BriefingEntry>) -> Void) {
        Appearance.current = Appearance.load()
        // The widget fetches the briefing itself, so it updates even when Scout isn't opened.
        Task {
            var digest = cachedDigest()
            if let data = try? await Feed.fetch(Feed.briefing), let b = Feed.decodeBriefing(data) {
                digest = BriefingDigest(briefing: b, topic: Shared.topic) ?? digest
            }
            let entry = BriefingEntry(date: .now, digest: digest ?? .sample)
            completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(60 * 60))))
        }
    }

    private func cachedDigest() -> BriefingDigest? {
        Feed.cached(Feed.briefing).flatMap(Feed.decodeBriefing).flatMap { BriefingDigest(briefing: $0, topic: Shared.topic) }
    }
}

struct BriefingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Shared.widgetKind, provider: BriefingProvider()) { entry in
            BriefingWidgetView(entry: entry)
                .containerBackground(for: .widget) { Theme.background }
                .widgetURL(URL(string: "scout://today"))
        }
        .configurationDisplayName("Briefing")
        .description("Your Today briefing's headline and top stories.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular, .accessoryInline])
    }
}

struct BriefingWidgetView: View {
    let entry: BriefingEntry
    @Environment(\.widgetFamily) private var family

    private var d: BriefingDigest { entry.digest }

    var body: some View {
        switch family {
        case .systemMedium: medium
        case .systemLarge: large
        case .accessoryRectangular: rectangular
        case .accessoryInline: Text(d.title)
        default: small
        }
    }

    private var label: some View {
        HStack(spacing: 6) {
            Circle().fill(Theme.accent).frame(width: 6, height: 6)
            Text(d.topic.title + (d.generated.map { " · \(Format.time($0))" } ?? ""))
                .font(.system(size: 10, weight: .semibold))
                .tracking(1)
                .textCase(.uppercase)
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
        }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            label
            Text(d.title)
                .font(Theme.headline(16, weight: .bold))
                .foregroundStyle(Theme.ink)
                .lineLimit(5)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var medium: some View {
        VStack(alignment: .leading, spacing: 7) {
            label
            Text(d.title)
                .font(Theme.headline(17, weight: .bold))
                .foregroundStyle(Theme.ink)
                .lineLimit(2)
            lines(2)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var large: some View {
        VStack(alignment: .leading, spacing: 10) {
            label
            Text(d.title)
                .font(Theme.headline(21, weight: .bold))
                .foregroundStyle(Theme.ink)
                .lineLimit(3)
            if let s = d.summary {
                Text(s).font(.system(size: 13)).foregroundStyle(Theme.ink.opacity(0.75)).lineLimit(4)
            }
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
            lines(5)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func lines(_ n: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(d.lines.prefix(n).enumerated()), id: \.offset) { i, line in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text("\(i + 1)").font(Theme.number(12, weight: .bold)).foregroundStyle(Theme.tertiary)
                    Text(line).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink).lineLimit(2)
                }
            }
        }
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(d.label).font(.system(size: 11, weight: .semibold)).textCase(.uppercase).widgetAccentable()
            Text(d.title).font(.system(size: 14, weight: .semibold)).lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
