import AVFoundation
import UIKit
import MediaPlayer
import SwiftUI
import WidgetKit

/// How far through what's playing. Its own object, so the many views that only need to know
/// whether something is playing don't redraw four times a second.
@MainActor
final class PlaybackClock: ObservableObject {
    @Published private(set) var progress: Double = 0
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var duration: Double = 0

    func set(elapsed e: Double, duration d: Double) {
        let dur = d.isFinite && d > 0 ? d : 0
        if dur != duration { duration = dur }
        elapsed = e.isFinite ? max(0, e) : 0
        let p = dur > 0 ? min(1, elapsed / dur) : 0
        if abs(p - progress) > 0.002 || p == 0 { progress = p }
    }

    func reset() { progress = 0; elapsed = 0; duration = 0 }
}

/// Which tab is on screen and which tabs have a story open (there the tab bar steps aside for the
/// story's own bar). Apart from the player, so a tab change doesn't redraw every audio view.
@MainActor
final class TabBarState: ObservableObject {
    static let shared = TabBarState()
    @Published private(set) var storyPages: [Int: Int] = [:]
    @Published var currentTab = 0 { didSet { if currentTab == oldValue { return } } }
    var storyOnScreen: Bool { storyPages[currentTab, default: 0] > 0 }
    func storyPage(in tab: Int, open: Bool) {
        storyPages[tab] = max(0, storyPages[tab, default: 0] + (open ? 1 : -1))
    }
}

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
    /// Play my briefings: the Lock Screen shows Scout's own cover for the edition.
    var cover: Bool = false
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
    /// How far through: in its own object, so only the play buttons and the player redraw as it
    /// moves, not every page.
    let clock = PlaybackClock()
    var progress: Double { clock.progress }
    var elapsed: Double { clock.elapsed }
    var duration: Double { clock.duration }
    /// Titles for the recordings in a playlist (Play my briefings), shown as each one starts.
    private var itemTitles: [ObjectIdentifier: (title: String, subtitle: String)] = [:]
    private weak var lastTitledItem: AVPlayerItem?


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
    /// Watches the player itself, so pause and play from anywhere (Control Centre, headphones, a
    /// phone call) keep the buttons in the app right.
    private var statusObservation: NSKeyValueObservation?

    private override init() {
        super.init()
        synth.delegate = self
        // Control Centre, the Lock Screen and headphones: play and pause do exactly that (never a
        // toggle, which could do the opposite if the app and the player disagreed)
        let center = MPRemoteCommandCenter.shared()
        for c in [center.playCommand, center.pauseCommand, center.togglePlayPauseCommand, center.skipForwardCommand,
                  center.skipBackwardCommand, center.changePlaybackPositionCommand] { c.isEnabled = true }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resume() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.toggle() }; return .success }
        // a phone call or another app's sound pauses Scout; when it ends, Scout carries on
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let info = note.userInfo ?? [:]
            let type = (info[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            let options = (info[AVAudioSessionInterruptionOptionKey] as? UInt).map(AVAudioSession.InterruptionOptions.init(rawValue:))
            Task { @MainActor in
                guard let self, self.playing != nil else { return }
                if type == .began { self.pause() }
                else if type == .ended, options?.contains(.shouldResume) == true { self.resume() }
            }
        }
        // headphones unplugged: pause, as iOS apps do
        NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            Task { @MainActor in if reason == .oldDeviceUnavailable { self?.pause() } }
        }
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

    /// Plays recordings one after the other (the short opening, then the briefing). `titles`, if
    /// given, names each recording for the Lock Screen as it starts.
    func play(_ id: String, title: String, urls: [URL], info: NowPlaying? = nil, titles: [(title: String, subtitle: String)] = []) {
        if playing == id { toggle(); return }
        guard !urls.isEmpty else { return }
        stop()
        let items = urls.map { AVPlayerItem(url: $0) }
        itemTitles = [:]
        for (item, t) in zip(items, titles) { itemTitles[ObjectIdentifier(item)] = t }
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
                .appending(queryItems: [URLQueryItem(name: "wav", value: "1")])   // this build plays Gemini's WAV recordings
            let recorded = index?.storyURL(s.id) != nil
            // fetch the recording; if it takes more than a second, the hold-on line starts
            let fetch = Task { () -> URL? in
                guard let url else { return nil }
                var req = URLRequest(url: url)
                req.timeoutInterval = 45
                guard let (data, resp) = try? await URLSession.shared.data(for: req),
                      (resp as? HTTPURLResponse)?.statusCode == 200, data.count > 1000 else { return nil }
                let wav = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")?.contains("wav") == true
                let file = FileManager.default.temporaryDirectory.appending(path: "story-\(s.id).\(wav ? "wav" : "mp3")")
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
        if paused { resume() } else { pause() }
    }

    func pause() {
        guard playing != nil, !paused else { return }
        if let player { player.pause() } else { synth.pauseSpeaking(at: .word) }
        paused = true
        updateNowPlaying()
    }

    func resume() {
        guard playing != nil, paused else { return }
        activateSession()      // the session may have been taken by a call or another app
        if let player { player.play() } else { synth.continueSpeaking() }
        paused = false
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
        clock.reset()
        artwork = nil
        if info.cover, let img = NowPlayingArt.cover(edition: Intro.edition) {
            artwork = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
        }
        updateNowPlaying()
        if !info.cover {
            Task { [weak self] in
                var picture: UIImage?
                if let url = info.artwork { picture = await ImageLoader.shared.image(url) }
                guard let self, self.playing == id, let img = NowPlayingArt.badged(picture) else { return }
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
        statusObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            let status = p.timeControlStatus
            let hasItem = p.currentItem != nil
            Task { @MainActor in
                guard let self, self.player === p, !self.preparing, hasItem else { return }
                // the player is the truth: paused from anywhere shows as paused here too
                if status == .playing, self.paused { self.paused = false; self.updateNowPlaying() }
                if status == .paused, !self.paused { self.paused = true; self.updateNowPlaying() }
            }
        }
        self.player = player
        player.play()
    }

    private func tick(_ t: CMTime) {
        guard let item = player?.currentItem else { return }
        // the hold-on line doesn't count; each recording in a playlist counts on its own
        guard !preparing else { return }
        if item !== lastTitledItem {
            lastTitledItem = item
            if let t = itemTitles[ObjectIdentifier(item)], var n = now {
                n.title = t.title; n.subtitle = t.subtitle; now = n
            }
            clock.set(elapsed: t.seconds, duration: item.duration.seconds)
            updateNowPlaying()
            return
        }
        let wasKnown = clock.duration > 0
        clock.set(elapsed: t.seconds, duration: item.duration.seconds)
        // the Lock Screen works out the time itself from the rate; tell it when the length is
        // first known, and every few seconds so it stays in step
        if (!wasKnown && clock.duration > 0) || Int(t.seconds * 4) % 20 == 0 { updateNowPlaying() }
    }

    private func finish() {
        statusObservation?.invalidate()
        statusObservation = nil
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
        clock.reset()
        itemTitles = [:]
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
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = player?.currentTime().seconds ?? elapsed
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
    /// TestFlight: hear the opening again.
    static func reset() { Shared.defaults.removeObject(forKey: key) }
    /// "Morning" or "Evening", now.
    static var edition: String { current.hasSuffix("Evening") ? "Evening" : "Morning" }
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
    /// Links between briefings, per section: "middle" ("Moving on to…") and "last" ("And finally…").
    var transitions: [String: [String: [File]]]? = nil

    func transitionURL(_ section: String, last: Bool) -> URL? {
        transitions?[section]?[last ? "last" : "middle"]?.randomElement().flatMap { f in Self.base?.appending(path: String(f.path.dropFirst())) }
    }

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
    @ObservedObject private var clock = Speaker.shared.clock
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
            if on { PlaybackVisual(style: visual, playing: true, progress: clock.progress, size: 18) }
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
            if on { PlaybackVisual(style: visual, playing: true, progress: clock.progress, size: 20, tint: .white) }
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
            if on { PlaybackVisual(style: .pulse, playing: true, progress: clock.progress, size: 74) }
            icon(on, size: 58)
                .overlay(Circle().strokeBorder(Theme.card, lineWidth: 3))

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
                    Text(mine && clock.duration > 0 ? Self.remaining(clock.duration - clock.elapsed) : "\(minutes) min")
                        .font(Theme.number(12, weight: .semibold)).foregroundStyle(Theme.secondary)
                }
                if on { PlaybackVisual(style: visual, playing: true, progress: clock.progress, size: 14, wide: true) }
                else {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.track)
                            Capsule().fill(Theme.accent).frame(width: g.size.width * (mine ? clock.progress : 0))
                        }
                    }
                    .frame(height: 4)
                }
            }
        }
        .padding(12)
        .background(Theme.track.opacity(0.6), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    static func remaining(_ s: Double) -> String {
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

/// Pictures for the Lock Screen and Control Centre: Scout's own cover for a full briefing ("Your
/// morning briefing", the date), and for anything else its picture with Scout's mark in the corner.
@MainActor
enum NowPlayingArt {
    static func cover(edition: String) -> UIImage? {
        let r = ImageRenderer(content: Cover(edition: edition))
        r.scale = 3
        return r.uiImage
    }

    static func badged(_ picture: UIImage?) -> UIImage? {
        let r = ImageRenderer(content: Badged(picture: picture))
        r.scale = 3
        return r.uiImage
    }

    private struct Cover: View {
        let edition: String
        var body: some View {
            ZStack {
                LinearGradient(colors: [Color(red: 0.07, green: 0.11, blue: 0.19), Color(red: 0.12, green: 0.17, blue: 0.29)],
                               startPoint: .top, endPoint: .bottom)
                Circle().fill(Color(red: 0.89, green: 0.33, blue: 0.33).opacity(0.18)).frame(width: 260).offset(x: 90, y: -110).blur(radius: 30)
                VStack(alignment: .leading, spacing: 10) {
                    ScoutMark(color: .white).frame(width: 64, height: 64)
                    Spacer()
                    Text("Your \(edition.lowercased()) briefing")
                        .font(.system(size: 30, weight: .heavy)).tracking(-0.5).foregroundStyle(.white)
                    Text(Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                        .font(.system(size: 17, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
                    HStack(spacing: 6) {
                        Circle().fill(Color(red: 0.89, green: 0.33, blue: 0.33)).frame(width: 8, height: 8)
                        Text("SCOUT").font(.system(size: 12, weight: .bold)).tracking(2).foregroundStyle(.white.opacity(0.6))
                    }
                    .padding(.top, 6)
                }
                .padding(28)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
            .frame(width: 300, height: 300)
        }
    }

    private struct Badged: View {
        let picture: UIImage?
        var body: some View {
            ZStack(alignment: .bottomLeading) {
                if let picture {
                    Image(uiImage: picture).resizable().scaledToFill().frame(width: 300, height: 300).clipped()
                } else {
                    LinearGradient(colors: [Color(red: 0.07, green: 0.11, blue: 0.19), Color(red: 0.12, green: 0.17, blue: 0.29)],
                                   startPoint: .top, endPoint: .bottom)
                }
                ScoutMark(color: .white)
                    .frame(width: 30, height: 30)
                    .padding(7)
                    .background(Color(red: 0.07, green: 0.11, blue: 0.19).opacity(0.85), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .padding(14)
            }
            .frame(width: 300, height: 300)
        }
    }
}
