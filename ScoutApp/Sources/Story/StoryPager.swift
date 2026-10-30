import SafariServices
import SwiftUI

/// A link to open in the in-app browser.
struct WebLink: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

/// One story at a time. Swipe left for the next story in the list you came from, right for the
/// previous one; swipe from the left edge to go back.
struct StoryPager: View {
    @EnvironmentObject private var store: NewsStore
    let route: StoryRoute
    @State private var current: String?
    @State private var reading: WebLink?

    init(route: StoryRoute) {
        self.route = route
        _current = State(initialValue: route.id)
    }

    private var ids: [String] {
        let seq = route.sequence.filter { store.story($0) != nil }
        return seq.contains(route.id) ? seq : [route.id]
    }

    private var story: Story? { store.story(current ?? route.id) }

    var body: some View {
        let list = ids
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(Array(list.enumerated()), id: \.element) { i, id in
                    StoryDetailView(id: id, position: i, count: list.count,
                                    next: i + 1 < list.count ? store.story(list[i + 1]) : nil,
                                    onNext: { withAnimation(.snappy) { current = list[i + 1] } },
                                    onOpen: { reading = WebLink(url: $0) })
                        .containerRelativeFrame(.horizontal)
                        .id(id)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $current)
        // every story you read goes into History
        .onAppear { if let story { store.remember(story) } }
        .onChange(of: current) { _, _ in if let story { store.remember(story) } }
        .scrollIndicators(.hidden)
        .scrollDisabled(list.count < 2)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(story?.outletName ?? "Story")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            if let story {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        withAnimation(.snappy) { store.toggleSaved(story) }
                    } label: {
                        Image(systemName: store.isSaved(story.id) ? "bookmark.fill" : "bookmark")
                    }
                    .accessibilityLabel(store.isSaved(story.id) ? "Remove from Saved" : "Save")
                    if let url = story.lead?.url {
                        ShareLink(item: url, subject: Text(story.title)) { Image(systemName: "square.and.arrow.up") }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let story, let url = story.lead?.url {
                Button { reading = WebLink(url: url) } label: {
                    HStack(spacing: 8) {
                        Favicon(host: story.lead?.host, size: 16)
                        Text("Read on \(story.outletName)").lineLimit(1)
                        Image(systemName: "arrow.up.right").font(.system(size: 12, weight: .bold))
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.background)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Theme.ink, in: Capsule())
                }
                .buttonStyle(PressStyle())
                .padding(.horizontal, 20)
                .padding(.top, 10)
                .padding(.bottom, 4)
                .background(Theme.background.opacity(0.94).ignoresSafeArea())
            }
        }
        .sheet(item: $reading) { link in
            SafariView(url: link.url).ignoresSafeArea()
        }
        .sensoryFeedback(.selection, trigger: current)
        .sensoryFeedback(.success, trigger: story.map { store.isSaved($0.id) } ?? false)
        .tint(Theme.ink)
    }
}

struct StoryDetailView: View {
    @EnvironmentObject private var store: NewsStore
    let id: String
    let position: Int
    let count: Int
    let next: Story?
    let onNext: () -> Void
    let onOpen: (URL) -> Void

    var body: some View {
        ScrollView {
            if let s = store.story(id) {
                VStack(alignment: .leading, spacing: 14) {
                    if s.imageURL != nil {
                        StoryImage(story: s)
                            .frame(height: 250)
                            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                            .overlay(alignment: .bottomTrailing) {
                                if let credit = s.imageCredit {
                                    Text("Image: \(credit)")
                                        .font(.system(size: 10, weight: .semibold))
                                        .padding(.horizontal, 7).padding(.vertical, 3)
                                        .background(.black.opacity(0.5), in: Capsule())
                                        .foregroundStyle(.white)
                                        .padding(10)
                                }
                            }
                    }
                    head(s)
                    summaryCard(s)
                    if s.status != "news", s.status != nil, s.likelihood != nil { RumourCheckCard(story: s) }
                    if !(s.stocks ?? []).isEmpty || !(s.marketTake ?? "").isEmpty { MarketImpactCard(story: s) }
                    coverage(s)
                    if count > 1 {
                        Text("Story \(position + 1) of \(count) · swipe for the next or previous story")
                            .font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                            .frame(maxWidth: .infinity)
                    }
                    if let next { upNext(next) }
                    Text("Summary, odds and market effects are written by AI and can be wrong. Not financial advice.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.tertiary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 24)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 24)
            } else {
                EmptyCard(symbol: "newspaper", title: "This story has gone", text: "It's no longer in the latest news.")
                    .padding(20)
            }
        }
        .scrollIndicators(.hidden)
    }

    private func head(_ s: Story) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                SourceLine(story: s)
                Text("· \(Format.ago(s.published))").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.tertiary)
            }
            Text(s.title)
                .font(Theme.headline(26, weight: .bold))
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    StatusPill(story: s)
                    ForEach([s.newsSection.title] + (s.topics ?? []).filter { $0 != "Other" }, id: \.self) { t in
                        Text(t)
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 8)
                            .frame(height: 20)
                            .background(Theme.track, in: Capsule())
                            .foregroundStyle(Theme.secondary)
                    }
                }
            }
            .scrollClipDisabled()
        }
        .padding(.horizontal, 4)
    }

    private func summaryCard(_ s: Story) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(Theme.accent).frame(width: 7, height: 7)
                Text("Scout AI summary").scoutLabel()
            }
            Text(s.summary ?? s.claim ?? "")
                .font(.system(size: 16))
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            if let points = s.keyPoints, !points.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(points, id: \.self) { p in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Circle().fill(Theme.ink.opacity(0.4)).frame(width: 5, height: 5).offset(y: -2)
                            Text(p).font(.system(size: 15)).foregroundStyle(Theme.text.opacity(0.85))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
        .scoutCard()
    }

    private func coverage(_ s: Story) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHead(title: "Coverage", detail: "\(s.outletCount) source\(s.outletCount > 1 ? "s" : "")")
            VStack(spacing: 0) {
                let sources = s.sources ?? []
                ForEach(Array(sources.enumerated()), id: \.offset) { i, src in
                    Button {
                        if let url = src.url { onOpen(url) }
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Favicon(host: src.host, size: 18).padding(.top, 1)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 4) {
                                    Text(src.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                                    Text("· \(Format.ago(src.published))").font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                                }
                                if let t = src.title {
                                    Text(t).font(.system(size: 14)).foregroundStyle(Theme.secondary).lineLimit(3)
                                        .multilineTextAlignment(.leading)
                                }
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.tertiary)
                                .padding(.top, 3)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressStyle())
                    .disabled(src.url == nil)
                    if i < sources.count - 1 {
                        Rectangle().fill(Theme.hairline).frame(height: 0.5).padding(.leading, 44)
                    }
                }
            }
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
    }

    private func upNext(_ n: Story) -> some View {
        Button(action: onNext) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Up next").scoutLabel()
                    Text(n.title).font(Theme.headline(16)).foregroundStyle(Theme.text).lineLimit(3)
                        .multilineTextAlignment(.leading)
                    Text("\(n.outletName) · \(Format.ago(n.published))").font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                }
                Spacer(minLength: 0)
                StoryImage(story: n)
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .scoutCard(padding: 16)
        }
        .buttonStyle(PressStyle())
    }
}

/// The AI's odds, in Halo's ring.
struct RumourCheckCard: View {
    let story: Story

    var body: some View {
        let p = Double(story.odds ?? 50) / 100
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Rumour check").scoutLabel()
                Spacer()
                StatusPill(story: story)
            }
            HStack(spacing: 16) {
                ZStack {
                    Ring(progress: p, lineWidth: 7)
                    Group {
                        switch story.status {
                        case "confirmed": Image(systemName: "checkmark").font(.system(size: 20, weight: .bold))
                        case "denied": Image(systemName: "xmark").font(.system(size: 20, weight: .bold))
                        default: Text("\(story.odds ?? 50)").font(Theme.number(24))
                        }
                    }
                    .foregroundStyle(Theme.ink)
                }
                .frame(width: 76, height: 76)
                VStack(alignment: .leading, spacing: 3) {
                    Text(story.verdict).font(Theme.headline(22)).foregroundStyle(p < 0.35 ? Theme.accent : Theme.text)
                    Text("\(story.outletCount) outlet\(story.outletCount > 1 ? "s" : "") reporting · first seen \(Format.ago(story.firstSeen).lowercased())")
                        .font(.system(size: 13)).foregroundStyle(Theme.secondary)
                }
            }
            if let r = story.likelihoodReason, !r.isEmpty {
                Text(r).font(.system(size: 15)).foregroundStyle(Theme.text.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
            }
            if let signals = story.signals, !signals.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(signals, id: \.self) { s in
                        Text(s).font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(Theme.track, in: Capsule())
                            .foregroundStyle(Theme.secondary)
                    }
                }
            }
        }
        .scoutCard()
    }
}

/// Which companies the story could move, up or down, and by how much.
struct MarketImpactCard: View {
    let story: Story

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Market impact").scoutLabel()
                Spacer()
                if story.impactLevel > 0, let level = story.overallImpact {
                    Text("\(level.capitalized) impact").font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 8).frame(height: 20)
                        .background(Theme.track, in: Capsule()).foregroundStyle(Theme.secondary)
                }
            }
            if let take = story.marketTake, !take.isEmpty {
                Text(take).font(.system(size: 15)).foregroundStyle(Theme.text.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(story.stocks ?? [], id: \.ticker) { k in
                NavigationLink(value: TickerRoute(ticker: k.ticker, name: k.name)) {
                    HStack(alignment: .top, spacing: 12) {
                        Monogram(name: k.name, ticker: k.ticker)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(k.name ?? k.ticker).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                                Text(k.ticker).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.tertiary)
                            }
                            if let r = k.reason {
                                Text(r).font(.system(size: 13)).foregroundStyle(Theme.secondary).multilineTextAlignment(.leading)
                            }
                        }
                        Spacer(minLength: 0)
                        VStack(alignment: .trailing, spacing: 5) {
                            HStack(spacing: 3) {
                                Image(systemName: Direction.arrow(k.direction)).font(.system(size: 10, weight: .bold))
                                Text(Direction.word(k.direction)).font(.system(size: 12, weight: .semibold))
                            }
                            .foregroundStyle(k.direction == "down" ? Theme.accent : Theme.ink)
                            ImpactDots(level: Impact.level(k.impact))
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
            }
        }
        .scoutCard()
    }
}

/// ●○○ low to ●●● high.
struct ImpactDots: View {
    let level: Int

    var body: some View {
        HStack(spacing: 3) {
            ForEach(1...3, id: \.self) { i in
                Circle().fill(i <= max(1, level) ? Theme.ink : Theme.track).frame(width: 5, height: 5)
            }
        }
        .accessibilityLabel(["Low", "Low", "Medium", "High"][min(3, max(0, level))] + " impact")
    }
}

/// A company's initials in a quiet circle.
struct Monogram: View {
    let name: String?
    let ticker: String

    var body: some View {
        Text(initials)
            .font(.system(size: initials.count > 3 ? 10 : 12, weight: .bold, design: .rounded))
            .foregroundStyle(Theme.text)
            .frame(width: 36, height: 36)
            .background(Theme.track, in: Circle())
    }

    private var initials: String {
        let t = ticker.split(whereSeparator: { ".-=^".contains($0) }).first.map(String.init) ?? ""
        if !t.isEmpty, Int(t) == nil { return String(t.prefix(4)).uppercased() }
        let words = (name ?? "?").split(separator: " ")
        return words.count > 1 ? "\(words[0].prefix(1))\(words[1].prefix(1))".uppercased() : String((words.first ?? "?").prefix(2)).uppercased()
    }
}

/// Lays chips out in rows, wrapping as needed.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > width { x = 0; y += row + spacing; row = 0 }
            x += s.width + spacing
            row = max(row, s.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX, x + s.width > bounds.maxX { x = bounds.minX; y += row + spacing; row = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            row = max(row, s.height)
        }
    }
}

struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let vc = SFSafariViewController(url: url)
        vc.preferredControlTintColor = UIColor(Theme.ink)
        vc.dismissButtonStyle = .close
        return vc
    }

    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
}
