import SwiftUI

/// Counts plays on the Scout service, for the /stats page (no personal details, just what was played).
enum Stats {
    static func played(_ kind: String, id: String, title: String) {
        guard let base = AudioIndex.base else { return }
        var req = URLRequest(url: base.appending(path: "stats/play"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["kind": kind, "id": id, "title": title])
        Task.detached { _ = try? await URLSession.shared.data(for: req) }
    }
}

/// What the phone's voice reads for a story when there's no recording.
enum StoryReading {
    static func parts(_ s: Story) -> [String] {
        [s.title, s.summary ?? s.claim ?? ""] + (s.keyPoints ?? [])
    }
}

/// How playing audio is drawn, chosen in Settings › Listening.
enum ListenVisual: String, CaseIterable, Identifiable {
    case bars, pulse, ring, wave
    static let key = "listen.visual"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .bars: return "Bars"
        case .pulse: return "Pulse"
        case .ring: return "Ring"
        case .wave: return "Wave"
        }
    }
}

/// The moving picture of the sound: bouncing bars, a pulse, a progress ring or a wave.
struct PlaybackVisual: View {
    let style: ListenVisual
    var playing = true
    var progress: Double = 0
    var size: CGFloat = 20
    var tint: Color = Theme.accent
    /// Stretch across the width (in the small player rows).
    var wide = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !playing)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            Group {
                switch style {
                case .bars: bars(t)
                case .pulse: pulse(t)
                case .ring: ring(t)
                case .wave: wave(t)
                }
            }
        }
        .frame(width: wide ? nil : size, height: size)
        .frame(maxWidth: wide ? .infinity : nil)
        .accessibilityHidden(true)
    }

    private func level(_ t: Double, _ i: Int) -> CGFloat {
        let a = sin(t * 5.1 + Double(i) * 1.7) * 0.5 + 0.5
        let b = sin(t * 3.3 + Double(i) * 0.9) * 0.5 + 0.5
        return CGFloat(0.25 + 0.75 * (a * 0.6 + b * 0.4))
    }

    private func bars(_ t: Double) -> some View {
        GeometryReader { g in
            let n = wide ? max(8, Int(g.size.width / 6)) : 4
            HStack(alignment: .center, spacing: wide ? 2.5 : size * 0.1) {
                ForEach(0..<n, id: \.self) { i in
                    Capsule().fill(tint.opacity(wide && Double(i) / Double(n) > progress ? 0.35 : 1))
                        .frame(height: g.size.height * (playing ? level(t, i) : 0.3))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func pulse(_ t: Double) -> some View {
        GeometryReader { g in
            if wide {
                line(g.size, dot: true, t: t)
            } else {
                ZStack {
                    ForEach(0..<3, id: \.self) { i in
                        let p = (t * 0.6 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                        Circle().stroke(tint.opacity(1 - p), lineWidth: max(1, size * 0.06))
                            .scaleEffect(0.35 + 0.65 * p)
                    }
                    Circle().fill(tint).frame(width: size * 0.3, height: size * 0.3)
                }
                .frame(width: g.size.width, height: g.size.height)
            }
        }
    }

    private func ring(_ t: Double) -> some View {
        GeometryReader { g in
            if wide {
                line(g.size, dot: false, t: t)
            } else {
                ZStack {
                    Circle().stroke(tint.opacity(0.2), lineWidth: max(2, size * 0.1))
                    Circle().trim(from: 0, to: max(0.02, progress))
                        .stroke(tint, style: StrokeStyle(lineWidth: max(2, size * 0.1), lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .padding(max(1, size * 0.05))
                .frame(width: g.size.width, height: g.size.height)
            }
        }
    }

    private func wave(_ t: Double) -> some View {
        Canvas { ctx, sz in
            for layer in 0..<2 {
                var path = Path()
                let amp = sz.height * (layer == 0 ? 0.38 : 0.22)
                let len = max(sz.width, 1)
                for x in stride(from: 0, through: len, by: 1) {
                    let k = Double(x / len)
                    let env = sin(k * .pi)
                    let y = sz.height / 2 + amp * env * sin(k * (wide ? 18 : 7) + t * (layer == 0 ? 6 : -4))
                    if x == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
                ctx.stroke(path, with: .color(tint.opacity(layer == 0 ? 1 : 0.4)), lineWidth: max(1.5, sz.height * 0.1))
            }
        }
    }

    /// A progress line, for the wide rows with Pulse and Ring.
    private func line(_ sz: CGSize, dot: Bool, t: Double) -> some View {
        ZStack(alignment: .leading) {
            Capsule().fill(tint.opacity(0.2)).frame(height: 4)
            Capsule().fill(tint).frame(width: max(4, sz.width * progress), height: 4)
            if dot {
                Circle().fill(tint)
                    .frame(width: 10, height: 10)
                    .scaleEffect(0.8 + 0.3 * (sin(t * 5) * 0.5 + 0.5))
                    .offset(x: max(0, sz.width * progress - 5))
            }
        }
        .frame(width: sz.width, height: sz.height)
    }
}

/// What's playing, with play/pause and close: above the tab bar, and beside Read on in a story.
struct NowPlayingBar: View {
    var compact = false
    @ObservedObject private var speaker = Speaker.shared
    @AppStorage(ListenVisual.key) private var visualRaw = ListenVisual.bars.rawValue

    var body: some View {
        if let now = speaker.now {
            let on = !speaker.paused
            HStack(spacing: 10) {
                thumb(now)
                VStack(alignment: .leading, spacing: 1) {
                    Text(now.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                    if speaker.preparing {
                        Text("Getting it ready…").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    } else if !compact {
                        Text(now.subtitle).font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if !compact || speaker.duration > 0 {
                    PlaybackVisual(style: ListenVisual(rawValue: visualRaw) ?? .bars, playing: on && !speaker.preparing,
                                   progress: speaker.progress, size: 18)
                }
                Button { speaker.toggle() } label: {
                    Image(systemName: on ? "pause.fill" : "play.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Theme.accent, in: Circle())
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(on ? "Pause" : "Play")
                if !compact {
                    Button { withAnimation(.snappy) { speaker.stop() } } label: {
                        Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.secondary)
                            .frame(width: 28, height: 32)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Stop")
                }
            }
            .padding(.leading, 6).padding(.trailing, 8)
            .frame(height: 50)
            .scoutGlass(Capsule())
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    @ViewBuilder private func thumb(_ now: NowPlaying) -> some View {
        Group {
            if let url = now.artwork {
                RemoteImage(url: url) { ScoutPlaceholder() }
            } else {
                ZStack {
                    Theme.accent.opacity(0.15)
                    Image(systemName: "headphones").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.accent)
                }
            }
        }
        .frame(width: 38, height: 38)
        .clipShape(Circle())
    }
}

extension View {
    /// The mini player above the tab bar while something plays (story pages show their own).
    func nowPlayingInset() -> some View { modifier(NowPlayingInset()) }

    /// Apple's glass on iOS 26, frosted material before it.
    @ViewBuilder func scoutGlass<S: Shape>(_ shape: S) -> some View {
        if #available(iOS 26, *) {
            self.glassEffect(.regular.interactive(), in: shape)
        } else {
            self.background(.regularMaterial, in: shape)
                .overlay(shape.stroke(Theme.hairline, lineWidth: 0.5))
        }
    }
}

private struct NowPlayingInset: ViewModifier {
    @ObservedObject private var speaker = Speaker.shared

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom) {
            if speaker.now != nil, speaker.storyPagesOpen == 0 {
                NowPlayingBar()
                    .padding(.horizontal, Design.sideMargin + 4)
                    .padding(.bottom, 6)
            }
        }
        .animation(.snappy, value: speaker.now == nil)
    }
}

/// The play button at the top of a story, in the accent.
struct StoryListenButton: View {
    let story: Story
    @ObservedObject private var speaker = Speaker.shared

    var body: some View {
        let id = "story-\(story.id)"
        let on = speaker.isPlaying(id)
        Button { speaker.play(story: story) } label: {
            Image(systemName: on ? "pause.circle.fill" : "play.circle.fill")
                .font(.system(size: 20, weight: .semibold))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, Theme.accent)
                .contentTransition(.symbolEffect(.replace))
        }
        .sensoryFeedback(.selection, trigger: on)
        .accessibilityLabel(on ? "Pause the story" : "Listen to the story")
    }
}

/// Scout's mark (the hub and its nodes) in white, pressed into the grey like an emboss: for
/// pictures that are still loading or missing.
struct ScoutPlaceholder: View {
    var body: some View {
        ZStack {
            Theme.track
            GeometryReader { g in
                let side = min(g.size.width, g.size.height) * 0.5
                ScoutMark(color: .white.opacity(0.92))
                    .frame(width: side, height: side)
                    .shadow(color: .black.opacity(0.22), radius: 0.6, x: 0.8, y: 1)
                    .shadow(color: .white.opacity(0.8), radius: 0.5, x: -0.6, y: -0.8)
                    .frame(width: g.size.width, height: g.size.height)
            }
        }
        .accessibilityHidden(true)
    }
}

/// The app icon's drawing (tools/make_icon.py): a hub with five nodes on spokes.
struct ScoutMark: View {
    var color: Color = .white

    var body: some View {
        Canvas { ctx, size in
            let k = min(size.width, size.height) / 640      // the drawing spans about 640 of the 1024 grid
            let hub = CGPoint(x: size.width / 2 + 18 * k, y: size.height / 2 + 6 * k)
            let nodes: [(CGFloat, CGFloat, CGFloat)] = [(-200, -214, 70), (176, -168, 76), (-232, 10, 44), (-104, 262, 58), (176, 170, 54)]
            for (dx, dy, _) in nodes {
                var spoke = Path()
                spoke.move(to: hub)
                spoke.addLine(to: CGPoint(x: hub.x + dx * k, y: hub.y + dy * k))
                ctx.stroke(spoke, with: .color(color), style: StrokeStyle(lineWidth: 30 * k, lineCap: .round))
            }
            for (dx, dy, r) in nodes {
                ctx.fill(Path(ellipseIn: CGRect(x: hub.x + (dx - r) * k, y: hub.y + (dy - r) * k, width: 2 * r * k, height: 2 * r * k)), with: .color(color))
            }
            ctx.fill(Path(ellipseIn: CGRect(x: hub.x - 92 * k, y: hub.y - 92 * k, width: 184 * k, height: 184 * k)), with: .color(color))
        }
    }
}
