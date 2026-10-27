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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Tube").scoutLabel()
                Spacer()
                if tube.isLoading { ProgressView().controlSize(.mini) }
                if let f = tube.fetched {
                    Button { Task { await tube.refresh(force: true) } } label: {
                        Text("Updated \(Format.time(f))").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            if tube.lines.isEmpty {
                Button { Task { await tube.refresh(force: true) } } label: {
                    Text(tube.failed ? "Tube status unavailable. Tap to try again." : "Loading…")
                        .font(.system(size: 14)).foregroundStyle(Theme.secondary)
                }
                .buttonStyle(.plain)
            } else {
                let bad = tube.lines.filter { $0.level > 0 }
                let good = tube.lines.filter { $0.level == 0 }
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
                HStack(spacing: 3) {
                    ForEach(tube.lines.sorted { $0.name < $1.name }) { line in
                        Capsule().fill(TubeService.colours[line.id] ?? Theme.ink)
                            .frame(height: 4)
                            .opacity(line.level == 0 ? 0.35 : 1)
                    }
                }
                .accessibilityHidden(true)
            }
        }
        .scoutCard()
        .task { await tube.refresh() }
        .sensoryFeedback(.selection, trigger: open)
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
