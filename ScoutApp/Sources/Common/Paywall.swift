import SwiftUI

/// A look at Scout with a subscription, switched on in Settings: the first 12 stories in each list
/// are open, the rest sit under a veil in the page's own colours with a lock. Nothing is sold.
enum Paywall {
    static let key = "preview.paywall"
    static let freeStories = 12
}

/// The veil and the lock over a story; tapping it opens the Scout Plus page.
struct Locked: ViewModifier {
    let locked: Bool
    @State private var showPlus = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if locked {
                    ZStack {
                        Rectangle().fill(.ultraThinMaterial)
                        Theme.card.opacity(0.62)
                        LockBadge()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { showPlus = true }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Locked story")
                    .accessibilityAddTraits(.isButton)
                    .transition(.opacity)
                }
            }
            .sheet(isPresented: $showPlus) { PlusSheet().presentationDetents([.medium, .large]) }
    }
}

extension View {
    func locked(_ locked: Bool) -> some View { modifier(Locked(locked: locked)) }
}

/// A padlock in a soft disc in the main color.
struct LockBadge: View {
    var body: some View {
        ZStack {
            Circle().fill(Theme.ink).frame(width: 46, height: 46)
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
            Image(systemName: "lock.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.background)
        }
    }
}

/// Where a lock leads: what a subscription would include. A preview only.
struct PlusSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 22) {
            ScoutLogo().frame(width: 84, height: 84).padding(.top, 28)
            VStack(spacing: 6) {
                Text("Scout Plus").font(.system(size: 26, weight: .semibold)).tracking(-0.3).foregroundStyle(Theme.text)
                Text("Every story, every briefing, every region.")
                    .font(.system(size: 15)).foregroundStyle(Theme.secondary)
            }
            VStack(alignment: .leading, spacing: 12) {
                perk("Unlimited stories in For you and every section")
                perk("Morning and evening briefings for all four sections")
                perk("AI summaries for every stock you follow")
            }
            .padding(.horizontal, 8)
            Spacer(minLength: 0)
            VStack(spacing: 8) {
                Text("Coming soon")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity).frame(height: 50)
                    .background(Theme.ink, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .foregroundStyle(Theme.background)
                Button("Not now") { dismiss() }
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.secondary)
                    .frame(height: 36)
            }
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background.ignoresSafeArea())
    }

    private func perk(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.accent)
                .frame(width: 18).padding(.top, 2)
            Text(text).font(.system(size: 15)).foregroundStyle(Theme.text)
            Spacer(minLength: 0)
        }
    }
}
