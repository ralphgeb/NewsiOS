import SwiftUI

struct TodayView: View {
    @EnvironmentObject private var store: NewsStore
    @EnvironmentObject private var weather: WeatherModel
    @EnvironmentObject private var tube: TubeService
    @Binding var showSettings: Bool
    @State private var path = NavigationPath()
    @State private var editionID: String?
    @State private var showTopics = false

    // Edit mode, as in Halo: drag cards to reorder them, minus to hide one, plus to bring it back.
    @AppStorage("today.cards.v4") private var orderRaw = ""   // v4: companies to watch moved to the bottom
    @AppStorage("today.hidden") private var hiddenRaw = ""
    @State private var editing = false
    @State private var dragging: TodayCard?
    @State private var dragOffset: CGFloat = 0
    @State private var dragShift: CGFloat = 0     // drag already used up by swapping past cards
    @State private var heights: [TodayCard: CGFloat] = [:]
    private let spacing: CGFloat = 14              // ScoutPage's gap between cards

    var body: some View {
        let page = store.frontPage(edition: editionID)
        ScoutNavigation(path: $path) {
            ScoutPage(showSettings: $showSettings, title: "Today", subtitle: subtitle,
                      onRefresh: {
                          async let news: Void = store.refresh()
                          async let sky: Void = weather.refresh(force: true)
                          async let trains: Void = tube.refresh(force: true)
                          _ = await (news, sky, trains)
                      }, isRefreshing: store.isLoading) {
                if let page {
                    ForEach(visible(page)) { card in
                        editableCard(card, page: page)
                    }
                    if editing {
                        hiddenSection(page)
                    } else {
                        footer(page)
                    }
                } else {
                    if !hidden.contains(.weather) || !hidden.contains(.tube) {
                        GlanceCard(showWeather: !hidden.contains(.weather), showTube: !hidden.contains(.tube))
                    }
                    waiting
                }
            }
            .onPreferenceChange(CardHeightsKey.self) { heights = $0 }
            .storyDestinations()
        }
        .onChange(of: store.topic) { _, _ in editionID = nil }
        // a widget tap shows Today from the top, closing any story you'd opened
        .onReceive(NotificationCenter.default.publisher(for: .scoutShowPage)) { note in
            if let url = note.object as? URL, url.host == nil || url.host == "today" { path = NavigationPath(); editing = false }
        }
        .onChange(of: editing) { _, on in if !on { dragging = nil; dragOffset = 0 } }
        .sheet(isPresented: $showTopics) { TopicsSheet().environmentObject(store).presentationDetents([.large]) }
        .sensoryFeedback(.impact(weight: .light), trigger: orderRaw)
        .sensoryFeedback(.selection, trigger: hiddenRaw)
        .sensoryFeedback(.impact(weight: .medium), trigger: dragging)
        .sensoryFeedback(.selection, trigger: editionID)
    }

    /// "Tuesday 27 October".
    private var subtitle: String {
        Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    // MARK: Order and hiding

    private var order: [TodayCard] {
        let saved = orderRaw.split(separator: ",").compactMap { TodayCard(rawValue: String($0)) }
        return saved + TodayCard.allCases.filter { !saved.contains($0) }
    }

    private var hidden: Set<TodayCard> {
        Set(hiddenRaw.split(separator: ",").compactMap { TodayCard(rawValue: String($0)) })
    }

    private func visible(_ page: FrontPage) -> [TodayCard] {
        let list = order.filter { isAvailable($0, page) && !hidden.contains($0) }
        // the weather and the metro share one card, where the first of the two sits
        guard let first = list.first(where: { $0 == .weather || $0 == .tube }) else { return list }
        return list.filter { ($0 != .weather && $0 != .tube) || $0 == first }
    }

    /// The weather and the metro share one card: hiding it hides both.
    private func hide(_ card: TodayCard) {
        if card == .weather || card == .tube {
            var h = hidden
            h.insert(.weather); h.insert(.tube)
            withAnimation(.snappy) { hiddenRaw = TodayCard.allCases.filter(h.contains).map(\.rawValue).joined(separator: ",") }
        } else {
            setHidden(card, true)
        }
    }

    private func isAvailable(_ card: TodayCard, _ page: FrontPage) -> Bool {
        switch card {
        case .weather, .tube, .markets: return true
        case .top: return !page.items.isEmpty
        case .movers: return !page.movers.isEmpty
        case .brief: return !page.brief.isEmpty
        case .more: return !page.more.isEmpty
        }
    }

    private func setHidden(_ card: TodayCard, _ hide: Bool) {
        var h = hidden
        if hide { h.insert(card) } else { h.remove(card) }
        withAnimation(.snappy) { hiddenRaw = TodayCard.allCases.filter(h.contains).map(\.rawValue).joined(separator: ",") }
    }

    /// Swaps two cards in the saved order.
    private func swap(_ a: TodayCard, _ b: TodayCard) {
        var cards = order
        guard let i = cards.firstIndex(of: a), let j = cards.firstIndex(of: b) else { return }
        cards.swapAt(i, j)
        orderRaw = cards.map(\.rawValue).joined(separator: ",")
    }

    // MARK: Editing

    @ViewBuilder
    private func editableCard(_ card: TodayCard, page: FrontPage) -> some View {
        let isDragged = dragging == card
        cardView(card, page: page)
            .allowsHitTesting(!editing)
            .background(GeometryReader { g in Color.clear.preference(key: CardHeightsKey.self, value: [card: g.size.height]) })
            .overlay {
                if editing {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(isDragged ? Theme.accent : Theme.hairline, lineWidth: isDragged ? 2 : 1)
                }
            }
            .overlay(alignment: .topLeading) {
                if editing {
                    CornerButton(symbol: "minus", label: "Hide \(card.title)") { hide(card) }
                        .offset(x: -8, y: -8)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .overlay(alignment: .trailing) {
                if editing {
                    // the handle: drag it and the card follows your finger straight away
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(isDragged ? Theme.accent : Theme.secondary)
                        .frame(width: 40, height: 40)
                        .background(Theme.background.opacity(0.92), in: Circle())
                        .frame(width: 56, height: 64)
                        .contentShape(Rectangle())
                        .gesture(handleDrag(card, page: page))
                        .padding(.trailing, 4)
                        .accessibilityHidden(true)
                }
            }
            .scaleEffect(isDragged ? 1.03 : 1)
            .shadow(color: .black.opacity(isDragged ? 0.18 : 0), radius: 18, y: 10)
            .offset(y: isDragged ? dragOffset : 0)
            .zIndex(isDragged ? 1 : 0)
            .animation(isDragged ? nil : .snappy, value: orderRaw)
            .animation(.snappy, value: dragging)
            .accessibilityAction(named: "Move up") { moveByOne(card, -1, page: page) }
            .accessibilityAction(named: "Move down") { moveByOne(card, 1, page: page) }
    }

    private func handleDrag(_ card: TodayCard, page: FrontPage) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { drag in
                if dragging != card { dragging = card; dragShift = 0 }
                follow(card, translation: drag.translation.height, list: visible(page))
            }
            .onEnded { _ in
                withAnimation(.snappy) {
                    dragging = nil
                    dragOffset = 0
                    dragShift = 0
                }
            }
    }

    /// Keeps the dragged card under the finger, swapping it past a neighbour once it's
    /// more than halfway over it.
    private func follow(_ card: TodayCard, translation: CGFloat, list: [TodayCard]) {
        var offset = translation - dragShift
        guard let i = list.firstIndex(of: card) else { return }
        if offset > 0, i + 1 < list.count {
            let h = heights[list[i + 1]] ?? 120
            if offset > h / 2 + spacing / 2 {
                swap(card, list[i + 1])
                dragShift += h + spacing
                offset -= h + spacing
            }
        } else if offset < 0, i > 0 {
            let h = heights[list[i - 1]] ?? 120
            if -offset > h / 2 + spacing / 2 {
                swap(card, list[i - 1])
                dragShift -= h + spacing
                offset += h + spacing
            }
        }
        dragOffset = offset
    }

    private func moveByOne(_ card: TodayCard, _ step: Int, page: FrontPage) {
        let list = visible(page)
        guard let i = list.firstIndex(of: card), list.indices.contains(i + step) else { return }
        withAnimation(.snappy) { swap(card, list[i + step]) }
    }

    /// Cards you've turned off, faded, each with a plus to bring it back.
    @ViewBuilder
    private func hiddenSection(_ page: FrontPage) -> some View {
        let off = order.filter { hidden.contains($0) && isAvailable($0, page) && !($0 == .tube && hidden.contains(.weather)) }
        if !off.isEmpty {
            Text("Hidden").scoutLabel()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 10)
            ForEach(off) { card in
                cardView(card, page: page)
                    .allowsHitTesting(false)
                    .opacity(0.38)
                    .overlay(alignment: .topLeading) {
                        CornerButton(symbol: "plus", label: "Show \(card.title)") {
                            if card == .weather || card == .tube {
                                var h = hidden
                                h.remove(.weather); h.remove(.tube)
                                withAnimation(.snappy) { hiddenRaw = TodayCard.allCases.filter(h.contains).map(\.rawValue).joined(separator: ",") }
                            } else {
                                setHidden(card, false)
                            }
                        }
                            .offset(x: -8, y: -8)
                    }
            }
        } else {
            Text("Tap the minus on a card to hide it. Hidden cards wait here.")
                .font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                .padding(.top, 6)
        }
    }

    // MARK: Cards

    private func sequence(_ page: FrontPage) -> [String] {
        var ids: [String] = []
        func add(_ id: String?) {
            if let id, !ids.contains(id) { ids.append(id) }
        }
        add(page.cover?.id)
        for item in page.items { add(item.story?.id) }
        for item in page.brief { add(item.story?.id) }
        for s in page.more { add(s.id) }
        return ids
    }

    @ViewBuilder
    private func cardView(_ card: TodayCard, page: FrontPage) -> some View {
        let seq = sequence(page)
        switch card {
        case .weather, .tube: GlanceCard(showWeather: !hidden.contains(.weather), showTube: !hidden.contains(.tube))
        case .markets: MarketsCard()
        case .top:
            VStack(spacing: 14) {
                TodayLead(page: page, sequence: seq)
                TopStoriesCard(items: restItems(page), sequence: seq, title: page.isWritten ? "Top stories" : "Key stories", start: page.cover == nil ? 1 : 2, heroes: 1)
            }
        case .movers: MoversCard(title: page.moversTitle, movers: page.movers)
        case .brief: InBriefCard(items: page.brief, sequence: seq)
        case .more: MoreCard(title: store.interests.isEmpty ? "More in \(store.topic.title)" : "More for you", stories: page.more, sequence: seq)
        }
    }

    /// The lead has its own card at the top, so Top stories carries on from number 2.
    private func restItems(_ page: FrontPage) -> [FrontPage.Item] {
        guard let cover = page.cover else { return page.items }
        return page.items.filter { $0.story?.id != cover.id }
    }

    private var waiting: some View {
        VStack(spacing: 14) {
            if store.isLoading {
                ProgressView().padding(.vertical, 40).frame(maxWidth: .infinity)
            } else if let error = store.lastError {
                EmptyCard(symbol: "wifi.exclamationmark", title: "Couldn't load the news", text: error)
                Button("Try again") { Task { await store.refresh() } }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text)
            } else {
                EmptyCard(symbol: "sun.horizon",
                          title: "Your briefing is on its way",
                          text: "Briefings arrive by 6:00 each morning. Pull down to check for the latest stories.")
            }
        }
    }

    private func footer(_ page: FrontPage) -> some View {
        VStack(spacing: 10) {
            Button { showTopics = true } label: {
                Label("Your topics", systemImage: "slider.horizontal.3")
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 16)
                    .frame(height: 36)
                    .background(Theme.card, in: Capsule())
                    .foregroundStyle(Theme.text)
            }
            .buttonStyle(PressStyle())
            Text("Next briefing \(Self.nextUpdate). Written by AI from the day's headlines. It can make mistakes. Not financial advice.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .padding(.top, 6)
    }

    static var nextUpdate: String {
        var london = Calendar(identifier: .gregorian)
        london.timeZone = TimeZone(identifier: "Europe/London") ?? .current
        return london.component(.hour, from: .now) < 6 ? "by 6:00 London time" : "tomorrow by 6:00 London time"
    }
}

struct CardHeightsKey: PreferenceKey {
    static var defaultValue: [TodayCard: CGFloat] = [:]
    static func reduce(value: inout [TodayCard: CGFloat], nextValue: () -> [TodayCard: CGFloat]) {
        value.merge(nextValue()) { $1 }
    }
}

/// The cards on Today, in their default order.
enum TodayCard: String, CaseIterable, Identifiable {
    case weather, tube, top, markets, brief, more, movers

    var id: String { rawValue }

    var title: String {
        switch self {
        case .weather, .tube: return "Weather and travel"
        case .markets: return "Markets"
        case .top: return "Top stories"
        case .movers: return "Companies to watch"
        case .brief: return "In brief"
        case .more: return "More stories"
        }
    }
}

// MARK: - Cards

/// The markets strip from Stocks, from the latest 30-minute update.
struct MarketsCard: View {
    @EnvironmentObject private var stocks: StocksStore

    var body: some View {
        MarketsStrip()
            .task { await stocks.refreshFileIfStale() }
    }
}

/// The day's cover: the lead picture, the briefing's headline and its overview.
struct CoverCard: View {
    let page: FrontPage
    let sequence: [String]
    @Binding var editionID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationLink(value: page.cover.map { StoryRoute(id: $0.id, sequence: sequence) }) {
                StoryImage(story: page.cover)
                    .frame(height: 340)
                    .overlay {
                        LinearGradient(stops: [.init(color: .black.opacity(0.35), location: 0),
                                               .init(color: .black.opacity(0), location: 0.25),
                                               .init(color: .black.opacity(0), location: 0.4),
                                               .init(color: .black.opacity(0.82), location: 1)],
                                       startPoint: .top, endPoint: .bottom)
                            .allowsHitTesting(false)
                    }
                    .overlay(alignment: .bottomLeading) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(page.title)
                                .font(Theme.headline(28, weight: .heavy))
                                .tracking(-0.4)
                                .foregroundStyle(.white)
                                .multilineTextAlignment(.leading)
                                .lineLimit(5)
                                .minimumScaleFactor(0.8)
                                .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
                            HStack(spacing: 4) {
                                if let cover = page.cover { Text(cover.outletName) }
                                Text("· \(page.reviewed) stories reviewed")
                                if let g = page.generated { Text("· \(Format.time(g))") }
                            }
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.75))
                            .lineLimit(1)
                        }
                        .padding(18)
                    }
                    .overlay(alignment: .topLeading) {
                        Text(page.label)
                            .font(.system(size: 11, weight: .heavy))
                            .tracking(1)
                            .textCase(.uppercase)
                            .padding(.horizontal, 10)
                            .frame(height: 24)
                            .background(Theme.accent, in: Capsule())
                            .foregroundStyle(.white)
                            .padding(14)
                    }
            }
            .buttonStyle(PressStyle())
            .disabled(page.cover == nil)

            // The overview stays on the News page, so Today is quicker to read.
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

}

/// The first thing on Today: the day's lead story as a cover (its picture, the headline set on it),
/// with your audio briefing built into the bottom of the same card. One tap reads, one tap listens.
struct TodayLead: View {
    let page: FrontPage
    let sequence: [String]

    var body: some View {
        VStack(spacing: 0) {
            NavigationLink(value: page.cover.map { StoryRoute(id: $0.id, sequence: sequence) }) {
                StoryImage(story: page.cover)
                    .frame(height: Design.leadImage)
                    .overlay {
                        LinearGradient(stops: [.init(color: .black.opacity(0.28), location: 0),
                                               .init(color: .black.opacity(0), location: 0.22),
                                               .init(color: .black.opacity(0), location: 0.38),
                                               .init(color: .black.opacity(0.85), location: 1)],
                                       startPoint: .top, endPoint: .bottom)
                            .allowsHitTesting(false)
                    }
                    .overlay(alignment: .topLeading) {
                        HStack(spacing: 6) {
                            Text("1").font(Theme.number(12, weight: .bold))
                                .frame(width: 20, height: 20)
                                .background(.white, in: Circle())
                                .foregroundStyle(Theme.accent)
                            Text("Top story").font(.system(size: 11, weight: .heavy)).tracking(0.8).textCase(.uppercase)
                        }
                        .padding(.leading, 3).padding(.trailing, 10)
                        .frame(height: 26)
                        .background(Theme.accent, in: Capsule())
                        .foregroundStyle(.white)
                        .padding(14)
                    }
                    .overlay(alignment: .bottomLeading) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(page.title)
                                .font(Theme.headline(26, weight: .heavy))
                                .tracking(-0.4)
                                .foregroundStyle(.white)
                                .multilineTextAlignment(.leading)
                                .lineLimit(4)
                                .minimumScaleFactor(0.8)
                                .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
                            if let cover = page.cover {
                                HStack(spacing: 4) {
                                    Text(cover.outletName)
                                    if cover.outletCount > 1 { Text("+\(cover.outletCount - 1)") }
                                    Text("· \(Format.ago(cover.published))")
                                }
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.78))
                                .lineLimit(1)
                            }
                        }
                        .padding(18)
                    }
            }
            .buttonStyle(PressStyle())
            .disabled(page.cover == nil)
            .storyZoomSource(page.cover?.id)

            PlayMyBriefings(embedded: true)
                .padding(.vertical, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

/// The briefing's top stories: the first two with pictures, the rest as numbered rows.
struct TopStoriesCard: View {
    let items: [FrontPage.Item]
    let sequence: [String]
    let title: String
    /// The number of the first story here (2 when the lead has its own card above).
    var start = 1
    /// How many open with a big picture.
    var heroes = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHead(title: title, detail: "\(items.count + start - 1)", top: 0)
            ForEach(Array(items.prefix(heroes).enumerated()), id: \.element.id) { i, item in
                if let s = item.story {
                    NavigationLink(value: StoryRoute(id: s.id, sequence: sequence)) {
                        NumberedHero(number: i + start, story: s, title: item.title, text: item.text)
                    }
                    .buttonStyle(PressStyle())
                    .storyZoomSource(s.id)
                } else {
                    plain(item, number: i + start)
                }
            }
            let rest = Array(items.dropFirst(heroes).enumerated())
            if !rest.isEmpty {
                VStack(spacing: 0) {
                    ForEach(rest, id: \.element.id) { i, item in
                        Group {
                            if let s = item.story {
                                NavigationLink(value: StoryRoute(id: s.id, sequence: sequence)) {
                                    StoryRow(story: s, number: i + heroes + start, text: item.text)
                                }
                                .buttonStyle(PressStyle())
                                .storyZoomSource(s.id)
                            } else {
                                plain(item, number: i + heroes + start).background(Color.clear)
                            }
                        }
                        if i < rest.count - 1 {
                            Rectangle().fill(Theme.hairline).frame(height: 0.5).padding(.leading, 16)
                        }
                    }
                }
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
        }
    }

    private func plain(_ item: FrontPage.Item, number: Int) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)").font(Theme.number(20, weight: .bold)).foregroundStyle(Theme.tertiary).frame(width: 22, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(Theme.headline(16)).foregroundStyle(Theme.text)
                if let t = item.text { Text(t).font(.system(size: 13)).foregroundStyle(Theme.secondary) }
            }
            Spacer(minLength: 0)
        }
        .scoutCard(padding: 16)
    }
}

/// A big numbered story: the picture, then the briefing's own headline and summary.
struct NumberedHero: View {
    let number: Int
    let story: Story
    let title: String
    let text: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StoryImage(story: story)
                .frame(height: Design.topImage)
                .overlay(alignment: .topLeading) {
                    Text("\(number)")
                        .font(Theme.number(15, weight: .bold))
                        .frame(width: 30, height: 30)
                        .background(Theme.card, in: Circle())
                        .foregroundStyle(Theme.text)
                        .padding(12)
                }
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    SourceLine(story: story)
                    Text("· \(Format.ago(story.published))").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.tertiary)
                }
                Text(title).font(Theme.headline(19)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                if let text, !text.isEmpty {
                    Text(text).font(.system(size: 14)).foregroundStyle(Theme.secondary).lineLimit(4)
                }
                TickerChips(story: story, limit: 4)
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

/// Companies, indices or brands the briefing expects to move.
struct MoversCard: View {
    let title: String
    let movers: [Mover]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHead(title: title, detail: "\(movers.count)")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(movers) { m in
                    NavigationLink(value: TickerRoute(ticker: m.ticker, name: m.name)) {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Monogram(name: m.name, ticker: m.ticker)
                                Spacer()
                                Image(systemName: Direction.arrow(m.direction))
                                    .font(.system(size: 12, weight: .bold))
                                    .frame(width: 26, height: 26)
                                    .background(m.direction == "down" ? Theme.accent.opacity(0.15) : Theme.track, in: Circle())
                                    .foregroundStyle(m.direction == "down" ? Theme.accent : Theme.ink)
                            }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(m.ticker).font(.system(size: 14, weight: .bold, design: .monospaced)).foregroundStyle(Theme.text)
                                Text(m.name ?? "").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary).lineLimit(1)
                            }
                            if let note = m.note {
                                Text(note).font(.system(size: 12)).foregroundStyle(Theme.text.opacity(0.75)).lineLimit(4)
                                    .multilineTextAlignment(.leading)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                    .buttonStyle(PressStyle())
                }
            }
        }
    }
}

/// One line per smaller story.
struct InBriefCard: View {
    let items: [FrontPage.Item]
    let sequence: [String]
    @AppStorage(Plus.key) private var hasPlus = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHead(title: "In brief", detail: "\(items.count)")
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                    NavigationLink(value: item.story.map { StoryRoute(id: $0.id, sequence: sequence) }) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Circle().fill(Theme.accent).frame(width: 6, height: 6).offset(y: -2)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title).font(.system(size: 15)).foregroundStyle(Theme.text)
                                    .multilineTextAlignment(.leading)
                                if let s = item.story {
                                    Text("\(s.outletName) · \(Format.ago(s.published))").font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                                }
                            }
                            Spacer(minLength: 0)
                            if item.story != nil {
                                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.tertiary)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressStyle())
                    .disabled(item.story == nil)
                    if i < items.count - 1 {
                        Rectangle().fill(Theme.hairline).frame(height: 0.5).padding(.leading, 32)
                    }
                }
            }
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .locked(!hasPlus)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
    }
}

struct MoreCard: View {
    let title: String
    let stories: [Story]
    let sequence: [String]
    @AppStorage(Plus.key) private var hasPlus = false
    private var paywall: Bool { !hasPlus }

    /// Small cards of a few stories each, with one big picture story halfway down.
    private var groups: (before: [[Story]], hero: Story?, after: [[Story]]) {
        let mid = stories.count / 2
        let heroIndex = stories.count >= 6 ? (stories.indices.dropFirst(mid).first { stories[$0].imageURL != nil } ?? mid) : nil
        let hero = heroIndex.map { stories[$0] }
        let rest = stories.filter { $0.id != hero?.id }
        let split = heroIndex.map { min($0, rest.count) } ?? rest.count
        func chunks(_ list: ArraySlice<Story>) -> [[Story]] {
            stride(from: list.startIndex, to: list.endIndex, by: 4).map { Array(list[$0..<min($0 + 4, list.endIndex)]) }
        }
        return (chunks(rest[..<split]), hero, chunks(rest[split...]))
    }

    var body: some View {
        let g = groups
        VStack(alignment: .leading, spacing: 12) {
            SectionHead(title: title, detail: "\(stories.count)")
            ForEach(g.before, id: \.first?.id) { StoryList(stories: $0, sequence: sequence, locked: paywall) }
            if let hero = g.hero {
                NavigationLink(value: StoryRoute(id: hero.id, sequence: sequence)) { HeroCard(story: hero) }
                    .buttonStyle(PressStyle())
                    .storyZoomSource(hero.id)
                    .locked(paywall)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
            ForEach(g.after, id: \.first?.id) { StoryList(stories: $0, sequence: sequence, locked: paywall) }
        }
    }
}

