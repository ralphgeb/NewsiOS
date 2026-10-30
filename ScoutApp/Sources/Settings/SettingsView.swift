import SwiftUI
import UserNotifications
import StoreKit
import WeatherKit

/// Publishes appearance changes so the whole app redraws in the new colors.
@MainActor
final class AppearanceStore: ObservableObject {
    @Published var appearance: Appearance {
        didSet {
            // a preview isn't saved, so it can't outlive the minute
            if previewing { Appearance.current = appearance } else { Appearance.save(appearance) }
            Self.applyStyle(appearance.mode)
        }
    }
    /// True while a look is being tried without Scout Plus.
    @Published private(set) var previewing = false
    private var previewEnds: Task<Void, Never>?
    static let previewSeconds = 10   // short while testing; 60 for release

    init() { appearance = Appearance.current }

    /// A look from the row of presets. Without Scout Plus it's a preview: after a minute the
    /// colors fade back to Scout's own.
    func apply(_ preset: Preset) {
        var a = Appearance(preset: preset, numberStyle: appearance.numberStyle)
        a.sameInBoth = appearance.sameInBoth
        a.mode = appearance.mode
        if Plus.isActive {
            previewing = false
            appearance = a
            return
        }
        previewing = true
        appearance = a
        previewEnds?.cancel()
        previewEnds = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.previewSeconds))
            guard !Task.isCancelled else { return }
            self?.endPreview()
        }
    }

    /// Back to the saved look, gently.
    func endPreview() {
        guard previewing else { return }
        previewEnds?.cancel()
        var a = Appearance.load()
        a.mode = appearance.mode
        a.numberStyle = appearance.numberStyle
        withAnimation(.easeInOut(duration: 1.2)) {
            previewing = false
            appearance = a
        }
    }

    /// Light, dark or Automatic, set on the window itself: SwiftUI's preferredColorScheme
    /// doesn't let go of Light or Dark when you go back to Automatic.
    static func applyStyle(_ mode: AppearanceMode) {
        let style: UIUserInterfaceStyle = mode == .light ? .light : mode == .dark ? .dark : .unspecified
        for scene in UIApplication.shared.connectedScenes {
            for window in (scene as? UIWindowScene)?.windows ?? [] { window.overrideUserInterfaceStyle = style }
        }
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
    @EnvironmentObject private var weather: WeatherModel
    @EnvironmentObject private var tube: TubeService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    /// Today's hidden cards (the same setting as Edit on Today).
    @AppStorage("today.hidden") private var hiddenCards = ""
    @AppStorage(WeatherModel.modeKey) private var weatherMode = WeatherModel.Mode.location.rawValue
    @AppStorage(TransitCity.key) private var transitCity = TransitCity.automatic.rawValue
    @AppStorage("onboarded") private var onboarded = true
    @AppStorage(Notifier.enabledKey) private var notify = false
    @State private var notifyNote: String?
    @State private var weatherSources: URL?
    @AppStorage(Plus.key) private var hasPlus = false
    @AppStorage(Plus.sinceKey) private var since = 0.0
    @AppStorage(Plus.sourceKey) private var plusSource = ""
    @State private var showPlus = false
    @State private var previewNote = false
    @State private var currentIcon: String?

    var body: some View {
        NavigationStack {
            Form {
                plusSection
                notificationsSection
                newsSection
                appearanceSection
                iconSection
                todaySection
                Section("How Scout works") {
                    Button("Show the welcome again") {
                        dismiss()
                        // the welcome covers the app once Settings has closed
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { onboarded = false }
                    }
                    explainer("Today", "Each morning at 6:00 the ScoutAI updater reads about 150 news sites, and AI writes a briefing for Tech, Finance, World and Fashion (World and Finance cover the US, the UK, Europe and Asia). Today shows your For you front page: the main events, the key stories and what to watch. Pull Today down to refresh.")
                    explainer("For you", "Stories on your topics, ranked by importance: how big the story is (an AI score and its market impact), how many outlets cover it and how recent it is. The day's very biggest stories are mixed in, and no more than three in a row share a topic. Scout reads about 150 news sites from the UK, the US, Europe and Asia. The sections run newest first.")
                    explainer("Rumour odds", "For unconfirmed stories the AI weighs who is reporting it, how many outlets agree and what the companies say. Likely is 65% and up, a toss-up 35 to 64%. When a rumour comes true or is denied, its label changes.")
                    explainer("Stocks", "Prices for about 3,500 stocks, indices, currencies and cryptos update every 30 minutes on weekdays, 7:00 to 22:30 UK time. Stocks you follow, America's biggest companies and the stocks in the news also get charts and key numbers; the ones you follow and the biggest get an AI summary each morning.")
                    explainer("Market impact", "Which companies a story could move, up or down, and by how much: one dot is low, three is high. Tap a company for every story that names it.")
                }
                Section {
                } footer: {
                    Text("Summaries, odds and market effects are written by AI in its own words and can be wrong. Not financial advice. Every story links to the original.")
                }
            }
            .scrollContentBackground(.hidden)
            .foregroundStyle(Theme.text)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .tint(Theme.ink)
        }
        // switches show "on" in the accent, here and on the pages inside Settings
        .toggleStyle(SwitchToggleStyle(tint: Theme.accent))
        .sheet(isPresented: $showPlus) { PlusSheet(reason: "Keep your look, and make your own colours, with Scout Plus.") }
        .overlay(alignment: .top) {
            if previewNote {
                PreviewNote { showPlus = true; previewNote = false }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task {
                        try? await Task.sleep(for: .seconds(5))
                        withAnimation(.snappy) { previewNote = false }
                    }
            }
        }
    }

    // MARK: Scout Plus

    private var plusSection: some View {
        Section {
            if hasPlus {
                HStack {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(Theme.accent)
                    Text("Scout Plus")
                    Spacer()
                    Text(sinceText).foregroundStyle(Theme.secondary)
                }
                if plusSource == "store" {
                    Button("Manage subscription") {
                        Task {
                            if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                                try? await AppStore.showManageSubscriptions(in: scene)
                            }
                        }
                    }
                } else {
                    Button("End test subscription", role: .destructive) {
                        withAnimation(.snappy) { hasPlus = false }
                        // back to the main icon, which comes free
                        if UIApplication.shared.alternateIconName != nil { UIApplication.shared.setAlternateIconName(nil) }
                    }
                    .foregroundStyle(.red)
                }
            } else {
                Button { showPlus = true } label: {
                    HStack(spacing: 12) {
                        ScoutLogo().frame(width: 34, height: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Get Scout Plus").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
                            Text("Every story, your stocks and your colours · \(Plus.price) a month")
                                .font(.system(size: 13)).foregroundStyle(Theme.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.tertiary)
                    }
                    .padding(.vertical, 4)
                }
            }
        } footer: {
            if hasPlus {
                Text(plusSource == "store"
                     ? "Through the App Store. In TestFlight it's a sandbox purchase, so nothing is charged."
                     : "A test subscription: nothing was charged. Ending it locks Plus again.")
            }
        }
        .listRowBackground(Theme.card)
    }

    private var sinceText: String {
        since > 0 ? "Since \(Date(timeIntervalSince1970: since).formatted(.dateTime.day().month(.abbreviated)))" : "Active"
    }

    // MARK: News

    private var newsSection: some View {
        Section {
            NavigationLink {
                TopicsPage()
            } label: {
                row("Your topics", store.interests.isEmpty ? "None yet" : "\(store.interests.count)")
            }
            RegionChips()
                .padding(.vertical, 6)
            Picker("Widget briefing", selection: $store.topic) {
                ForEach(Topic.allCases) { Text($0.title).tag($0) }
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
            Text("For you on Today and in News follows your topics; Regions sets where World and Finance stories come from. The widget shows the briefing you pick here. News and the briefings are written at 6:00 each morning, London time; Scout fetches them whenever you open it.")
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
                        Button {
                            withAnimation(.snappy) { look.apply(p) }
                            if !hasPlus { withAnimation(.snappy) { previewNote = true } }
                        } label: {
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

            Picker("Typeface", selection: $look.appearance.numberStyle) {
                ForEach(NumberStyle.allCases) { s in
                    Text(s.title).tag(s)
                }
            }

            HStack(spacing: 16) {
                ZStack {
                    Ring(progress: 0.72, lineWidth: 5)
                    Text("72").font(Theme.number(15)).foregroundStyle(Theme.text)
                }
                .frame(width: 58, height: 58)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Morning tech briefing").scoutLabel()
                    Text("The day's biggest stories, at a glance").font(Theme.headline(17)).foregroundStyle(Theme.text)
                }
                Spacer()
            }
            .padding(.vertical, 4)

            if hasPlus {
                NavigationLink {
                    CustomColorsView()
                } label: {
                    HStack {
                        Text("Custom colors")
                        Spacer()
                        swatches
                    }
                }
            } else {
                Button { showPlus = true } label: {
                    HStack {
                        Text("Custom colors").foregroundStyle(Theme.text)
                        Spacer()
                        Image(systemName: "lock.fill").font(.system(size: 13)).foregroundStyle(Theme.tertiary)
                    }
                }
            }

            Button("Reset to original colors", role: .destructive) { withAnimation { look.reset() } }
                .foregroundStyle(.red)
        } header: {
            Text("Appearance")
        } footer: {
            Text(hasPlus
                 ? "Pick a look, or make your own under Custom colors; Reset goes back to Scout's own. The typeface is for headlines and numbers. The widgets follow too."
                 : "Try any look for a few seconds; Scout Plus keeps it and adds your own colours. Light, Dark and Automatic, and the typeface, are always yours to choose.")
        }
        .listRowBackground(Theme.card)
    }

    /// The colors in use now, as small dots.
    private var swatches: some View {
        let c = look.appearance.colors(for: scheme == .dark ? .dark : .light)
        return HStack(spacing: -5) {
            ForEach(Array([c.ink, c.textColor, look.appearance.accent, c.background, c.card].enumerated()), id: \.offset) { _, rgba in
                Circle().fill(rgba.color).frame(width: 18, height: 18)
                    .overlay(Circle().stroke(Theme.hairline, lineWidth: 1))
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: App icon

    /// The Home Screen icon in each look's colours: Scout Plus.
    private var iconSection: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(AppIcons.all, id: \.name) { icon in
                        let on = currentIcon == icon.alternate
                        Button {
                            guard hasPlus else { showPlus = true; return }
                            UIApplication.shared.setAlternateIconName(icon.alternate) { _ in
                                currentIcon = UIApplication.shared.alternateIconName
                            }
                        } label: {
                            VStack(spacing: 6) {
                                Image(icon.preview)
                                    .resizable()
                                    .frame(width: 60, height: 60)
                                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .stroke(on ? Theme.accent : Theme.hairline, lineWidth: on ? 2.5 : 1)
                                        .padding(-3))
                                    .overlay(alignment: .bottomTrailing) {
                                        if !hasPlus && icon.alternate != nil {
                                            Image(systemName: "lock.fill")
                                                .font(.system(size: 10, weight: .bold))
                                                .foregroundStyle(.white)
                                                .padding(5)
                                                .background(.black.opacity(0.45), in: Circle())
                                                .offset(x: 4, y: 4)
                                        }
                                    }
                                Text(icon.name).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondary)
                            }
                        }
                        .buttonStyle(PressStyle())
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 4)
            }
        } header: {
            Text("App icon")
        } footer: {
            Text(hasPlus ? "Your Home Screen icon, in the colours of each look." : "Icons in the colours of each look come with Scout Plus.")
        }
        .listRowBackground(Theme.card)
        .onAppear { currentIcon = UIApplication.shared.alternateIconName }
    }

    // MARK: Today, reading, notifications

    private var todaySection: some View {
        Section {
            Toggle("Weather", isOn: cardShown("weather"))
            if !hiddenCards.split(separator: ",").contains("weather") {
                Picker("Weather for", selection: $weatherMode) {
                    ForEach(WeatherModel.Mode.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .onChange(of: weatherMode) { _, _ in Task { await weather.refresh(force: true) } }
            }
            Toggle("Metro status", isOn: cardShown("tube"))
            if !hiddenCards.split(separator: ",").contains("tube") {
                Picker("Metro for", selection: $transitCity) {
                    ForEach(TransitCity.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .onChange(of: transitCity) { _, _ in Task { await tube.refresh(force: true) } }
            }
            Toggle("Markets", isOn: cardShown("markets"))
            // Apple Weather's credit, which Apple asks apps using its forecasts to show
            HStack {
                Text("\u{F8FF} Weather")
                Spacer()
                if let weatherSources {
                    Link("Data sources", destination: weatherSources).foregroundStyle(Theme.secondary)
                }
            }
            .task { weatherSources = try? await WeatherService.shared.attribution.legalPageURL }
        } header: {
            Text("On Today")
        } footer: {
            Text("Weather from Apple Weather (Open-Meteo stands in if it can't answer). Tap the weather card for the 24-hour chart. Metro status live for London (TfL), New York (MTA) and Paris (Île-de-France Mobilités); Automatic picks the nearest, or London. Tap the metro card to fold it away. To move cards, or hide others, tap Edit on Today.")
        }
        .listRowBackground(Theme.card)
    }

    /// A switch for one of Today's cards, sharing Today's own list of hidden cards.
    private func cardShown(_ card: String) -> Binding<Bool> {
        Binding(
            get: { !hiddenCards.split(separator: ",").contains(Substring(card)) },
            set: { show in
                var set = Set(hiddenCards.split(separator: ",").map(String.init))
                if show { set.remove(card) } else { set.insert(card) }
                withAnimation(.snappy) { hiddenCards = set.sorted().joined(separator: ",") }
            }
        )
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
            Text("A one-line teaser of your Today topic when a new briefing is written. iOS decides exactly when Scout checks, usually soon after 6:00.")
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

// MARK: - Custom colors

/// Every color you can change, for Light or Dark (or both), like Halo's.
struct CustomColorsView: View {
    @EnvironmentObject private var look: AppearanceStore
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Form {
            Section {
                ColorPicker("Main color", selection: colorBinding(\.ink), supportsOpacity: false)
                ColorPicker("Text", selection: textBinding, supportsOpacity: false)
                ColorPicker("Accent", selection: accentBinding, supportsOpacity: false)
                ColorPicker("Background", selection: colorBinding(\.background), supportsOpacity: false)
                ColorPicker("Cards", selection: colorBinding(\.card), supportsOpacity: false)
                Toggle("Same colors in Light and Dark", isOn: $look.appearance.sameInBoth)
            } footer: {
                Text("Colors you pick here are for \(look.appearance.sameInBoth ? "both Light and Dark mode" : (scheme == .dark ? "Dark mode" : "Light mode")). Main color is for rings, charts, icons and selected buttons; Text is for words, and fainter text is a lighter shade of it; Accent is for highlights, the selected tab and falling prices.")
            }
            .listRowBackground(Theme.card)

            Section("Preview") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 14) {
                        ZStack {
                            Ring(progress: 0.72, lineWidth: 5)
                            Text("72").font(Theme.number(15)).foregroundStyle(Theme.text)
                        }
                        .frame(width: 58, height: 58)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Morning tech briefing").scoutLabel()
                            Text("The day's biggest stories, at a glance").font(Theme.headline(17)).foregroundStyle(Theme.text)
                        }
                    }
                    Text("Top stories").font(.system(size: 20, weight: .heavy)).foregroundStyle(Theme.accent)
                    Text("Times and sources use a lighter shade of the text color.")
                        .font(.system(size: 13)).foregroundStyle(Theme.secondary)
                    HStack(spacing: 8) {
                        Text("Selected").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.background)
                            .padding(.horizontal, 12).frame(height: 28).background(Theme.ink, in: Capsule())
                        Text("Not selected").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                            .padding(.horizontal, 12).frame(height: 28).background(Theme.track, in: Capsule())
                    }
                }
                .padding(.vertical, 6)
            }
            .listRowBackground(Theme.card)

        }
        .scrollContentBackground(.hidden)
        .foregroundStyle(Theme.text)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Custom colors")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Edits the palette for the current appearance (or both, when they're shared).
    private func edit(_ change: (inout PaletteColors) -> Void) {
        var a = look.appearance
        a.presetID = "custom"
        if a.sameInBoth || scheme != .dark { change(&a.light) }
        if a.sameInBoth || scheme == .dark { change(&a.dark) }
        look.appearance = a
    }

    private func colorBinding(_ key: WritableKeyPath<PaletteColors, RGBA>) -> Binding<Color> {
        Binding(
            get: { look.appearance.colors(for: scheme == .dark ? .dark : .light)[keyPath: key].color },
            set: { new in edit { $0[keyPath: key] = RGBA(new) } }
        )
    }

    private var textBinding: Binding<Color> {
        Binding(
            get: { look.appearance.colors(for: scheme == .dark ? .dark : .light).textColor.color },
            set: { new in edit { $0.text = RGBA(new) } }
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
}

/// The note at the top of Settings when a look is tried without Scout Plus.
private struct PreviewNote: View {
    let getPlus: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "paintpalette.fill").font(.system(size: 16)).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Previewing for \(AppearanceStore.previewSeconds) seconds").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                Text("Get Scout Plus to keep it and customise every colour.")
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
            Spacer(minLength: 4)
            Button("Get Plus", action: getPlus)
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 12).frame(height: 30)
                .background(Theme.ink, in: Capsule())
                .foregroundStyle(Theme.background)
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 16, y: 6)
    }
}

/// Scout's icon in each look's colours. nil is the main icon.
enum AppIcons {
    struct Icon { let name: String; let alternate: String?; var preview: String { "IconPreview-\(name)" } }
    static let all: [Icon] = [Icon(name: "Scout", alternate: nil)] +
        ["Graphite", "Ocean", "Forest", "Mono", "Dusk", "Sand"].map { Icon(name: $0, alternate: "AppIcon-\($0)") }
}
