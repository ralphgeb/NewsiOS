import AVFoundation
import MediaPlayer
import SwiftUI
import WidgetKit

/// What's playing, for the mini player, the story page and the Lock Screen / Control Centre.
struct NowPlaying: Equatable {
    var title: String
    /// "Tech briefing", or the outlet for a story.
    var subtitle: String
    var artwork: URL?
    /// The story, when a story is playing (opens it from the mini player).
    var storyID: String?
    /// The briefing's section, when a briefing is playing.
    var section: String?
}

/// Plays briefings and stories: the Scout service's recordings (Google's Chirp 3: HD voice), or
/// the iPhone's own voice when there's no recording. It keeps going with the screen locked, with
/// the title, picture, play/pause and 15-second skips on the Lock Screen and in Control Centre.
@MainActor
final class Speaker: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    static let shared = Speaker()

    /// What's being read ("story-<id>", "brief-Tech-…"), nil when quiet.
    @Published private(set) var playing: String? { didSet { if oldValue != playing { share() } } }
    @Published private(set) var paused = false { didSet { if oldValue != paused { share() } } }
    @Published private(set) var now: NowPlaying?
    /// Getting a story ready (the "hold on" line is playing, or the recording is on its way).
    @Published private(set) var preparing = false
    /// How far through, 0 to 1 (recordings only), and the seconds played and in total.
    @Published private(set) var progress: Double = 0
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var duration: Double = 0
    /// Story pages on screen: the mini player above the tab bar steps aside for theirs.
    @Published var storyPagesOpen = 0

    /// Tells the Listen widget which briefing is playing, so its button shows pause.
    private func share() {
        let section = playing.flatMap { id in id.hasPrefix("brief-") ? id.split(separator: "-").dropFirst().first.map(String.init) : nil }
        Shared.defaults.set(section, forKey: ListenState.sectionKey)
        Shared.defaults.set(paused, forKey: ListenState.pausedKey)
        WidgetCenter.shared.reloadTimelines(ofKind: ListenState.widgetKind)
    }

    private let synth = AVSpeechSynthesizer()
    private var player: AVQueuePlayer?
    private var endObserver: NSObjectProtocol?
    private var timeObserver: Any?
    /// The recording that ends playback when it finishes (the hold-on line doesn't).
    private var lastItem: AVPlayerItem?
    private var artwork: MPMediaItemArtwork?
    private var storyTask: Task<Void, Never>?

    private override init() {
        super.init()
        synth.delegate = self
        let center = MPRemoteCommandCenter.shared()
        center.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.toggle() }; return .success }
        center.playCommand.addTarget { [weak self] _ in Task { @MainActor in self?.toggle() }; return .success }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.toggle() }; return .success }
        center.skipForwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.preferredIntervals = [15]
        center.skipForwardCommand.addTarget { [weak self] _ in Task { @MainActor in self?.skip(15) }; return .success }
        center.skipBackwardCommand.addTarget { [weak self] _ in Task { @MainActor in self?.skip(-15) }; return .success }
        center.changePlaybackPositionCommand.addTarget { [weak self] e in
            let t = (e as? MPChangePlaybackPositionCommandEvent)?.positionTime ?? 0
            Task { @MainActor in self?.player?.seek(to: CMTime(seconds: t, preferredTimescale: 600)) }
            return .success
        }
    }

    func isPlaying(_ id: String) -> Bool { playing == id && !paused }

    // MARK: Playing

    /// Reads `parts` with the phone's voice (a short pause between each), or pauses and resumes.
    func play(_ id: String, title: String, parts: [String], info: NowPlaying? = nil) {
        if playing == id { toggle(); return }
        stop()
        startSpeaking(parts)
        begin(id, info ?? NowPlaying(title: title, subtitle: "Scout"))
    }

    /// Plays a recording from the Scout service, or pauses and resumes it.
    func play(_ id: String, title: String, url: URL, info: NowPlaying? = nil) {
        play(id, title: title, urls: [url], info: info)
    }

    /// Plays recordings one after the other (the short opening, then the briefing).
    func play(_ id: String, title: String, urls: [URL], info: NowPlaying? = nil) {
        if playing == id { toggle(); return }
        guard !urls.isEmpty else { return }
        stop()
        let items = urls.map { AVPlayerItem(url: $0) }
        startPlayer(items, last: items.last)
        begin(id, info ?? NowPlaying(title: title, subtitle: "Scout"))
    }

    /// A story: its recording if there is one. If not, the Scout service records it (a few
    /// seconds); after half a second a short "hold on" line plays while it does. If it can't
    /// be recorded, the phone's voice reads the story instead.
    func play(story s: Story) {
        let id = "story-\(s.id)"
        if playing == id { toggle(); return }
        stop()
        let info = NowPlaying(title: s.title, subtitle: s.outletName, artwork: s.imageURL, storyID: s.id)
        begin(id, info)
        preparing = true
        storyTask = Task { [weak self] in
            let index = await AudioIndex.load()
            guard let self, self.playing == id else { return }
            let url = index?.storyURL(s.id) ?? AudioIndex.base?.appending(path: "audio/story/\(s.id).mp3")
            let recorded = index?.storyURL(s.id) != nil
            // fetch the recording; if it takes more than a second, the hold-on line starts
            let fetch = Task { () -> URL? in
                guard let url else { return nil }
                var req = URLRequest(url: url)
                req.timeoutInterval = 45
                guard let (data, resp) = try? await URLSession.shared.data(for: req),
                      (resp as? HTTPURLResponse)?.statusCode == 200, data.count > 1000 else { return nil }
                let file = FileManager.default.temporaryDirectory.appending(path: "story-\(s.id).mp3")
                try? data.write(to: file, options: .atomic)
                return file
            }
            if !recorded {
                try? await Task.sleep(for: .milliseconds(500))
                if self.playing == id, self.player == nil, let hold = index?.holdURL() {
                    let item = AVPlayerItem(url: hold)
                    self.startPlayer([item], last: nil)
                    self.updateNowPlaying()
                }
            }
            let file = await fetch.value
            guard self.playing == id else { return }
            self.preparing = false
            if let file {
                let item = AVPlayerItem(url: file)
                if let player = self.player {
                    self.lastItem = item
                    player.insert(item, after: player.items().last)
                    if !self.paused { player.play() }
                } else {
                    self.startPlayer([item], last: item)
                }
            } else {
                // no recording (offline, or today's limit): the phone reads it
                self.player?.pause()
                self.player = nil
                self.startSpeaking(StoryReading.parts(s))
            }
            self.updateNowPlaying()
        }
        Stats.played("story", id: s.id, title: s.title)
    }

    func toggle() {
        guard playing != nil else { return }
        if let player {
            if paused { player.play() } else { player.pause() }
        } else {
            if paused { synth.continueSpeaking() } else { synth.pauseSpeaking(at: .word) }
        }
        paused.toggle()
        updateNowPlaying()
    }

    func skip(_ seconds: Double) {
        guard let player else { return }
        let t = max(0, player.currentTime().seconds + seconds)
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600))
    }

    func stop() {
        storyTask?.cancel()
        storyTask = nil
        synth.stopSpeaking(at: .immediate)
        player?.pause()
        finish()
    }

    /// Waits (up to 15 seconds) until a recording is really playing.
    func waitUntilSounding() async {
        for _ in 0..<60 {
            guard let player else { return }
            if player.timeControlStatus == .playing { return }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    // MARK: Inside

    private func begin(_ id: String, _ info: NowPlaying) {
        playing = id
        paused = false
        now = info
        progress = 0; elapsed = 0; duration = 0
        artwork = nil
        updateNowPlaying()
        if let url = info.artwork {
            Task { [weak self] in
                guard let img = await ImageLoader.shared.image(url), let self, self.playing == id else { return }
                self.artwork = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
                self.updateNowPlaying()
            }
        }
    }

    private func activateSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [])
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    private func startSpeaking(_ parts: [String]) {
        activateSession()
        let voice = Self.bestVoice()
        for (i, part) in parts.enumerated() where !part.isEmpty {
            let u = AVSpeechUtterance(string: part)
            u.voice = voice
            u.rate = AVSpeechUtteranceDefaultSpeechRate * 1.02
            u.postUtteranceDelay = i == 0 ? 0.45 : 0.3
            synth.speak(u)
        }
    }

    private func startPlayer(_ items: [AVPlayerItem], last: AVPlayerItem?) {
        activateSession()
        let player = AVQueuePlayer(items: items)
        lastItem = last
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] note in
            let item = note.object as? AVPlayerItem
            Task { @MainActor in
                guard let self, let item, item === self.lastItem else { return }
                self.finish()
            }
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] t in
            Task { @MainActor in self?.tick(t) }
        }
        self.player = player
        player.play()
    }

    private func tick(_ t: CMTime) {
        guard let item = player?.currentItem else { return }
        // the hold-on line and the opening don't count towards the progress
        guard !preparing, lastItem == nil || item === lastItem else { return }
        let d = item.duration.seconds
        elapsed = t.seconds
        duration = d.isFinite ? d : 0
        progress = duration > 0 ? min(1, elapsed / duration) : 0
        if Int(elapsed * 4) % 8 == 0 { updateNowPlaying() }
    }

    private func finish() {
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player = nil
        lastItem = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        playing = nil
        paused = false
        preparing = false
        now = nil
        progress = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func updateNowPlaying() {
        guard let now else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: preparing ? "Getting your story ready…" : now.title,
            MPMediaItemPropertyArtist: now.subtitle,
            MPMediaItemPropertyAlbumTitle: "Scout",
            MPNowPlayingInfoPropertyPlaybackRate: paused ? 0.0 : 1.0,
        ]
        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        }
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// The best English voice on the phone: Premium, then Enhanced, then the default, in the
    /// phone's own English (British in the UK).
    static func bestVoice() -> AVSpeechSynthesisVoice? {
        let region = Locale.current.region?.identifier ?? "GB"
        let wanted = ["GB", "US", "AU", "IE"].contains(region) ? "en-\(region)" : "en-GB"
        let english = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
        func rank(_ v: AVSpeechSynthesisVoice) -> Int {
            (v.quality == .premium ? 20 : v.quality == .enhanced ? 10 : 0) + (v.language == wanted ? 5 : 0)
        }
        return english.max { rank($0) < rank($1) } ?? AVSpeechSynthesisVoice(language: wanted)
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in if !self.synth.isSpeaking { self.finish() } }
    }
}

/// The friendly opening ("Had your coffee yet?…") plays before the first briefing you hear in
/// each edition (morning and evening); after that, briefings start straight with the news. The
/// note is kept in the App Group, so the widgets' play buttons count too.
enum Intro {
    private static let key = "listen.introPlayed"

    /// Today's date and edition, e.g. "2026-11-10-Morning".
    static var current: String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/London") ?? .current
        let d = cal.dateComponents([.year, .month, .day, .hour], from: .now)
        return String(format: "%04d-%02d-%02d-", d.year ?? 0, d.month ?? 0, d.day ?? 0) + ((d.hour ?? 0) < 15 ? "Morning" : "Evening")
    }

    static var due: Bool { Shared.defaults.string(forKey: key) != current }
    static func markPlayed() { Shared.defaults.set(current, forKey: key) }

    /// What to play for a section: its opening first when one is due, then the briefing.
    static func urls(_ index: AudioIndex, _ section: String, voice: String) -> [URL]? {
        guard let main = index.url(section, voice) else { return nil }
        if due, let intro = index.url(section, "intro") {
            markPlayed()
            return [intro, main]
        }
        return [main]
    }
}

/// The spoken briefings the updater records each morning (/audio.json on the Scout service).
struct AudioIndex: Decodable {
    struct Voice: Decodable { let label: String; let name: String? }
    struct File: Decodable { let path: String }
    struct Section: Decodable { let title: String?; let files: [String: File] }
    let voices: [String: Voice]
    let sections: [String: Section]
    /// The stories recorded ahead (the day's top 15).
    var stories: [String: File]? = nil
    /// The short "hold on" lines.
    var hold: [String]? = nil

    static var base: URL? {
        (Bundle.main.object(forInfoDictionaryKey: "ScoutStocksURL") as? String).flatMap(URL.init(string:))
    }

    func storyURL(_ id: String) -> URL? {
        stories?[id].flatMap { p in Self.base?.appending(path: String(p.path.dropFirst())) }
    }

    func holdURL() -> URL? {
        hold?.randomElement().flatMap { p in Self.base?.appending(path: String(p.dropFirst())) }
    }

    static func load() async -> AudioIndex? {
        guard let data = await Feed.fetchFromService("audio.json") ?? Feed.cached("audio.json") else { return nil }
        return try? Feed.decoder.decode(AudioIndex.self, from: data)
    }

    /// A recording's full address, e.g. …/audio/Tech-chirp.mp3.
    func url(_ section: String, _ voice: String) -> URL? {
        guard let path = sections[section]?.files[voice]?.path, let base = Self.base else { return nil }
        return base.appending(path: String(path.dropFirst()))
    }
}

/// A briefing's Listen button: the recording in Google's Chirp 3: HD voice, or the phone's voice
/// if the recording isn't ready yet. Each section tries a different design for now, to compare.
struct BriefingListen: View {
    enum Style { case pill, bar, bubble, player }

    let topic: Topic
    let brief: SectionBrief
    var style: Style = .pill
    var artwork: URL? = nil
    @ObservedObject private var speaker = Speaker.shared
    @State private var index: AudioIndex?
    @State private var showPlus = false
    @AppStorage(Plus.key) private var hasPlus = false

    static let voice = "chirp"

    /// The round button half over the picture's corner, for every section.
    static func style(for topic: Topic) -> Style { .bubble }

    private var id: String { "brief-\(topic.rawValue)-\(brief.generated?.timeIntervalSince1970 ?? 0)-\(Self.voice)" }
    private let visual = ListenVisual.bars

    /// About how long the briefing takes to hear.
    private var minutes: Int {
        let chars = Self.parts(brief).reduce(0) { $0 + $1.count }
        return max(1, Int((Double(chars) / 15.5 / 60).rounded()))
    }

    var body: some View {
        let on = speaker.isPlaying(id)
        let mine = speaker.playing == id
        Button {
            Task { await play() }
        } label: {
            switch style {
            case .pill: pill(on)
            case .bar: bar(on, mine)
            case .bubble: bubble(on)
            case .player: playerRow(on, mine)
            }
        }
        .buttonStyle(PressStyle())
        .sensoryFeedback(.selection, trigger: on)
        .accessibilityLabel(on ? "Pause the \(topic.title) briefing" : "Listen to the \(topic.title) briefing, \(minutes) minutes")
        .task { index = await AudioIndex.load() }
        .sheet(isPresented: $showPlus) { PlusSheet(reason: "Listening to the briefings is part of Scout Plus.") }
    }

    private func icon(_ on: Bool, size: CGFloat) -> some View {
        Image(systemName: on ? "pause.fill" : "play.fill")
            .font(.system(size: size * 0.38, weight: .black))
            .foregroundStyle(.white)
            .offset(x: on ? 0 : size * 0.04)
            .frame(width: size, height: size)
            .background(Theme.accent, in: Circle())
            .contentTransition(.symbolEffect(.replace))
    }

    /// 1. A small capsule on the picture.
    private func pill(_ on: Bool) -> some View {
        HStack(spacing: 7) {
            icon(on, size: 26)
            if on { PlaybackVisual(style: visual, playing: true, progress: speaker.progress, size: 18) }
            else { Text("\(minutes) min") }
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(Theme.text)
        .padding(.leading, 4).padding(.trailing, 11)
        .frame(height: 34)
        .background(Theme.card, in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
    }

    /// 2. A full-width accent bar under the picture.
    private func bar(_ on: Bool, _ mine: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: on ? "pause.fill" : "play.fill").font(.system(size: 15, weight: .black))
                .contentTransition(.symbolEffect(.replace))
            Text(on ? "Playing the briefing" : mine ? "Resume the briefing" : "Listen to the briefing")
            Spacer(minLength: 0)
            if on { PlaybackVisual(style: visual, playing: true, progress: speaker.progress, size: 20, tint: .white) }
            else { Text("\(minutes) min").opacity(0.8) }
        }
        .font(.system(size: 15, weight: .bold))
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .frame(height: 50)
        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// 3. A big round button half over the picture's corner.
    private func bubble(_ on: Bool) -> some View {
        ZStack {
            if on { PlaybackVisual(style: .pulse, playing: true, progress: speaker.progress, size: 74) }
            icon(on, size: 58)
                .overlay(Circle().strokeBorder(Theme.card, lineWidth: 3))
                .overlay(alignment: .topTrailing) {
                    if !hasPlus {
                        Image(systemName: "lock.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.text)
                            .frame(width: 20, height: 20).background(Theme.card, in: Circle())
                            .offset(x: 2, y: -2)
                    }
                }
        }
        .frame(width: 76, height: 76)
        .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
    }

    /// 4. A small player under the picture: play, a progress line and the time left.
    private func playerRow(_ on: Bool, _ mine: Bool) -> some View {
        HStack(spacing: 12) {
            icon(on, size: 40)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Listen").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.text)
                    Spacer()
                    Text(mine && speaker.duration > 0 ? Self.clock(speaker.duration - speaker.elapsed) : "\(minutes) min")
                        .font(Theme.number(12, weight: .semibold)).foregroundStyle(Theme.secondary)
                }
                if on { PlaybackVisual(style: visual, playing: true, progress: speaker.progress, size: 14, wide: true) }
                else {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.track)
                            Capsule().fill(Theme.accent).frame(width: g.size.width * (mine ? speaker.progress : 0))
                        }
                    }
                    .frame(height: 4)
                }
            }
        }
        .padding(12)
        .background(Theme.track.opacity(0.6), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    static func clock(_ s: Double) -> String {
        let t = max(0, Int(s.rounded()))
        return "-\(t / 60):" + String(format: "%02d", t % 60)
    }

    private func play() async {
        let title = "\(topic.title) briefing"
        guard hasPlus else { showPlus = true; return }
        if speaker.playing == id { speaker.toggle(); return }
        if index?.url(topic.rawValue, Self.voice) == nil { index = await AudioIndex.load() }
        let info = NowPlaying(title: brief.title, subtitle: title, artwork: artwork, section: topic.rawValue)
        if let index, let urls = Intro.urls(index, topic.rawValue, voice: Self.voice) {
            speaker.play(id, title: title, urls: urls, info: info)
        } else {
            speaker.play(id, title: title, parts: Self.parts(brief), info: info)
        }
        Stats.played("briefing", id: topic.rawValue, title: title)
    }

    static func parts(_ brief: SectionBrief) -> [String] {
        [brief.title, NewsStore.paragraphs(brief.summary).first ?? ""]
            + (brief.highlights.isEmpty ? brief.points.map(\.line) : brief.highlights.map { $0.label.isEmpty ? $0.text : "\($0.label). \($0.text)" })
    }
}

/// What the Listen widget's buttons do in the app: the recording in the chosen voice, or the
/// phone's voice reading the briefing when there's no recording yet. It waits until the sound has
/// actually started, so iOS keeps the app playing in the background.
@MainActor
enum PlayBriefing {
    static func run(section: String, voice: String = BriefingListen.voice) async {
        guard let topic = Topic(rawValue: section), Plus.isActive else { return }
        let briefing = Feed.cached(Feed.briefing).flatMap(Feed.decodeBriefing)
        let brief = briefing?.section(topic)
        let id = "brief-\(section)-\(brief?.generated?.timeIntervalSince1970 ?? 0)-\(voice)"
        let speaker = Speaker.shared
        if speaker.playing == id { speaker.toggle(); return }
        let info = NowPlaying(title: brief?.title ?? "\(topic.title) briefing", subtitle: "\(topic.title) briefing", section: section)
        if let index = await AudioIndex.load(), let urls = Intro.urls(index, section, voice: voice) {
            speaker.play(id, title: "\(topic.title) briefing", urls: urls, info: info)
            Stats.played("briefing", id: section, title: "\(topic.title) briefing")
            await speaker.waitUntilSounding()
        } else if let brief {
            speaker.play(id, title: "\(topic.title) briefing", parts: BriefingListen.parts(brief), info: info)
        }
    }
}
