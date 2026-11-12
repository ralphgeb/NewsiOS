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

/// What's playing: tap it to go back to the story (or the briefing), with play/pause and a
/// close button to stop. It sits beside the tab bar (iOS 26), above it, or in a story's bottom bar.
struct NowPlayingBar: View {
    enum Look { case floating, accessory, inline, story }
    var look: Look = .floating
    /// The story on screen (tapping the player there doesn't open it again).
    var current: String? = nil
    @ObservedObject private var speaker = Speaker.shared
    @ObservedObject private var clock = Speaker.shared.clock
    @Environment(\.openURL) private var openURL

    var body: some View {
        if let now = speaker.now {
            let on = !speaker.paused
            let small = look == .inline
            HStack(spacing: small ? 8 : 10) {
                Button { open(now) } label: {
                    HStack(spacing: small ? 8 : 10) {
                        thumb(now, size: small ? 28 : 36)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(now.title).font(.system(size: small ? 12.5 : 13, weight: .semibold))
                                .foregroundStyle(Theme.text).lineLimit(1)
                            if !small {
                                Text(speaker.preparing ? "Getting it ready…" : now.subtitle)
                                    .font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                        if !small, !speaker.preparing {
                            PlaybackVisual(style: .bars, playing: on, progress: clock.progress, size: 16)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open \(now.title)")
                Button { speaker.toggle() } label: {
                    Group {
                        if speaker.preparing {
                            ProgressView().tint(.white).controlSize(.small)
                        } else {
                            Image(systemName: on ? "pause.fill" : "play.fill")
                                .font(.system(size: small ? 12 : 14, weight: .bold))
                                .contentTransition(.symbolEffect(.replace))
                        }
                    }
                    .foregroundStyle(.white)
                    .frame(width: small ? 28 : 34, height: small ? 28 : 34)
                    .background(Theme.accent, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(on ? "Pause" : "Play")
                Button { withAnimation(.snappy) { speaker.stop() } } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: small ? 11 : 12, weight: .bold))
                        .foregroundStyle(Theme.secondary)
                        .frame(width: small ? 24 : 30, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop")
            }
            .padding(.leading, small ? 4 : 6).padding(.trailing, small ? 4 : 6)
            .frame(height: small ? 40 : 50)
            .modifier(BarBackground(glass: look == .floating || look == .story))
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// Back to what's playing: the story, or the briefing's section.
    private func open(_ now: NowPlaying) {
        if let id = now.storyID {
            if id != current, let url = URL(string: "scout://story/\(id)") { openURL(url) }
        }
        else if let section = now.section, let url = URL(string: "scout://news?section=\(section)") { openURL(url) }
    }

    @ViewBuilder private func thumb(_ now: NowPlaying, size: CGFloat) -> some View {
        Group {
            if let url = now.artwork {
                RemoteImage(url: url) { ScoutPlaceholder() }
            } else {
                ZStack {
                    Theme.accent.opacity(0.15)
                    Image(systemName: "headphones").font(.system(size: size * 0.4, weight: .semibold)).foregroundStyle(Theme.accent)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
    }
}

/// Glass for a bar standing on its own; none inside the tab bar's accessory, which has its own.
private struct BarBackground: ViewModifier {
    let glass: Bool
    func body(content: Content) -> some View {
        if glass { content.scoutGlass(Capsule()) } else { content }
    }
}

/// The player in the tab bar's accessory (iOS 26): beside the shrunken tab bar while you
/// scroll, a full bar above it otherwise.
@available(iOS 26, *)
struct NowPlayingAccessory: View {
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    var body: some View {
        NowPlayingBar(look: placement == .inline ? .inline : .accessory)
            .padding(.horizontal, 6)
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

/// Before iOS 26.1 (no tab bar accessory to switch on and off), the player floats above the tab bar.
private struct NowPlayingInset: ViewModifier {
    @ObservedObject private var speaker = Speaker.shared
    @ObservedObject private var bar = TabBarState.shared

    func body(content: Content) -> some View {
        if #available(iOS 26.1, *) {
            content
        } else {
            content.safeAreaInset(edge: .bottom) {
                if speaker.now != nil, !bar.storyOnScreen {
                    NowPlayingBar()
                        .padding(.horizontal, Design.sideMargin + 4)
                        .padding(.bottom, 6)
                }
            }
            .animation(.snappy, value: speaker.now == nil)
        }
    }
}

/// The play button at the top of a story, in the accent.
struct StoryListenButton: View {
    let story: Story
    @ObservedObject private var speaker = Speaker.shared
    @AppStorage(Plus.key) private var hasPlus = false
    @State private var showPlus = false

    var body: some View {
        let id = "story-\(story.id)"
        let on = speaker.isPlaying(id)
        Button { if hasPlus { speaker.play(story: story) } else { showPlus = true } } label: {
            if speaker.playing == id && speaker.preparing {
                // straight away, so it's clear the tap worked while the story gets ready
                ProgressView().tint(Theme.accent)
            } else {
                Image(systemName: on ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Theme.accent)
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .sensoryFeedback(.selection, trigger: on)
        .accessibilityLabel(on ? "Pause the story" : "Listen to the story")
        .sheet(isPresented: $showPlus) { PlusSheet(reason: "Listening to stories is part of Scout Plus.") }
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

/// Today's "Play my briefings": the chosen sections' briefings one after another, the friendly
/// opening first (once per edition) and a short link before each next one ("Moving on to the
/// markets…", "Last one, I promise…"). The sections are chosen in Settings › Play my briefings.
struct PlayMyBriefings: View {
    @EnvironmentObject private var store: NewsStore
    @ObservedObject private var speaker = Speaker.shared
    @AppStorage(Plus.key) private var hasPlus = false
    @AppStorage(PlayAll.key) private var chosen = PlayAll.defaultValue
    /// The edition last played, so the title can offer to play it again.
    @AppStorage("playall.lastPlayed") private var lastPlayed = ""
    @State private var showPlus = false
    @State private var busy = false
    /// Picked once each time Today opens, so it changes from day to day without flickering.
    @State private var pick = Int.random(in: 0..<100)

    private static let fresh = [("Catch me up", "on what I missed"), ("Play my briefings", "the news, read to you"),
                                ("What did I miss?", "your briefings, one after another"), ("Brief me", "a few minutes, all you need"),
                                ("Listen to today's news", "your briefings, back to back")]
    private static let again = [("Listen again", "your briefings from the top"), ("Play them again", "in case you missed a bit"),
                                ("Hear it all again", "your briefings, back to back")]

    private var sections: [Topic] { PlayAll.sections(chosen).filter { store.briefing.section($0) != nil } }
    private var id: String { "brief-all-\(Intro.current)-\(sections.map(\.rawValue).joined())" }
    private var heard: Bool { lastPlayed == Intro.current }

    private var minutes: Int {
        let chars = sections.compactMap { store.briefing.section($0) }.flatMap(BriefingListen.parts).reduce(0) { $0 + $1.count }
        return max(1, Int((Double(chars) / 15.5 / 60).rounded()))
    }

    var body: some View {
        if !sections.isEmpty {
            let on = speaker.isPlaying(id)
            let mine = speaker.playing == id
            let list = heard ? Self.again : Self.fresh
            let words = list[pick % list.count]
            Button { Task { await play() } } label: {
                HStack(spacing: 14) {
                    ZStack {
                        Circle().fill(Theme.accent)
                        Circle().strokeBorder(Theme.accent.opacity(0.25), lineWidth: 5).padding(-5)
                        if busy && !mine {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: on ? "pause.fill" : "play.fill")
                                .font(.system(size: 16, weight: .black)).foregroundStyle(.white)
                                .offset(x: on ? 0 : 1.5)
                                .contentTransition(.symbolEffect(.replace))
                        }
                    }
                    .frame(width: 44, height: 44)
                    .padding(5)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Your \(Intro.edition.lowercased()) briefing").scoutLabel()
                        Text(on ? "Playing now" : mine ? "Carry on listening" : words.0)
                            .font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.text)
                        Text(on || mine ? sections.map(\.title).joined(separator: " · ") : "\(words.1) · \(minutes) min")
                            .font(.system(size: 13)).foregroundStyle(Theme.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if on { ClockVisual() }
                }
                .padding(.leading, 8).padding(.trailing, 16).padding(.vertical, 10)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
            .buttonStyle(PressStyle())
            .sensoryFeedback(.selection, trigger: on)
            .sheet(isPresented: $showPlus) { PlusSheet(reason: "Listening to the briefings is part of Scout Plus.") }
        }
    }

    private func play() async {
        guard hasPlus else { showPlus = true; return }
        if speaker.playing == id { speaker.toggle(); return }
        busy = true
        defer { busy = false }
        guard let index = await AudioIndex.load() else { return }
        var urls: [URL] = []
        var titles: [(title: String, subtitle: String)] = []
        for (i, topic) in sections.enumerated() {
            guard let brief = store.briefing.section(topic), let main = index.url(topic.rawValue, BriefingListen.voice) else { continue }
            let label = "\(topic.title) briefing"
            if urls.isEmpty, Intro.due, let intro = index.url(topic.rawValue, "intro") {
                Intro.markPlayed()
                urls.append(intro); titles.append((brief.title, label))
            } else if !urls.isEmpty, let link = index.transitionURL(topic.rawValue, last: i == sections.count - 1) {
                urls.append(link); titles.append((brief.title, label))
            }
            urls.append(main); titles.append((brief.title, label))
        }
        guard !urls.isEmpty else { return }
        let first = sections.first.flatMap { store.briefing.section($0) }
        speaker.play(id, title: "Your briefings", urls: urls,
                     info: NowPlaying(title: first?.title ?? "Your briefings", subtitle: "Your \(Intro.edition.lowercased()) briefing", cover: true), titles: titles)
        lastPlayed = Intro.current
        Stats.played("briefing", id: "all", title: "Play my briefings")
    }
}

/// The moving bars, watching the clock (so only this redraws as it plays).
private struct ClockVisual: View {
    var tint: Color = Theme.accent
    @ObservedObject private var clock = Speaker.shared.clock
    var body: some View { PlaybackVisual(style: .bars, playing: true, progress: clock.progress, size: 20, tint: tint) }
}

/// Which sections Play my briefings plays, in order (Settings).
enum PlayAll {
    static let key = "playall.sections"
    static let defaultValue = Topic.allCases.map(\.rawValue).joined(separator: ",")
    static func sections(_ raw: String) -> [Topic] {
        let set = Set(raw.split(separator: ",").map(String.init))
        return Topic.allCases.filter { set.contains($0.rawValue) }
    }
}
