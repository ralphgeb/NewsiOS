import SwiftUI

/// Every story you've opened, newest first and grouped by day, with your saved stories one tap
/// away. Both are kept after the stories leave the news.
struct HistoryView: View {
    @EnvironmentObject private var store: NewsStore
    @Binding var showSettings: Bool
    @State private var list = HistoryList.history
    @State private var editing = false

    enum HistoryList: String, CaseIterable, Identifiable {
        case history = "History", saved = "Saved"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            ScoutPage(showSettings: $showSettings, title: "History", subtitle: subtitle, pinnedHeight: 50,
                      editing: isEmpty ? nil : $editing, pageKey: list.rawValue) {
                CapsuleSwitcher(items: HistoryList.allCases, selection: $list, title: \.rawValue)
                    .frame(height: 46)
                    .padding(.bottom, 4)
            } content: {
                if list == .history { history } else { saved }
            }
            .storyDestinations()
            .onChange(of: list) { _, _ in editing = false }
            .onChange(of: isEmpty) { _, empty in if empty { editing = false } }
            .sensoryFeedback(.selection, trigger: list)
        }
    }

    private var isEmpty: Bool { list == .history ? store.history.isEmpty : store.saved.isEmpty }

    private var subtitle: String {
        let n = list == .history ? store.history.count : store.saved.count
        return list == .history ? "\(n) stor\(n == 1 ? "y" : "ies") read" : "\(n) saved"
    }

    // MARK: History

    @ViewBuilder private var history: some View {
        if store.history.isEmpty {
            EmptyCard(symbol: "clock.arrow.circlepath", title: "Nothing read yet",
                      text: "Stories you open show up here, so you can always find one again.")
        } else {
            let seq = store.history.map(\.id)
            ForEach(days) { group in
                SectionHead(title: Self.dayTitle(group.day), detail: "\(group.entries.count)")
                rows(group.entries.map(\.story), sequence: seq) { store.forget($0) }
            }
            if editing {
                Button("Clear history", role: .destructive) { withAnimation(.snappy) { store.clearHistory() } }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity).frame(height: 44)
                    .background(Theme.card, in: Capsule())
            }
        }
    }

    private struct DayGroup: Identifiable {
        let day: Date
        var entries: [HistoryEntry]
        var id: Date { day }
    }

    private var days: [DayGroup] {
        let cal = Calendar.current
        var out: [DayGroup] = []
        for e in store.history {
            let d = cal.startOfDay(for: e.opened)
            if out.last?.day == d { out[out.count - 1].entries.append(e) } else { out.append(DayGroup(day: d, entries: [e])) }
        }
        return out
    }

    static func dayTitle(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    // MARK: Saved

    @ViewBuilder private var saved: some View {
        if store.saved.isEmpty {
            EmptyCard(symbol: "bookmark", title: "Nothing saved yet",
                      text: "Tap the bookmark at the top of any story to keep it here.")
        } else {
            rows(store.saved, sequence: store.saved.map(\.id)) { store.unsave($0) }
        }
    }

    // MARK: Rows

    private func rows(_ stories: [Story], sequence: [String], remove: @escaping (String) -> Void) -> some View {
        VStack(spacing: 0) {
            ForEach(stories) { s in
                HStack(spacing: 0) {
                    if editing {
                        Button { withAnimation(.snappy) { remove(s.id) } } label: {
                            Image(systemName: "minus")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(Theme.background)
                                .frame(width: 24, height: 24)
                                .background(Theme.accent, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .padding(.leading, 14)
                        .transition(.scale.combined(with: .opacity))
                        .accessibilityLabel("Remove")
                    }
                    NavigationLink(value: StoryRoute(id: s.id, sequence: sequence)) { StoryRow(story: s) }
                        .buttonStyle(PressStyle())
                        .disabled(editing)
                }
                if s.id != stories.last?.id {
                    Rectangle().fill(Theme.hairline).frame(height: 0.5).padding(.leading, 16)
                }
            }
        }
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}
