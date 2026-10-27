import SwiftUI

/// Rumours, as a section of News: unconfirmed stories with the AI's odds, and how earlier rumours
/// turned out.
struct RumoursSection: View {
    @EnvironmentObject private var store: NewsStore
    @State private var status: RumourStatus = .rumour
    @AppStorage("rumours.sort") private var sortRaw = RumourSort.latest.rawValue

    private var sort: RumourSort { RumourSort(rawValue: sortRaw) ?? .latest }

    var body: some View {
        let list = store.rumours(status, sort: sort)
        VStack(spacing: 14) {
            HStack(spacing: 8) {
                HStack(spacing: 2) {
                    ForEach(RumourStatus.allCases) { s in
                        Button {
                            withAnimation(.snappy) { status = s }
                        } label: {
                            Text(s.title)
                                .font(.system(size: 13, weight: .bold))
                                .frame(maxWidth: .infinity).frame(height: 30)
                                .background(status == s ? Theme.ink : Color.clear, in: Capsule())
                                .foregroundStyle(status == s ? Theme.background : Theme.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(3)
                .background(Theme.track, in: Capsule())
                Menu {
                    Picker("Sort", selection: $sortRaw) {
                        ForEach(RumourSort.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 36, height: 36)
                        .background(Theme.card, in: Circle())
                        .foregroundStyle(Theme.ink)
                }
                .accessibilityLabel("Sort, \(sort.title)")
            }
            SectionHead(title: status == .rumour ? "Rumours" : status.title,
                        detail: "\(list.count) · \(sort.title.lowercased())")
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
        .sensoryFeedback(.selection, trigger: sortRaw)
        .sensoryFeedback(.selection, trigger: status)
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
