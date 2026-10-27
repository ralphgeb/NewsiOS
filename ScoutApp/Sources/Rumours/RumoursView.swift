import SwiftUI

/// Unconfirmed stories with the AI's odds, and how earlier rumours turned out.
struct RumoursView: View {
    @EnvironmentObject private var store: NewsStore
    @Binding var showSettings: Bool
    @State private var status: RumourStatus = .rumour
    @AppStorage("rumours.sort") private var sortRaw = RumourSort.latest.rawValue

    private var sort: RumourSort { RumourSort(rawValue: sortRaw) ?? .latest }

    var body: some View {
        let list = store.rumours(status, sort: sort)
        NavigationStack {
            ScoutPage(showSettings: $showSettings, title: "Rumours", subtitle: subtitle(list.count), pinnedHeight: 46) { _ in
                HStack(spacing: 0) {
                    CapsuleSwitcher(items: RumourStatus.allCases, selection: $status, title: \.title)
                    Menu {
                        Picker("Sort", selection: $sortRaw) {
                            ForEach(RumourSort.allCases) { Text($0.title).tag($0.rawValue) }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 34, height: 34)
                            .background(Theme.card, in: Circle())
                            .foregroundStyle(Theme.ink)
                    }
                    .accessibilityLabel("Sort, \(sort.title)")
                    .padding(.trailing, 20)
                }
                .frame(height: 46)
                .padding(.bottom, 4)
            } content: {
                if list.isEmpty {
                    empty
                } else {
                    let seq = list.prefix(80).map(\.id)
                    ForEach(list.prefix(80)) { s in
                        NavigationLink(value: StoryRoute(id: s.id, sequence: seq)) { RumourCard(story: s) }
                            .buttonStyle(PressStyle())
                    }
                    Text("Odds are the AI's view from how many outlets report it, who the sources are and what the companies say. They can be wrong.")
                        .font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                        .multilineTextAlignment(.center).padding(.horizontal, 24)
                }
            }
            .storyDestinations()
            .sensoryFeedback(.selection, trigger: sortRaw)
        }
    }

    private func subtitle(_ count: Int) -> String {
        let word = status == .rumour ? "open rumour\(count == 1 ? "" : "s")" : status.title.lowercased()
        return "\(count) \(word) · \(sort.title.lowercased())"
    }

    private var empty: some View {
        switch status {
        case .rumour:
            return EmptyCard(symbol: "dot.radiowaves.left.and.right", title: "No open rumours", text: "New rumours appear here as soon as they're reported.")
        case .confirmed:
            return EmptyCard(symbol: "checkmark.circle", title: "Nothing confirmed yet", text: "When a rumour comes true, it moves here.")
        case .denied:
            return EmptyCard(symbol: "xmark.circle", title: "Nothing denied yet", text: "When a company denies a rumour, it moves here.")
        }
    }
}

/// The claim, the odds in Halo's ring, and the picture.
struct RumourCard: View {
    let story: Story

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    Ring(progress: Double(story.odds ?? 50) / 100, lineWidth: 5)
                    Group {
                        switch story.status {
                        case "confirmed": Image(systemName: "checkmark").font(.system(size: 15, weight: .bold))
                        case "denied": Image(systemName: "xmark").font(.system(size: 15, weight: .bold))
                        default: Text("\(story.odds ?? 50)").font(Theme.number(17))
                        }
                    }
                    .foregroundStyle(Theme.ink)
                }
                .frame(width: 54, height: 54)
                VStack(alignment: .leading, spacing: 6) {
                    SourceLine(story: story)
                    Text(story.isRumour ? story.claim ?? story.title : story.title)
                        .font(Theme.headline(16))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(4)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                StoryImage(story: story)
                    .frame(width: 70, height: 70)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            OddsBar(story: story)
            TickerChips(story: story, limit: 5)
        }
        .scoutCard(padding: 16)
    }
}
