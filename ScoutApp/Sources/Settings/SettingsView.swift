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
    static let previewSeconds = 60

    init() { appearance = Appearance.current }

    /// A look from the row of presets. The light looks switch to Light. Without Scout Plus, any but
    /// your free one is a preview: after a minute the colors fade back.
    func apply(_ preset: Preset) {
        var a = Appearance(preset: preset, numberStyle: appearance.numberStyle)
        a.sameInBoth = appearance.sameInBoth
        a.mode = preset.prefersLight ? .light : appearance.mode
        if Plus.isActive || preset.id == Plus.freeStyle {
            Self.crossfade {
                previewing = false
                appearance = a
            }
            return
        }
        Self.crossfade {
            previewing = true
            appearance = a
        }
        previewEnds?.cancel()
        previewEnds = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.previewSeconds))
            guard !Task.isCancelled else { return }
            self?.endPreview()
        }
    }

    /// The welcome's style page: this look becomes the free one, and is applied.
    func chooseFree(_ preset: Preset) {
        UserDefaults.standard.set(preset.id, forKey: Plus.freeStyleKey)
        apply(preset)
    }

    /// Back to the saved look, gently.
    func endPreview() {
        guard previewing else { return }
        previewEnds?.cancel()
        var a = Appearance.load()
        a.mode = appearance.mode
        a.numberStyle = appearance.numberStyle
        Self.crossfade(duration: 1.2) {
            previewing = false
            appearance = a
        }
    }

    /// Changes the look under a picture of the screen as it is, then fades the picture away, so
    /// one look melts into the next (instead of both fading out over black and back in).
    static func crossfade(duration: Double = 0.8, _ change: () -> Void) {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .filter { !$0.isHidden }
        let shots: [UIView] = windows.compactMap { w in
            guard let shot = w.snapshotView(afterScreenUpdates: false) else { return nil }
            shot.frame = w.bounds
            w.addSubview(shot)
            return shot
        }
        var quiet = Transaction()
        quiet.disablesAnimations = true
        withTransaction(quiet) { change() }
        UIView.animate(withDuration: duration, delay: 0.08, options: [.curveEaseInOut, .allowUserInteraction]) {
            shots.forEach { $0.alpha = 0 }
        } completion: { _ in
            shots.forEach { $0.removeFromSuperview() }
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
        // back to Scout's own colours, or without Plus to your free look
        let base = Plus.isActive ? Preset.all[0] : (Preset.all.first { $0.id == Plus.freeStyle } ?? Preset.all[0])
        var a = Appearance(preset: base, numberStyle: Appearance.standard.numberStyle)
        a.mode = base.prefersLight ? .light : appearance.mode
        previewEnds?.cancel()
        Self.crossfade {
            previewing = false
            appearance = a
        }
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
    @AppStorage(Plus.freeStyleKey) private var freeStyle = "scout"
    @AppStorage(Plus.testFreeKey) private var testAsFree = false
    @AppStorage(PlayAll.key) private var playAll = PlayAll.defaultValue
    @State private var showPlus = false
    @State private var previewNote = false
    @State private var currentIcon: String?

    var body: some View {
        NavigationStack {
            Form {
                plusSection
                newsSection
                notificationsSection
                appearanceSection
                iconSection
                Section {
                    if !hasPlus {
                        Button("Restore purchases") { Task { await PlusStore.shared.restore() } }
                    }
                    Link("Privacy policy", destination: Plus.privacyURL)
                    Link("Terms of use", destination: Plus.termsURL)
                    Link("Support", destination: Plus.supportURL)
                }
                .listRowBackground(Theme.card)
                Section("How Scout works") {
                    explainer("Briefings", "Twice a day, by 6:00 and by 16:30 UK time, Scout reads about 180 news sites from the US, the UK, Europe and Asia, and AI writes a briefing for Tech, Finance, World and Fashion: what happened, why it matters and what to watch. Pull any page down to refresh.")
                    explainer("For you", "Today's front page: stories on your topics, ranked by how big they are (an AI score and market impact), how many outlets cover them and how recent they are, with the day's biggest stories mixed in and no more than three in a row on one topic.")
                    explainer("Sections", "Tech, Finance, World and Fashion run newest first, with the stories on your topics and from the places you follow moved up, a mix of outlets and regions at the top, and nothing hidden.")
                    explainer("Listening", "With Scout Plus every briefing is read aloud, and Play my briefings on Today plays them one after another. Any story can be played too: the first time anyone plays it, it's recorded in a few seconds and kept for everyone.")
                    explainer("Stocks", "Prices for about 3,500 stocks, indices, currencies and cryptos update every 30 minutes on weekdays, 7:00 to 22:30 UK time. Stocks you follow, America's biggest companies and the stocks in the news also get charts, key numbers and a daily AI summary.")
                    explainer("Market impact", "Which companies a story could move, up or down, and by how much: one dot is low, three is high. Tap a company for every story that names it.")
                }
                .listRowBackground(Theme.card)
                updatesSection
                if Plus.isTestFlight { testFlightSection }
                Section {
                } footer: {
                    Text("Scout's summaries are written by AI, and it can get things wrong now and then, so please don't treat anything here as financial advice. Every story links to the original if you'd like to read more.")
                }
            }
            .scrollContentBackground(.hidden)
            // the same gap between every section, and Scout Plus close to the top
            .listSectionSpacing(18)
            .contentMargins(.top, 4, for: .scrollContent)
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
                }
            } else {
                Button { showPlus = true } label: {
                    HStack(spacing: 12) {
                        ScoutLogo(animated: false).frame(width: 34, height: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Get Scout Plus").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
                            Text("Listen, every story, your stocks and colours · \(Plus.price) a month")
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
                Text("Through the App Store.")
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
            RegionChips()
                .padding(.vertical, 6)
            NavigationLink {
                TopicsPage()
            } label: {
                row("Your topics", store.interests.isEmpty ? "None yet" : "\(store.interests.count)")
            }
            NavigationLink {
                subpage("What to play") { playAllSection }
            } label: {
                row("What to play in your briefings", "\(PlayAll.sections(playAll).count) of 4")
            }
            NavigationLink {
                subpage("Today") { todaySection }
            } label: {
                row("What to see on Today", "")
            }
            Picker("Notification briefing", selection: $store.topic) {
                ForEach(Topic.allCases) { Text($0.title).tag($0) }
            }
        } header: {
            Text("News")
        } footer: {
            Text("World and Finance lean towards the places you pick; Tech, Finance, World and Fashion lean towards your topics.")
        }
        .listRowBackground(Theme.card)
    }

    /// Which briefings Play my briefings plays, in order.
    private var playAllSection: some View {
        Section {
            ForEach(Topic.allCases) { t in
                Toggle(t.title, isOn: Binding(
                    get: { PlayAll.sections(playAll).contains(t) },
                    set: { on in
                        var set = Set(PlayAll.sections(playAll))
                        if on { set.insert(t) } else if set.count > 1 { set.remove(t) }
                        playAll = Topic.allCases.filter(set.contains).map(\.rawValue).joined(separator: ",")
                    }))
                .tint(Theme.accent)
            }
        } header: {
            Text("Play my briefings")
        } footer: {
            Text("The briefings Play my briefings on Today plays, one after another, in this order.")
        }
        .listRowBackground(Theme.card)
    }

    /// When the news last came in, and a way to fetch it now: at the bottom, out of the way.
    private var updatesSection: some View {
        Section {
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
            Text("Updates")
        }
        .listRowBackground(Theme.card)
    }

    /// TestFlight builds only: switches for trying things out. The App Store build never shows this.
    private var testFlightSection: some View {
        Section {
            Toggle("Test as a free user", isOn: $testAsFree)
                .tint(Theme.accent)
                .onChange(of: testAsFree) { _, _ in Task { await PlusStore.shared.refresh() } }
            Button("Hear the friendly opening again") { Intro.reset() }
            Button("Show the welcome again") { onboarded = false; dismiss() }
            Link("Scout numbers (halopro.xyz)", destination: URL(string: "https://halopro.xyz/scout/")!)
            row("Version", "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""))")
        } header: {
            Text("TestFlight")
        } footer: {
            Text(testAsFree ? "Scout Plus is off on this phone so you can try the free version; switch it off to get your subscription back." : "Only in TestFlight builds. Test as a free user turns Scout Plus off on this phone without cancelling the sandbox subscription.")
        }
        .listRowBackground(Theme.card)
    }

    /// A page inside Settings, in Settings' own look.
    private func subpage<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        Form { content() }
            .scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
            .foregroundStyle(Theme.text)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toggleStyle(SwitchToggleStyle(tint: Theme.accent))
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
                            look.apply(p)
                            if !hasPlus && p.id != freeStyle { withAnimation(.snappy) { previewNote = true } }
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
                                // your free look is yours; the others come with Scout Plus (a try lasts a minute)
                                .overlay(alignment: .bottomTrailing) {
                                    if !hasPlus && p.id != freeStyle {
                                        Image(systemName: "lock.fill")
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundStyle(.white)
                                            .padding(4)
                                            .background(.black.opacity(0.45), in: Circle())
                                    }
                                }
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

            Button("Reset to original colors", role: .destructive) { look.reset() }
                .foregroundStyle(.red)
        } header: {
            Text("Appearance")
        } footer: {
            if !hasPlus { Text("Your look is free. Try the others for a minute; Scout Plus keeps them.") }
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
            Toggle("Top stories", isOn: cardShown("top"))
            Toggle("In brief", isOn: cardShown("brief"))
            Toggle("More stories", isOn: cardShown("more"))
            Toggle("Companies to watch", isOn: cardShown("movers"))
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
            Text("Switch off the cards you don't want on Today.")
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
                Text("For \(look.appearance.sameInBoth ? "Light and Dark mode" : (scheme == .dark ? "Dark mode" : "Light mode")).")
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
        ["Graphite", "Greyscale", "Ocean", "Sky", "Blush", "Forest", "Mono", "Dusk", "Sand"].map { Icon(name: $0, alternate: "AppIcon-\($0)") }
}
