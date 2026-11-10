import AVFoundation
import MediaPlayer
import SwiftUI

/// Reads briefings and story summaries aloud with the iPhone's own voices: free, on the phone,
/// and it keeps going with the screen locked (with play and pause on the Lock Screen).
@MainActor
final class Speaker: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    static let shared = Speaker()

    /// What's being read ("story-<id>", "brief-Tech"…), nil when quiet.
    @Published private(set) var playing: String?
    @Published private(set) var paused = false

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

/// ▶︎ Listen / ❚❚ Pause, for a briefing card.
struct ListenButton: View {
    let id: String
    let title: String
    let parts: () -> [String]
    @ObservedObject private var speaker = Speaker.shared

    var body: some View {
        let on = speaker.isPlaying(id)
        Button {
            speaker.play(id, title: title, parts: parts())
        } label: {
            HStack(spacing: 6) {
                Image(systemName: on ? "pause.fill" : "play.fill").font(.system(size: 11, weight: .bold))
                Text(on ? "Pause" : (speaker.playing == id ? "Resume" : "Listen"))
            }
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 12).frame(height: 30)
            .background(on ? Theme.ink : Theme.track, in: Capsule())
            .foregroundStyle(on ? Theme.background : Theme.text)
            .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(PressStyle())
        .sensoryFeedback(.selection, trigger: on)
        .accessibilityLabel(on ? "Pause reading" : "Listen to \(title)")
    }
}

/// A briefing's Listen row: the phone's voice, and the two recorded voices to compare
/// (WaveNet and Chirp 3: HD) once the morning's recordings are ready.
struct BriefingListen: View {
    let topic: Topic
    let brief: SectionBrief
    @ObservedObject private var speaker = Speaker.shared
    @State private var index: AudioIndex?

    var body: some View {
        let base = "brief-\(topic.rawValue)-\(brief.generated?.timeIntervalSince1970 ?? 0)"
        // a recording is for this briefing when its title matches
        let recorded = index?.sections[topic.rawValue]?.title == brief.title
        HStack(spacing: 6) {
            chip(base + "-phone", "Phone", "iphone") {
                speaker.play(base + "-phone", title: "\(topic.title) briefing", parts: Self.parts(brief))
            }
            if recorded, let url = index?.url(topic.rawValue, "wavenet") {
                chip(base + "-wavenet", "WaveNet", "waveform") { speaker.play(base + "-wavenet", title: "\(topic.title) briefing", url: url) }
            }
            if recorded, let url = index?.url(topic.rawValue, "chirp") {
                chip(base + "-chirp", "Chirp HD", "waveform.badge.plus") { speaker.play(base + "-chirp", title: "\(topic.title) briefing", url: url) }
            }
            Spacer(minLength: 0)
        }
        .task { index = await AudioIndex.load() }
    }

    static func parts(_ brief: SectionBrief) -> [String] {
        [brief.title, NewsStore.paragraphs(brief.summary).first ?? ""]
            + (brief.highlights.isEmpty ? brief.points.map(\.line) : brief.highlights.map { $0.label.isEmpty ? $0.text : "\($0.label). \($0.text)" })
    }

    private func chip(_ id: String, _ label: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        let on = speaker.isPlaying(id)
        return Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: on ? "pause.fill" : "play.fill").font(.system(size: 10, weight: .bold))
                Text(label)
            }
            .font(.system(size: 12.5, weight: .semibold))
            .padding(.horizontal, 11).frame(height: 30)
            .background(on ? Theme.ink : Theme.track, in: Capsule())
            .foregroundStyle(on ? Theme.background : Theme.text)
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(on ? "Pause" : "Listen with the \(label) voice")
    }
}

/// What the Listen widget's buttons do in the app: the recording in the chosen voice when the
/// morning's is ready, the phone's voice reading the briefing otherwise.
@MainActor
enum PlayBriefing {
    static func run(section: String, voice: String) async {
        guard let topic = Topic(rawValue: section) else { return }
        let briefing = Feed.cached(Feed.briefing).flatMap(Feed.decodeBriefing)
        let brief = briefing?.section(topic)
        let id = "brief-\(section)-\(brief?.generated?.timeIntervalSince1970 ?? 0)-\(voice)"
        if voice != "phone", let index = await AudioIndex.load(),
           brief == nil || index.sections[section]?.title == brief?.title,
           let url = index.url(section, voice) {
            Speaker.shared.play(id, title: "\(topic.title) briefing", url: url)
        } else if let brief {
            Speaker.shared.play(id, title: "\(topic.title) briefing", parts: BriefingListen.parts(brief))
        }
    }
}
