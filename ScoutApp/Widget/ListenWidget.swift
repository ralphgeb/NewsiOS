import AppIntents
import SwiftUI
import WidgetKit

struct ListenConfig: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Listen"
    static var description = IntentDescription("Play a briefing without opening Scout.")

    @Parameter(title: "Section (small widget)", default: .tech)
    var section: BriefingSection
}

struct ListenEntry: TimelineEntry {
    let date: Date
    let section: BriefingSection
    /// The section playing in Scout right now (shows pause on its button).
    var nowPlaying: String? = ListenState.paused ? nil : ListenState.section
    /// Each section's briefing headline.
    let titles: [String: String]
    var appearance: Appearance = Appearance.load()
}

struct ListenProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> ListenEntry {
        ListenEntry(date: .now, section: .tech, titles: [:])
    }

    func snapshot(for config: ListenConfig, in context: Context) async -> ListenEntry {
        Appearance.current = Appearance.load()
        return entry(config, Feed.cached(Feed.briefing).flatMap(Feed.decodeBriefing))
    }

    func timeline(for config: ListenConfig, in context: Context) async -> Timeline<ListenEntry> {
        Appearance.current = Appearance.load()
        var briefing = Feed.cached(Feed.briefing).flatMap(Feed.decodeBriefing)
        if let data = try? await Feed.fetchFresh(Feed.briefing), let b = Feed.decodeBriefing(data) { briefing = b }
        return Timeline(entries: [entry(config, briefing)], policy: .after(.now.addingTimeInterval(60 * 60)))
    }

    private func entry(_ config: ListenConfig, _ briefing: Briefing?) -> ListenEntry {
        var titles: [String: String] = [:]
        for t in Topic.allCases { titles[t.rawValue] = briefing?.section(t)?.title }
        return ListenEntry(date: .now, section: config.section, titles: titles)
    }
}

struct ListenWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "ScoutListen", intent: ListenConfig.self, provider: ListenProvider()) { entry in
            ListenWidgetView(entry: entry)
        }
        .configurationDisplayName("Listen")
        .description("Play a briefing without opening Scout. Small: one section. Medium: all four.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct ListenWidgetView: View {
    let entry: ListenEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var scheme

    private var palette: PaletteColors { entry.appearance.colors(for: scheme == .dark ? .dark : .light) }
    private var text: Color { palette.textColor.color }
    private var ink: Color { palette.ink.color }
    private var accent: Color { entry.appearance.accent.color }

    var body: some View {
        Group {
            if family == .systemSmall { small } else { medium }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(for: .widget) { palette.background.color }
        .widgetURL(URL(string: "scout://news?section=\(entry.section.topic.rawValue)"))
    }

    private var label: some View {
        HStack(spacing: 6) {
            Circle().fill(accent).frame(width: 6, height: 6)
            Text("Listen").font(.system(size: 10, weight: .semibold)).tracking(1).textCase(.uppercase)
                .foregroundStyle(text.opacity(0.5))
        }
    }

    private func play(_ topic: Topic, size: CGFloat) -> some View {
        let on = entry.nowPlaying == topic.rawValue
        return Button(intent: PlayBriefingIntent(section: topic.rawValue, voice: "chirp")) {
            Image(systemName: on ? "pause.fill" : "play.fill")
                .font(.system(size: size * 0.38, weight: .bold))
                .foregroundStyle(.white)
                .offset(x: on ? 0 : size * 0.03)
                .frame(width: size, height: size)
                .background(accent, in: Circle())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
    }

    private var small: some View {
        let topic = entry.section.topic
        return VStack(alignment: .leading, spacing: 6) {
            label
            Text(topic.title).font(Theme.headline(17, weight: .bold)).foregroundStyle(text)
            Text(entry.titles[topic.rawValue] ?? "Your briefing arrives by 6:00")
                .font(.system(size: 11.5)).foregroundStyle(text.opacity(0.6)).lineLimit(3)
            Spacer(minLength: 0)
            play(topic, size: 40)
        }
    }

    private var medium: some View {
        VStack(alignment: .leading, spacing: 8) {
            label
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(Topic.allCases) { t in
                    HStack(spacing: 8) {
                        play(t, size: 30)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(t.title).font(.system(size: 13, weight: .bold)).foregroundStyle(text)
                            Text(entry.titles[t.rawValue] ?? "By 6:00").font(.system(size: 10)).foregroundStyle(text.opacity(0.55)).lineLimit(2)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }
}
