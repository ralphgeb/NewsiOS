import AppIntents
import SwiftUI
import WidgetKit

struct ListenConfig: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Listen"
    static var description = IntentDescription("Play a briefing without opening Scout.")

    @Parameter(title: "Section (small widget)", default: .tech)
    var section: BriefingSection
}

/// The up and down arrows: move one widget to the next or previous section's briefing. Each
/// widget keeps its own page (by its size and the section picked in Edit Widget), so two Listen
/// widgets don't move together.
struct ListenStepIntent: AppIntent {
    static var title: LocalizedStringResource = "Next briefing"
    static var isDiscoverable = false

    /// Where this widget's page is kept.
    @Parameter(title: "Widget") var slot: String
    /// The section it shows now.
    @Parameter(title: "Section") var current: String
    @Parameter(title: "Step") var step: Int

    init() {}
    init(slot: String, current: Topic, step: Int) {
        self.slot = slot
        self.current = current.rawValue
        self.step = step
    }

    static func key(_ slot: String) -> String { "listen.widget.\(slot)" }

    func perform() async throws -> some IntentResult {
        let all = Topic.allCases
        let i = all.firstIndex { $0.rawValue == current } ?? 0
        Shared.defaults.set(all[(i + step + all.count) % all.count].rawValue, forKey: Self.key(slot))
        return .result()
    }
}

struct ListenEntry: TimelineEntry {
    let date: Date
    /// The section shown now (the arrows move it).
    let topic: Topic
    /// This widget's own page key (its size and configured section).
    var slot: String = ""
    /// Scout Plus (listening is part of it); without it the play button opens the offer.
    var plus: Bool = Shared.defaults.bool(forKey: "plus.active")
    /// The section playing in Scout right now (shows pause on its button).
    var nowPlaying: String? = ListenState.paused ? nil : ListenState.section
    /// Each section's briefing headline.
    let titles: [String: String]
    /// Each section's briefing in three sentences.
    var summaries: [String: String] = [:]
    var appearance: Appearance = Appearance.load()
}

struct ListenProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> ListenEntry {
        Appearance.current = Appearance.load()
        return ListenEntry(date: .now, topic: .tech, titles: [:])
    }

    func snapshot(for config: ListenConfig, in context: Context) async -> ListenEntry {
        Appearance.current = Appearance.load()
        return entry(config, context, Feed.cached(Feed.briefing).flatMap(Feed.decodeBriefing))
    }

    func timeline(for config: ListenConfig, in context: Context) async -> Timeline<ListenEntry> {
        Appearance.current = Appearance.load()
        var briefing = Feed.cached(Feed.briefing).flatMap(Feed.decodeBriefing)
        if let data = try? await Feed.fetchFresh(Feed.briefing), let b = Feed.decodeBriefing(data) { briefing = b }
        return Timeline(entries: [entry(config, context, briefing)], policy: .after(.now.addingTimeInterval(60 * 60)))
    }

    private func entry(_ config: ListenConfig, _ context: Context, _ briefing: Briefing?) -> ListenEntry {
        var titles: [String: String] = [:], summaries: [String: String] = [:]
        for t in Topic.allCases {
            guard let b = briefing?.section(t) else { continue }
            titles[t.rawValue] = b.title
            summaries[t.rawValue] = Self.sentences(b.summary ?? "", 3)
        }
        // the section the arrows chose, else the one picked in Edit Widget
        let slot = "\(context.family == .systemSmall ? "small" : "medium")-\(config.section.rawValue)"
        let topic = Shared.defaults.string(forKey: ListenStepIntent.key(slot)).flatMap(Topic.init(rawValue:)) ?? config.section.topic
        return ListenEntry(date: .now, topic: topic, slot: slot, titles: titles, summaries: summaries)
    }

    /// The first `n` sentences of a briefing's summary.
    static func sentences(_ text: String, _ n: Int) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        var out: [String] = []
        flat.enumerateSubstrings(in: flat.startIndex..., options: .bySentences) { sub, _, _, stop in
            if let sub { out.append(sub.trimmingCharacters(in: .whitespaces)) }
            if out.count >= n { stop = true }
        }
        return out.joined(separator: " ")
    }
}

struct ListenWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "ScoutListen", intent: ListenConfig.self, provider: ListenProvider()) { entry in
            ListenWidgetView(entry: entry)
        }
        .configurationDisplayName("Listen")
        .description("Play a briefing without opening Scout. Use the arrows to move between Tech, Finance, World and Fashion.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct ListenWidgetView: View {
    let entry: ListenEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var scheme

    private var palette: PaletteColors { entry.appearance.colors(for: scheme == .dark ? .dark : .light) }
    private var text: Color { palette.textColor.color }
    private var accent: Color { entry.appearance.accent.color }
    private var topic: Topic { entry.topic }

    var body: some View {
        Group {
            if family == .systemSmall { small } else { medium }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(for: .widget) { palette.background.color }
        .widgetURL(URL(string: "scout://news?section=\(topic.rawValue)"))
    }

    private var label: some View {
        HStack(spacing: 6) {
            Image(systemName: "headphones").font(.system(size: 9, weight: .bold)).foregroundStyle(accent)
            Text("Listen").font(.system(size: 10, weight: .semibold)).tracking(1).textCase(.uppercase)
                .foregroundStyle(text.opacity(0.5))
        }
    }

    @ViewBuilder private func play(size: CGFloat) -> some View {
        if entry.plus { playButton(size: size) } else {
            Link(destination: URL(string: "scout://plus")!) {
                Image(systemName: "lock.fill")
                    .font(.system(size: size * 0.34, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(accent, in: Circle())
            }
            .accessibilityLabel("Listening is part of Scout Plus")
        }
    }

    private func playButton(size: CGFloat) -> some View {
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
        .accessibilityLabel(on ? "Pause the \(topic.title) briefing" : "Play the \(topic.title) briefing")
    }

    /// An up or down arrow with a big target, so it's easy to press.
    private func arrow(_ step: Int) -> some View {
        Button(intent: ListenStepIntent(slot: entry.slot, current: topic, step: step)) {
            Image(systemName: step < 0 ? "chevron.up" : "chevron.down")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(text.opacity(0.7))
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(step < 0 ? "Previous briefing" : "Next briefing")
    }

    /// Four dots, one filled for the section shown.
    private var dots: some View {
        VStack(spacing: 4) {
            ForEach(Topic.allCases) { t in
                Circle().fill(t == topic ? accent : text.opacity(0.2)).frame(width: 5, height: 5)
            }
        }
    }

    private var arrows: some View {
        VStack(spacing: 0) {
            arrow(-1)
            Spacer(minLength: 4)
            dots
            Spacer(minLength: 4)
            arrow(1)
        }
        .frame(width: 40)
        .padding(.vertical, -8)
        .padding(.trailing, -8)
    }

    private var small: some View {
        HStack(alignment: .top, spacing: 4) {
            VStack(alignment: .leading, spacing: 5) {
                label
                Text(topic.title).font(Theme.headline(17, weight: .bold)).foregroundStyle(text)
                Text(entry.titles[topic.rawValue] ?? "Your briefing arrives by 6:00")
                    .font(.system(size: 11.5)).foregroundStyle(text.opacity(0.6)).lineLimit(3)
                Spacer(minLength: 0)
                play(size: 44)
            }
            Spacer(minLength: 0)
            arrows
        }
    }

    /// Like the small one, with the headline and the briefing's opening beside the play button.
    private var medium: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 5) {
                label
                Text(topic.title).font(Theme.headline(17, weight: .bold)).foregroundStyle(text)
                Spacer(minLength: 0)
                play(size: 44)
            }
            .frame(width: 92, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.titles[topic.rawValue] ?? "Your \(topic.title) briefing")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(text).lineLimit(2)
                Text(entry.summaries[topic.rawValue] ?? "Briefings arrive by 6:00 each morning.")
                    .font(.system(size: 11.5)).lineSpacing(1).foregroundStyle(text.opacity(0.62))
                    .lineLimit(5)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            arrows
        }
    }
}
