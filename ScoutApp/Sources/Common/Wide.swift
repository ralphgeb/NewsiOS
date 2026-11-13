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

/// The fold layout. Outer screen: one page at a time, the tabs standing on the right edge, stacked
/// at the bottom. Inner screen: the chosen page on the left, Today on the right (it slides over when
/// the phone opens) and the tabs beside it; what's playing sits at the bottom of the right side.
struct WideRoot: View {
    @Binding var tab: Int
    @Binding var showSettings: Bool
    @State private var path = NavigationPath()
    /// Opens with Today full width, then Today slides to the right and the other page comes in.
    @State private var settled = false
    @ObservedObject private var speaker = Speaker.shared

    var body: some View {
        GeometryReader { g in
            let two = g.size.width >= 700
            let rail: CGFloat = two ? 76 : 64
            let todayWidth = min(max(g.size.width * 0.40, 360), 520)
            NavigationStack(path: $path) {
                HStack(spacing: 0) {
                    if two {
                        ZStack {
                            page(1) { NewsView(showSettings: $showSettings) }
                            page(2) { StocksView(showSettings: $showSettings) }
                            page(3) { HistoryView(showSettings: $showSettings) }
                        }
                        .frame(maxWidth: .infinity)
                        .opacity(settled ? 1 : 0)
                        .offset(x: settled ? 0 : -60)
                        Rectangle().fill(Theme.hairline).frame(width: 0.5).ignoresSafeArea()
                        TodayView(showSettings: $showSettings)
                            .environment(\.scoutTab, 0)
                            .safeAreaInset(edge: .bottom) { player }
                            .frame(width: settled ? todayWidth : g.size.width - rail)
                            .clipped()
                    } else {
                        ZStack {
                            page(0) { TodayView(showSettings: $showSettings) }
                            page(1) { NewsView(showSettings: $showSettings) }
                            page(2) { StocksView(showSettings: $showSettings) }
                            page(3) { HistoryView(showSettings: $showSettings) }
                        }
                        .frame(maxWidth: .infinity)
                        .safeAreaInset(edge: .bottom) { player }
                    }
                    TabRail(tab: $tab, showSettings: $showSettings, todayPinned: two)
                        .frame(width: rail)
                }
                .background(Theme.background.ignoresSafeArea())
                .toolbar(.hidden, for: .navigationBar)
                .storyDestinations()
            }
            .tint(Theme.ink)
            .animation(.snappy, value: speaker.now == nil)
            .onAppear { if two && tab == 0 { tab = 1 } }
            .onChange(of: two) { _, open in
                // opening the phone: Today moves to the right; closing it: back to one page
                if open && tab == 0 { tab = 1 }
                settled = false
                withAnimation(.spring(response: 0.65, dampingFraction: 0.86).delay(0.2)) { settled = true }
            }
        }
        .environment(\.scoutWide, true)
        .onAppear { withAnimation(.spring(response: 0.65, dampingFraction: 0.86).delay(0.35)) { settled = true } }
        .onReceive(NotificationCenter.default.publisher(for: .scoutShowPage)) { _ in path = NavigationPath() }
    }

    /// What's playing, at the bottom of the right-hand side (hidden while a story is open).
    @ViewBuilder private var player: some View {
        if speaker.now != nil, path.isEmpty {
            NowPlayingBar()
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
                .transition(.move(edge: .bottom).combined(with: .opacity))
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

/// The tabs, standing on the right edge and stacked at the bottom, within reach of your thumb:
/// Today, Briefings, Stocks, History. Settings sits at the top.
struct TabRail: View {
    @Binding var tab: Int
    @Binding var showSettings: Bool
    /// On the inner screen Today is always showing, so its tab just takes it back to the top.
    var todayPinned = false

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
            ForEach(items, id: \.0) { index, title, symbol in
                Button {
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
