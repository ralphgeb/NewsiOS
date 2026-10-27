import SwiftUI
import UserNotifications

/// Publishes appearance changes so the whole app redraws in the new colors.
@MainActor
final class AppearanceStore: ObservableObject {
    @Published var appearance: Appearance { didSet { Appearance.save(appearance) } }

    init() { appearance = Appearance.current }

    func apply(_ preset: Preset) {
        var a = Appearance(preset: preset, numberStyle: appearance.numberStyle)
        a.sameInBoth = appearance.sameInBoth
        a.mode = appearance.mode
        appearance = a
    }

    /// Back to the original colors and type; light or dark stays as you set it.
    func reset() {
        var a = Appearance.standard
        a.mode = appearance.mode
        appearance = a
    }
}

struct SettingsView: View {
    @EnvironmentObject private var store: NewsStore
    @EnvironmentObject private var look: AppearanceStore
    @EnvironmentObject private var weather: WeatherService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @AppStorage(WeekStart.key) private var weekStartsOnMonday = WeekStart.startsOnMonday
    @AppStorage(WeatherService.modeKey) private var weatherMode = WeatherService.Mode.location.rawValue
    @AppStorage("links.reader") private var reader = false
    @AppStorage(Notifier.enabledKey) private var notify = false
    @State private var notifyNote: String?

    var body: some View {
        NavigationStack {
            Form {
                newsSection
                appearanceSection
                todaySection
                readingSection
                notificationsSection
                Section("How Scout works") {
                    explainer("Today", "Each morning at 5:00 the ScoutAI updater reads about 100 news sites, and AI writes a front page for Tech, Finance, World and Fashion: the main events, the key stories and what to watch. Tech also gets an evening edition and Rumour watch. Pull Today down, or tap the date, for earlier days.")
                    explainer("All", "Ranked by importance: how big the story is (an AI score and its market impact), how many outlets cover it, how recent it is, and a small boost for your interests. It loses half its weight every 30 hours. The sections run newest first.")
                    explainer("Rumour odds", "For unconfirmed stories the AI weighs who is reporting it, how many outlets agree and what the companies say. Likely is 65% and up, a toss-up 35 to 64%. When a rumour comes true or is denied, it moves to Confirmed or Denied.")
                    explainer("Market impact", "Which companies a story could move, up or down, and by how much: one dot is low, three is high. Tap a company for every story that names it.")
                }
                Section {
                } footer: {
                    Text("Summaries, odds and market effects are written by AI in its own words and can be wrong. Not financial advice. Every story links to the original.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .tint(Theme.ink)
        }
    }

    // MARK: News

    private var newsSection: some View {
        Section {
            Picker("Today is about", selection: $store.topic) {
                ForEach(Topic.allCases) { Text($0.title).tag($0) }
            }
            NavigationLink {
                InterestsView()
            } label: {
                row("News interests", store.interests.isEmpty ? "None" : "\(store.interests.count)")
            }
            Button {
                Task { await store.refresh() }
            } label: {
                HStack {
                    Text("Refresh now")
                    Spacer()
                    if store.isLoading { ProgressView() }
                    else if let d = store.lastFetch {
                        Text(d.formatted(.relative(presentation: .named))).foregroundStyle(Theme.secondary)
                    }
                }
            }
            if let message = store.lastError {
                Text(message).font(.footnote).foregroundStyle(Theme.accent)
            }
            row("Last update", store.updated.map { $0.formatted(.dateTime.weekday(.abbreviated).hour().minute()) } ?? "–")
            row("Stories", store.stories.count.formatted())
        } header: {
            Text("News")
        } footer: {
            Text("Interests rank stories higher under All. News and Today are written at 5:00 each morning, London time; Scout fetches them whenever you open it.")
        }
        .listRowBackground(Theme.card)
    }

    // MARK: Appearance (the same as Halo's)

    private var appearanceSection: some View {
        Section {
            Picker("Mode", selection: $look.appearance.mode) {
                ForEach(AppearanceMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(Preset.all) { p in
                        Button { withAnimation(.snappy) { look.apply(p) } } label: {
                            VStack(spacing: 6) {
                                ZStack {
                                    Circle().fill((scheme == .dark ? p.dark : p.light).background.color)
                                    Circle().inset(by: 7).trim(from: 0, to: 0.72)
                                        .stroke((scheme == .dark ? p.dark : p.light).ink.color, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                                        .rotationEffect(.degrees(-90))
                                    Circle().fill(p.accent.color).frame(width: 9, height: 9)
                                }
                                .frame(width: 52, height: 52)
                                .overlay(Circle().stroke(look.appearance.presetID == p.id ? Theme.accent : Theme.hairline,
                                                         lineWidth: look.appearance.presetID == p.id ? 2 : 1))
                                Text(p.name).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 6)
            }

            ColorPicker("Main color", selection: colorBinding(\.ink), supportsOpacity: false)
            ColorPicker("Accent", selection: accentBinding, supportsOpacity: false)
            ColorPicker("Background", selection: colorBinding(\.background), supportsOpacity: false)
            ColorPicker("Cards", selection: colorBinding(\.card), supportsOpacity: false)
            Toggle("Same colors in Light and Dark", isOn: $look.appearance.sameInBoth)

            Picker("Typeface", selection: $look.appearance.numberStyle) {
                ForEach(NumberStyle.allCases) { s in
                    Text(s.title).tag(s)
                }
            }

            HStack(spacing: 16) {
                ZStack {
                    Ring(progress: 0.72, lineWidth: 5)
                    Text("72").font(Theme.number(15)).foregroundStyle(Theme.ink)
                }
                .frame(width: 58, height: 58)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Morning tech briefing").scoutLabel()
                    Text("The day's biggest stories, at a glance").font(Theme.headline(17)).foregroundStyle(Theme.ink)
                }
                Spacer()
            }
            .padding(.vertical, 4)

            Button("Reset to original colors", role: .destructive) { withAnimation { look.reset() } }
        } header: {
            Text("Appearance")
        } footer: {
            Text("Colors you pick here are for \(look.appearance.sameInBoth ? "both Light and Dark mode" : (scheme == .dark ? "Dark mode" : "Light mode")). The typeface is for headlines and numbers. The widgets follow too.")
        }
        .listRowBackground(Theme.card)
    }

    /// Edits the palette for the current appearance (or both, when they're shared).
    private func colorBinding(_ key: WritableKeyPath<PaletteColors, RGBA>) -> Binding<Color> {
        Binding(
            get: { look.appearance.colors(for: scheme == .dark ? .dark : .light)[keyPath: key].color },
            set: { new in
                var a = look.appearance
                a.presetID = "custom"
                if a.sameInBoth || scheme != .dark { a.light[keyPath: key] = RGBA(new) }
                if a.sameInBoth || scheme == .dark { a.dark[keyPath: key] = RGBA(new) }
                look.appearance = a
            }
        )
    }

    private var accentBinding: Binding<Color> {
        Binding(
            get: { look.appearance.accent.color },
            set: { new in
                look.appearance.presetID = "custom"
                look.appearance.accent = RGBA(new)
            }
        )
    }

    // MARK: Today, reading, notifications

    private var todaySection: some View {
        Section {
            Picker("Weather", selection: $weatherMode) {
                ForEach(WeatherService.Mode.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .onChange(of: weatherMode) { _, _ in Task { await weather.refresh(force: true) } }
            Picker("Week starts on", selection: $weekStartsOnMonday) {
                Text("Monday").tag(true)
                Text("Sunday").tag(false)
            }
        } header: {
            Text("Today")
        } footer: {
            Text("Weather by Open-Meteo, Tube status live from TfL. To hide a card, or move it, tap Edit on Today.")
        }
        .listRowBackground(Theme.card)
    }

    private var readingSection: some View {
        Section {
            Toggle("Open articles in Reader", isOn: $reader)
        } header: {
            Text("Reading")
        } footer: {
            Text("Opens the original article in Safari's Reader view when the site allows it.")
        }
        .listRowBackground(Theme.card)
    }

    private var notificationsSection: some View {
        Section {
            Toggle("Morning briefing", isOn: Binding(get: { notify }, set: { on in
                Task {
                    if on {
                        let granted = await Notifier.requestAccess()
                        notify = granted
                        notifyNote = granted ? nil : "Notifications are off for Scout. Turn them on in the Settings app › Notifications › Scout."
                        if granted { Notifier.markSeen(store.briefing) }
                    } else {
                        notify = false
                    }
                }
            }))
            if let notifyNote {
                Text(notifyNote).font(.footnote).foregroundStyle(Theme.accent)
            }
        } header: {
            Text("Notifications")
        } footer: {
            Text("A one-line teaser of your Today topic when a new briefing is written. iOS decides exactly when Scout checks, usually soon after 5:00.")
        }
        .listRowBackground(Theme.card)
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).font(Theme.number(16, weight: .medium)).foregroundStyle(Theme.secondary)
        }
    }

    private func explainer(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(text).font(.system(size: 13)).foregroundStyle(Theme.secondary)
        }
        .padding(.vertical, 2)
        .listRowBackground(Theme.card)
    }
}

/// Topics ranked higher under All, grouped by section.
struct InterestsView: View {
    @EnvironmentObject private var store: NewsStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            ForEach(Topic.allCases) { topic in
                Section(topic.title) {
                    ForEach(topic.interests, id: \.self) { t in
                        Button {
                            withAnimation(.snappy) {
                                if store.interests.contains(t) { store.interests.remove(t) } else { store.interests.insert(t) }
                            }
                        } label: {
                            HStack {
                                Text(t).foregroundStyle(Theme.ink)
                                Spacer()
                                if store.interests.contains(t) {
                                    Image(systemName: "checkmark").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.accent)
                                }
                            }
                        }
                    }
                }
                .listRowBackground(Theme.card)
            }
            Section {
                if !store.interests.isEmpty {
                    Button("Clear all", role: .destructive) { withAnimation(.snappy) { store.interests.removeAll() } }
                }
            } footer: {
                Text("Stories on these topics rank higher under All in News.")
            }
            .listRowBackground(Theme.card)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("News interests")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .tint(Theme.ink)
        .sensoryFeedback(.selection, trigger: store.interests)
    }
}

/// The morning briefing notification. Scout checks for a new briefing when iOS wakes it in the
/// background, and posts its one-line teaser.
enum Notifier {
    static let enabledKey = "notify.morning"
    private static let seenKey = "notify.seen"

    static func requestAccess() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    /// Marks the current briefing as already seen, so only newer ones notify.
    static func markSeen(_ briefing: Briefing) {
        if let d = BriefingDigest(briefing: briefing, topic: Shared.topic) {
            UserDefaults.standard.set(d.id, forKey: seenKey)
        }
    }

    static func notifyIfNew(_ briefing: Briefing) async {
        guard UserDefaults.standard.bool(forKey: enabledKey),
              let d = BriefingDigest(briefing: briefing, topic: Shared.topic),
              d.id != UserDefaults.standard.string(forKey: seenKey),
              let g = d.generated, Date.now.timeIntervalSince(g) < 12 * 3600 else { return }
        UserDefaults.standard.set(d.id, forKey: seenKey)
        let content = UNMutableNotificationContent()
        content.title = d.label
        content.body = d.teaser ?? d.title
        content.sound = .default
        content.userInfo = ["url": "scout://today"]
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: d.id, content: content, trigger: nil))
    }
}
