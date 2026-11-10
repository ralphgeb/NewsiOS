import Foundation

/// What the app tells the Listen widget: which section's briefing is playing, and if it's paused.
enum ListenState {
    static let widgetKind = "ScoutListen"
    static let sectionKey = "listen.section"
    static let pausedKey = "listen.paused"

    /// The section playing right now (Tech, Finance…), nil when quiet.
    static var section: String? { Shared.defaults.string(forKey: sectionKey) }
    static var paused: Bool { Shared.defaults.bool(forKey: pausedKey) }

    static func isPlaying(_ section: String) -> Bool { self.section == section && !paused }
}
