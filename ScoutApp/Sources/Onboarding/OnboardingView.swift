import SwiftUI

/// The first thing a new install shows, before any permission is asked: the logo, what Scout is,
/// and why it would like your location. Three quiet pages, then Today.
struct OnboardingView: View {
    @EnvironmentObject private var weather: WeatherModel
    @EnvironmentObject private var store: NewsStore
    var finish: () -> Void
    @State private var page = 0
    @State private var nextReady = false

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                welcome.tag(0)
                howItWorks.tag(1)
                topics.tag(2)
                location.tag(3)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .animation(.smooth, value: page)

            // dots on the left say there's more to swipe; the next step sits small on the right
            HStack(alignment: .center) {
                HStack(spacing: 6) {
                    ForEach(0..<4) { i in
                        Capsule()
                            .fill(i == page ? Theme.ink : Theme.ink.opacity(0.18))
                            .frame(width: i == page ? 16 : 6, height: 6)
                    }
                }
                .animation(.snappy, value: page)
                .accessibilityLabel("Page \(page + 1) of 4")
                Spacer()
                if page == 3 {
                    Button("Not now") { done() }
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.secondary)
                        .padding(.trailing, 14)
                }
                Button {
                    if page < 3 {
                        page += 1
                    } else {
                        weather.requestPermission()
                        done()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(page < 3 ? "Next" : "Allow location")
                        Image(systemName: "arrow.right").font(.system(size: 13, weight: .semibold))
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .padding(.horizontal, 18)
                    .frame(height: 40)
                    .background(Theme.ink, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .foregroundStyle(Theme.background)
                }
                .buttonStyle(PressStyle())
                // on the first page, Next waits until the name and the line have faded in
                .opacity(page > 0 || nextReady ? 1 : 0)
                .disabled(page == 0 && !nextReady)
                .animation(.easeInOut(duration: 0.6), value: nextReady)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 18)
            .task {
                try? await Task.sleep(for: .seconds(4.8))
                nextReady = true
            }
        }
        .fontDesign(.default)
        .background(Theme.background.ignoresSafeArea())
        .sensoryFeedback(.selection, trigger: page)
    }

    private func done() {
        if !Shared.hasChosenTopic { Shared.topic = .tech }   // the widget's briefing, until changed in Settings
        finish()
    }

    // MARK: Pages

    private var topics: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("What do you follow?")
                        .font(.system(size: 26, weight: .semibold))
                        .tracking(-0.3)
                        .foregroundStyle(Theme.text)
                    Text(store.interests.count < 3
                         ? "Pick three or more topics. For you follows them, with the day's biggest stories mixed in."
                         : "\(store.interests.count) picked. You can change these any time in Settings.")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.text.opacity(0.65))
                        .contentTransition(.opacity)
                }
                RegionChips(compact: true)
                TopicChips(compact: true)
            }
            .padding(.horizontal, 24)
            .padding(.top, 28)
            .padding(.bottom, 12)
        }
        .scrollIndicators(.hidden)
    }

    private var welcome: some View {
        VStack(spacing: 26) {
            Spacer()
            ScoutLogo()
                .frame(width: 150, height: 150)   // the drawing fills about half: a logo of ~75 pt
            // the name, then the line, each fading up slowly once the logo has settled
            VStack(spacing: 6) {
                Reveal(delay: 1.8, duration: 1.8) {
                    Text("Scout")
                        .font(.system(size: 28, weight: .semibold))
                        .tracking(-0.3)
                        .foregroundStyle(Theme.text)
                }
                Reveal(delay: 3.0, duration: 1.8) {
                    Text("Your morning news, simplified.")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.secondary)
                }
            }
            Spacer()
            Spacer()
        }
        .padding(.horizontal, 32)
    }

    private var howItWorks: some View {
        VStack(alignment: .leading, spacing: 24) {
            Spacer()
            Text("One calm read\nwith your coffee")
                .font(.system(size: 26, weight: .semibold))
                .tracking(-0.3)
                .foregroundStyle(Theme.text)
                .padding(.bottom, 4)
            point("sun.horizon", "A briefing by 7:00",
                  "Every morning Scout reads about 150 news sites from the UK, the US, Europe and Asia, and writes briefings on what happened, why it matters and what to watch.")
            point("cup.and.saucer", "It doesn't break news",
                  "It gathers the night's breaking news into one short, clear front page, ready before your first coffee.")
            point("chart.line.uptrend.xyaxis", "The rest of your morning",
                  "A front page built around your topics, plus your stocks, the weather and the metro, all on Today.")
            Spacer()
        }
        .padding(.horizontal, 32)
    }

    private var location: some View {
        VStack(spacing: 18) {
            Spacer()
            WeatherIcon(name: "partly-day", size: 54)
                .padding(.bottom, 6)
            Text("Weather where you are")
                .font(.system(size: 26, weight: .semibold))
                .tracking(-0.3)
                .foregroundStyle(Theme.text)
                .multilineTextAlignment(.center)
            Text("Scout asks for your location only to show the weather for your area on Today. Just your rough area is used to fetch the forecast, and it isn't kept.\n\nWithout it, Scout shows the weather in London.")
                .font(.system(size: 15))
                .lineSpacing(2)
                .foregroundStyle(Theme.text.opacity(0.7))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Spacer()
        }
        .padding(.horizontal, 36)
    }

    private func point(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(Theme.accent)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
                Text(text).font(.system(size: 14)).lineSpacing(1.5).foregroundStyle(Theme.text.opacity(0.65))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Scout's icon without its tile, in the main color, alive: it grows out of the centre in one
/// movement, the hub first and the spokes stretching out with their nodes on the end, then the
/// nodes breathe gently. Still for Reduce Motion.
struct ScoutLogo: View {
    @State private var grown: Bool
    @State private var breathe = false
    private let animated: Bool

    /// Still (fully drawn, no breathing) where it's just a mark, like the Scout Plus sheet.
    init(animated: Bool = true) {
        self.animated = animated
        _grown = State(initialValue: !animated)
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // The app icon's layout (tools/make_icon.py), on a 1024 grid, relative to the hub.
    private struct Node { let x: CGFloat; let y: CGFloat; let r: CGFloat; let colour: Color }
    private static let red = Color(red: 226 / 255, green: 85 / 255, blue: 85 / 255)
    private static let grey = Color(red: 149 / 255, green: 154 / 255, blue: 162 / 255)
    private static let nodes = [
        Node(x: -200, y: -214, r: 70, colour: Theme.ink),
        Node(x: 176, y: -168, r: 76, colour: red),
        Node(x: -232, y: 10, r: 44, colour: grey),
        Node(x: -104, y: 262, r: 58, colour: Theme.ink),
        Node(x: 176, y: 170, r: 54, colour: Theme.ink),
    ]
    private static let hub = CGPoint(x: 518, y: 518)   // the drawing's centre, so it grows from the middle

    var body: some View {
        GeometryReader { geo in
            let k = geo.size.width / 1024
            let hub = CGPoint(x: Self.hub.x * k, y: Self.hub.y * k)
            ZStack {
                ForEach(Array(Self.nodes.enumerated()), id: \.offset) { i, n in
                    // each spoke follows a moment after the last, so it unfolds rather than snaps
                    let grow = Animation.spring(duration: 1.9, bounce: 0.18).delay(0.25 + Double(i) * 0.09)
                    let t: CGFloat = grown ? 1 : 0
                    let end = CGPoint(x: hub.x + n.x * k * t, y: hub.y + n.y * k * t)
                    Spoke(from: hub, to: CGPoint(x: hub.x + n.x * k, y: hub.y + n.y * k), progress: t)
                        .stroke(Theme.ink, style: StrokeStyle(lineWidth: 30 * k, lineCap: .round))
                        .animation(grow, value: grown)
                    Circle()
                        .fill(n.colour)
                        .frame(width: n.r * 2 * k, height: n.r * 2 * k)
                        .scaleEffect(grown ? 1 : 0.15)
                        .position(end)
                        .animation(grow, value: grown)
                        .scaleEffect(breathe ? 1.07 : 1)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 2.8).repeatForever().delay(Double(i) * 0.4), value: breathe)
                }
                Circle()
                    .fill(Theme.ink)
                    .frame(width: 184 * k, height: 184 * k)
                    .scaleEffect(grown ? 1 : 0.01)
                    .animation(.spring(duration: 1.4, bounce: 0.25), value: grown)
                    .scaleEffect(breathe ? 1.04 : 1)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 2.8).repeatForever(), value: breathe)
                    .position(hub)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel("Scout")
        .onAppear {
            guard !grown, animated else { return }
            if reduceMotion { grown = true; return }
            grown = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { breathe = true }
        }
    }
}

/// A line from the hub that stretches out to its node as progress goes from 0 to 1.
private struct Spoke: Shape {
    let from: CGPoint
    let to: CGPoint
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: from)
            p.addLine(to: CGPoint(x: from.x + (to.x - from.x) * progress, y: from.y + (to.y - from.y) * progress))
        }
    }
}

/// Fades its content up into place after a short wait.
private struct Reveal<Content: View>: View {
    let delay: Double
    var duration: Double = 0.8
    @ViewBuilder var content: Content
    @State private var shown = false

    var body: some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 6)
            .onAppear { withAnimation(.easeInOut(duration: duration).delay(delay)) { shown = true } }
    }
}
