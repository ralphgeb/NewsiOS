import SwiftUI

/// Scout Plus. Without it (the default) the summaries, the first stories of each list and the
/// look presets (for a minute) are free; the rest is locked. The purchase is a test for now:
/// nothing is charged.
enum Plus {
    static let key = "plus.active"
    static let sinceKey = "plus.since"

    static var isActive: Bool { UserDefaults.standard.bool(forKey: key) }

    /// "£1" in the UK, "$1" elsewhere.
    static var price: String {
        Locale.current.currency?.identifier == "GBP" ? "£1" : "$1"
    }
}

enum Paywall {
    /// Stories open before the first big picture card in each News list.
    static let freeStories = 8
}

/// A light veil over a whole card, so the text and pictures still show through, with one lock in
/// the middle; tapping it opens Scout Plus.
struct Locked: ViewModifier {
    let locked: Bool
    @State private var showPlus = false

    func body(content: Content) -> some View {
        content
            .blur(radius: locked ? 2.2 : 0)
            .allowsHitTesting(!locked)
            .overlay {
                if locked {
                    ZStack {
                        Theme.background.opacity(0.38)
                        LockBadge()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { showPlus = true }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Locked. Scout Plus")
                    .accessibilityAddTraits(.isButton)
                    .transition(.opacity)
                }
            }
            .sheet(isPresented: $showPlus) { PlusSheet() }
    }
}

extension View {
    func locked(_ locked: Bool) -> some View { modifier(Locked(locked: locked)) }
}

/// Just the padlock: soft white, with a shadow so it reads on light and dark cards.
struct LockBadge: View {
    var body: some View {
        Image(systemName: "lock.fill")
            .font(.system(size: 30, weight: .medium))
            .foregroundStyle(.white.opacity(0.92))
            .shadow(color: .black.opacity(0.35), radius: 10, y: 3)
            .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
    }
}

/// What Scout Plus includes, and a test checkout: confirm, a moment of processing, then a
/// welcome. Nothing is charged; Settings can end the test subscription.
struct PlusSheet: View {
    /// Why it opened, shown under the title ("Adding stocks is part of Scout Plus").
    var reason: String? = nil
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Plus.key) private var hasPlus = false
    @AppStorage(Plus.sinceKey) private var since = 0.0
    @State private var step = Step.offer

    enum Step { case offer, confirm, paying, done }

    var body: some View {
        VStack(spacing: 20) {
            ScoutLogo().frame(width: 84, height: 84).padding(.top, 24)
            if step == .done {
                welcome.transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else {
                offer.transition(.opacity)
            }
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background.ignoresSafeArea())
        .presentationDetents([.large])
        .animation(.smooth(duration: 0.35), value: step)
        .sensoryFeedback(.success, trigger: step == .done)
        .interactiveDismissDisabled(step == .paying)
    }

    private var offer: some View {
        VStack(spacing: 20) {
            VStack(spacing: 6) {
                Text("Scout Plus").font(.system(size: 26, weight: .semibold)).tracking(-0.3).foregroundStyle(Theme.text)
                Text(reason ?? "Every story, every briefing, every region.")
                    .font(.system(size: 15)).foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
            }
            VStack(alignment: .leading, spacing: 12) {
                perk("Every story in For you and every section")
                perk("Follow any stock, with its AI summary")
                perk("Your own colours and themes, kept")
                perk("Every morning\u{2019}s briefing for all four sections")
            }
            .padding(.horizontal, 8)
            Spacer(minLength: 0)
            if step == .offer {
                VStack(spacing: 8) {
                    Button { withAnimation(.smooth) { step = .confirm } } label: {
                        Text("Subscribe · \(Plus.price) a month")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(maxWidth: .infinity).frame(height: 52)
                            .background(Theme.ink, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .foregroundStyle(Theme.background)
                    }
                    .buttonStyle(PressStyle())
                    Text("Cancel any time.").font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                    Button("Not now") { dismiss() }
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.secondary)
                        .frame(height: 36)
                }
                .transition(.opacity)
            } else {
                confirm.transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    /// The confirm step: what you're buying and the price, then one tap.
    private var confirm: some View {
        VStack(spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Scout Plus").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
                    Text("Monthly · renews automatically").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                }
                Spacer()
                Text("\(Plus.price)/mo").font(Theme.number(17, weight: .semibold)).foregroundStyle(Theme.text)
            }
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
            Button {
                step = .paying
                Task {
                    try? await Task.sleep(for: .milliseconds(1400))
                    hasPlus = true
                    since = Date.now.timeIntervalSince1970
                    step = .done
                    try? await Task.sleep(for: .milliseconds(1800))
                    dismiss()
                }
            } label: {
                ZStack {
                    if step == .paying {
                        ProgressView().tint(Theme.background)
                    } else {
                        Text("Confirm").font(.system(size: 16, weight: .semibold))
                    }
                }
                .frame(maxWidth: .infinity).frame(height: 52)
                .background(Theme.ink, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .foregroundStyle(Theme.background)
            }
            .buttonStyle(PressStyle())
            .disabled(step == .paying)
            Text("Test purchase: you won\u{2019}t be charged.")
                .font(.system(size: 12)).foregroundStyle(Theme.tertiary)
            Button("Cancel") { withAnimation(.smooth) { step = .offer } }
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.secondary)
                .frame(height: 32)
                .disabled(step == .paying)
        }
        .padding(18)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var welcome: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(Theme.accent)
                .symbolEffect(.bounce, value: step == .done)
            Text("Welcome to Scout Plus").font(.system(size: 24, weight: .semibold)).tracking(-0.3).foregroundStyle(Theme.text)
            Text("Everything is unlocked.").font(.system(size: 15)).foregroundStyle(Theme.secondary)
            Spacer(minLength: 0)
        }
        .padding(.top, 20)
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
