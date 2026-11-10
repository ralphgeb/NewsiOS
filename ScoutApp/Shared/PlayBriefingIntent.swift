import AppIntents

/// Plays a section's spoken briefing from the Listen widget (or Shortcuts) without opening Scout.
/// An audio playback intent runs in the app in the background, so the briefing keeps playing.
struct PlayBriefingIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Play a Scout briefing"
    static var description = IntentDescription("Plays the morning briefing for a section.")

    /// Tech, Finance, World or Fashion.
    @Parameter(title: "Section") var section: String
    /// "chirp" (Chirp 3: HD, the Aoede voice).
    @Parameter(title: "Voice") var voice: String

    static var openAppWhenRun = false

    init() {}

    init(section: String, voice: String) {
        self.section = section
        self.voice = voice
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !WIDGET
        await PlayBriefing.run(section: section, voice: voice)
        #endif
        return .result()
    }
}
