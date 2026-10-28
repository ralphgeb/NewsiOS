import SwiftUI

// MARK: - stocks.json (written by the ScoutAI updater: prices every 30 minutes, AI summaries each morning)

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

    init(title: String, source: String?, link: String?, published: Date?) {
        self.title = title
        self.source = source
        self.link = link
        self.published = published
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
    /// Stocks the last three days' stories name, most-mentioned first.
    var mentioned: [String]

    enum CodingKeys: String, CodingKey { case pricesUpdated, summariesUpdated, top, benchmarks, quotes, charts, news, summaries, mentioned }

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
        mentioned = c.lenient(.mentioned) ?? []
    }
}

/// prices.json: prices for about 3,500 stocks every 30 minutes, and yesterday's risers and fallers.
struct PriceList: Decodable {
    struct Mover: Decodable, Identifiable, Hashable {
        let symbol: String
        let name: String
        let pct: Double
        let price: Double
        var id: String { symbol }

        // each one is a short list: [symbol, name, % change, price]
        init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            symbol = try c.decode(String.self)
            name = try c.decode(String.self)
            pct = try c.decode(Double.self)
            price = try c.decode(Double.self)
        }
    }

    struct Movers: Decodable {
        var day: String?
        var up: [Mover]
        var down: [Mover]

        enum CodingKeys: String, CodingKey { case day, up, down }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            day = c.lenient(.day)
            up = c.lenientArray(.up) ?? []
            down = c.lenientArray(.down) ?? []
        }
    }

    var updated: Date?
    /// symbol → [price, previous close, unix time]
    var q: [String: [Double?]]
    var movers: Movers?

    enum CodingKeys: String, CodingKey { case updated, q, movers }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        updated = c.date(.updated)
        q = c.lenient(.q) ?? [:]
        movers = c.lenient(.movers)
    }

    func quote(_ symbol: String) -> Quote? {
        guard let row = q[symbol], let price = row.first ?? nil else { return nil }
        var quote = Quote(symbol: symbol)
        quote.price = price
        quote.prevClose = row.count > 1 ? row[1] : nil
        quote.time = row.count > 2 ? row[2] : nil
        return quote
    }

    /// "Mon 26 Oct", the day the movers are from.
    var moversDay: String? {
        guard let d = movers?.day else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: d)?.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }
}

// MARK: - Chart ranges (the charts in stocks.json)

enum ChartRange: String, CaseIterable, Identifiable {
    case day = "1D", month = "1M", year = "1Y"
    var id: String { rawValue }

    var fileKey: String {
        switch self {
        case .day: return "d1"
        case .month: return "m1"
        case .year: return "y1"
        }
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
    @Published private(set) var prices: PriceList?
    /// A first price fetched on the phone for a stock you've just added that no list has yet.
    @Published private(set) var firstLook: [String: Quote] = [:]
    @Published private(set) var firstLookChart: [String: [ChartPoint]] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var directory: [SymbolEntry] = []
    @Published var mine: [String] { didSet { UserDefaults.standard.set(mine, forKey: Self.mineKey) } }
    @Published var display: ChangeDisplay { didSet { UserDefaults.standard.set(display.rawValue, forKey: "stocks.display") } }
    /// Names for stocks you added, from the directory, so rows read well before the first price.
    private var names: [String: String] { didSet { UserDefaults.standard.set(names, forKey: "stocks.names") } }

    private static let mineKey = "stocks.mine"

    init() {
        mine = UserDefaults.standard.stringArray(forKey: Self.mineKey) ?? []
        display = ChangeDisplay(rawValue: UserDefaults.standard.string(forKey: "stocks.display") ?? "") ?? .percent
        names = (UserDefaults.standard.dictionary(forKey: "stocks.names") as? [String: String]) ?? [:]
        if let data = Feed.cached(Feed.stocks) { file = try? Feed.decoder.decode(StocksFile.self, from: data) }
        if let data = Feed.cached(Feed.prices) { prices = try? Feed.decoder.decode(PriceList.self, from: data) }
    }

    var top: [String] { file?.top ?? [] }
    var markets: [String] { StockNames.markets }

    // MARK: Reading

    /// Prices come from the ScoutAI updater, every 30 minutes on weekdays; the app never asks a
    /// price service itself.
    /// The detailed list first, then the wide one, then a first look fetched on the phone.
    func quote(_ symbol: String) -> Quote? {
        file?.quotes[symbol] ?? prices?.quote(symbol) ?? firstLook[symbol]
    }

    func name(_ symbol: String) -> String {
        if let q = file?.quotes[symbol] { return q.displayName }
        if let n = StockNames.known[symbol] ?? names[symbol] { return n }
        if let m = ((prices?.movers?.up ?? []) + (prices?.movers?.down ?? [])).first(where: { $0.symbol == symbol }) { return m.name }
        return firstLook[symbol]?.displayName ?? symbol
    }

    func sparkline(_ symbol: String) -> [ChartPoint] {
        let pts = fileChart(symbol, .day)
        return pts.isEmpty ? (firstLookChart[symbol] ?? []) : pts
    }

    /// Stocks named in the latest stories.
    var inTheNews: [String] { file?.mentioned ?? [] }
    /// Whether the detailed list has it (charts, numbers, AI summary), not just a price.
    func isDetailed(_ symbol: String) -> Bool { file?.quotes[symbol] != nil }

    func summary(_ symbol: String) -> StockSummary? { file?.summaries[symbol] }
    func headlines(_ symbol: String) -> [StockHeadline] { file?.news[symbol] ?? [] }
    func fileChart(_ symbol: String, _ range: ChartRange) -> [ChartPoint] {
        file?.charts[symbol]?[range.fileKey]?.points ?? []
    }

    /// "Prices every 30 minutes · last at 14:42", or the day for older ones.
    var updatedText: String {
        guard let p = file?.pricesUpdated else { return "Prices every 30 minutes" }
        let when = Calendar.current.isDateInToday(p) ? Format.time(p)
            : p.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        return "Prices every 30 minutes · last at \(when)"
    }

    // MARK: Updating

    private var lastFileFetch: Date?

    /// Fetches stocks.json again when the copy we have is more than a few minutes old.
    func refreshFileIfStale() async {
        if let last = lastFileFetch, Date.now.timeIntervalSince(last) < 3 * 60 { return }
        await refreshFile()
    }

    func refreshFile() async {
        lastFileFetch = .now
        isLoading = true
        defer { isLoading = false }
        async let detailed = Feed.fetchStocks()
        async let wide = Feed.fetchFromService(Feed.prices)
        let (d, w) = await (detailed, wide)
        let decoded = await Task.detached(priority: .userInitiated) { () -> (StocksFile?, PriceList?) in
            (d.flatMap { try? Feed.decoder.decode(StocksFile.self, from: $0) }, w.flatMap { try? Feed.decoder.decode(PriceList.self, from: $0) })
        }.value
        if let f = decoded.0 { file = f }
        if let p = decoded.1 { prices = p }
        // a first look is only needed until a list has the stock
        for s in firstLook.keys where file?.quotes[s] != nil || prices?.q[s] != nil {
            firstLook[s] = nil
            firstLookChart[s] = nil
        }
    }

    /// For a stock you've just added that neither list has yet: one look at Yahoo from the phone, so
    /// it isn't blank until the next 30-minute update takes over.
    func fetchFirstLook(_ symbol: String) async {
        guard quote(symbol) == nil, let r = await FirstLook.fetch(symbol) else { return }
        firstLook[symbol] = r.quote
        firstLookChart[symbol] = r.points
    }

    /// While a stocks page is open, looks for the next 30-minute update every five minutes.
    func keepFresh() async {
        while !Task.isCancelled {
            await refreshFileIfStale()
            try? await Task.sleep(for: .seconds(5 * 60))
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
            await fetchFirstLook(s)
            await StocksRequests.send([s])
            // its price comes with the next 30-minute update, and its summary within minutes when quick
            // summaries are on: look for both every five minutes for up to 40 minutes
            for _ in 0..<8 {
                try? await Task.sleep(for: .seconds(5 * 60))
                await refreshFile()
                if quote(s)?.price != nil, summary(s) != nil { break }
            }
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
            .prefix(40).map { $0.0 }
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
