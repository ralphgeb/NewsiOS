import Charts
import SwiftUI

/// Markets along the top, your stocks, then the biggest US companies. Prices update every 30 minutes
/// on weekdays; the page picks up each update while it's open.
struct StocksView: View {
    @EnvironmentObject private var stocks: StocksStore
    @Binding var showSettings: Bool
    @State private var editing = false
    @State private var showSearch = false
    @State private var allNews = false

    var body: some View {
        NavigationStack {
            ScoutPage(showSettings: $showSettings, title: "Stocks", subtitle: stocks.updatedText,
                      editing: stocks.mine.isEmpty ? nil : $editing,
                      onRefresh: { await refreshAll() }, isRefreshing: stocks.isLoading) {
                SectionHead(title: "Markets")
                MarketsStrip()
                SectionHead(title: "Your stocks", detail: stocks.mine.isEmpty ? nil : "\(stocks.mine.count)")
                if stocks.mine.isEmpty {
                    addPrompt
                } else {
                    StockList(symbols: stocks.mine, editing: editing)
                    if !editing { addButton }
                }
                if !stocks.inTheNews.isEmpty {
                    let list = stocks.inTheNews
                    SectionHead(title: "In the news", detail: "named in Scout's stories")
                    StockList(symbols: allNews ? list : Array(list.prefix(8)), editing: false)
                    if list.count > 8 {
                        Button {
                            withAnimation(.snappy) { allNews.toggle() }
                        } label: {
                            Text(allNews ? "Show fewer" : "Show all \(list.count)")
                                .font(.system(size: 14, weight: .semibold))
                                .frame(maxWidth: .infinity).frame(height: 40)
                                .background(Theme.card, in: Capsule())
                                .foregroundStyle(Theme.text)
                        }
                        .buttonStyle(PressStyle())
                    }
                }
                if !stocks.top.isEmpty {
                    SectionHead(title: "America's biggest companies", detail: "by market value")
                    StockList(symbols: stocks.top, editing: false)
                }
                Text("Prices update every 30 minutes on weekdays, 7:00 to 22:30 UK time. Tap a change to switch between %, the price change and market value. AI summaries are written each morning. Not financial advice.")
                    .font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                    .multilineTextAlignment(.center).padding(.horizontal, 20)
            }
            .storyDestinations()
            .task { await stocks.refreshFileIfStale() }
            .task { await stocks.keepFresh() }
            .task { await stocks.keepRequestsAlive() }
            .sheet(isPresented: $showSearch) { StockSearchView().environmentObject(stocks) }
            .onChange(of: stocks.mine.isEmpty) { _, empty in if empty { editing = false } }
        }
    }

    private func refreshAll() async { await stocks.refreshFile() }

    private var addPrompt: some View {
        Button { showSearch = true } label: {
            HStack(spacing: 14) {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .bold))
                    .frame(width: 40, height: 40)
                    .background(Theme.accent, in: Circle())
                    .foregroundStyle(.white)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add the companies you follow").font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.text)
                    Text("Search 50,000 stocks, funds, indices, currencies and crypto by name or ticker.")
                        .font(.system(size: 13)).foregroundStyle(Theme.secondary)
                }
                Spacer(minLength: 0)
            }
            .scoutCard(padding: 16)
        }
        .buttonStyle(PressStyle())
    }

    private var addButton: some View {
        Button { showSearch = true } label: {
            Label("Add a stock", systemImage: "plus")
                .font(.system(size: 15, weight: .semibold))
                .frame(maxWidth: .infinity).frame(height: 46)
                .background(Theme.card, in: Capsule())
                .foregroundStyle(Theme.text)
        }
        .buttonStyle(PressStyle())
    }
}

/// Indices, the pound, bitcoin, gold and oil, side by side.
struct MarketsStrip: View {
    @EnvironmentObject private var stocks: StocksStore

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(stocks.markets, id: \.self) { s in
                    NavigationLink(value: TickerRoute(ticker: s, name: StockNames.known[s])) {
                        MarketTile(symbol: s)
                    }
                    .buttonStyle(PressStyle())
                }
            }
        }
        .scrollClipDisabled()
    }
}

struct MarketTile: View {
    @EnvironmentObject private var stocks: StocksStore
    let symbol: String

    var body: some View {
        let q = stocks.quote(symbol)
        VStack(alignment: .leading, spacing: 6) {
            Text(stocks.name(symbol)).font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.secondary).lineLimit(1)
            Text(StockFormat.price(q?.price, q))
                .font(Theme.number(17, weight: .bold)).foregroundStyle(Theme.text)
                .lineLimit(1).minimumScaleFactor(0.7)
                .contentTransition(.numericText())
            HStack(spacing: 6) {
                ChangeText(quote: q, display: .percent)
                Spacer(minLength: 0)
                Sparkline(points: stocks.sparkline(symbol), baseline: q?.prevClose, down: q?.isDown ?? false)
                    .frame(width: 44, height: 18)
            }
        }
        .padding(12)
        .frame(width: 146, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .animation(.snappy, value: q?.price)
    }
}

/// Rows on one card, with hairlines between them.
struct StockList: View {
    @EnvironmentObject private var stocks: StocksStore
    let symbols: [String]
    var editing = false

    var body: some View {
        VStack(spacing: 0) {
            ForEach(symbols, id: \.self) { s in
                HStack(spacing: 0) {
                    if editing {
                        Button { withAnimation(.snappy) { stocks.remove(s) } } label: {
                            Image(systemName: "minus")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 24, height: 24)
                                .background(Theme.accent, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .padding(.leading, 14)
                        .transition(.scale.combined(with: .opacity))
                        .accessibilityLabel("Remove \(s)")
                    }
                    NavigationLink(value: TickerRoute(ticker: s, name: stocks.name(s))) { StockRow(symbol: s) }
                        .buttonStyle(PressStyle())
                        .disabled(editing)
                }
                if s != symbols.last {
                    Rectangle().fill(Theme.hairline).frame(height: 0.5).padding(.leading, 66)
                }
            }
        }
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

/// Monogram, ticker and name, today's line, price and the change.
struct StockRow: View {
    @EnvironmentObject private var stocks: StocksStore
    let symbol: String

    var body: some View {
        let q = stocks.quote(symbol)
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
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .animation(.snappy, value: q?.price)
    }
}

/// The day's change on a filled pill: ink when up, accent when down. Tap to switch what it shows.
struct ChangePill: View {
    @EnvironmentObject private var stocks: StocksStore
    let quote: Quote?

    var body: some View {
        Button {
            withAnimation(.snappy) { stocks.display = stocks.display.next }
        } label: {
            Text(StockFormat.change(quote, stocks.display))
                .font(Theme.number(12, weight: .bold))
                .lineLimit(1)
                .padding(.horizontal, 7)
                .frame(minWidth: 70, minHeight: 22)
                .background(quote?.changePct == nil ? Theme.track : (quote?.isDown == true ? Theme.accent : Theme.ink), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .foregroundStyle(quote?.changePct == nil ? Theme.secondary : (quote?.isDown == true ? Color.white : Theme.background))
                .contentTransition(.numericText())
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: stocks.display)
    }
}

struct ChangeText: View {
    let quote: Quote?
    var display: ChangeDisplay = .percent

    var body: some View {
        Text(StockFormat.change(quote, display))
            .font(Theme.number(12, weight: .bold))
            .foregroundStyle(quote?.isDown == true ? Theme.accent : Theme.text)
            .lineLimit(1)
    }
}

/// Today's line, with the previous close as a faint dotted rule.
struct Sparkline: View {
    let points: [ChartPoint]
    var baseline: Double?
    var down = false

    var body: some View {
        if points.count > 1 {
            let values = points.map(\.value) + [baseline].compactMap { $0 }
            let lo = values.min() ?? 0, hi = values.max() ?? 1
            Chart {
                if let baseline {
                    RuleMark(y: .value("Close", baseline))
                        .foregroundStyle(Theme.ink.opacity(0.25))
                        .lineStyle(StrokeStyle(lineWidth: 0.8, dash: [1.5, 2.5]))
                }
                ForEach(points) { p in
                    LineMark(x: .value("Time", p.time), y: .value("Price", p.value))
                        .foregroundStyle(down ? Theme.accent : Theme.ink)
                        .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.monotone)
                }
            }
            .chartYScale(domain: lo...(hi > lo ? hi : lo + 1))
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartLegend(.hidden)
            .accessibilityHidden(true)
        } else {
            Color.clear
        }
    }
}

/// Search the whole directory, or add a ticker it doesn't know.
struct StockSearchView: View {
    @EnvironmentObject private var stocks: StocksStore
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            let results = stocks.search(text)
            List {
                if stocks.directory.isEmpty {
                    HStack { ProgressView(); Text("Loading the list of stocks…").foregroundStyle(Theme.secondary) }
                        .listRowBackground(Theme.card)
                }
                ForEach(results) { e in
                    Button {
                        withAnimation(.snappy) { stocks.toggle(e.symbol, name: e.name) }
                    } label: {
                        HStack(spacing: 12) {
                            Monogram(name: e.name, ticker: e.symbol)
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 6) {
                                    Text(e.symbol).font(.system(size: 15, weight: .heavy)).foregroundStyle(Theme.text)
                                    Text(e.kindTitle).font(.system(size: 10, weight: .bold)).textCase(.uppercase)
                                        .padding(.horizontal, 5).padding(.vertical, 1)
                                        .background(Theme.track, in: Capsule()).foregroundStyle(Theme.secondary)
                                }
                                Text(e.name).font(.system(size: 13)).foregroundStyle(Theme.secondary).lineLimit(1)
                                if !e.exchange.isEmpty {
                                    Text(e.exchange).font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                                }
                            }
                            Spacer()
                            Image(systemName: stocks.follows(e.symbol) ? "checkmark.circle.fill" : "plus.circle")
                                .font(.system(size: 22))
                                .foregroundStyle(stocks.follows(e.symbol) ? Theme.accent : Theme.ink)
                        }
                    }
                    .listRowBackground(Theme.card)
                }
                if let raw = rawTicker, !results.contains(where: { $0.symbol == raw }) {
                    Button {
                        stocks.toggle(raw, name: nil)
                    } label: {
                        Label(stocks.follows(raw) ? "\(raw) added" : "Add \(raw) as a ticker", systemImage: stocks.follows(raw) ? "checkmark.circle.fill" : "plus.circle")
                            .foregroundStyle(Theme.text)
                    }
                    .listRowBackground(Theme.card)
                }
                Section {
                } footer: {
                    Text("Try a company or a ticker: \"Scottish Mortgage\", \"SpaceX\", \"BARC.L\". London tickers end in .L. A stock you add gets its price with the next update (within 30 minutes) and its AI summary soon after.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
            .searchable(text: $text, placement: .navigationBarDrawer(displayMode: .always), prompt: "Company or ticker")
            .autocorrectionDisabled()
            .navigationTitle("Add stocks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .tint(Theme.ink)
            .task { await stocks.loadDirectory() }
            .sensoryFeedback(.success, trigger: stocks.mine.count)
        }
    }

    /// What you typed, if it looks like a ticker.
    private var rawTicker: String? {
        let t = text.trimmingCharacters(in: .whitespaces).uppercased()
        guard t.count >= 1, t.count <= 15, t.range(of: #"^[A-Z0-9^][A-Z0-9.\-=^]*$"#, options: .regularExpression) != nil else { return nil }
        return t
    }
}
