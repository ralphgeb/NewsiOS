import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// A quick summary written on the iPhone by Apple Intelligence (iOS 26 and later), shown straight
/// away for a stock that doesn't have Scout's server summary yet. Free and private: nothing leaves
/// the phone. On iPhones without Apple Intelligence it simply isn't offered.
enum OnDeviceSummary {
    struct Result: Hashable {
        let headline: String?
        let text: String
        let written: Date
    }

    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26, *) { return SystemLanguageModel.default.isAvailable }
        #endif
        return false
    }

    private static let instructions = """
    You write short, neutral company updates for the stocks screen of a news app. Use only the \
    information given; never invent news, numbers or reasons. British English. This is not \
    financial advice, so never recommend buying or selling. Reply with a headline of at most 70 \
    characters on the first line, then a blank line, then two to four sentences on what is going on \
    with the company and its shares right now. If there are no stories or headlines, say there is no \
    major news and describe the price move.
    """

    /// Writes a summary from the price move, the latest headlines and the Scout stories that name it.
    static func write(name: String, symbol: String, quote: Quote?, monthChange: Double?,
                      headlines: [StockHeadline], stories: [Story]) async -> Result? {
        #if canImport(FoundationModels)
        guard #available(iOS 26, *), SystemLanguageModel.default.isAvailable else { return nil }
        var lines: [String] = ["Company: \(name) (\(symbol))"]
        if let q = quote, let p = q.price {
            var line = "Price: \(p.formatted(.number.precision(.fractionLength(2)))) \(q.currency ?? "")"
            if let pct = q.changePct { line += "; today \(pct.formatted(.number.precision(.fractionLength(2))))%" }
            if let m = monthChange { line += "; past month \(m.formatted(.number.precision(.fractionLength(1))))%" }
            if let lo = q.wk52Low, let hi = q.wk52High { line += "; 52-week range \(lo.formatted())–\(hi.formatted())" }
            lines.append(line)
        }
        let recent = stories.prefix(5).map { "- \($0.title) (\($0.outletName)): \($0.summary ?? "")" }
        let heads = headlines.prefix(6).map { h -> String in
            if let source = h.source, !source.isEmpty { return "- \(h.title) (\(source))" }
            return "- \(h.title)"
        }
        lines.append(recent.isEmpty && heads.isEmpty ? "- (no recent stories or headlines)" : (recent + heads).joined(separator: "\n"))
        do {
            let session = LanguageModelSession(instructions: instructions)
            let reply = try await session.respond(to: lines.joined(separator: "\n"))
            return parse(reply.content)
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }

    /// The first line is the headline, the rest the summary.
    private static func parse(_ text: String) -> Result? {
        let cleaned = text.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        let parts = cleaned.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard parts.count > 1 else { return Result(headline: nil, text: cleaned, written: .now) }
        let head = parts[0].trimmingCharacters(in: CharacterSet(charactersIn: "#: "))
        return Result(headline: head.count <= 90 ? head : nil, text: parts.dropFirst().joined(separator: " "), written: .now)
    }
}
