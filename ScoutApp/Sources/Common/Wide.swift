import SwiftUI

// MARK: - The iPhone Duo
//
// Only the Duo gets this; an ordinary iPhone keeps the usual tab bar. Folded (the outer screen,
// nearly as wide as it's tall) Scout is the phone app, a little wider and shorter, with the four
// tabs standing in the right-hand status column under the clock and battery. Opened and held
// sideways, each page splits into two columns (Today: the weather and Top stories on the left,
// More for you on the right; Briefings: the briefing left, the stories right; Stocks: your stocks
// and the ones in the news left, the top ten right). Opened and upright: one roomy column.

private struct ScoutWideKey: EnvironmentKey { static let defaultValue = false }
private struct StatusBandKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }

extension EnvironmentValues {
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
    /// The Duo's shape: far less tall than an ordinary iPhone (outer screen, or opened upright).
    static func isDuo(_ size: CGSize) -> Bool { size.height / max(size.width, 1) < 1.6 || size.width >= 760 }
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
/// right-hand column, under the clock, camera and battery, with what's playing just above them.
/// Where iOS keeps that column for itself (the status column) the tabs sit inside it.
struct DuoRoot: View {
    @Binding var tab: Int
    @Binding var showSettings: Bool
    let statusColumn: CGFloat

    var body: some View {
        let inColumn = statusColumn > 40
        let column = inColumn ? statusColumn : 74
        HStack(spacing: 0) {
            ZStack {
                // every page stays alive (and keeps its place) while another one shows
                page(0) { TodayView(showSettings: $showSettings) }
                page(1) { NewsView(showSettings: $showSettings) }
                page(2) { StocksView(showSettings: $showSettings) }
                page(3) { HistoryView(showSettings: $showSettings) }
            }
            .frame(maxWidth: .infinity)
            if !inColumn { Color.clear.frame(width: column) }
        }
        .overlay(alignment: .bottomTrailing) {
            VStack(spacing: 10) {
                RailPlayer()
                DuoRail(selection: $tab)
            }
            .padding(.bottom, 10)
            .frame(width: column)
            .frame(maxHeight: .infinity, alignment: .bottom)
            .offset(x: inColumn ? column : 0)
        }
        .background(Theme.background.ignoresSafeArea())
    }

    private func page<V: View>(_ index: Int, @ViewBuilder _ view: () -> V) -> some View {
        view()
            .storyTab(index)
            .storyZoomScope()
            .tint(Theme.ink)
            .opacity(tab == index ? 1 : 0)
            .allowsHitTesting(tab == index)
            .accessibilityHidden(tab != index)
    }
}

/// The tabs standing up, as in Halo: a slim capsule in the bottom of the right-hand column,
/// within reach of the thumb. Tap the tab you're on to go back to its top.
struct DuoRail: View {
    @Binding var selection: Int

    private let items: [(Int, String, String, String)] = [
        (0, "Today", "newspaper", "newspaper.fill"),
        (1, "Briefings", "list.bullet.rectangle.portrait", "list.bullet.rectangle.portrait.fill"),
        (2, "Stocks", "chart.line.uptrend.xyaxis", "chart.line.uptrend.xyaxis"),
        (3, "History", "clock.arrow.circlepath", "clock.arrow.circlepath"),
    ]

    var body: some View {
        VStack(spacing: 2) {
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
        .sensoryFeedback(.selection, trigger: selection)
    }
}

/// Portrait on an ordinary iPhone; any way round on the opened Duo, so Scout fills it.
enum DuoOrientation {
    static func mask(_ scene: UIWindowScene?) -> UIInterfaceOrientationMask {
        guard let b = scene?.screen.bounds else { return .portrait }
        return min(b.width, b.height) >= 560 ? .all : .portrait
    }

    /// Asks iOS to look again after the screen changes (folded or opened).
    @MainActor static func refresh() {
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            if mask(scene) == .portrait { scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { _ in } }
        }
    }
}

/// What's playing, as a pill in the tab rail: the artwork, the bars moving with the sound, and
/// play/pause. Tap the artwork to go to what's playing.
struct RailPlayer: View {
    @ObservedObject private var speaker = Speaker.shared
    @Environment(\.openURL) private var openURL

    var body: some View {
        if let now = speaker.now {
            VStack(spacing: 8) {
                Button { open(now) } label: {
                    Group {
                        if let url = now.artwork {
                            RemoteImage(url: url) { Theme.accent.opacity(0.15) }
                        } else {
                            ZStack {
                                Theme.accent.opacity(0.15)
                                Image(systemName: "headphones").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.accent)
                            }
                        }
                    }
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(PressStyle())
                .accessibilityLabel("Now playing: \(now.title)")
                RailBars()
                Button { speaker.toggle() } label: {
                    Image(systemName: speaker.paused ? "play.fill" : "pause.fill")
                        .font(.system(size: 13, weight: .black))
                        .frame(width: 34, height: 34)
                        .background(Theme.accent, in: Circle())
                        .foregroundStyle(.white)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(PressStyle())
                .accessibilityLabel(speaker.paused ? "Play" : "Pause")
            }
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(Theme.accent.opacity(0.1), in: Capsule())
            .padding(.horizontal, 6)
            .transition(.scale.combined(with: .opacity))
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
        PlaybackVisual(style: .bars, playing: !speaker.paused, progress: clock.progress, size: 20, tint: Theme.accent)
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
                ScrollView { left().padding(.vertical, 12) }
                    .scrollIndicators(.hidden)
                    .frame(width: min(g.size.width * 0.44, 560))
                ScrollView { right().padding(.vertical, 12) }
                    .scrollIndicators(.hidden)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, g.size.width < 700 ? 12 : 28)
        }
    }
}
