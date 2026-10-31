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
    /// Which pulse design to show (three to compare for now).
    var style = 0

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

            if pulse.total > 0 { PulseView(pulse: pulse, style: style) }

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
                    // a quiet row, like the app's other links, rather than a big button
                    NavigationLink(value: TickerRoute(ticker: symbol, name: stocks.name(symbol))) {
                        HStack {
                            Text("Charts and key numbers").font(.system(size: 14, weight: .semibold))
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(Theme.text)
                        .padding(.horizontal, 14).frame(height: 42)
                        .background(Theme.track, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(PressStyle())
                }
                // fades in where it sits, inside the card
                .transition(.opacity)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        // the card moves and grows as one piece, and nothing shows outside it while it does
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .geometryGroup()
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

extension NewsPulse {
    /// -1 (all negative) to 1 (all positive); mixed stories pull towards the middle.
    var score: Double { total > 0 ? (up - down) / total : 0 }
}

/// The news pulse, in one of three designs to compare:
/// 0, a meter of thin bars from a neutral dot in the middle (right for positive, left for negative);
/// 1, a needle on a track that runs from negative to positive;
/// 2, positive and negative stories counted side by side.
struct PulseView: View {
    let pulse: NewsPulse
    var style = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(pulse.verdict).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text)
                Spacer()
                Text("\(pulse.reasons.count) stor\(pulse.reasons.count == 1 ? "y" : "ies") this week")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.tertiary)
            }
            switch style % 3 {
            case 0: meter
            case 1: needle
            default: counts
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(pulse.verdict), from \(pulse.reasons.count) stories this week")
    }

    private var ends: some View {
        HStack {
            Text("Negative"); Spacer(); Text("Positive")
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(Theme.tertiary)
    }

    // thin bars either side of a dot; they light up outward from the middle
    private var meter: some View {
        let half = 12
        let lit = Int((abs(pulse.score) * Double(half)).rounded())
        return VStack(spacing: 4) {
            HStack(spacing: 3) {
                ForEach(0..<half, id: \.self) { i in
                    let on = pulse.score < 0 && i >= half - lit
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(on ? Theme.accent : Theme.track)
                        .frame(maxWidth: .infinity).frame(height: 8 + CGFloat(half - i) * 0.6)
                }
                Circle().fill(Theme.ink).frame(width: 8, height: 8).padding(.horizontal, 3)
                ForEach(0..<half, id: \.self) { i in
                    let on = pulse.score > 0 && i < lit
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(on ? Theme.ink : Theme.track)
                        .frame(maxWidth: .infinity).frame(height: 8 + CGFloat(i) * 0.6)
                }
            }
            .frame(height: 16)
            ends
        }
    }

    // a track from negative to positive with a needle where the news sits
    private var needle: some View {
        VStack(spacing: 4) {
            GeometryReader { g in
                let x = g.size.width * (pulse.score + 1) / 2
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(LinearGradient(colors: [Theme.accent.opacity(0.7), Theme.track, Theme.ink.opacity(0.7)],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(height: 6)
                    Rectangle().fill(Theme.ink.opacity(0.25)).frame(width: 1, height: 12).offset(x: g.size.width / 2)
                    Circle()
                        .fill(Theme.card)
                        .overlay(Circle().stroke(pulse.score < 0 ? Theme.accent : Theme.ink, lineWidth: 3))
                        .frame(width: 14, height: 14)
                        .offset(x: min(max(0, x - 7), g.size.width - 14))
                }
                .frame(height: 14)
            }
            .frame(height: 14)
            ends
        }
    }

    // positive and negative stories as two counted rows of blocks
    private var counts: some View {
        let pos = Int(pulse.up.rounded()), neg = Int(pulse.down.rounded())
        return HStack(spacing: 14) {
            row(neg, Theme.accent, "Negative")
            row(pos, Theme.ink, "Positive")
        }
    }

    private func row(_ n: Int, _ colour: Color, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 2) {
                ForEach(0..<10, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1.5).fill(i < min(n, 10) ? colour : Theme.track).frame(height: 10)
                }
            }
            Text("\(label) · \(n)").font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.tertiary)
        }
        .frame(maxWidth: .infinity)
    }
}
