import CoreLocation
import SwiftUI

/// The city whose metro Today shows. Automatic picks from where the iPhone last was, or its time zone.
enum TransitCity: String, CaseIterable, Identifiable {
    case automatic, london, nyc, paris

    var id: String { rawValue }
    static let key = "transit.city"

    var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .london: return "London"
        case .nyc: return "New York"
        case .paris: return "Paris"
        }
    }

    /// What locals call it, for the card's title.
    var network: String {
        switch self {
        case .nyc: return "Subway"
        case .paris: return "Métro"
        default: return "Tube"
        }
    }

    var source: String {
        switch self {
        case .nyc: return "MTA"
        case .paris: return "Île-de-France Mobilités"
        default: return "TfL"
        }
    }

    static var chosen: TransitCity {
        let pick = TransitCity(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .automatic
        return pick == .automatic ? guess() : pick
    }

    /// The nearest of the three if the iPhone was within about 100 km of it, otherwise its time zone.
    /// Uses the last location iOS already has, so it never asks for permission itself.
    private static func guess() -> TransitCity {
        let centres: [(TransitCity, CLLocation)] = [
            (.london, CLLocation(latitude: 51.5072, longitude: -0.1276)),
            (.nyc, CLLocation(latitude: 40.7128, longitude: -74.0060)),
            (.paris, CLLocation(latitude: 48.8566, longitude: 2.3522)),
        ]
        if let here = CLLocationManager().location,
           let near = centres.min(by: { here.distance(from: $0.1) < here.distance(from: $1.1) }),
           here.distance(from: near.1) < 100_000 {
            return near.0
        }
        switch TimeZone.current.identifier {
        case "America/New_York": return .nyc
        case "Europe/Paris": return .paris
        default: return .london
        }
    }
}

/// Live metro status: London's Tube and Elizabeth line from TfL's free, official feed; New York's
/// subway and Paris's métro and RER through the Scout service, which asks the MTA and
/// Île-de-France Mobilités once every two minutes for everyone.
@MainActor
final class TubeService: ObservableObject {
    struct Line: Identifiable {
        let id: String
        let name: String
        /// 0 good, 1 minor, 2 severe
        let level: Int
        let status: String
        let reason: String
        let colour: Color
        /// New York's and Paris's lines go by a letter or number, shown in a round badge.
        var badge: String? = nil
        var badgeText: Color = .white
        /// Position in the network's own order (1, 2, 3… A, C, E…), for the colour strip.
        var order = 0
    }

    @Published private(set) var lines: [Line] = []
    @Published private(set) var fetched: Date?
    @Published private(set) var failed = false
    @Published private(set) var isLoading = false
    @Published private(set) var city: TransitCity = TransitCity.chosen

    private struct LineJSON: Decodable {
        struct Status: Decodable {
            let statusSeverity: Int
            let statusSeverityDescription: String
            let reason: String?
        }
        let id: String
        let name: String
        let lineStatuses: [Status]
    }

    private struct ServiceJSON: Decodable {
        struct Line: Decodable {
            let id: String
            let name: String
            let short: String?
            let colour: String?
            let text: String?
            let level: Int
            let status: String
            let reason: String?
        }
        let lines: [Line]
    }

    func refresh(force: Bool = false) async {
        let want = TransitCity.chosen
        let moved = want != city
        if !force, !moved, let f = fetched, Date.now.timeIntervalSince(f) < 2 * 60 { return }
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        if moved {
            city = want
            lines = []
            fetched = nil
        }
        do {
            let found = want == .london ? try await Self.london() : try await Self.service(want)
            guard want == city else { return }
            var ordered = want == .london ? found.sorted { $0.name < $1.name } : found
            for i in ordered.indices { ordered[i].order = i }
            lines = ordered.sorted { ($0.level, $1.name) > ($1.level, $0.name) }
            fetched = .now
            failed = false
        } catch {
            failed = lines.isEmpty
        }
    }

    private static func london() async throws -> [Line] {
        let url = URL(string: "https://api.tfl.gov.uk/Line/Mode/tube,elizabeth-line/Status")!
        let (data, _) = try await URLSession.shared.data(from: url)
        let raw = try JSONDecoder().decode([LineJSON].self, from: data)
        return raw.map { l in
            let statuses = l.lineStatuses.map { (level: Self.level($0.statusSeverity), text: $0.statusSeverityDescription, reason: $0.reason ?? "") }
            let worst = statuses.map { $0.level }.max() ?? 0
            var texts: [String] = []
            for s in statuses where s.level == worst && !texts.contains(s.text) { texts.append(s.text) }
            var reasons: [String] = []
            for s in statuses where !s.reason.isEmpty && !reasons.contains(s.reason) { reasons.append(Self.tidy(s.reason, l.name)) }
            return Line(id: l.id, name: l.name, level: worst, status: texts.joined(separator: " · "),
                        reason: reasons.joined(separator: "\n\n"), colour: colours[l.id] ?? Theme.ink)
        }
    }

    private static func service(_ city: TransitCity) async throws -> [Line] {
        guard let s = Bundle.main.object(forInfoDictionaryKey: "ScoutStocksURL") as? String,
              let base = URL(string: s) else { throw URLError(.badURL) }
        var request = URLRequest(url: base.appending(path: "transit/\(city.rawValue)"))
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(ServiceJSON.self, from: data).lines.map { l in
            Line(id: l.id, name: l.name, level: l.level, status: l.status, reason: l.reason ?? "",
                 colour: Color(hexString: l.colour) ?? Theme.ink, badge: l.short,
                 badgeText: Color(hexString: l.text) ?? .white)
        }
    }

    private static func level(_ severity: Int) -> Int {
        if severity == 10 || severity == 18 { return 0 }
        if [9, 7, 14, 15, 19, 0, 8].contains(severity) { return 1 }
        return 2
    }

    /// Drops the line's own name from the front of TfL's explanation.
    private static func tidy(_ reason: String, _ name: String) -> String {
        var r = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["\(name) line:", "\(name) Line:", "\(name):"] where r.hasPrefix(prefix) {
            r = String(r.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        return r
    }

    static let colours: [String: Color] = [
        "bakerloo": Color(red: 0.70, green: 0.39, blue: 0.02), "central": Color(red: 0.89, green: 0.13, blue: 0.09),
        "circle": Color(red: 1.00, green: 0.83, blue: 0.00), "district": Color(red: 0.00, green: 0.47, blue: 0.16),
        "hammersmith-city": Color(red: 0.95, green: 0.66, blue: 0.73), "jubilee": Color(red: 0.63, green: 0.65, blue: 0.66),
        "metropolitan": Color(red: 0.61, green: 0.00, blue: 0.34), "northern": Color(white: 0.35),
        "piccadilly": Color(red: 0.00, green: 0.21, blue: 0.53), "victoria": Color(red: 0.00, green: 0.60, blue: 0.83),
        "waterloo-city": Color(red: 0.58, green: 0.80, blue: 0.73), "elizabeth": Color(red: 0.41, green: 0.31, blue: 0.63),
    ]
}

private extension Color {
    /// "#0039A6" from the Scout service.
    init?(hexString: String?) {
        guard let s = hexString?.trimmingCharacters(in: CharacterSet(charactersIn: "#")), s.count == 6,
              let v = UInt32(s, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

/// Lines with problems first (tap one for why), then the rest in one line.
struct TubeCard: View {
    @EnvironmentObject private var tube: TubeService
    @State private var open: String?
    /// Tap the card's top line to fold it into one compact strip, and again to open it.
    @AppStorage("tube.compact") private var compact = false

    var body: some View {
        let bad = tube.lines.filter { $0.level > 0 }
        let good = tube.lines.filter { $0.level == 0 }
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.snappy) { compact.toggle() }
            } label: {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "tram.fill").font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                        Text(tube.city.network).font(.system(size: 16, weight: .heavy)).foregroundStyle(Theme.ink)
                        Spacer(minLength: 4)
                        if tube.isLoading {
                            ProgressView().controlSize(.mini)
                        } else if let f = tube.fetched {
                            Text(Format.time(f)).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.tertiary)
                        }
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Theme.tertiary)
                            .rotationEffect(.degrees(compact ? 0 : 180))
                    }
                    // folded: the second line says what's wrong, line by line
                    if compact {
                        if tube.lines.isEmpty {
                            Text(summary(bad)).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.secondary)
                        } else if bad.isEmpty {
                            HStack(spacing: 8) {
                                Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(Theme.ink)
                                Text("Good service on all lines").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.ink)
                                Spacer(minLength: 8)
                                lineStrip.frame(width: 90)
                            }
                        } else {
                            FlowLayout(spacing: 6) {
                                ForEach(groups(bad)) { g in groupChip(g) }
                            }
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(compact ? "\(tube.city.network), \(summary(bad)). Show details" : "\(tube.city.network). Fold away")

            if !compact {
                if tube.lines.isEmpty {
                    Button { Task { await tube.refresh(force: true) } } label: {
                        Text(tube.failed ? "\(tube.city.network) status unavailable. Tap to try again." : "Loading…")
                            .font(.system(size: 14)).foregroundStyle(Theme.secondary)
                    }
                    .buttonStyle(.plain)
                } else {
                    if bad.isEmpty {
                        HStack(spacing: 10) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.ink)
                            Text("Good service on all lines").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.ink)
                        }
                    } else {
                        VStack(spacing: 0) {
                            ForEach(bad) { line in
                                row(line)
                                if line.id != bad.last?.id {
                                    Rectangle().fill(Theme.hairline).frame(height: 0.5).padding(.leading, 16)
                                }
                            }
                        }
                        if !good.isEmpty {
                            Text("Good service on the other \(good.count) line\(good.count == 1 ? "" : "s")")
                                .font(.system(size: 13)).foregroundStyle(Theme.secondary)
                        }
                    }
                    lineStrip
                    Text("\(tube.city.title) · live from \(tube.city.source)")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.tertiary)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, compact ? 15 : 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .task { await tube.refresh() }
        .sensoryFeedback(.selection, trigger: open)
        .sensoryFeedback(.impact(weight: .light), trigger: compact)
    }

    private func summary(_ bad: [TubeService.Line]) -> String {
        if tube.lines.isEmpty { return tube.failed ? "Unavailable" : "Loading…" }
        if bad.isEmpty { return "Good service" }
        if bad.count == 1, let line = bad.first { return "\(line.name): \(line.status)" }
        return "\(bad.count) lines disrupted"
    }

    /// Lines with the same problem together, worst first: "Minor delays" with each line's colour.
    private struct LineGroup: Identifiable {
        let status: String
        let level: Int
        let lines: [TubeService.Line]
        var id: String { status }
    }

    private func groups(_ bad: [TubeService.Line]) -> [LineGroup] {
        var order: [String] = []
        var byStatus: [String: [TubeService.Line]] = [:]
        for line in bad {
            if byStatus[line.status] == nil { order.append(line.status) }
            byStatus[line.status, default: []].append(line)
        }
        return order.map { LineGroup(status: $0, level: byStatus[$0]?.map(\.level).max() ?? 1, lines: byStatus[$0] ?? []) }
            .sorted { $0.level > $1.level }
    }

    private func groupChip(_ g: LineGroup) -> some View {
        HStack(spacing: 7) {
            HStack(spacing: 3) {
                ForEach(g.lines) { line in
                    if let badge = line.badge {
                        Text(badge)
                            .font(.system(size: badge.count > 2 ? 6 : 9, weight: .bold))
                            .foregroundStyle(line.badgeText)
                            .frame(width: 16, height: 16)
                            .background(line.colour, in: Circle())
                    } else {
                        Circle().fill(line.colour).frame(width: 9, height: 9)
                    }
                }
            }
            Text(g.status)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(g.level == 2 ? Theme.accent : Theme.ink)
        }
        .lineLimit(1)
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(g.level == 2 ? Theme.accent.opacity(0.1) : Theme.track, in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(g.status): \(g.lines.map(\.name).joined(separator: ", "))")
    }

    /// Every line's colour, faded when it's running well.
    private var lineStrip: some View {
        HStack(spacing: 2) {
            ForEach(tube.lines.sorted { $0.order < $1.order }) { line in
                Capsule().fill(line.colour)
                    .frame(height: 4)
                    .opacity(line.level == 0 ? 0.3 : 1)
            }
        }
        .accessibilityHidden(true)
    }

    private func row(_ line: TubeService.Line) -> some View {
        Button {
            withAnimation(.snappy) { open = open == line.id ? nil : line.id }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    if let badge = line.badge {
                        Text(badge)
                            .font(.system(size: badge.count > 2 ? 9 : 13, weight: .bold))
                            .foregroundStyle(line.badgeText)
                            .minimumScaleFactor(0.7)
                            .frame(width: 26, height: 26)
                            .background(line.colour, in: Circle())
                    } else {
                        Capsule().fill(line.colour).frame(width: 4, height: 30)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(line.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
                        Text(line.status).font(.system(size: 13, weight: .medium))
                            .foregroundStyle(line.level == 2 ? Theme.accent : Theme.secondary)
                    }
                    Spacer()
                    if !line.reason.isEmpty {
                        Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Theme.tertiary)
                            .rotationEffect(.degrees(open == line.id ? 180 : 0))
                    }
                }
                if open == line.id, !line.reason.isEmpty {
                    Text(line.reason).font(.system(size: 13)).foregroundStyle(Theme.ink.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                        .padding(.leading, 14)
                        .transition(.opacity)
                }
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(line.reason.isEmpty)
    }
}
