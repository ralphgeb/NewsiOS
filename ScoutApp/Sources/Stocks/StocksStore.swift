import SwiftUI

// MARK: - stocks.json (written by the ScoutAI updater: hourly prices, AI summaries each morning)

struct Quote: Codable, Hashable {
    var symbol: String
    var name: String?
    var shortName: String?
    var exchange: String?
    var currency: String?
    var price: Double?
    var prevClose: Double?
    var open: Double?
    var high: Double?
    var low: Double?
    var volume: Double?
    var avgVolume: Double?
    var marketCap: Double?
    var pe: Double?
    var eps: Double?
    var divYield: Double?
    var wk52High: Double?
    var wk52Low: Double?
    var marketState: String?
    var time: Double?

    enum CodingKeys: String, CodingKey {
        case symbol, name, shortName, exchange, currency, price, prevClose, open, high, low, volume, avgVolume,
             marketCap, pe, eps, divYield, wk52High, wk52Low, marketState, time
    }

    init(symbol: String) { self.symbol = symbol }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        symbol = c.lenient(.symbol) ?? ""
        name = c.lenient(.name)
        shortName = c.lenient(.shortName)
        exchange = c.lenient(.exchange)
        currency = c.lenient(.currency)
        price = c.lenient(.price)
        prevClose = c.lenient(.prevClose)
        open = c.lenient(.open)
        high = c.lenient(.high)
        low = c.lenient(.low)
        volume = c.lenient(.volume)
        avgVolume = c.lenient(.avgVolume)
        marketCap = c.lenient(.marketCap)
        pe = c.lenient(.pe)
        eps = c.lenient(.eps)
        divYield = c.lenient(.divYield)
        wk52High = c.lenient(.wk52High)
        wk52Low = c.lenient(.wk52Low)
        marketState = c.lenient(.marketState)
        time = c.lenient(.time)
    }

    var change: Double? { price.flatMap { p in prevClose.map { p - $0 } } }
    var changePct: Double? {
        guard let p = price, let pc = prevClose, pc != 0 else { return nil }
        return (p - pc) / pc * 100
    }
    var isDown: Bool { (change ?? 0) < 0 }

    /// The name people know: "Apple" rather than "Apple Inc."
    var displayName: String {
        if let n = StockNames.known[symbol] { return n }
        let n = [shortName, name].compactMap { $0 }.first { !$0.isEmpty && $0 != symbol } ?? symbol
        return n.replacingOccurrences(of: #",?\s+(Inc\.?|Incorporated|Corporation|Corp\.?|plc|PLC|Ltd\.?|Limited|N\.V\.|S\.A\.|AG|SE|Holdings?)$"#,
                                      with: "", options: .regularExpression)
    }

    var updatedAt: Date? { time.map { Date(timeIntervalSince1970: $0) } }
    var isIndex: Bool { symbol.hasPrefix("^") || symbol.hasSuffix(".SS") }
}

struct Series: Codable, Hashable {
    var t: [Double]
    var c: [Double?]

    var points: [ChartPoint] {
        zip(t, c).compactMap { t, c in c.map { ChartPoint(time: Date(timeIntervalSince1970: t), value: $0) } }
    }
}

struct ChartPoint: Hashable, Identifiable {
    let time: Date
    let value: Double
    var id: Date { time }
}

struct StockHeadline: Decodable, Hashable {
    var title: String
    var source: String?
    var link: String?
    var published: Date?

    enum CodingKeys: String, CodingKey { case title, source, link, published }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = c.lenient(.title) ?? ""
        source = c.lenient(.source)
        link = c.lenient(.link)
        published = c.date(.published)
    }
}

struct StockSummary: Decodable, Hashable {
    var headline: String?
    var summary: String?
    var sentiment: String?
    var generated: Date?

    enum CodingKeys: String, CodingKey { case headline, summary, sentiment, generated }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        headline = c.lenient(.headline)
        summary = c.lenient(.summary)
        sentiment = c.lenient(.sentiment)
        generated = c.date(.generated)
    }
}

struct StocksFile: Decodable {
    var pricesUpdated: Date?
    var summariesUpdated: Date?
    var top: [String]
    var benchmarks: [String]
    var quotes: [String: Quote]
    var charts: [String: [String: Series]]
    var news: [String: [StockHeadline]]
    var summaries: [String: StockSummary]

    enum CodingKeys: String, CodingKey { case pricesUpdated, summariesUpdated, top, benchmarks, quotes, charts, news, summaries }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pricesUpdated = c.date(.pricesUpdated)
        summariesUpdated = c.date(.summariesUpdated)
        top = c.lenient(.top) ?? []
        benchmarks = c.lenient(.benchmarks) ?? []
        quotes = c.lenient(.quotes) ?? [:]
        charts = c.lenient(.charts) ?? [:]
        news = c.lenient(.news) ?? [:]
        summaries = c.lenient(.summaries) ?? [:]
    }
}

// MARK: - Yahoo Finance (live, straight from the iPhone: free, no key)

enum Yahoo {
    enum Range: String, CaseIterable, Identifiable {
        case day = "1D", week = "1W", month = "1M", half = "6M", year = "1Y", five = "5Y"
        var id: String { rawValue }

        var query: (range: String, interval: String) {
            switch self {
            case .day: return ("1d", "5m")
            case .week: return ("5d", "30m")
            case .month: return ("1mo", "1d")
            case .half: return ("6mo", "1d")
            case .year: return ("1y", "1d")
            case .five: return ("5y", "1wk")
            }
        }

        /// The matching chart in stocks.json, for when Yahoo can't be reached.
        var fileKey: String? {
            switch self {
            case .day: return "d1"
            case .month: return "m1"
            case .year: return "y1"
            default: return nil
            }
        }
    }

    struct Result {
        var quote: Quote
        var points: [ChartPoint]
        var isOpen: Bool
    }

    private struct Response: Decodable {
        struct Chart: Decodable { let result: [Item]? }
        struct Item: Decodable {
            let meta: Meta
            let timestamp: [Double]?
            let indicators: Indicators
        }
        struct Meta: Decodable {
            let symbol: String?
            let currency: String?
            let exchangeName: String?
            let fullExchangeName: String?
            let regularMarketPrice: Double?
            let regularMarketTime: Double?
            let chartPreviousClose: Double?
            let previousClose: Double?
            let regularMarketDayHigh: Double?
            let regularMarketDayLow: Double?
            let regularMarketVolume: Double?
            let fiftyTwoWeekHigh: Double?
            let fiftyTwoWeekLow: Double?
            let longName: String?
            let shortName: String?
            let currentTradingPeriod: Periods?
        }
        struct Periods: Decodable { let regular: Period? }
        struct Period: Decodable { let start: Double; let end: Double }
        struct Indicators: Decodable { let quote: [Closes]? }
        struct Closes: Decodable { let close: [Double?]? }
        let chart: Chart
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 12
        config.httpAdditionalHeaders = ["User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"]
        return URLSession(configuration: config)
    }()

    static func chart(_ symbol: String, range: Range = .day) async throws -> Result {
        let path = symbol.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: ".-="))) ?? symbol
        let q = range.query
        var hosts = ["query1", "query2"].shuffled()
        var lastError: Error = URLError(.badServerResponse)
        while let host = hosts.popLast() {
            guard let url = URL(string: "https://\(host).finance.yahoo.com/v8/finance/chart/\(path)?range=\(q.range)&interval=\(q.interval)&includePrePost=false") else { break }
            do {
                let (data, response) = try await session.data(from: url)
                if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw URLError(.badServerResponse) }
                let r = try JSONDecoder().decode(Response.self, from: data)
                guard let item = r.chart.result?.first else { throw URLError(.cannotParseResponse) }
                let m = item.meta
                var quote = Quote(symbol: m.symbol ?? symbol)
                quote.name = m.longName
                quote.shortName = m.shortName
                quote.exchange = m.fullExchangeName ?? m.exchangeName
                quote.currency = m.currency
                quote.price = m.regularMarketPrice
                quote.prevClose = range == .day ? (m.previousClose ?? m.chartPreviousClose) : m.previousClose
                quote.high = m.regularMarketDayHigh
                quote.low = m.regularMarketDayLow
                quote.volume = m.regularMarketVolume
                quote.wk52High = m.fiftyTwoWeekHigh
                quote.wk52Low = m.fiftyTwoWeekLow
                quote.time = m.regularMarketTime
                let closes = item.indicators.quote?.first?.close ?? []
                let points = zip(item.timestamp ?? [], closes).compactMap { t, c in
                    c.map { ChartPoint(time: Date(timeIntervalSince1970: t), value: $0) }
                }
                let now = Date.now.timeIntervalSince1970
                let open = m.currentTradingPeriod?.regular.map { now >= $0.start && now <= $0.end } ?? false
                quote.marketState = open ? "REGULAR" : "CLOSED"
                return Result(quote: quote, points: points, isOpen: open)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }
}

// MARK: - The symbol directory (ScoutAI's data/symbols.json: about 52,000 stocks, funds, indices…)

struct SymbolEntry: Identifiable, Hashable {
    let symbol: String
    let name: String
    let exchange: String
    let rank: Int
    let kind: String
    var id: String { symbol }

    var kindTitle: String {
        switch kind {
        case "F": return "Fund"
        case "I": return "Index"
        case "C": return "Crypto"
        case "X": return "Currency"
        default: return "Stock"
        }
    }
}

enum StockNames {
    /// Friendly names for the indices and markets shown along the top.
    static let known: [String: String] = [
        "^GSPC": "S&P 500", "^DJI": "Dow Jones", "^IXIC": "Nasdaq", "^NDX": "Nasdaq 100", "^RUT": "Russell 2000",
        "^FTSE": "FTSE 100", "^FTMC": "FTSE 250", "^GDAXI": "DAX", "^FCHI": "CAC 40", "^STOXX50E": "Euro Stoxx 50",
        "^N225": "Nikkei 225", "^HSI": "Hang Seng", "^AXJO": "ASX 200", "000001.SS": "Shanghai", "000300.SS": "CSI 300",
        "^BSESN": "Sensex", "^NSEI": "Nifty 50", "GBPUSD=X": "£ / $", "EURGBP=X": "€ / £", "BTC-USD": "Bitcoin",
        "GC=F": "Gold", "BZ=F": "Brent oil",
    ]

    /// The markets strip: the UK and US first, then currencies and commodities, then the rest.
    static let markets = ["^FTSE", "^GSPC", "^IXIC", "^DJI", "^FTMC", "GBPUSD=X", "BTC-USD", "GC=F", "BZ=F",
                          "^GDAXI", "^FCHI", "^STOXX50E", "^N225", "^HSI"]
}

// MARK: - Store

enum ChangeDisplay: String, CaseIterable {
    case percent, change, cap

    var next: ChangeDisplay {
        switch self {
        case .percent: return .change
        case .change: return .cap
        case .cap: return .percent
        }
    }
}

@MainActor
final class StocksStore: ObservableObject {
    @Published private(set) var file: StocksFile?
    @Published private(set) var live: [String: Quote] = [:]
    @Published private(set) var intraday: [String: [ChartPoint]] = [:]
    @Published private(set) var lastLive: Date?
    /// False when Yahoo couldn't be reached on the last try, so prices come from the hourly file.
    @Published private(set) var liveWorks = true
    @Published private(set) var anyMarketOpen = false
    @Published private(set) var isLoading = false
    @Published private(set) var directory: [SymbolEntry] = []
    @Published var mine: [String] { didSet { UserDefaults.standard.set(mine, forKey: Self.mineKey) } }
    @Published var display: ChangeDisplay { didSet { UserDefaults.standard.set(display.rawValue, forKey: "stocks.display") } }
    /// Names for stocks you added, from the directory, so rows read well before the first price.
    private var names: [String: String] { didSet { UserDefaults.standard.set(names, forKey: "stocks.names") } }

    private static let mineKey = "stocks.mine"
    private var openSymbols: Set<String> = []

    init() {
        mine = UserDefaults.standard.stringArray(forKey: Self.mineKey) ?? []
        display = ChangeDisplay(rawValue: UserDefaults.standard.string(forKey: "stocks.display") ?? "") ?? .percent
        names = (UserDefaults.standard.dictionary(forKey: "stocks.names") as? [String: String]) ?? [:]
        if let data = Feed.cached(Feed.stocks) { file = try? Feed.decoder.decode(StocksFile.self, from: data) }
    }

    var top: [String] { file?.top ?? [] }
    var markets: [String] { StockNames.markets }

    // MARK: Reading

    /// The freshest quote: live from Yahoo when we have it, otherwise the hourly file.
    func quote(_ symbol: String) -> Quote? {
        let base = file?.quotes[symbol]
        guard var q = live[symbol] else { return base }
        // the file knows things the live chart doesn't: market value, P/E, dividends…
        if let b = base {
            let now = q.price ?? 0, then = b.price ?? 0
            q.marketCap = b.marketCap.map { cap in then > 0 && now > 0 ? cap * now / then : cap }
            q.pe = b.pe; q.eps = b.eps; q.divYield = b.divYield; q.avgVolume = b.avgVolume
            if q.open == nil { q.open = b.open }
            if q.name == nil { q.name = b.name }
            if q.shortName == nil { q.shortName = b.shortName }
        }
        return q
    }

    func name(_ symbol: String) -> String {
        if let q = quote(symbol) { return q.displayName }
        return StockNames.known[symbol] ?? names[symbol] ?? symbol
    }

    func sparkline(_ symbol: String) -> [ChartPoint] {
        if let pts = intraday[symbol], pts.count > 1 { return pts }
        return file?.charts[symbol]?["d1"]?.points ?? []
    }

    func summary(_ symbol: String) -> StockSummary? { file?.summaries[symbol] }
    func headlines(_ symbol: String) -> [StockHeadline] { file?.news[symbol] ?? [] }
    func fileChart(_ symbol: String, _ range: Yahoo.Range) -> [ChartPoint] {
        range.fileKey.flatMap { file?.charts[symbol]?[$0]?.points } ?? []
    }

    var updatedText: String {
        if anyMarketOpen, liveWorks, lastLive != nil { return "Live · markets open" }
        if let l = lastLive, liveWorks { return "Updated \(Format.ago(l).lowercased()) · markets closed" }
        if let p = file?.pricesUpdated { return "Prices from \(Format.ago(p).lowercased())" }
        return "Loading prices…"
    }

    // MARK: Updating

    func refreshFile() async {
        guard let data = try? await Feed.fetch(Feed.stocks) else { return }
        let decoded = await Task.detached(priority: .userInitiated) { try? Feed.decoder.decode(StocksFile.self, from: data) }.value
        if let decoded { file = decoded }
    }

    /// Live prices for these symbols, a few at a time.
    func refreshLive(_ symbols: [String]) async {
        let list = Array(Set(symbols))
        guard !list.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        var results: [String: Yahoo.Result] = [:]
        await withTaskGroup(of: (String, Yahoo.Result?).self) { group in
            var index = 0
            while index < min(6, list.count) {
                let s = list[index]
                group.addTask { (s, try? await Yahoo.chart(s)) }
                index += 1
            }
            for await (s, r) in group {
                if let r { results[s] = r }
                if index < list.count {
                    let s2 = list[index]
                    group.addTask { (s2, try? await Yahoo.chart(s2)) }
                    index += 1
                }
            }
        }
        for (s, r) in results {
            live[s] = r.quote
            if r.points.count > 1 { intraday[s] = r.points }
            if r.isOpen { openSymbols.insert(s) } else { openSymbols.remove(s) }
        }
        liveWorks = !results.isEmpty
        anyMarketOpen = !openSymbols.isEmpty
        if !results.isEmpty { lastLive = .now }
    }

    /// Keeps prices live while a stocks page is on screen: every 20 seconds while a market is open,
    /// every five minutes otherwise. Cancelled when the page goes away.
    func keepLive(_ symbols: @escaping @MainActor () -> [String]) async {
        while !Task.isCancelled {
            await refreshLive(symbols())
            let wait: Double = anyMarketOpen && liveWorks ? 20 : 300
            try? await Task.sleep(for: .seconds(wait))
        }
    }

    // MARK: Your stocks

    func follows(_ symbol: String) -> Bool { mine.contains(symbol) }

    func add(_ symbol: String, name: String?) {
        let s = symbol.uppercased()
        guard !mine.contains(s) else { return }
        mine.append(s)
        if let name { names[s] = name }
        Task {
            await refreshLive([s])
            await StocksRequests.send([s])
        }
    }

    func remove(_ symbol: String) { mine.removeAll { $0 == symbol } }

    func toggle(_ symbol: String, name: String?) {
        if follows(symbol) { remove(symbol) } else { add(symbol, name: name) }
    }

    /// Once a day, tells the shared list which stocks you follow, so their AI summaries keep coming.
    func keepRequestsAlive() async {
        let key = "stocks.requested"
        let last = UserDefaults.standard.double(forKey: key)
        guard !mine.isEmpty, Date.now.timeIntervalSince1970 - last > 20 * 3600 else { return }
        if await StocksRequests.send(mine) { UserDefaults.standard.set(Date.now.timeIntervalSince1970, forKey: key) }
    }

    // MARK: Search

    func loadDirectory() async {
        guard directory.isEmpty else { return }
        let data: Data?
        if let cached = Feed.cached(Feed.symbols) {
            data = cached
            Task { _ = try? await Feed.fetch(Feed.symbols) }    // fresher copy for next time
        } else {
            data = try? await Feed.fetch(Feed.symbols)
        }
        guard let data else { return }
        directory = await Task.detached(priority: .userInitiated) { Self.parse(data) }.value
    }

    nonisolated private static func parse(_ data: Data) -> [SymbolEntry] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["s"] as? [[Any]] else { return [] }
        let exchanges = root["exchanges"] as? [String] ?? []
        return rows.compactMap { r in
            guard r.count >= 5, let s = r[0] as? String, let n = r[1] as? String else { return nil }
            let ex = (r[2] as? Int).flatMap { exchanges.indices.contains($0) ? exchanges[$0] : nil } ?? ""
            return SymbolEntry(symbol: s, name: n, exchange: ex, rank: r[3] as? Int ?? 0, kind: r[4] as? String ?? "E")
        }
    }

    /// Ticker matches first, then names, bigger companies before smaller.
    func search(_ text: String) -> [SymbolEntry] {
        let q = text.trimmingCharacters(in: .whitespaces)
        guard q.count >= 1 else { return [] }
        let up = q.uppercased(), low = q.lowercased()
        var scored: [(SymbolEntry, Int)] = []
        for e in directory {
            let score: Int
            if e.symbol == up || e.symbol.split(separator: ".").first.map(String.init) == up { score = 0 }
            else if e.symbol.hasPrefix(up) { score = 1 }
            else {
                let name = e.name.lowercased()
                if name.hasPrefix(low) { score = 2 }
                else if q.count >= 2, name.contains(" " + low) { score = 3 }
                else if q.count >= 3, name.contains(low) { score = 4 }
                else { continue }
            }
            scored.append((e, score))
        }
        return scored.sorted { ($0.1, -$0.0.rank, $0.0.symbol.count) < ($1.1, -$1.0.rank, $1.0.symbol.count) }
            .prefix(40).map(\.0)
    }
}

/// The shared list of stocks people follow (a small Cloudflare Worker). The morning update writes
/// an AI summary for each of them, so a stock you add gets one too.
enum StocksRequests {
    static var url: URL? {
        (Bundle.main.object(forInfoDictionaryKey: "ScoutStocksURL") as? String).flatMap { URL(string: $0) }
    }

    @discardableResult
    static func send(_ symbols: [String]) async -> Bool {
        guard let base = url, !symbols.isEmpty else { return false }
        var req = URLRequest(url: base.appending(path: "add"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["symbols": Array(symbols.prefix(40))])
        req.timeoutInterval = 15
        guard let result = try? await URLSession.shared.data(for: req) else { return false }
        return (result.1 as? HTTPURLResponse)?.statusCode == 200
    }
}

// MARK: - Formatting

enum StockFormat {
    static func price(_ v: Double?, _ q: Quote?) -> String {
        guard let v else { return "–" }
        let digits = abs(v) >= 1000 ? 0 : (abs(v) < 1 ? 4 : 2)
        let n = v.formatted(.number.precision(.fractionLength(abs(v) >= 1000 && q?.isIndex != true ? 2 : digits)))
        guard let q, !q.isIndex else { return n }
        switch q.currency {
        case "GBp", "GBX": return n + "p"
        case "GBP": return "£" + n
        case "USD": return "$" + n
        case "EUR": return "€" + n
        case "JPY": return "¥" + n
        default: return n
        }
    }

    static func change(_ q: Quote?, _ display: ChangeDisplay) -> String {
        guard let q else { return "–" }
        switch display {
        case .percent:
            guard let p = q.changePct else { return "–" }
            return (p >= 0 ? "+" : "−") + abs(p).formatted(.number.precision(.fractionLength(2))) + "%"
        case .change:
            guard let c = q.change else { return "–" }
            return (c >= 0 ? "+" : "−") + abs(c).formatted(.number.precision(.fractionLength(abs(c) >= 100 ? 0 : 2)))
        case .cap:
            return q.marketCap.map(big) ?? (q.changePct.map { ($0 >= 0 ? "+" : "−") + abs($0).formatted(.number.precision(.fractionLength(2))) + "%" } ?? "–")
        }
    }

    /// 5.2T, 820B, 12.3M
    static func big(_ v: Double) -> String {
        let a = abs(v)
        let (d, s): (Double, String) = a >= 1e12 ? (1e12, "T") : a >= 1e9 ? (1e9, "B") : a >= 1e6 ? (1e6, "M") : a >= 1e3 ? (1e3, "K") : (1, "")
        return (v / d).formatted(.number.precision(.fractionLength(v / d >= 100 || s.isEmpty ? 0 : 1))) + s
    }
}
