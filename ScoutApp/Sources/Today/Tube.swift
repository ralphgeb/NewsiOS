import SwiftUI

/// Live Tube and Elizabeth line status from TfL's free, official feed.
@MainActor
final class TubeService: ObservableObject {
    struct Line: Identifiable {
        let id: String
        let name: String
        /// 0 good, 1 minor, 2 severe
        let level: Int
        let status: String
        let reason: String
    }

    @Published private(set) var lines: [Line] = []
    @Published private(set) var fetched: Date?
    @Published private(set) var failed = false
    @Published private(set) var isLoading = false

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

    func refresh(force: Bool = false) async {
        if !force, let f = fetched, Date.now.timeIntervalSince(f) < 2 * 60 { return }
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let url = URL(string: "https://api.tfl.gov.uk/Line/Mode/tube,elizabeth-line/Status")!
            let (data, _) = try await URLSession.shared.data(from: url)
            let raw = try JSONDecoder().decode([LineJSON].self, from: data)
            lines = raw.map { l in
                let statuses = l.lineStatuses.map { (level: Self.level($0.statusSeverity), text: $0.statusSeverityDescription, reason: $0.reason ?? "") }
                let worst = statuses.map { $0.level }.max() ?? 0
                var texts: [String] = []
                for s in statuses where s.level == worst && !texts.contains(s.text) { texts.append(s.text) }
                var reasons: [String] = []
                for s in statuses where !s.reason.isEmpty && !reasons.contains(s.reason) { reasons.append(Self.tidy(s.reason, l.name)) }
                return Line(id: l.id, name: l.name, level: worst, status: texts.joined(separator: " · "), reason: reasons.joined(separator: "\n\n"))
            }
            .sorted { ($0.level, $1.name) > ($1.level, $0.name) }
            fetched = .now
            failed = false
        } catch {
            failed = lines.isEmpty
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
                        Text("Tube").font(.system(size: 16, weight: .heavy)).foregroundStyle(Theme.ink)
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
                                ForEach(bad.prefix(5)) { line in lineChip(line) }
                                if bad.count > 5 {
                                    Text("+\(bad.count - 5)")
                                        .font(.system(size: 12, weight: .bold))
                                        .padding(.horizontal, 9).frame(height: 26)
                                        .background(Theme.track, in: Capsule())
                                        .foregroundStyle(Theme.secondary)
                                }
                            }
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(compact ? "Tube, \(summary(bad)). Show details" : "Tube. Fold away")

            if !compact {
                if tube.lines.isEmpty {
                    Button { Task { await tube.refresh(force: true) } } label: {
                        Text(tube.failed ? "Tube status unavailable. Tap to try again." : "Loading…")
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

    /// A disrupted line: its colour, name and what's wrong, in one chip.
    private func lineChip(_ line: TubeService.Line) -> some View {
        HStack(spacing: 6) {
            Capsule().fill(TubeService.colours[line.id] ?? Theme.ink).frame(width: 4, height: 14)
            Text(line.name.replacingOccurrences(of: " line", with: ""))
                .font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.ink)
            Text(line.status)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(line.level == 2 ? Theme.accent : Theme.secondary)
        }
        .lineLimit(1)
        .padding(.leading, 8).padding(.trailing, 10)
        .frame(height: 26)
        .background(line.level == 2 ? Theme.accent.opacity(0.1) : Theme.track, in: Capsule())
    }

    /// Every line's colour, faded when it's running well.
    private var lineStrip: some View {
        HStack(spacing: 2) {
            ForEach(tube.lines.sorted { $0.name < $1.name }) { line in
                Capsule().fill(TubeService.colours[line.id] ?? Theme.ink)
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
                    Capsule().fill(TubeService.colours[line.id] ?? Theme.ink).frame(width: 4, height: 30)
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
