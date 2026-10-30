import StoreKit
import SwiftUI

/// Scout Plus. Without it (the default) the summaries, the first stories of each list and the
/// look presets (for a minute) are free; the rest is locked. The purchase is a test for now:
/// nothing is charged.
enum Plus {
    static let key = "plus.active"
    static let sinceKey = "plus.since"
    /// "store" for a real (or sandbox) subscription, "test" for the pretend checkout.
    static let sourceKey = "plus.source"

    static var isActive: Bool { UserDefaults.standard.bool(forKey: key) }

    /// Before the App Store answers: "£0.99" in the UK, "$0.99" elsewhere.
    static var price: String {
        Locale.current.currency?.identifier == "GBP" ? "£0.99" : "$0.99"
    }
}

/// The Scout Plus subscription through the App Store (StoreKit 2): the product, buying it with
/// Apple's own sheet, and keeping Plus on while the subscription is active. In TestFlight the
/// purchase happens in Apple's sandbox, so nothing is charged.
@MainActor
final class PlusStore: ObservableObject {
    static let shared = PlusStore()
    static let productID = "com.ralphgeb.scout.plus.monthly"

    @Published private(set) var product: Product?
    private var updates: Task<Void, Never>?

    private init() {
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                if case .verified(let t) = result { await t.finish() }
                await self?.refresh()
            }
        }
        Task { await load(); await refresh() }
    }

    /// The price in your own currency ("£0.99" in London). The App Store gives it in the currency of
    /// the account's store, which for a TestFlight sandbox account can be another country's; the
    /// UK and US prices are both 0.99, so there it's shown in your currency.
    var price: String {
        guard let product else { return Plus.price }
        if let local = Locale.current.currency?.identifier, ["GBP", "USD"].contains(local),
           product.priceFormatStyle.currencyCode != local {
            return product.price.formatted(.currency(code: local))
        }
        return product.displayPrice
    }

    func load() async {
        product = try? await Product.products(for: [Self.productID]).first
    }

    /// Plus is on while an App Store subscription is active; a test purchase stays as it is.
    func refresh() async {
        var active = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let t) = result, t.productID == Self.productID, t.revocationDate == nil { active = true }
        }
        let d = UserDefaults.standard
        if active {
            if !d.bool(forKey: Plus.key) { d.set(Date.now.timeIntervalSince1970, forKey: Plus.sinceKey) }
            d.set(true, forKey: Plus.key)
            d.set("store", forKey: Plus.sourceKey)
        } else if d.string(forKey: Plus.sourceKey) == "store" {
            d.set(false, forKey: Plus.key)
        }
    }

    /// Apple's payment sheet (double-click to pay). True once the subscription is active.
    func purchase() async -> Bool {
        if product == nil { await load() }
        guard let product else { return false }
        guard let result = try? await product.purchase() else { return false }
        if case .success(let verification) = result, case .verified(let t) = verification {
            await t.finish()
            await refresh()
            return true
        }
        return false
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
    @ObservedObject private var plus = PlusStore.shared

    enum Step { case offer, confirm, paying, done }

    /// The sheet is as tall as what's in it, measured as it draws.
    @State private var height: CGFloat = 430

    var body: some View {
        VStack(spacing: 14) {
            ScoutLogo(animated: false).frame(width: 56, height: 56)
            if step == .done {
                welcome.transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else {
                offer.transition(.opacity)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 30)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity)
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { g in Color.clear.preference(key: SheetHeightKey.self, value: g.size.height) })
        .onPreferenceChange(SheetHeightKey.self) { h in if h > 0 { height = h } }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.background.ignoresSafeArea())
        .presentationDetents([.height(height)])
        .presentationDragIndicator(.visible)
        .animation(.smooth(duration: 0.35), value: step)
        .sensoryFeedback(.success, trigger: step == .done)
        .interactiveDismissDisabled(step == .paying)
    }

    private var offer: some View {
        VStack(spacing: 14) {
            VStack(spacing: 4) {
                Text("Scout Plus").font(.system(size: 22, weight: .semibold)).tracking(-0.3).foregroundStyle(Theme.text)
                Text(reason ?? "Every story, every briefing, every region.")
                    .font(.system(size: 14)).foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
            }
            VStack(alignment: .leading, spacing: 8) {
                perk("Every story in For you and every section")
                perk("Follow any stock, with its AI summary")
                perk("Your own colours, themes and app icons")
            }
            .padding(.horizontal, 8)
            if step == .offer || (step == .paying && plus.product != nil) {
                VStack(spacing: 8) {
                    Button { subscribe() } label: {
                        ZStack {
                            if step == .paying {
                                ProgressView().tint(Theme.background)
                            } else {
                                Text("Subscribe · \(plus.price) a month")
                            }
                        }
                            .font(.system(size: 16, weight: .semibold))
                            .frame(maxWidth: .infinity).frame(height: 52)
                            .background(Theme.ink, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .foregroundStyle(Theme.background)
                    }
                    .buttonStyle(PressStyle())
                    .disabled(step == .paying)
                    Text(plus.product == nil ? "Cancel any time. Test purchase: nothing is charged." : "Cancel any time in Settings. Renews monthly.")
                        .font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                }
                .padding(.top, 14)   // a little air between the perks and the button
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
                Text("\(plus.price)/mo").font(Theme.number(17, weight: .semibold)).foregroundStyle(Theme.text)
            }
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
            Button {
                step = .paying
                Task {
                    try? await Task.sleep(for: .milliseconds(1400))
                    hasPlus = true
                    since = Date.now.timeIntervalSince1970
                    UserDefaults.standard.set("test", forKey: Plus.sourceKey)
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
        }
        .padding(.vertical, 20)
    }

    /// Apple's own payment sheet when the App Store has the product; the test checkout otherwise.
    private func subscribe() {
        guard plus.product != nil else {
            withAnimation(.smooth) { step = .confirm }
            return
        }
        step = .paying
        Task {
            if await plus.purchase() {
                step = .done
                try? await Task.sleep(for: .milliseconds(1800))
                dismiss()
            } else {
                withAnimation(.smooth) { step = .offer }
            }
        }
    }

    private func perk(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.accent)
                .frame(width: 18).padding(.top, 2)
            Text(text).font(.system(size: 14)).foregroundStyle(Theme.text)
            Spacer(minLength: 0)
        }
    }
}

private struct SheetHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
