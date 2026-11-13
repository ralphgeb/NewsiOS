import SwiftUI

/// Every tab is built the same way, as in Halo: a pinned header (a big title with one line under
/// it, plus optional pinned content like News's sections) and a page that scrolls underneath.
/// Pull the page down to fetch the latest.
struct ScoutPage<Pinned: View, Content: View>: View {
    @Binding var showSettings: Bool
    var title: String
    /// One line under the title: the date, when it was updated, how many…
    var subtitle: String
    /// Height of the pinned content below the header.
    var pinnedHeight: CGFloat = 0
    /// When set, the header shows an Edit / Done button.
    var editing: Binding<Bool>? = nil
    /// Called when the page is pulled down and let go.
    var onRefresh: (() async -> Void)? = nil
    var isRefreshing = false
    /// Which page of several is showing (News's sections): each keeps its own place, and one
    /// you haven't scrolled yet opens at the top.
    var pageKey: String? = nil
    @ViewBuilder var pinned: () -> Pinned
    @ViewBuilder var content: () -> Content

    /// Where the page is scrolled to, kept in an object the page itself doesn't watch: only the
    /// header (which hides and shows) redraws as you scroll, never the stories.
    @State private var scroll = PageScroll()
    @Environment(\.scoutTab) private var tab

    var body: some View {
        ZStack(alignment: .top) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 16) { content() }
                        .padding(.horizontal, Design.sideMargin)
                        .padding(.top, PageHeader.height + pinnedHeight + 10)
                        .padding(.bottom, 36)
                        // never wider than the screen, so the page only ever moves up and down
                        .containerRelativeFrame(.horizontal)
                        .background(GeometryReader { g in
                            Color.clear.preference(key: ScrollOffsetKey.self, value: -g.frame(in: .named("page")).minY)
                        })
                        .background(alignment: .top) { Color.clear.frame(height: 1).id(RememberScroll.top) }
                }
                .coordinateSpace(name: "page")
                .modifier(TrackScrollOffset(scroll: scroll, pinned: PageHeader.height + pinnedHeight, editing: editing?.wrappedValue == true))
                .modifier(RememberScroll(key: pageKey, scroll: scroll))
                .modifier(ScrollRelease(scroll: scroll) { pulled in
                    if pulled > 64, let onRefresh { Task { await onRefresh() } }
                })
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                // tapping the tab you're on goes back to the top
                .onReceive(NotificationCenter.default.publisher(for: .scoutScrollTop)) { note in
                    guard (note.object as? Int) == tab else { return }
                    withAnimation(.snappy) { proxy.scrollTo(RememberScroll.top, anchor: .top) }
                    scroll.show()
                }
            }

            PageHeaderLayer(scroll: scroll, pinnedHeight: pinnedHeight) {
                PageHeader(title: title, subtitle: subtitle, showSettings: $showSettings,
                           editing: editing, isRefreshing: isRefreshing,
                           pull: onRefresh == nil ? 0 : scroll.pull)
                pinned()
            }

            // the status bar keeps a solid background, so text never scrolls under the clock
            Theme.background
                .frame(height: 0)
                .ignoresSafeArea(edges: .top)
        }
        .onChange(of: pageKey) { _, _ in scroll.show() }
        .background(Theme.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }
}

/// The scroll position and what follows from it. Only the values views draw from are published,
/// and only when they change: the header's hidden state, the hairline under it, and the pull.
@MainActor
final class PageScroll: ObservableObject {
    @Published private(set) var hidden = false
    @Published private(set) var scrolled = false
    @Published private(set) var pull: CGFloat = 0
    private(set) var y: CGFloat = 0
    private var last: CGFloat = 0
    var furthestPull: CGFloat = 0

    func update(_ y: CGFloat, pinned: CGFloat, editing: Bool) {
        self.y = y
        let s = y > 4
        if s != scrolled { scrolled = s }
        let p = max(0, -y)
        if p != pull, p > 0 || pull != 0 { pull = p }
        furthestPull = max(furthestPull, p)
        let delta = y - last
        if y < pinned || editing {
            if hidden { hidden = false }       // near the top, or editing: always shown
        } else if delta > 8 {
            if !hidden { hidden = true }       // moving down the page
        } else if delta < -8 {
            if hidden { hidden = false }       // moving back up
        } else {
            return                             // small wobbles don't count
        }
        last = y
    }

    func show() { if hidden { hidden = false } }
}

/// The header over the page: slides away while you scroll down, back when you scroll up.
private struct PageHeaderLayer<H: View>: View {
    @ObservedObject var scroll: PageScroll
    let pinnedHeight: CGFloat
    @ViewBuilder var header: () -> H

    var body: some View {
        VStack(spacing: 0) { header() }
            .background(Theme.background)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.hairline).frame(height: 0.5).opacity(scroll.scrolled && !scroll.hidden ? 1 : 0)
            }
            .offset(y: scroll.hidden ? -(PageHeader.height + pinnedHeight + 12) : 0)
            .opacity(scroll.hidden ? 0 : 1)
            .animation(.snappy(duration: 0.32), value: scroll.hidden)
    }
}

extension ScoutPage where Pinned == EmptyView {
    init(showSettings: Binding<Bool>, title: String, subtitle: String, editing: Binding<Bool>? = nil,
         onRefresh: (() async -> Void)? = nil, isRefreshing: Bool = false,
         @ViewBuilder content: @escaping () -> Content) {
        self._showSettings = showSettings
        self.title = title
        self.subtitle = subtitle
        self.editing = editing
        self.onRefresh = onRefresh
        self.isRefreshing = isRefreshing
        self.pinnedHeight = 0
        self.pinned = { EmptyView() }
        self.content = content
    }
}

/// Calls back when a finger lets go of the scroll view, with how far the page was pulled down past
/// the top during that touch. (iOS 17 can't tell when you let go, so there it calls back as soon as
/// the page is pulled 70 points.)
private struct ScrollRelease: ViewModifier {
    let scroll: PageScroll
    let onRelease: (_ furthestPull: CGFloat) -> Void
    @State private var armed = true

    func body(content: Content) -> some View {
        if #available(iOS 18, *) {
            content
                .onScrollPhaseChange { old, new in
                    if new == .interacting { scroll.furthestPull = 0 }
                    if old == .interacting, new != .interacting {
                        onRelease(scroll.furthestPull)
                        scroll.furthestPull = 0
                    }
                }
        } else {
            content.onReceive(scroll.$pull) { p in
                if armed, p > 70 {
                    armed = false
                    onRelease(p)
                } else if p < 2 {
                    armed = true
                }
            }
        }
    }
}

// MARK: - Header

/// The big title with one line under it, the same on every tab, and the round buttons on the right.
struct PageHeader: View {
    let title: String
    let subtitle: String
    @Binding var showSettings: Bool
    var editing: Binding<Bool>? = nil
    var isRefreshing = false
    /// How far the page is pulled down, to show the refresh hint.
    var pull: CGFloat = 0
    static let height: CGFloat = 74

    var body: some View {
        let ready = pull > 64
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.system(size: 32, weight: .heavy))
                    .tracking(-0.6)
                    .foregroundStyle(Theme.text)
                HStack(spacing: 6) {
                    if isRefreshing {
                        ProgressView().controlSize(.mini)
                    } else if pull > 8 {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 10, weight: .bold))
                            .rotationEffect(.degrees(ready ? 180 : 0))
                            .foregroundStyle(ready ? Theme.accent : Theme.tertiary)
                            .animation(.snappy, value: ready)
                    }
                    Text(pull > 8 && !isRefreshing ? (ready ? "Release to refresh" : "Pull to refresh") : subtitle)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                }
            }
            .accessibilityElement(children: .combine)

            Spacer()

            if let editing {
                Button(editing.wrappedValue ? "Done" : "Edit") {
                    withAnimation(.snappy) { editing.wrappedValue.toggle() }
                }
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(editing.wrappedValue ? Theme.ink : Theme.card, in: Capsule())
                .foregroundStyle(editing.wrappedValue ? Theme.background : Theme.text)
            }
            SettingsButton(showSettings: $showSettings)
        }
        .padding(.horizontal, 20)
        .frame(height: Self.height)
        .sensoryFeedback(.impact(weight: .light), trigger: ready)
    }
}

/// The gear in a round bubble, top right of every page.
struct SettingsButton: View {
    @Binding var showSettings: Bool
    /// In the fold layout Settings lives on the tab rail, so the page's own gear goes.
    @Environment(\.scoutWide) private var wide

    var body: some View {
        if !wide { gear }
    }

    private var gear: some View {
        Button { showSettings = true } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 16))
                .frame(width: 36, height: 36)
                .background(Theme.card, in: Circle())
                .foregroundStyle(Theme.ink)
        }
        .accessibilityLabel("Settings")
    }
}

// MARK: - Scroll tracking

struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Reports how far a ScrollView has scrolled. iOS 18 reads it from the scroll view itself;
/// iOS 17 falls back to the preference set inside the content.
struct TrackScrollOffset: ViewModifier {
    let scroll: PageScroll
    let pinned: CGFloat
    let editing: Bool

    func body(content: Content) -> some View {
        if #available(iOS 18, *) {
            content.onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { _, v in
                MainActor.assumeIsolated { scroll.update(v, pinned: pinned, editing: editing) }
            }
        } else {
            content.onPreferenceChange(ScrollOffsetKey.self) { v in
                MainActor.assumeIsolated { scroll.update(v, pinned: pinned, editing: editing) }
            }
        }
    }
}

/// Keeps each page's scroll position (iOS 18) when the page key changes: back to where that page
/// was left, or its top the first time. iOS 17 can't scroll to a position, so there every page
/// opens at its top.
struct RememberScroll: ViewModifier {
    static let top = "scout.page.top"
    let key: String?
    let scroll: PageScroll

    func body(content: Content) -> some View {
        if #available(iOS 18, *) {
            content.modifier(RememberScroll18(key: key, scroll: scroll))
        } else {
            ScrollViewReader { proxy in
                content.onChange(of: key) { _, _ in proxy.scrollTo(Self.top, anchor: .top) }
            }
        }
    }
}

@available(iOS 18, *)
private struct RememberScroll18: ViewModifier {
    let key: String?
    let scroll: PageScroll
    @State private var position = ScrollPosition(idType: String.self)
    @State private var saved: [String: CGFloat] = [:]

    func body(content: Content) -> some View {
        content
            .scrollPosition($position)
            .onChange(of: key) { old, new in
                if let old { saved[old] = scroll.y }
                let y = new.flatMap { saved[$0] } ?? 0
                // once the new page is in place, so it's tall enough to scroll to
                DispatchQueue.main.async { position.scrollTo(y: y) }
            }
    }
}
