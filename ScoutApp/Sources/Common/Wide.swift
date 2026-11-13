import SwiftUI

// MARK: - The iPhone Duo
//
// Everything in this file is for the iPhone Duo only. Any other iPhone never reaches it: RootView
// shows the ordinary tab bar there, exactly as before.
//
// Folded (the outer screen) Scout is the phone app, a little wider and shorter, with the four tabs
// standing in the right-hand column under the clock and battery, and the floating player above
// the page while something plays. Opened, what's playing becomes one more button in the tab rail.
// Opened and held sideways, each page splits into two columns (Today: the weather and Top stories
// on the left, More for you on the right; Briefings: the briefing left, the stories right; Stocks:
// your stocks and the ones in the news left, the top ten right). Opened and upright: one roomy
// column, and a story shows the rest of the stories in a grid underneath.

private struct ScoutDuoKey: EnvironmentKey { static let defaultValue = false }
private struct DuoInnerKey: EnvironmentKey { static let defaultValue = false }
private struct ScoutWideKey: EnvironmentKey { static let defaultValue = false }
private struct StatusBandKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }

extension EnvironmentValues {
    /// True only on the iPhone Duo (either screen); false on every other iPhone.
    var scoutDuo: Bool {
        get { self[ScoutDuoKey.self] }
        set { self[ScoutDuoKey.self] = newValue }
    }
    /// The Duo opened up (the big inner screen), either way round.
    var duoInner: Bool {
        get { self[DuoInnerKey.self] }
        set { self[DuoInnerKey.self] = newValue }
    }
    /// True on the opened Duo held sideways: pages split into two columns, stories open in two.
    var scoutWide: Bool {
        get { self[ScoutWideKey.self] }
        set { self[ScoutWideKey.self] = newValue }
    }
    /// The status bar's height when it runs across the top (the opened Duo, upright); 0 elsewhere.
    var statusBand: CGFloat {
        get { self[StatusBandKey.self] }
        set { self[StatusBandKey.self] = newValue }
    }
}

enum DuoScreen {
    /// The iPhone Duo: both its screens are far squarer than any ordinary iPhone's (an ordinary
    /// iPhone's screen is at least 1.7 times as tall as it's wide). Read from the screen itself,
    /// never from the space a page gets, so the keyboard or a sheet can't flip the layout.
    @MainActor static var isFoldable: Bool {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let b = scene?.screen.bounds ?? UIScreen.main.bounds
        let long = max(b.width, b.height), short = max(1, min(b.width, b.height))
        return long / short < 1.6
    }
    /// The opened Duo: the big screen (the outer one is under 560 points across).
    static func inner(_ size: CGSize) -> Bool { min(size.width, size.height) >= 560 }
    /// Wide enough for two phone-width columns: the opened Duo held sideways.
    static func columns(_ size: CGSize) -> Bool { size.width >= 760 }
}

/// A page's navigation stack (each tab keeps its own, as on the phone).
struct ScoutNavigation<Content: View>: View {
    var path: Binding<NavigationPath>? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        if let path {
            NavigationStack(path: path, root: content)
        } else {
            NavigationStack(root: content)
        }
    }
}

/// The Duo, closed or open: one page at a time, the four tabs stacked at the bottom of the
/// right-hand column, under the clock, camera and battery. Where iOS keeps that column for itself
/// (the status column) the tabs sit inside it.
struct DuoRoot: View {
    @Binding var tab: Int
    @Binding var showSettings: Bool
    let statusColumn: CGFloat
    /// The opened Duo: what's playing is a button in the rail. Folded: it floats over the page.
    let inner: Bool
    @ObservedObject private var speaker = Speaker.shared
    @ObservedObject private var bar = TabBarState.shared

    var body: some View {
        let inColumn = statusColumn > 40
        let column = inColumn ? statusColumn : 74
        HStack(spacing: 0) {
            GeometryReader { g in
                ZStack {
                    // every page stays alive (and keeps its place) while another one shows; each is
                    // held to exactly the space there is, so one page can never push the others wider
                    page(0, g.size) { TodayView(showSettings: $showSettings) }
                    page(1, g.size) { NewsView(showSettings: $showSettings) }
                    page(2, g.size) { StocksView(showSettings: $showSettings) }
                    page(3, g.size) { HistoryView(showSettings: $showSettings) }
                }
                .frame(width: g.size.width, height: g.size.height)
            }
            if !inColumn { Color.clear.frame(width: column) }
        }
        .overlay(alignment: .bottomTrailing) {
            DuoRail(selection: $tab, player: inner)
                .padding(.bottom, 10)
                .frame(width: column)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .offset(x: inColumn ? column : 0)
        }
        .background(Theme.background.ignoresSafeArea())
    }

    private func page<V: View>(_ index: Int, _ size: CGSize, @ViewBuilder _ view: () -> V) -> some View {
        view()
            .storyTab(index)
            // folded: the floating player over the bottom of the page, as on the phone
            .safeAreaInset(edge: .bottom) {
                if !inner, speaker.now != nil, !bar.storyOnScreen {
                    NowPlayingBar()
                        .padding(.horizontal, Design.sideMargin + 4)
                        .padding(.bottom, 6)
                }
            }
            .animation(.snappy, value: speaker.now == nil)
            .storyZoomScope()
            .tint(Theme.ink)
            .frame(width: size.width, height: size.height)
            .clipped()
            .opacity(tab == index ? 1 : 0)
            .allowsHitTesting(tab == index)
            .accessibilityHidden(tab != index)
    }
}

/// The tabs standing up, as in Halo: a slim capsule in the bottom of the right-hand column,
/// within reach of the thumb. Tap the tab you're on to go back to its top.
struct DuoRail: View {
    @Binding var selection: Int
    /// The opened Duo: while something plays, its play / pause button tops the rail.
    var player = false
    @ObservedObject private var speaker = Speaker.shared

    private let items: [(Int, String, String, String)] = [
        (0, "Today", "newspaper", "newspaper.fill"),
        (1, "Briefings", "list.bullet.rectangle.portrait", "list.bullet.rectangle.portrait.fill"),
        (2, "Stocks", "chart.line.uptrend.xyaxis", "chart.line.uptrend.xyaxis"),
        (3, "History", "clock.arrow.circlepath", "clock.arrow.circlepath"),
    ]

    var body: some View {
        VStack(spacing: 2) {
            if player, speaker.now != nil {
                RailPlayButton()
                    .transition(.scale.combined(with: .opacity))
            }
            ForEach(items, id: \.0) { index, title, symbol, selected in
                let on = selection == index
                Button {
                    if on { NotificationCenter.default.post(name: .scoutScrollTop, object: index) }
                    selection = index
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: on ? selected : symbol)
                            .font(.system(size: 18, weight: .semibold))
                            .frame(width: 44, height: 44)
                            .background(on ? Theme.accent : .clear, in: Circle())
                            .foregroundStyle(on ? .white : Theme.text)
                        Text(title)
                            .font(.system(size: 9.5, weight: .semibold))
                            .lineLimit(1).minimumScaleFactor(0.8)
                            .foregroundStyle(on ? Theme.text : Theme.secondary)
                    }
                    .frame(width: 60, height: 66)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(.vertical, 8)
        .background(Theme.card, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 0.5))
        .padding(.horizontal, 6)
        .animation(.snappy(duration: 0.25), value: selection)
        .animation(.snappy, value: speaker.now == nil)
        .sensoryFeedback(.selection, trigger: selection)
    }
}

/// Portrait on an ordinary iPhone; any way round on the opened Duo, so Scout fills it.
enum DuoOrientation {
    static func mask(_ scene: UIWindowScene?) -> UIInterfaceOrientationMask {
        guard isFoldableScreen(scene), let b = scene?.screen.bounds else { return .portrait }
        return min(b.width, b.height) >= 560 ? .all : .portrait
    }

    private static func isFoldableScreen(_ scene: UIWindowScene?) -> Bool {
        guard let b = scene?.screen.bounds else { return false }
        return max(b.width, b.height) / max(1, min(b.width, b.height)) < 1.6
    }

    /// Asks iOS to look again after the screen changes (folded or opened).
    @MainActor static func refresh() {
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            if mask(scene) == .portrait { scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { _ in } }
        }
    }
}

/// What's playing, as one more button at the top of the tab rail (the opened Duo): play / pause,
/// with the bars moving under it while it plays. Hold it to go to what's playing.
private struct RailPlayButton: View {
    @ObservedObject private var speaker = Speaker.shared
    @Environment(\.openURL) private var openURL

    var body: some View {
        if let now = speaker.now {
            Button { speaker.toggle() } label: {
                VStack(spacing: 3) {
                    Image(systemName: speaker.paused ? "play.fill" : "pause.fill")
                        .font(.system(size: 16, weight: .black))
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 44, height: 44)
                        .background(Theme.accent.opacity(0.16), in: Circle())
                        .foregroundStyle(Theme.accent)
                    RailBars()
                        .frame(height: 12)
                }
                .frame(width: 60, height: 66)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button { open(now) } label: { Label("Go to what's playing", systemImage: "arrow.up.right") }
                Button(role: .destructive) { speaker.stop() } label: { Label("Stop", systemImage: "stop.fill") }
            }
            .accessibilityLabel(speaker.paused ? "Play \(now.title)" : "Pause \(now.title)")
            .sensoryFeedback(.selection, trigger: speaker.paused)
        }
    }

    private func open(_ now: NowPlaying) {
        if let id = now.storyID, let url = URL(string: "scout://story/\(id)") { openURL(url) }
        else if let section = now.section, let url = URL(string: "scout://news?section=\(section)") { openURL(url) }
    }
}

/// The bars, moving while the sound plays (only this redraws as the clock ticks).
private struct RailBars: View {
    @ObservedObject private var speaker = Speaker.shared
    @ObservedObject private var clock = Speaker.shared.clock
    var body: some View {
        PlaybackVisual(style: .bars, playing: !speaker.paused, progress: clock.progress, size: 12, tint: Theme.accent)
    }
}

/// Two columns for a story or a stock on a wide screen: the left one stays put while the right
/// one scrolls.
struct TwoColumns<Left: View, Right: View>: View {
    @ViewBuilder var left: () -> Left
    @ViewBuilder var right: () -> Right

    var body: some View {
        GeometryReader { g in
            HStack(alignment: .top, spacing: g.size.width < 700 ? 12 : 28) {
                ScrollView { left().padding(.top, 24).padding(.bottom, 12) }
                    .scrollIndicators(.hidden)
                    .frame(width: min(g.size.width * 0.44, 560))
                ScrollView { right().padding(.top, 24).padding(.bottom, 12) }
                    .scrollIndicators(.hidden)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, g.size.width < 700 ? 12 : 28)
        }
    }
}
