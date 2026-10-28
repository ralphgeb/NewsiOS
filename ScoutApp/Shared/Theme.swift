import SwiftUI
import UIKit

/// Scout's palette: a main color (ink), a text color and one accent, chosen in Settings as in Halo.
/// Everything else is ink or text at a lower opacity, so any palette stays coherent in light and dark.
enum Theme {
    static var ink: Color {
        Color(UIColor { Appearance.current.colors(for: $0.userInterfaceStyle).ink.uiColor })
    }

    static var accent: Color { Appearance.current.accent.color }

    static var background: Color {
        Color(UIColor { Appearance.current.colors(for: $0.userInterfaceStyle).background.uiColor })
    }

    static var card: Color {
        Color(UIColor { Appearance.current.colors(for: $0.userInterfaceStyle).card.uiColor })
    }

    /// Words: the Text color from Settings, or the main color when none is set.
    static var text: Color {
        Color(UIColor { Appearance.current.colors(for: $0.userInterfaceStyle).textColor.uiColor })
    }

    static var secondary: Color { text.opacity(0.5) }
    static var tertiary: Color { text.opacity(0.28) }
    static var track: Color { ink.opacity(0.08) }
    static var hairline: Color { ink.opacity(0.08) }

    // MARK: Type

    /// Big numbers in the chosen style, with fixed-width digits so counters don't wobble.
    static func number(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: Appearance.current.numberStyle.design).monospacedDigit()
    }

    /// Headlines in the chosen style.
    static func headline(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: Appearance.current.numberStyle.design)
    }

    /// Small uppercase labels.
    static let label = Font.system(size: 11, weight: .semibold)
    static let labelTracking: CGFloat = 1.1
}

extension View {
    /// Small uppercase label style used across the app.
    func scoutLabel() -> some View {
        self.font(Theme.label)
            .tracking(Theme.labelTracking)
            .textCase(.uppercase)
            .foregroundStyle(Theme.secondary)
    }

    /// The single card surface.
    func scoutCard(padding: CGFloat = 18) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

/// Halo's ring: ink on a quiet track, with the accent dot riding on the end of the arc.
struct Ring: View {
    var progress: Double
    var lineWidth: CGFloat = 8
    var showsTip = true

    var body: some View {
        ZStack {
            Circle().stroke(Theme.track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(progress, 1)))
                .stroke(Theme.ink, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if showsTip && progress > 0.02 {
                GeometryReader { geo in
                    let r = min(geo.size.width, geo.size.height) / 2
                    let a = Angle.degrees(-90 + 360 * min(progress, 1)).radians
                    Circle()
                        .fill(Theme.accent)
                        .frame(width: lineWidth * 0.55, height: lineWidth * 0.55)
                        .position(x: geo.size.width / 2 + r * cos(a), y: geo.size.height / 2 + r * sin(a))
                }
            }
        }
        .padding(lineWidth / 2)
    }
}
