import SwiftUI

/// The first thing a new install shows, before any permission is asked: the logo, what Scout is,
/// and why it would like your location. Three quiet pages, then Today.
struct OnboardingView: View {
    @EnvironmentObject private var weather: WeatherModel
    var finish: () -> Void
    @State private var page = 0

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                welcome.tag(0)
                howItWorks.tag(1)
                location.tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .animation(.smooth, value: page)

            HStack(spacing: 7) {
                ForEach(0..<3) { i in
                    Capsule()
                        .fill(i == page ? Theme.ink : Theme.track)
                        .frame(width: i == page ? 18 : 7, height: 7)
                }
            }
            .animation(.snappy, value: page)
            .padding(.bottom, 22)

            buttons
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
        }
        .background(Theme.background.ignoresSafeArea())
        .sensoryFeedback(.selection, trigger: page)
    }

    // MARK: Pages

    private var welcome: some View {
        VStack(spacing: 28) {
            Spacer()
            ScoutLogo()
                .frame(width: 168, height: 168)
            Reveal(delay: 1.1) {
                VStack(spacing: 8) {
                    Text("Scout")
                        .font(Theme.headline(40, weight: .heavy))
                        .tracking(-0.8)
                        .foregroundStyle(Theme.text)
                    Text("Your morning news, simplified.")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Theme.secondary)
                }
            }
            Spacer()
            Spacer()
        }
        .padding(.horizontal, 32)
    }

    private var howItWorks: some View {
        VStack(alignment: .leading, spacing: 26) {
            Spacer()
            Text("One calm read\nwith your coffee")
                .font(Theme.headline(32, weight: .heavy))
                .tracking(-0.6)
                .foregroundStyle(Theme.text)
            point("sun.horizon", "A briefing by 7:00",
                  "Every morning Scout reads about 100 news sites and writes one briefing for Tech, Finance, World and Fashion: what happened, why it matters and what to watch.")
            point("cup.and.saucer", "It doesn't break news",
                  "Scout gathers the night's breaking news into one short, clear front page, so you're up to date before your first coffee is finished.")
            point("chart.line.uptrend.xyaxis", "The rest of your morning",
                  "The stocks you follow, the weather and the metro, all on Today.")
            Spacer()
        }
        .padding(.horizontal, 28)
    }

    private var location: some View {
        VStack(spacing: 22) {
            Spacer()
            ZStack {
                Circle().fill(Theme.card).frame(width: 112, height: 112)
                WeatherIcon(name: "partly-day", size: 64)
            }
            Text("Weather where you are")
                .font(Theme.headline(30, weight: .heavy))
                .tracking(-0.5)
                .foregroundStyle(Theme.text)
                .multilineTextAlignment(.center)
            Text("Scout asks for your location only to show the weather for your area on Today. Just your rough area is used to fetch the forecast, and it isn't kept.\n\nWithout it, Scout shows the weather in London.")
                .font(.system(size: 16))
                .foregroundStyle(Theme.text.opacity(0.75))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Spacer()
        }
        .padding(.horizontal, 32)
    }

    private func point(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.text)
                Text(text).font(.system(size: 15)).foregroundStyle(Theme.text.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Buttons

    @ViewBuilder private var buttons: some View {
        VStack(spacing: 6) {
            Button {
                if page < 2 {
                    page += 1
                } else {
                    weather.requestPermission()
                    finish()
                }
            } label: {
                Text(page < 2 ? "Next" : "Allow location")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(Theme.ink, in: Capsule())
                    .foregroundStyle(Theme.background)
            }
            .buttonStyle(PressStyle())

            Button(page < 2 ? " " : "Not now") { if page == 2 { finish() } }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.secondary)
                .frame(height: 40)
                .disabled(page < 2)
        }
    }
}

/// Scout's icon, alive: the spokes draw out from the hub, the white nodes breathe one after
/// another, and the red node glides in to its place. Slow and small on purpose.
struct ScoutLogo: View {
    @State private var drawn = false
    @State private var arrived = false
    @State private var breathe = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // The app icon's layout (tools/make_icon.py), on a 1024 grid, relative to the hub.
    private struct Node { let x: CGFloat; let y: CGFloat; let r: CGFloat; let colour: Color }
    private static let navy = Color(red: 19 / 255, green: 27 / 255, blue: 44 / 255)
    private static let red = Color(red: 226 / 255, green: 85 / 255, blue: 85 / 255)
    private static let grey = Color(red: 149 / 255, green: 154 / 255, blue: 162 / 255)
    private static let nodes = [
        Node(x: -200, y: -214, r: 70, colour: .white),
        Node(x: 176, y: -168, r: 76, colour: red),
        Node(x: -232, y: 10, r: 44, colour: grey),
        Node(x: -104, y: 262, r: 58, colour: .white),
        Node(x: 176, y: 170, r: 54, colour: .white),
    ]
    private static let hub = CGPoint(x: 530, y: 500)

    var body: some View {
        GeometryReader { geo in
            let k = geo.size.width / 1024
            let hub = CGPoint(x: Self.hub.x * k, y: Self.hub.y * k)
            ZStack {
                RoundedRectangle(cornerRadius: geo.size.width * 0.225, style: .continuous)
                    .fill(Self.navy)
                    .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
                ForEach(Array(Self.nodes.enumerated()), id: \.offset) { i, n in
                    let isRed = i == 1
                    // the red node starts further out, so it travels in towards the centre
                    let far: CGFloat = isRed && !arrived ? 1.7 : 1
                    let end = CGPoint(x: hub.x + n.x * k * far, y: hub.y + n.y * k * far)
                    Path { p in p.move(to: hub); p.addLine(to: end) }
                        .trim(from: 0, to: drawn ? 1 : 0)
                        .stroke(.white, style: StrokeStyle(lineWidth: 30 * k, lineCap: .round))
                    Circle()
                        .fill(n.colour)
                        .frame(width: n.r * 2 * k, height: n.r * 2 * k)
                        .scaleEffect(drawn ? (breathe && !isRed ? 1.08 : 1) : 0.2)
                        .opacity(isRed ? (arrived ? 1 : 0) : (drawn ? 1 : 0))
                        .position(end)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 2.4).repeatForever().delay(Double(i) * 0.35), value: breathe)
                }
                Circle()
                    .fill(.white)
                    .frame(width: 184 * k, height: 184 * k)
                    .scaleEffect(drawn ? (breathe ? 1.04 : 1) : 0.6)
                    .position(hub)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 2.4).repeatForever(), value: breathe)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel("Scout")
        .onAppear {
            guard !drawn else { return }
            if reduceMotion {
                drawn = true; arrived = true
                return
            }
            withAnimation(.easeOut(duration: 0.9)) { drawn = true }
            withAnimation(.spring(duration: 1.4, bounce: 0.15).delay(0.5)) { arrived = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { breathe = true }
        }
    }
}

/// Fades its content up into place after a short wait.
private struct Reveal<Content: View>: View {
    let delay: Double
    @ViewBuilder var content: Content
    @State private var shown = false

    var body: some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 10)
            .onAppear { withAnimation(.easeOut(duration: 0.8).delay(delay)) { shown = true } }
    }
}
