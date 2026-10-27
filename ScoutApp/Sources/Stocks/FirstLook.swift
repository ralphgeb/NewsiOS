import Foundation

/// One look at Yahoo Finance from the phone, only for a stock you've just added that Scout's lists
/// don't have yet. From then on its price comes with the 30-minute updates like every other stock.
enum FirstLook {
    struct Result {
        let quote: Quote
        let points: [ChartPoint]
    }

    private struct Response: Decodable {
        struct Chart: Decodable { let result: [Item]? }
        struct Item: Decodable {
            let meta: Meta
            let timestamp: [Double]?
            let indicators: Indicators
        }
        struct Meta: Decodable {
            let currency: String?
            let fullExchangeName: String?
            let exchangeName: String?
            let regularMarketPrice: Double?
            let regularMarketTime: Double?
            let chartPreviousClose: Double?
            let previousClose: Double?
            let regularMarketDayHigh: Double?
            let regularMarketDayLow: Double?
            let fiftyTwoWeekHigh: Double?
            let fiftyTwoWeekLow: Double?
            let longName: String?
            let shortName: String?
        }
        struct Indicators: Decodable { let quote: [Closes]? }
        struct Closes: Decodable { let close: [Double?]? }
        let chart: Chart
    }

    static func fetch(_ symbol: String) async -> Result? {
        let path = symbol.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: ".-="))) ?? symbol
        guard let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(path)?range=1d&interval=5m&includePrePost=false") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        guard let result = try? await URLSession.shared.data(for: request),
              (result.1 as? HTTPURLResponse)?.statusCode == 200,
              let r = try? JSONDecoder().decode(Response.self, from: result.0),
              let item = r.chart.result?.first, let price = item.meta.regularMarketPrice else { return nil }
        let m = item.meta
        var q = Quote(symbol: symbol)
        q.name = m.longName
        q.shortName = m.shortName
        q.exchange = m.fullExchangeName ?? m.exchangeName
        q.currency = m.currency
        q.price = price
        q.prevClose = m.previousClose ?? m.chartPreviousClose
        q.high = m.regularMarketDayHigh
        q.low = m.regularMarketDayLow
        q.wk52High = m.fiftyTwoWeekHigh
        q.wk52Low = m.fiftyTwoWeekLow
        q.time = m.regularMarketTime
        let closes = item.indicators.quote?.first?.close ?? []
        let points = zip(item.timestamp ?? [], closes).compactMap { t, c in
            c.map { ChartPoint(time: Date(timeIntervalSince1970: t), value: $0) }
        }
        return Result(quote: q, points: points)
    }
}
