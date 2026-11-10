import AVFoundation
import MediaPlayer
import SwiftUI
import WidgetKit

/// Reads briefings and story summaries aloud with the iPhone's own voices: free, on the phone,
/// and it keeps going with the screen locked (with play and pause on the Lock Screen).
@MainActor
final class Speaker: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    static let shared = Speaker()

    /// What's being read ("story-<id>", "brief-Tech"…), nil when quiet.
    @Published private(set) var playing: String? { didSet { if oldValue != playing { share() } } }
    @Published private(set) var paused = false { didSet { if oldValue != paused { share() } } }

    /// Tells the Listen widget which briefing is playing, so its button shows pause.
    private func share() {
        let section = playing.flatMap { id in id.hasPrefix("brief-") ? id.split(separator: "-").dropFirst().first.map(String.init) : nil }
        Shared.defaults.set(section, forKey: ListenState.sectionKey)
        Shared.defaults.set(paused, forKey: ListenState.pausedKey)
        WidgetCenter.shared.reloadTimelines(ofKind: ListenState.widgetKind)
    }

    private let synth = AVSpeechSynthesizer()
    /// A recorded briefing (WaveNet or Chirp 3: HD) plays here instead of the phone's voice.
    private var player: AVPlayer?
    private var endObserver: NSObjectProtocol?
    private var title = ""

    private override init() {
        super.init()
        synth.delegate = self
        let center = MPRemoteCommandCenter.shared()
        center.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.toggle() }; return .success }
        center.playCommand.addTarget { [weak self] _ in Task { @MainActor in self?.toggle() }; return .success }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.toggle() }; return .success }
    }

    func isPlaying(_ id: String) -> Bool { playing == id && !paused }

    /// Starts reading `parts` (a short pause between each), or pauses and resumes the same thing.
    func play(_ id: String, title: String, parts: [String]) {
        if playing == id { toggle(); return }
        stop()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        let voice = Self.bestVoice()
        for (i, part) in parts.enumerated() where !part.isEmpty {
            let u = AVSpeechUtterance(string: part)
            u.voice = voice
            u.rate = AVSpeechUtteranceDefaultSpeechRate * 1.02
            u.postUtteranceDelay = i == 0 ? 0.45 : 0.3
            synth.speak(u)
        }
        playing = id
        paused = false
        self.title = title
        updateNowPlaying()
    }

    /// Plays a recorded briefing from the Scout service, or pauses and resumes it.
    func play(_ id: String, title: String, url: URL) {
        if playing == id { toggle(); return }
        stop()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [])
        try? AVAudioSession.sharedInstance().setActive(true)
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.finish() }
        }
        self.player = player
        player.play()
        playing = id
        paused = false
        self.title = title
        updateNowPlaying()
    }

    /// Waits (up to 15 seconds) until a recording is really playing.
    func waitUntilSounding() async {
        for _ in 0..<60 {
            guard let player else { return }
            if player.timeControlStatus == .playing { return }
            try? await Task.sleep(for: .milliseconds(250))
        }
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

    func stop() {
        synth.stopSpeaking(at: .immediate)
        player?.pause()
        finish()
    }

    private func finish() {
        player = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        playing = nil
        paused = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func updateNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: "Scout",
            MPNowPlayingInfoPropertyPlaybackRate: paused ? 0.0 : 1.0,
        ]
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

/// The spoken briefings the updater records each morning (/audio.json on the Scout service).
struct AudioIndex: Decodable {
    struct Voice: Decodable { let label: String; let name: String? }
    struct File: Decodable { let path: String }
    struct Section: Decodable { let title: String?; let files: [String: File] }
    let voices: [String: Voice]
    let sections: [String: Section]

    static func load() async -> AudioIndex? {
        guard let data = await Feed.fetchFromService("audio.json") ?? Feed.cached("audio.json") else { return nil }
        return try? Feed.decoder.decode(AudioIndex.self, from: data)
    }

    /// A recording's full address, e.g. …/audio/Tech-chirp.mp3.
    func url(_ section: String, _ voice: String) -> URL? {
        guard let path = sections[section]?.files[voice]?.path,
              let s = Bundle.main.object(forInfoDictionaryKey: "ScoutStocksURL") as? String, let base = URL(string: s) else { return nil }
        return base.appending(path: String(path.dropFirst()))
    }
}

/// The big Listen button that sits on a briefing's picture: the morning's recording in Google's
/// Chirp 3: HD voice, or the phone's voice if the recording isn't ready yet.
struct BriefingListen: View {
    let topic: Topic
    let brief: SectionBrief
    @ObservedObject private var speaker = Speaker.shared
    @State private var index: AudioIndex?

    static let voice = "chirp"

    private var id: String { "brief-\(topic.rawValue)-\(brief.generated?.timeIntervalSince1970 ?? 0)-\(Self.voice)" }

    /// About how long the briefing takes to hear.
    private var minutes: Int {
        let chars = Self.parts(brief).reduce(0) { $0 + $1.count }
        return max(1, Int((Double(chars) / 15.5 / 60).rounded()))
    }

    var body: some View {
        let on = speaker.isPlaying(id)
        Button {
            Task { await play() }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: on ? "pause.fill" : "play.fill")
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(Theme.accent, in: Circle())
                    .contentTransition(.symbolEffect(.replace))
                if on {
                    Image(systemName: "waveform")
                        .font(.system(size: 12, weight: .semibold))
                        .symbolEffect(.variableColor.iterative, isActive: true)
                } else {
                    Text("\(minutes) min")
                }
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.text)
            .padding(.leading, 4).padding(.trailing, 11)
            .frame(height: 32)
            .background(Theme.card, in: Capsule())
            .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        }
        .buttonStyle(PressStyle())
        .sensoryFeedback(.selection, trigger: on)
        .accessibilityLabel(on ? "Pause the \(topic.title) briefing" : "Listen to the \(topic.title) briefing, \(minutes) minutes")
        .task { index = await AudioIndex.load() }
    }

    private func play() async {
        let title = "\(topic.title) briefing"
        if speaker.playing == id { speaker.toggle(); return }
        if index?.url(topic.rawValue, Self.voice) == nil { index = await AudioIndex.load() }
        if let url = index?.url(topic.rawValue, Self.voice) {
            speaker.play(id, title: title, url: url)
        } else {
            speaker.play(id, title: title, parts: Self.parts(brief))
        }
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
        guard let topic = Topic(rawValue: section) else { return }
        let briefing = Feed.cached(Feed.briefing).flatMap(Feed.decodeBriefing)
        let brief = briefing?.section(topic)
        let id = "brief-\(section)-\(brief?.generated?.timeIntervalSince1970 ?? 0)-\(voice)"
        let speaker = Speaker.shared
        if speaker.playing == id { speaker.toggle(); return }
        if let url = await AudioIndex.load()?.url(section, voice) {
            speaker.play(id, title: "\(topic.title) briefing", url: url)
            await speaker.waitUntilSounding()
        } else if let brief {
            speaker.play(id, title: "\(topic.title) briefing", parts: BriefingListen.parts(brief))
        }
    }
}
