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
    @ViewBuilder var pinned: () -> Pinned
    @ViewBuilder var content: () -> Content

    @State private var offset: CGFloat = 0

    var body: some View {
        ZStack(alignment: .top) {
            ScrollView {
                VStack(spacing: 16) { content() }
                    .padding(.horizontal, 20)
                    .padding(.top, PageHeader.height + pinnedHeight + 10)
                    .padding(.bottom, 36)
                    // never wider than the screen, so the page only ever moves up and down
                    .containerRelativeFrame(.horizontal)
                    .background(GeometryReader { g in
                        Color.clear.preference(key: ScrollOffsetKey.self, value: -g.frame(in: .named("page")).minY)
                    })
            }
            .coordinateSpace(name: "page")
            .modifier(TrackScrollOffset(offset: $offset))
            .modifier(ScrollRelease(offset: offset) { pulled in
                if pulled > 64, let onRefresh { Task { await onRefresh() } }
            })
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)

            VStack(spacing: 0) {
                PageHeader(title: title, subtitle: subtitle, showSettings: $showSettings,
                           editing: editing, isRefreshing: isRefreshing,
                           pull: onRefresh == nil ? 0 : max(0, -offset))
                pinned()
            }
            .background(Theme.background.ignoresSafeArea(edges: .top))
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.hairline).frame(height: 0.5).opacity(offset > 4 ? 1 : 0)
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
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
    let offset: CGFloat
    let onRelease: (_ furthestPull: CGFloat) -> Void
    @State private var furthest: CGFloat = 0
    @State private var armed = true

    func body(content: Content) -> some View {
        if #available(iOS 18, *) {
            content
                .onChange(of: offset) { _, y in furthest = max(furthest, -y) }
                .onScrollPhaseChange { old, new in
                    if new == .interacting { furthest = 0 }
                    if old == .interacting, new != .interacting {
                        onRelease(furthest)
                        furthest = 0
                    }
                }
        } else {
            content.onChange(of: offset) { _, y in
                if armed, y < -70 {
                    armed = false
                    onRelease(-y)
                } else if abs(y) < 2 {
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

    var body: some View {
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
    @Binding var offset: CGFloat

    func body(content: Content) -> some View {
        if #available(iOS 18, *) {
            content.onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { _, v in
                offset = v
            }
        } else {
            content.onPreferenceChange(ScrollOffsetKey.self) { offset = $0 }
        }
    }
}
