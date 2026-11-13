import SwiftUI

// MARK: - The wide layout (an unfolded inner screen)
//
// On a wide screen Today stays on the left, always there; the right side switches between
// Briefings, Stocks and History with a vertical tab rail on the right edge; whatever's playing runs
// along the bottom, full width. A story or a stock opens across the whole screen in two columns:
// the picture and the headline on the left, everything else on the right.

enum WideLayout: String, CaseIterable, Identifiable {
    case automatic, on, off
    var id: String { rawValue }
    static let key = "layout.wide"
    var title: String {
        switch self {
        case .automatic: return "Automatic (wide screens)"
        case .on: return "Always"
        case .off: return "Off"
        }
    }

    /// Wide enough for two columns: an unfolded screen, or forced on in TestFlight.
    static func isWide(width: CGFloat, sizeClass: UserInterfaceSizeClass?, setting: String) -> Bool {
        switch WideLayout(rawValue: setting) ?? .automatic {
        case .on: return true
        case .off: return false
        case .automatic: return width >= 700 || sizeClass == .regular
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

/// Today on the left, the chosen page on the right, the tab rail on the right edge.
struct WideRoot: View {
    @Binding var tab: Int
    @Binding var showSettings: Bool
    @State private var path = NavigationPath()
    /// Opens with Today full width, then Today slides to the left and the right side comes in.
    @State private var settled = false
    @ObservedObject private var speaker = Speaker.shared
    var body: some View {
        GeometryReader { g in
            // on a phone forced into this layout, everything shrinks to fit
            let rail: CGFloat = g.size.width < 700 ? 62 : 78
            let left = min(max(g.size.width * 0.42, min(360, g.size.width * 0.46)), 540)
            NavigationStack(path: $path) {
                HStack(spacing: 0) {
                    TodayView(showSettings: $showSettings)
                        .environment(\.scoutTab, 0)
                        .frame(width: settled ? left : g.size.width - rail)
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
                    TabRail(tab: $tab, showSettings: $showSettings)
                        .frame(width: rail)
                }
                .background(Theme.background.ignoresSafeArea())
                .toolbar(.hidden, for: .navigationBar)
                .storyDestinations()
            }
            .tint(Theme.ink)
            // what's playing runs along the bottom, across both sides
            .safeAreaInset(edge: .bottom) {
                if speaker.now != nil, path.isEmpty {
                    NowPlayingBar()
                        .padding(.horizontal, 24)
                        .padding(.bottom, 6)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.snappy, value: speaker.now == nil)
        }
        .environment(\.scoutWide, true)
        .onAppear {
            if tab == 0 { tab = 1 }
            withAnimation(.spring(response: 0.65, dampingFraction: 0.86).delay(0.35)) { settled = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .scoutShowPage)) { _ in path = NavigationPath() }
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

/// The tabs, standing on the right edge: Today (back to its top), Briefings, Stocks, History,
/// and Settings at the bottom.
struct TabRail: View {
    @Binding var tab: Int
    @Binding var showSettings: Bool

    private let items: [(Int, String, String)] = [
        (0, "Today", "newspaper"),
        (1, "Briefings", "list.bullet.rectangle.portrait"),
        (2, "Stocks", "chart.line.uptrend.xyaxis"),
        (3, "History", "clock.arrow.circlepath"),
    ]

    var body: some View {
        VStack(spacing: 8) {
            ForEach(items, id: \.0) { index, title, symbol in
                Button {
                    if index == 0 {
                        // Today is always on the left: a tap takes it back to the top
                        NotificationCenter.default.post(name: .scoutScrollTop, object: 0)
                    } else if index == tab {
                        NotificationCenter.default.post(name: .scoutScrollTop, object: index)
                    } else {
                        withAnimation(.snappy) { tab = index }
                    }
                } label: {
                    let on = index == tab
                    VStack(spacing: 4) {
                        Image(systemName: symbol)
                            .font(.system(size: 19, weight: on ? .bold : .medium))
                            .frame(width: 50, height: 38)
                            .background(on ? Theme.accent.opacity(0.14) : Color.clear, in: Capsule())
                        Text(title).font(.system(size: 10, weight: on ? .bold : .semibold))
                    }
                    .foregroundStyle(on ? Theme.accent : (index == 0 ? Theme.text : Theme.secondary))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                .accessibilityAddTraits(index == tab ? .isSelected : [])
            }
            Spacer()
            Button { showSettings = true } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 44, height: 44)
                    .foregroundStyle(Theme.secondary)
            }
            .buttonStyle(PressStyle())
            .accessibilityLabel("Settings")
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 6)
        .frame(maxHeight: .infinity)
        .scoutGlass(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .padding(.vertical, 10)
        .padding(.trailing, 8)
        .sensoryFeedback(.selection, trigger: tab)
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
