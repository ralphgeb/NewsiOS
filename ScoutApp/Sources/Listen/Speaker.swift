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

    func toggle() {
        guard playing != nil else { return }
        if paused { synth.continueSpeaking() } else { synth.pauseSpeaking(at: .word) }
        paused.toggle()
        updateNowPlaying()
    }

    func stop() {
        synth.stopSpeaking(at: .immediate)
        finish()
    }

    private func finish() {
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
