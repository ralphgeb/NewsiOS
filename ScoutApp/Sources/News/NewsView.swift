import SwiftUI

/// Every story from all the sites. All is ranked by importance; Tech, Finance, World and Fashion
/// open with that section's front page and then run newest first. Swipe sideways between sections.
struct NewsView: View {
    @EnvironmentObject private var store: NewsStore
    @Binding var showSettings: Bool
    @AppStorage("news.section") private var sectionRaw = NewsSection.all.rawValue
    /// How many stories each section shows, so a section you come back to is as long as you left it.
    @State private var limits: [NewsSection: Int] = [:]
    @State private var forward = true
    @State private var showInterests = false
    @AppStorage(Paywall.key) private var paywall = false

    private var section: NewsSection { NewsSection(rawValue: sectionRaw) ?? .all }

    private var sectionBinding: Binding<NewsSection> {
        Binding(get: { section }, set: { go(to: $0) })
    }

    var body: some View {
        NavigationStack {
            ScoutPage(showSettings: $showSettings, title: "News", subtitle: subtitle, pinnedHeight: 50,
                      onRefresh: { await store.refresh() }, isRefreshing: store.isLoading,
                      pageKey: section.rawValue) {
                CapsuleSwitcher(items: NewsSection.allCases, selection: sectionBinding, title: \.rawValue)
                    .frame(height: 46)
                    .padding(.bottom, 4)
            } content: {
                page(section)
                    .id(section)
                    .transition(.asymmetric(insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                                            removal: .opacity))
            }
            .simultaneousGesture(swipe)
            .storyDestinations()
        }
        .sheet(isPresented: $showInterests) {
            TopicsSheet()
                .environmentObject(store)
                .presentationDetents([.large])
        }
    }

    private var subtitle: String {
        guard let u = store.updated else { return store.isLoading ? "Loading…" : "Waiting for the first update" }
        return Format.briefing(u)
    }

    private func go(to next: NewsSection) {
        guard next != section else { return }
        let all = NewsSection.allCases
        forward = (all.firstIndex(of: next) ?? 0) > (all.firstIndex(of: section) ?? 0)
        withAnimation(.snappy) { sectionRaw = next.rawValue }
    }

    /// A clear sideways flick moves to the next or previous section.
    private var swipe: some Gesture {
        DragGesture(minimumDistance: 30)
            .onEnded { v in
                let w = v.translation.width, h = v.translation.height
                guard abs(w) > 70, abs(w) > abs(h) * 1.8 else { return }
                let all = NewsSection.allCases
                guard let i = all.firstIndex(of: section) else { return }
                let j = i + (w < 0 ? 1 : -1)
                if all.indices.contains(j) { go(to: all[j]) }
            }
    }

    @ViewBuilder
    private func page(_ section: NewsSection) -> some View {
        let all = store.newsItems(section)
        let items = Array(all.prefix(limits[section] ?? 40))
        let seq = items.map(\.id)
        // the paywall preview: the first 12 stories open, the rest locked
        let locked: Set<String> = paywall ? Set(items.dropFirst(Paywall.freeStories).map(\.id)) : []
        VStack(spacing: 14) {
            if store.stories.isEmpty {
                if store.isLoading {
                    ProgressView().padding(.vertical, 60)
                } else {
                    EmptyCard(symbol: "newspaper", title: "No stories yet",
                              text: store.lastError ?? "Pull down to check for the latest news.")
                }
            } else if all.isEmpty {
                EmptyCard(symbol: "magnifyingglass", title: "Nothing here yet", text: "Try another section.")
            } else {
                if section == .all, store.interests.isEmpty {
                    interestsPrompt
                }
                let cover = section.topic.flatMap { store.briefing.section($0) }
                let hero = cover == nil ? heroPick(items, section) : nil
                if let topic = section.topic, let brief = cover {
                    SectionCover(topic: topic, brief: brief, lead: store.story(brief.leadStoryId), sequence: seq)
                } else if let hero {
                    NavigationLink(value: StoryRoute(id: hero.id, sequence: seq)) { HeroCard(story: hero) }
                        .buttonStyle(PressStyle())
                }
                SectionHead(title: section == .all ? (store.interests.isEmpty ? "Top stories" : "For you") : "Latest", detail: "\(all.count) stories")
                ForEach(chunks(items.filter { $0.id != hero?.id })) { chunk in
                    if let big = chunk.hero {
                        NavigationLink(value: StoryRoute(id: big.id, sequence: seq)) { HeroCard(story: big) }
                            .buttonStyle(PressStyle())
                            .locked(locked.contains(big.id))
                            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    } else {
                        StoryList(stories: chunk.rows, sequence: seq, locked: locked)
                    }
                }
                if all.count > items.count {
                    Button {
                        withAnimation(.snappy) { limits[section, default: 40] += 40 }
                    } label: {
                        Text("Show more stories")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(maxWidth: .infinity).frame(height: 46)
                            .background(Theme.card, in: Capsule())
                            .foregroundStyle(Theme.text)
                    }
                    .buttonStyle(PressStyle())
                }
            }
        }
    }

    /// The picture story at the top: the first with a picture among the top few.
    private func heroPick(_ items: [Story], _ section: NewsSection) -> Story? {
        items.prefix(section == .all ? 3 : 6).first { $0.imageURL != nil } ?? items.first
    }

    private struct Chunk: Identifiable {
        let id: String
        var hero: Story? = nil
        var rows: [Story] = []
    }

    /// Rows in groups of eight, with a picture story between groups, as on the web.
    private func chunks(_ list: [Story]) -> [Chunk] {
        var out: [Chunk] = []
        var i = 0
        while i < list.count {
            if i > 0, list[i].imageURL != nil {
                out.append(Chunk(id: "h-" + list[i].id, hero: list[i]))
                i += 1
            }
            let end = min(i + 8, list.count)
            if i < end { out.append(Chunk(id: "r-" + list[i].id, rows: Array(list[i..<end]))) }
            i = end
        }
        return out
    }

    private var interestsPrompt: some View {
        Button { showInterests = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "sparkles").foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Make it yours").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                    Text("Pick your topics and For you follows them.").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(Theme.tertiary)
            }
            .scoutCard(padding: 16)
        }
        .buttonStyle(PressStyle())
    }
}

/// A section's "today" cover: the main topic, a short summary, the key stories and what to watch.
struct SectionCover: View {
    let topic: Topic
    let brief: SectionBrief
    let lead: Story?
    let sequence: [String]
    @EnvironmentObject private var store: NewsStore

    var body: some View {
        VStack(spacing: 14) {
            leadCard
            highlightsCard
            if !brief.movers.isEmpty { moversCard }
        }
    }

    // The picture, the headline of the day and one paragraph.
    private var leadCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationLink(value: lead.map { StoryRoute(id: $0.id, sequence: sequence) }) {
                StoryImage(story: lead).frame(height: 190)
            }
            .buttonStyle(PressStyle())
            .disabled(lead == nil)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Circle().fill(Theme.accent).frame(width: 7, height: 7)
                    Text(topic.coverLabel + (brief.generated.map { " · \(Format.time($0))" } ?? "")).scoutLabel()
                }
                Text(brief.title).font(Theme.headline(22, weight: .bold)).foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                if let first = NewsStore.paragraphs(brief.summary).first {
                    Text(first).font(.system(size: 15)).lineSpacing(2).foregroundStyle(Theme.text.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(18)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    /// The rest of the day in short pieces: a label in the accent, a sentence or two, and the story
    /// behind it a tap away. Older briefings without highlights show their key points the same way.
    private var items: [SectionBrief.Highlight] {
        if !brief.highlights.isEmpty { return brief.highlights }
        return brief.points.map { SectionBrief.Highlight(label: "", text: $0.line, storyId: $0.storyId) }
    }

    @ViewBuilder private var highlightsCard: some View {
        let list = items
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("Highlights").scoutLabel().padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 4)
                ForEach(Array(list.enumerated()), id: \.offset) { i, h in
                    let story = store.story(h.storyId)
                    NavigationLink(value: story.map { StoryRoute(id: $0.id, sequence: sequence) }) {
                        HStack(alignment: .top, spacing: 14) {
                            // the bullet: a short accent bar that runs alongside the text
                            Capsule().fill(Theme.accent).frame(width: 3).frame(maxHeight: .infinity)
                            VStack(alignment: .leading, spacing: 5) {
                                if !h.label.isEmpty {
                                    Text(h.label)
                                        .font(.system(size: 11, weight: .bold))
                                        .tracking(0.8)
                                        .textCase(.uppercase)
                                        .foregroundStyle(Theme.accent)
                                }
                                Text(h.text)
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(Theme.text)
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                            if story != nil {
                                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Theme.tertiary)
                                    .padding(.top, 2)
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressStyle())
                    .disabled(story == nil)
                    if i < list.count - 1 {
                        Rectangle().fill(Theme.hairline).frame(height: 0.5).padding(.leading, 35)
                    }
                }
            }
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
    }

    private var moversCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(topic.moversTitle).scoutLabel()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(brief.movers) { m in
                        NavigationLink(value: TickerRoute(ticker: m.ticker, name: m.name)) {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 4) {
                                    Image(systemName: Direction.arrow(m.direction)).font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(m.direction == "down" ? Theme.accent : Theme.ink)
                                    Text(m.ticker).font(.system(size: 13, weight: .bold, design: .monospaced)).foregroundStyle(Theme.text)
                                }
                                Text(m.name ?? "").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondary).lineLimit(1)
                                if let note = m.note {
                                    Text(note).font(.system(size: 11)).foregroundStyle(Theme.text.opacity(0.7)).lineLimit(3)
                                        .multilineTextAlignment(.leading)
                                }
                            }
                            .padding(10)
                            .frame(width: 170, height: 96, alignment: .topLeading)
                            .background(Theme.track, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(PressStyle())
                    }
                }
            }
            .scrollClipDisabled()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}
