import SwiftUI

/// A stock as a card rather than a row: price and today's line, a one-line take from its AI
/// summary, and the news pulse, a bar showing whether the latest stories lean up or down for it.
/// Tap to open the card in place (the full summary, what's driving it and the latest headlines);
/// Open goes to the stock's own page.
struct StockCard: View {
    @EnvironmentObject private var stocks: StocksStore
    @EnvironmentObject private var news: NewsStore
    @AppStorage(Plus.key) private var hasPlus = false
    let symbol: String
    @Binding var expanded: String?

    private var isOpen: Bool { expanded == symbol }

    var body: some View {
        let q = stocks.quote(symbol)
        let summary = stocks.summary(symbol)
        let pulse = NewsPulse(stories: news.stories(mentioning: symbol), ticker: symbol)
        VStack(alignment: .leading, spacing: 12) {
            // price line
            HStack(spacing: 12) {
                Monogram(name: q?.displayName, ticker: symbol)
                VStack(alignment: .leading, spacing: 1) {
                    Text(symbol).font(.system(size: 16, weight: .heavy)).foregroundStyle(Theme.text).lineLimit(1)
                    Text(stocks.name(symbol)).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Sparkline(points: stocks.sparkline(symbol), baseline: q?.prevClose, down: q?.isDown ?? false)
                    .frame(width: 54, height: 26)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(StockFormat.price(q?.price, q))
                        .font(Theme.number(16, weight: .bold)).foregroundStyle(Theme.text)
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .contentTransition(.numericText())
                    ChangePill(quote: q)
                }
                .frame(minWidth: 82, alignment: .trailing)
            }

            // the take: the summary's headline, or what the news says
            if let take = summary?.headline ?? pulse.leadReason {
                Text(take)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(isOpen ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if pulse.total > 0 { PulseBar(pulse: pulse) }

            if isOpen {
                VStack(alignment: .leading, spacing: 12) {
                    if let text = summary?.summary {
                        Text(text)
                            .font(.system(size: 14)).lineSpacing(2)
                            .foregroundStyle(Theme.text.opacity(0.8))
                            .fixedSize(horizontal: false, vertical: true)
                            .locked(!hasPlus)
                    }
                    if !pulse.reasons.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("What's driving it").scoutLabel()
                            ForEach(Array(pulse.reasons.prefix(3).enumerated()), id: \.offset) { _, r in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Image(systemName: Direction.arrow(r.direction))
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(r.direction == "down" ? Theme.accent : Theme.ink)
                                    Text(r.text).font(.system(size: 13)).foregroundStyle(Theme.text)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                    let heads = stocks.headlines(symbol).prefix(2)
                    if !heads.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Latest").scoutLabel()
                            ForEach(Array(heads.enumerated()), id: \.offset) { _, h in
                                Text(h.title + (h.source.map { " · \($0)" } ?? ""))
                                    .font(.system(size: 13)).foregroundStyle(Theme.text.opacity(0.8))
                                    .lineLimit(2)
                            }
                        }
                    }
                    NavigationLink(value: TickerRoute(ticker: symbol, name: stocks.name(symbol))) {
                        HStack(spacing: 6) {
                            Text("Open \(symbol)")
                            Image(systemName: "arrow.right").font(.system(size: 12, weight: .semibold))
                        }
                        .font(.system(size: 14, weight: .semibold))
                        .padding(.horizontal, 14).frame(height: 36)
                        .background(Theme.ink, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .foregroundStyle(Theme.background)
                    }
                    .buttonStyle(PressStyle())
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .onTapGesture { withAnimation(.snappy(duration: 0.35)) { expanded = isOpen ? nil : symbol } }
        .sensoryFeedback(.impact(weight: .light), trigger: isOpen)
        .animation(.snappy, value: q?.price)
    }
}

/// How the last week's stories say a stock could move: each story's expected direction,
/// weighted by how big the AI thinks the effect is (low 1, medium 2, high 3).
struct NewsPulse {
    struct Reason { let direction: String; let text: String }
    var up = 0.0, down = 0.0, mixed = 0.0
    var reasons: [Reason] = []
    var leadReason: String? { reasons.first?.text }
    var total: Double { up + down + mixed }

    init(stories: [Story], ticker: String) {
        let since = Date.now.addingTimeInterval(-7 * 86400)
        for s in stories where s.published >= since {
            guard let k = s.stocks?.first(where: { $0.ticker == ticker }) else { continue }
            let w: Double = k.impact == "high" ? 3 : k.impact == "medium" ? 2 : 1
            switch k.direction {
            case "up": up += w
            case "down": down += w
            default: mixed += w
            }
            if let r = k.reason, !r.isEmpty { reasons.append(Reason(direction: k.direction ?? "mixed", text: r)) }
        }
    }

    /// "Leaning up", "Leaning down" or "Mixed".
    var verdict: String {
        guard total > 0 else { return "Quiet" }
        if up > down * 1.5 && up >= mixed { return "News leaning up" }
        if down > up * 1.5 && down >= mixed { return "News leaning down" }
        return "Mixed news"
    }
}

/// The pulse as one split bar: up in the main colour, mixed faint, down in the accent.
struct PulseBar: View {
    let pulse: NewsPulse

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(pulse.verdict).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text)
                Spacer()
                Text("\(pulse.reasons.count) stor\(pulse.reasons.count == 1 ? "y" : "ies") this week")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.tertiary)
            }
            GeometryReader { g in
                let w = g.size.width, t = max(pulse.total, 1)
                HStack(spacing: 2) {
                    if pulse.up > 0 { Capsule().fill(Theme.ink).frame(width: max(6, w * pulse.up / t - 2)) }
                    if pulse.mixed > 0 { Capsule().fill(Theme.ink.opacity(0.2)).frame(width: max(6, w * pulse.mixed / t - 2)) }
                    if pulse.down > 0 { Capsule().fill(Theme.accent).frame(width: max(6, w * pulse.down / t - 2)) }
                }
            }
            .frame(height: 6)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(pulse.verdict), from \(pulse.reasons.count) stories this week")
    }
}
