import SwiftUI

// MARK: - The wide layout (an unfolded inner screen)
//
// Outer screen: one page, tabs on the right edge. Inner screen: Today on the right, always there;
// the left side switches between Briefings, Stocks and History; what's playing sits bottom right. A story or a stock opens across the whole screen in two columns:
// the picture and the headline on the left, everything else on the right.

enum WideLayout: String, CaseIterable, Identifiable {
    case automatic, on, off
    var id: String { rawValue }
    static let key = "layout.wide"
    /// TestFlight builds open in the fold layout straight away; the App Store version picks it on wide screens.
    static var defaultValue: String { (Plus.isTestFlight ? WideLayout.on : .automatic).rawValue }
    /// Wider than this (in points) is the open, inner screen: two columns.
    static let openWidth: CGFloat = 600
    var title: String {
        switch self {
        case .automatic: return "Automatic (inner screen)"
        case .on: return "Fold layout, always"
        case .off: return "Off"
        }
    }

    /// Wide enough for two columns: an unfolded screen, or forced on in TestFlight.
    static func isWide(width: CGFloat, sizeClass: UserInterfaceSizeClass?, setting: String) -> Bool {
        switch WideLayout(rawValue: setting) ?? .automatic {
        case .on: return true
        case .off: return false
        case .automatic: return width >= openWidth || sizeClass == .regular
        }
    }
}

private struct ScoutWideKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// True in the wide layout: pages share one navigation stack, stories open in two columns.
    var scoutWide: Bool {
        get { self[ScoutWideKey.self] }
        set { self[ScoutWideKey.self] = newValue }
    }
}

/// A page's navigation: its own stack on a phone; in the wide layout the whole screen's one stack,
/// so a story opened from either side fills the screen.
struct ScoutNavigation<Content: View>: View {
    var path: Binding<NavigationPath>? = nil
    @ViewBuilder var content: () -> Content
    @Environment(\.scoutWide) private var wide

    var body: some View {
        if wide {
            content()
        } else if let path {
            NavigationStack(path: path, root: content)
        } else {
            NavigationStack(root: content)
        }
    }
}

/// The fold layout. Outer screen: one page at a time. Inner screen: Today on the left (it slides
/// over when the phone opens) and the chosen page on the right. On both, the tabs stand on the
/// right edge, always there (stories open beside them), with what's playing as a pill above them.
struct WideRoot: View {
    @Binding var tab: Int
    @Binding var showSettings: Bool
    @State private var path = NavigationPath()
    /// Opens with Today full width, then Today moves to the left and the other page comes in.
    @State private var settled = false

    var body: some View {
        GeometryReader { g in
            let two = g.size.width >= WideLayout.openWidth
            let rail: CGFloat = two ? 76 : 64
            let todayWidth = min(max((g.size.width - rail) * 0.42, 360), 520)
            HStack(spacing: 0) {
                NavigationStack(path: $path) {
                    HStack(spacing: 0) {
                        if two {
                            TodayView(showSettings: $showSettings)
                                .environment(\.scoutTab, 0)
                                .frame(width: settled ? todayWidth : g.size.width - rail)
                                .clipped()
                            Rectangle().fill(Theme.hairline).frame(width: 0.5).ignoresSafeArea()
                            ZStack {
                                page(1) { NewsView(showSettings: $showSettings) }
                                page(2) { StocksView(showSettings: $showSettings) }
                                page(3) { HistoryView(showSettings: $showSettings) }
                            }
                            .frame(maxWidth: .infinity)
                            .opacity(settled ? 1 : 0)
                            .offset(x: settled ? 0 : 60)
                        } else {
                            ZStack {
                                page(0) { TodayView(showSettings: $showSettings) }
                                page(1) { NewsView(showSettings: $showSettings) }
                                page(2) { StocksView(showSettings: $showSettings) }
                                page(3) { HistoryView(showSettings: $showSettings) }
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .background(Theme.background.ignoresSafeArea())
                    .toolbar(.hidden, for: .navigationBar)
                    .storyDestinations()
                }
                .tint(Theme.ink)
                TabRail(tab: $tab, showSettings: $showSettings, todayPinned: two, onTab: { path = NavigationPath() })
                    .frame(width: rail)
            }
            .background(Theme.background.ignoresSafeArea())
            .onAppear { if two && tab == 0 { tab = 1 } }
            .onChange(of: two) { _, open in
                // opening the phone: Today moves to the left; closing it: back to one page
                if open && tab == 0 { tab = 1 }
                settled = false
                withAnimation(.spring(response: 0.65, dampingFraction: 0.86).delay(0.2)) { settled = true }
            }
        }
        .environment(\.scoutWide, true)
        .onAppear { withAnimation(.spring(response: 0.65, dampingFraction: 0.86).delay(0.35)) { settled = true } }
        .onReceive(NotificationCenter.default.publisher(for: .scoutShowPage)) { note in
            path = NavigationPath()
            // a link to a story opens it across the screen, beside the tabs
            if let url = note.object as? URL, url.host == "story", let id = url.pathComponents.dropFirst().first {
                path.append(StoryRoute(id: id, sequence: [id]))
            }
        }
    }

    /// Each page stays alive (its scroll position too) while another one shows.
    private func page<V: View>(_ index: Int, @ViewBuilder _ view: () -> V) -> some View {
        view()
            .environment(\.scoutTab, index)
            .opacity(tab == index ? 1 : 0)
            .allowsHitTesting(tab == index)
            .accessibilityHidden(tab != index)
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

/// The tabs, standing on the right edge and stacked at the bottom, within reach of your thumb:
/// Today, Briefings, Stocks, History. Settings sits at the top.
struct TabRail: View {
    @Binding var tab: Int
    @Binding var showSettings: Bool
    /// On the inner screen Today is always showing, so its tab just takes it back to the top.
    var todayPinned = false
    /// Called when a tab is chosen (an open story closes).
    var onTab: () -> Void = {}
    @ObservedObject private var speaker = Speaker.shared

    private let items: [(Int, String, String)] = [
        (0, "Today", "newspaper"),
        (1, "Briefings", "list.bullet.rectangle.portrait"),
        (2, "Stocks", "chart.line.uptrend.xyaxis"),
        (3, "History", "clock.arrow.circlepath"),
    ]

    var body: some View {
        VStack(spacing: 6) {
            Button { showSettings = true } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 44, height: 44)
                    .foregroundStyle(Theme.secondary)
            }
            .buttonStyle(PressStyle())
            .accessibilityLabel("Settings")
            Spacer()
            RailPlayer()
                .padding(.bottom, 6)
            ForEach(items, id: \.0) { index, title, symbol in
                Button {
                    onTab()
                    if index == 0 && todayPinned || index == tab {
                        NotificationCenter.default.post(name: .scoutScrollTop, object: index)
                    } else {
                        withAnimation(.snappy) { tab = index }
                    }
                } label: {
                    let on = index == tab || (index == 0 && todayPinned)
                    VStack(spacing: 3) {
                        Image(systemName: symbol)
                            .font(.system(size: 18, weight: on ? .bold : .medium))
                            .frame(width: 46, height: 34)
                            .background(index == tab ? Theme.accent.opacity(0.14) : Color.clear, in: Capsule())
                        Text(title).font(.system(size: 10, weight: on ? .bold : .semibold))
                            .lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(index == tab ? Theme.accent : on ? Theme.text : Theme.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                .accessibilityAddTraits(index == tab ? .isSelected : [])
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 4)
        .frame(maxHeight: .infinity)
        .scoutGlass(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .padding(.vertical, 10)
        .padding(.trailing, 8)
        .sensoryFeedback(.selection, trigger: tab)
        .animation(.snappy, value: speaker.now == nil)
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
