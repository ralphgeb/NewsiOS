import Charts
import SwiftUI

/// One company, index or market: the price (updated every 30 minutes), a chart you can drag across,
/// key numbers, the AI's take, headlines and every Scout story that names it.
struct StockDetailView: View {
    @EnvironmentObject private var stocks: StocksStore
    @EnvironmentObject private var store: NewsStore
    let route: TickerRoute
    @State private var range: ChartRange = .day
    @State private var points: [ChartPoint] = []
    @State private var selected: Date?
    @State private var reading: WebLink?
    /// Apple Intelligence's quick summary, until Scout's own arrives.
    @State private var localSummary: OnDeviceSummary.Result?
    @State private var writing = false
    @AppStorage("links.reader") private var reader = false

    private var symbol: String { route.ticker }

    var body: some View {
        let q = stocks.quote(symbol)
        let stories = store.stories(mentioning: symbol)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(q)
                chartCard(q)
                stats(q)
                aiCard
                headlines
                if !stories.isEmpty {
                    SectionHead(title: "In Scout", detail: "\(stories.count) stor\(stories.count == 1 ? "y" : "ies")")
                    StoryList(stories: Array(stories.prefix(12)), sequence: stories.map(\.id))
                }
                Text("Prices update every 30 minutes on weekdays. The summary is written by AI and can be wrong. Not financial advice.")
                    .font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                    .multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.horizontal, 20)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .scrollIndicators(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(symbol)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    withAnimation(.snappy) { stocks.toggle(symbol, name: route.name ?? q?.displayName) }
                } label: {
                    Label(stocks.follows(symbol) ? "Following" : "Follow",
                          systemImage: stocks.follows(symbol) ? "star.fill" : "star")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 13, weight: .semibold))
                }
                .sensoryFeedback(.success, trigger: stocks.follows(symbol))
            }
        }
        .tint(Theme.ink)
        .task { await prepareSummary() }
        // the chart follows the range and each new 30-minute update
        .onAppear { points = stocks.fileChart(symbol, range) }
        .onChange(of: range) { _, r in withAnimation(.snappy) { points = stocks.fileChart(symbol, r) } }
        .onChange(of: stocks.file?.pricesUpdated) { _, _ in points = stocks.fileChart(symbol, range) }
        .sheet(item: $reading) { SafariView(url: $0.url, reader: reader).ignoresSafeArea() }
    }

    private var isCompany: Bool { !(stocks.quote(symbol)?.isIndex ?? false) && StockNames.known[symbol] == nil }

    /// Fresh headlines and, if Scout has no summary yet, a quick one from Apple Intelligence.
    private func prepareSummary() async {
        await stocks.refreshFileIfStale()
        guard isCompany, stocks.summary(symbol) == nil, localSummary == nil, OnDeviceSummary.isAvailable else { return }
        writing = true
        defer { writing = false }
        let month = stocks.fileChart(symbol, .month)
        let monthChange = month.first.flatMap { first in stocks.quote(symbol)?.price.map { ($0 - first.value) / first.value * 100 } }
        let q = stocks.quote(symbol)
        let result = await OnDeviceSummary.write(
            name: q?.displayName ?? route.name ?? symbol, symbol: symbol, quote: q, monthChange: monthChange,
            headlines: stocks.headlines(symbol),
            stories: store.stories(mentioning: symbol))
        withAnimation(.snappy) { localSummary = result }
    }

    // MARK: Header

    private func header(_ q: Quote?) -> some View {
        let shown = selectedPoint
        let first = points.first?.value
        let base = range == .day ? (q?.prevClose ?? first) : first
        let value = shown?.value ?? q?.price
        let delta = value.flatMap { v in base.map { v - $0 } }
        let pct = delta.flatMap { d in base.flatMap { $0 != 0 ? d / $0 * 100 : nil } }
        let down = (delta ?? 0) < 0
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Monogram(name: q?.displayName ?? route.name, ticker: symbol)
                VStack(alignment: .leading, spacing: 1) {
                    Text(q?.displayName ?? route.name ?? symbol)
                        .font(.system(size: 22, weight: .heavy)).tracking(-0.3)
                        .foregroundStyle(Theme.ink).lineLimit(2)
                    Text([symbol, q?.exchange, q?.currency].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
                }
            }
            Text(StockFormat.price(value, q))
                .font(Theme.number(46, weight: .heavy))
                .tracking(-1)
                .foregroundStyle(Theme.ink)
                .contentTransition(.numericText())
                .padding(.top, 6)
            HStack(spacing: 8) {
                if let delta, let pct {
                    Text("\(delta >= 0 ? "+" : "−")\(abs(delta).formatted(.number.precision(.fractionLength(2)))) (\(abs(pct).formatted(.number.precision(.fractionLength(2))))%)")
                        .font(Theme.number(15, weight: .bold))
                        .foregroundStyle(down ? Theme.accent : Theme.ink)
                }
                Text(shown.map { label(for: $0.time) } ?? rangeLabel(q))
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.secondary)
            }
        }
        .animation(.snappy, value: value)
    }

    private func rangeLabel(_ q: Quote?) -> String {
        switch range {
        case .day:
            guard let t = q?.updatedAt else { return "Today" }
            let when = Calendar.current.isDateInToday(t) ? Format.time(t) : t.formatted(.dateTime.weekday(.abbreviated).hour().minute())
            return q?.marketState == "REGULAR" ? "Today · at \(when)" : "At close · \(when)"
        case .month: return "Past month"
        case .year: return "Past year"
        }
    }

    private func label(for date: Date) -> String {
        switch range {
        case .day: return date.formatted(date: .omitted, time: .shortened)
        default: return date.formatted(.dateTime.day().month(.abbreviated).year())
        }
    }

    private var selectedPoint: ChartPoint? {
        guard let selected, !points.isEmpty else { return nil }
        return points.min { abs($0.time.timeIntervalSince(selected)) < abs($1.time.timeIntervalSince(selected)) }
    }

    // MARK: Chart

    private func chartCard(_ q: Quote?) -> some View {
        let base = range == .day ? q?.prevClose : points.first?.value
        let down = (points.last?.value ?? 0) < (base ?? points.first?.value ?? 0)
        let color = down ? Theme.accent : Theme.ink
        let values = points.map(\.value) + (range == .day ? [base].compactMap { $0 } : [])
        let lo = values.min() ?? 0, hi = values.max() ?? 1
        let pad = max((hi - lo) * 0.08, hi * 0.0005)
        return VStack(spacing: 14) {
            ZStack {
                if points.count > 1 {
                    Chart {
                        if let base, range == .day {
                            RuleMark(y: .value("Previous close", base))
                                .foregroundStyle(Theme.ink.opacity(0.3))
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                        }
                        ForEach(points) { p in
                            AreaMark(x: .value("Time", p.time), yStart: .value("Low", lo - pad), yEnd: .value("Price", p.value))
                                .foregroundStyle(LinearGradient(colors: [color.opacity(0.22), color.opacity(0)], startPoint: .top, endPoint: .bottom))
                                .interpolationMethod(.monotone)
                            LineMark(x: .value("Time", p.time), y: .value("Price", p.value))
                                .foregroundStyle(color)
                                .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                                .interpolationMethod(.monotone)
                        }
                        if let s = selectedPoint {
                            RuleMark(x: .value("Selected", s.time)).foregroundStyle(Theme.ink.opacity(0.35))
                            PointMark(x: .value("Selected", s.time), y: .value("Price", s.value))
                                .foregroundStyle(Theme.accent).symbolSize(70)
                        } else if let last = points.last {
                            PointMark(x: .value("Now", last.time), y: .value("Price", last.value))
                                .foregroundStyle(Theme.accent).symbolSize(45)
                        }
                    }
                    .chartYScale(domain: (lo - pad)...(hi + pad))
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                            AxisValueLabel().font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.tertiary)
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { _ in
                            AxisGridLine().foregroundStyle(Theme.hairline)
                            AxisValueLabel().font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.tertiary)
                        }
                    }
                    .chartXSelection(value: $selected)
                    .sensoryFeedback(.selection, trigger: selectedPoint?.time)
                } else {
                    Text(stocks.quote(symbol) == nil ? "The chart arrives with the next update, within 30 minutes." : "No chart for this range yet.")
                        .font(.system(size: 13)).foregroundStyle(Theme.tertiary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(height: 220)

            HStack(spacing: 4) {
                ForEach(ChartRange.allCases) { r in
                    Button {
                        withAnimation(.snappy) { range = r; selected = nil }
                    } label: {
                        Text(r.rawValue)
                            .font(.system(size: 13, weight: .bold))
                            .frame(maxWidth: .infinity).frame(height: 30)
                            .background(range == r ? Theme.ink : Color.clear, in: Capsule())
                            .foregroundStyle(range == r ? Theme.background : Theme.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(Theme.track, in: Capsule())
            .sensoryFeedback(.selection, trigger: range)
        }
        .scoutCard(padding: 16)
    }

    // MARK: Numbers

    private func stats(_ q: Quote?) -> some View {
        let rows: [(String, String?)] = [
            ("Open", q?.open.map { StockFormat.price($0, q) }),
            ("Prev close", q?.prevClose.map { StockFormat.price($0, q) }),
            ("Day high", q?.high.map { StockFormat.price($0, q) }),
            ("Day low", q?.low.map { StockFormat.price($0, q) }),
            ("52w high", q?.wk52High.map { StockFormat.price($0, q) }),
            ("52w low", q?.wk52Low.map { StockFormat.price($0, q) }),
            ("Volume", q?.volume.flatMap { $0 > 0 ? StockFormat.big($0) : nil }),
            ("Avg volume", q?.avgVolume.map(StockFormat.big)),
            ("Market value", q?.marketCap.map(StockFormat.big)),
            ("P/E", q?.pe.map { $0.formatted(.number.precision(.fractionLength(1))) }),
            ("EPS", q?.eps.map { $0.formatted(.number.precision(.fractionLength(2))) }),
            ("Dividend", q?.divYield.map { $0.formatted(.number.precision(.fractionLength(2))) + "%" }),
        ]
        let shown = rows.compactMap { r in r.1.map { (r.0, $0) } }
        return Group {
            if !shown.isEmpty {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 18), GridItem(.flexible(), spacing: 18)], alignment: .leading, spacing: 12) {
                    ForEach(shown.indices, id: \.self) { i in
                        HStack {
                            Text(shown[i].0).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.secondary)
                            Spacer(minLength: 4)
                            Text(shown[i].1).font(Theme.number(14, weight: .bold)).foregroundStyle(Theme.ink).lineLimit(1)
                        }
                    }
                }
                .scoutCard(padding: 16)
            }
        }
    }

    // MARK: AI and headlines

    @ViewBuilder
    private var aiCard: some View {
        if let s = stocks.summary(symbol), let text = s.summary {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Circle().fill(Theme.accent).frame(width: 7, height: 7)
                    Text("What's happening").scoutLabel()
                    Spacer()
                    if let sentiment = s.sentiment {
                        Text(sentiment.capitalized)
                            .font(.system(size: 11, weight: .bold))
                            .padding(.horizontal, 8).frame(height: 20)
                            .background(sentiment == "negative" ? Theme.accent.opacity(0.15) : Theme.track, in: Capsule())
                            .foregroundStyle(sentiment == "negative" ? Theme.accent : Theme.ink)
                    }
                }
                if let h = s.headline {
                    Text(h).font(Theme.headline(20, weight: .heavy)).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
                }
                Text(text).font(.system(size: 15)).foregroundStyle(Theme.ink.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
                if let g = s.generated {
                    Text("Scout AI · \(Format.ago(g).lowercased())").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.tertiary)
                }
            }
            .scoutCard()
        } else if let l = localSummary {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "apple.intelligence").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
                    Text("What's happening").scoutLabel()
                }
                if let h = l.headline {
                    Text(h).font(Theme.headline(20, weight: .heavy)).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
                }
                Text(l.text).font(.system(size: 15)).foregroundStyle(Theme.ink.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
                Text("Written on this iPhone by Apple Intelligence. Scout's own summary replaces it once it's ready.")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.tertiary)
            }
            .scoutCard()
            .transition(.opacity)
        } else if writing {
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text("Writing a quick summary on this iPhone…").font(.system(size: 14)).foregroundStyle(Theme.secondary)
            }
            .scoutCard(padding: 16)
        } else if isCompany {
            HStack(spacing: 12) {
                Image(systemName: "sparkles").foregroundStyle(Theme.accent)
                Text(stocks.follows(symbol)
                     ? "Scout's AI is writing a summary of \(symbol). It usually arrives within minutes."
                     : "Follow \(symbol) and Scout's AI will write a summary of it.")
                    .font(.system(size: 14)).foregroundStyle(Theme.secondary)
            }
            .scoutCard(padding: 16)
        }
    }

    @ViewBuilder
    private var headlines: some View {
        let list = stocks.headlines(symbol)
        if !list.isEmpty {
            SectionHead(title: "Headlines", detail: "\(list.count)")
            VStack(spacing: 0) {
                ForEach(Array(list.enumerated()), id: \.offset) { i, h in
                    Button {
                        if let u = Story.web(h.link) { reading = WebLink(url: u) }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(h.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
                                .multilineTextAlignment(.leading)
                            Text([h.source, Format.ago(h.published)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressStyle())
                    if i < list.count - 1 {
                        Rectangle().fill(Theme.hairline).frame(height: 0.5).padding(.leading, 16)
                    }
                }
            }
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
    }
}
