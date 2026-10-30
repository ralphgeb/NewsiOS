import SwiftUI
import UIKit

/// Opens a story, with the list it was opened from so you can swipe to the next one.
struct StoryRoute: Hashable {
    let id: String
    var sequence: [String] = []
}

/// A company's page: its live price, chart, AI summary and every story that names it.
struct TickerRoute: Hashable {
    let ticker: String
    let name: String?
}

extension View {
    /// The pages every tab can push: a story, and a company.
    func storyDestinations() -> some View {
        self
            .navigationDestination(for: StoryRoute.self) { StoryPager(route: $0) }
            .navigationDestination(for: TickerRoute.self) { StockDetailView(route: $0) }
    }
}

extension Format {
    /// The News page's line: "Your morning briefing", or which day's it is when it's older.
    static func briefing(_ date: Date) -> String {
        let cal = Calendar.current
        let h = cal.component(.hour, from: date)
        let part = h < 12 ? "morning" : h < 17 ? "afternoon" : "evening"
        if cal.isDateInToday(date) { return "Your \(part) briefing" }
        if cal.isDateInYesterday(date) { return "Yesterday's \(part) briefing" }
        return "Your briefing from \(date.formatted(.dateTime.weekday(.wide)))"
    }

    /// "Just now", "12m ago", "3h ago", "Yesterday", "4d ago"
    static func ago(_ date: Date?) -> String {
        guard let date, date != .distantPast else { return "" }
        let s = Date.now.timeIntervalSince(date)
        if s < 60 { return "Just now" }
        if s < 3600 { return "\(Int(s / 60))m ago" }
        if s < 86400 { return "\(Int(s / 3600))h ago" }
        let d = Int(s / 86400)
        return d == 1 ? "Yesterday" : "\(d)d ago"
    }
}

// MARK: - Images

/// Pictures for stories, kept in memory while the app runs and on disk through URLCache.
final class ImageLoader {
    static let shared = ImageLoader()
    private let memory = NSCache<NSURL, UIImage>()
    private let session: URLSession

    private init() {
        memory.countLimit = 300
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 30 << 20, diskCapacity: 300 << 20)
        config.requestCachePolicy = .returnCacheDataElseLoad
        // some news sites refuse requests that don't look like a browser
        config.httpAdditionalHeaders = ["User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"]
        session = URLSession(configuration: config)
    }

    func cached(_ url: URL) -> UIImage? { memory.object(forKey: url as NSURL) }

    func image(_ url: URL) async -> UIImage? {
        if let img = cached(url) { return img }
        guard let result = try? await session.data(from: url),
              (result.1 as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
              let img = UIImage(data: result.0) else { return nil }
        // shrink big pictures once, so scrolling stays smooth
        let ready = img.preparingThumbnail(of: Self.fit(img.size, max: 1200)) ?? img
        memory.setObject(ready, forKey: url as NSURL)
        return ready
    }

    private static func fit(_ size: CGSize, max m: CGFloat) -> CGSize {
        let scale = min(1, m / max(size.width, size.height, 1))
        return CGSize(width: size.width * scale, height: size.height * scale)
    }
}

struct RemoteImage<Placeholder: View>: View {
    let url: URL?
    @ViewBuilder var placeholder: () -> Placeholder
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
                    .transition(.opacity)
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            guard let url else { image = nil; return }
            if let hit = ImageLoader.shared.cached(url) { image = hit; return }
            let loaded = await ImageLoader.shared.image(url)
            withAnimation(.easeOut(duration: 0.2)) { image = loaded }
        }
    }
}

/// A story's picture, or a quiet box with the outlet's name when it has none.
struct StoryImage: View {
    let story: Story?

    var body: some View {
        Color.clear
            .overlay {
                RemoteImage(url: story?.imageURL) {
                    ZStack {
                        Theme.track
                        VStack(spacing: 6) {
                            Image(systemName: story?.newsSection.symbol ?? "newspaper")
                                .font(.system(size: 18, weight: .medium))
                            Text(story?.outletName ?? "Scout")
                                .font(Theme.headline(13))
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 8)
                        }
                        .foregroundStyle(Theme.tertiary)
                    }
                }
            }
            .clipped()
            .accessibilityHidden(true)
    }
}

// MARK: - Small pieces

/// The outlet's icon and name, with how many more are covering it.
struct SourceLine: View {
    let story: Story

    var body: some View {
        HStack(spacing: 5) {
            Favicon(host: story.lead?.host)
            Text(story.outletName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.text.opacity(0.75))
                .lineLimit(1)
            if story.outletCount > 1 {
                Text("+\(story.outletCount - 1)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.tertiary)
            }
        }
    }
}

struct Favicon: View {
    let host: String?
    var size: CGFloat = 14

    var body: some View {
        RemoteImage(url: host.flatMap { URL(string: "https://www.google.com/s2/favicons?domain=\($0)&sz=64") }) {
            Circle().fill(Theme.track)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
    }
}

/// "Rumour · 45%", "Confirmed" or "Denied".
struct StatusPill: View {
    let story: Story

    var body: some View {
        if let text {
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background(story.status == "denied" ? Theme.accent.opacity(0.15) : Theme.track, in: Capsule())
                .foregroundStyle(story.status == "denied" ? Theme.accent : Theme.text)
        }
    }

    private var text: String? {
        switch story.status {
        case "rumour": return "Rumour · \(story.odds.map { "\($0)%" } ?? "?")"
        case "confirmed": return "Confirmed"
        case "denied": return "Denied"
        default: return nil
        }
    }
}

/// Companies a story could move: an arrow (ink for up, accent for down) and the ticker.
struct TickerChips: View {
    let story: Story
    var limit = 3

    var body: some View {
        let list = Array((story.stocks ?? []).prefix(limit))
        if !list.isEmpty {
            HStack(spacing: 5) {
                ForEach(list, id: \.ticker) { k in
                    HStack(spacing: 3) {
                        Image(systemName: Direction.arrow(k.direction)).font(.system(size: 8, weight: .bold))
                            .foregroundStyle(k.direction == "down" ? Theme.accent : Theme.ink)
                        Text(k.ticker).font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Theme.text.opacity(0.75))
                    }
                    .padding(.horizontal, 6)
                    .frame(height: 20)
                    .background(Theme.track, in: Capsule())
                }
            }
        }
    }
}

/// A section title: big and heavy like the page titles, in the accent, with an optional count.
struct SectionHead: View {
    let title: String
    var detail: String? = nil
    /// A line under the title, on the left ("US, by market value").
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 26, weight: .heavy))
                    .tracking(-0.5)
                    .foregroundStyle(Theme.accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer()
                if let detail {
                    Text(detail).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.tertiary)
                }
            }
            if let subtitle {
                Text(subtitle).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.secondary)
            }
        }
        .padding(.horizontal, 2)
        .padding(.top, 14)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// How likely a rumour is, as a bar: ink when likely, accent when unlikely.
struct OddsBar: View {
    let story: Story

    var body: some View {
        let p = Double(story.odds ?? 50) / 100
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(story.verdict).font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(p < 0.35 ? Theme.accent : Theme.text)
                Spacer()
                Text("\(story.outletCount) outlet\(story.outletCount > 1 ? "s" : "") · \(Format.ago(story.updated))")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondary)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.track)
                    Capsule().fill(p < 0.35 ? Theme.accent : Theme.ink.opacity(0.35 + 0.65 * p))
                        .frame(width: max(6, g.size.width * p))
                }
            }
            .frame(height: 5)
        }
    }
}

// MARK: - Cards and rows

/// A big picture over the headline and summary.
struct HeroCard: View {
    let story: Story

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StoryImage(story: story)
                .frame(height: 200)
            VStack(alignment: .leading, spacing: 8) {
                SourceLine(story: story)
                Text(story.title)
                    .font(Theme.headline(21))
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                if let summary = story.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(3)
                }
                HStack(spacing: 6) {
                    Text(Format.ago(story.published)).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.tertiary)
                    StatusPill(story: story)
                    TickerChips(story: story)
                }
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

/// Headline on the left, picture on the right.
struct StoryRow: View {
    let story: Story
    var number: Int? = nil
    var text: String? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let number {
                Text("\(number)").font(Theme.number(20, weight: .bold)).foregroundStyle(Theme.tertiary)
                    .frame(width: 22, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 6) {
                SourceLine(story: story)
                Text(story.title)
                    .font(Theme.headline(16))
                    .foregroundStyle(Theme.text)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                if let text, !text.isEmpty {
                    Text(text).font(.system(size: 13)).foregroundStyle(Theme.secondary).lineLimit(3)
                }
                HStack(spacing: 6) {
                    Text(Format.ago(story.published)).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.tertiary)
                    StatusPill(story: story)
                }
                TickerChips(story: story)
            }
            Spacer(minLength: 0)
            StoryImage(story: story)
                .frame(width: 86, height: 86)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }
}

/// Rows on one card, with hairlines between them, like Halo's grouped metrics.
struct StoryList: View {
    let stories: [Story]
    let sequence: [String]
    /// Under the paywall preview: one veil and one lock for the whole card.
    var locked = false

    var body: some View {
        VStack(spacing: 0) {
            ForEach(stories) { s in
                NavigationLink(value: StoryRoute(id: s.id, sequence: sequence)) { StoryRow(story: s) }
                    .buttonStyle(PressStyle())
                if s.id != stories.last?.id {
                    Rectangle().fill(Theme.hairline).frame(height: 0.5).padding(.leading, 16)
                }
            }
        }
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .locked(locked)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

/// A gentle press: the card dims and shrinks a touch.
struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.75 : 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.snappy(duration: 0.18), value: configuration.isPressed)
    }
}

/// The round minus or plus on a card's corner in edit mode (from Halo).
struct CornerButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Theme.background)
                .frame(width: 26, height: 26)
                .background(symbol == "minus" ? Theme.ink : Theme.accent, in: Circle())
                .overlay(Circle().stroke(Theme.background, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// A friendly empty state.
struct EmptyCard: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 26, weight: .light)).foregroundStyle(Theme.tertiary)
            Text(title).font(Theme.headline(18)).foregroundStyle(Theme.text)
            Text(text).font(.system(size: 14)).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
        }
        .padding(.vertical, 36)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

/// The capsule switcher used for News sections and rumour states: a filled capsule slides to the
/// one you pick.
struct CapsuleSwitcher<Item: Hashable & Identifiable>: View {
    let items: [Item]
    @Binding var selection: Item
    let title: (Item) -> String
    var badge: (Item) -> Int = { _ in 0 }
    @Namespace private var ns

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(items) { item in
                    let on = item == selection
                    Button {
                        withAnimation(.snappy) { selection = item }
                    } label: {
                        HStack(spacing: 5) {
                            Text(title(item))
                            if badge(item) > 0 {
                                Text("\(badge(item))")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(on ? Theme.text : Theme.background)
                                    .padding(.horizontal, 5)
                                    .frame(minWidth: 18, minHeight: 18)
                                    .background(on ? Theme.background : Theme.accent, in: Capsule())
                            }
                        }
                        .font(.system(size: 14, weight: .semibold))
                        .padding(.horizontal, 14)
                        .frame(height: 34)
                        .foregroundStyle(on ? Theme.background : Theme.text)
                        .background {
                            if on {
                                Capsule().fill(Theme.ink).matchedGeometryEffect(id: "on", in: ns)
                            } else {
                                Capsule().fill(Theme.card)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
        }
        .scrollClipDisabled()
        .sensoryFeedback(.selection, trigger: selection)
    }
}
