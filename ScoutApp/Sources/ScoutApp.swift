import BackgroundTasks
import SwiftUI
import UserNotifications
import WidgetKit

@main
struct ScoutApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var store = NewsStore()
    @StateObject private var look = AppearanceStore()
    @StateObject private var weather = WeatherModel()
    @StateObject private var tube = TubeService()
    @StateObject private var stocks = StocksStore()
    @AppStorage("onboarded") private var onboarded = false
    private static let refreshID = "com.ralphgeb.scout.refresh"

    init() {
        // listens for App Store transactions (Scout Plus) from launch
        _ = PlusStore.shared
        // iOS wakes the app in the background now and then; each time Scout checks for a new
        // briefing, posts the morning notification if one's arrived, and refreshes the widget.
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshID, using: nil) { task in
            Self.scheduleRefresh()
            let work = Task {
                if let data = try? await Feed.fetchFresh(Feed.briefing), let b = Feed.decodeBriefing(data) {
                    await Notifier.notifyIfNew(b)
                }
                WidgetCenter.shared.reloadTimelines(ofKind: Shared.widgetKind)
                task.setTaskCompleted(success: true)
            }
            task.expirationHandler = { work.cancel() }
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                // A new install opens straight on the welcome, with nothing of the app behind it.
                if onboarded {
                    RootView().transition(.opacity)
                } else {
                    OnboardingView { withAnimation(.easeInOut(duration: 0.5)) { onboarded = true } }
                        .transition(.opacity)
                }
            }
                .environmentObject(store)
                .environmentObject(look)
                .environmentObject(weather)
                .environmentObject(tube)
                .environmentObject(stocks)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                AppearanceStore.applyStyle(look.appearance.mode)
                Task {
                    await store.refreshIfStale()
                    // you've seen this one in the app, so it won't notify later
                    Notifier.markSeen(store.briefing)
                }
                Task { await weather.refresh() }
                Task { await tube.refresh() }
            case .background:
                Self.scheduleRefresh()
                // picks up any color or topic change from this visit, in case a reload was skipped
                WidgetCenter.shared.reloadAllTimelines()
            default:
                break
            }
        }
    }

    static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 45 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}

/// Shows the morning notification even while Scout is open, and opens Today when it's tapped.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let s = response.notification.request.content.userInfo["url"] as? String, let url = URL(string: s) else { return }
        await MainActor.run { _ = UIApplication.shared.open(url) }
    }
}

struct RootView: View {
    @EnvironmentObject private var store: NewsStore
    @EnvironmentObject private var look: AppearanceStore
    @EnvironmentObject private var weather: WeatherModel
    @EnvironmentObject private var tube: TubeService
    @State private var showSettings = false
    @State private var showPlus = false
    @State private var tab = 0
    @Environment(\.horizontalSizeClass) private var sizeClass
    @AppStorage(WideLayout.key) private var wideSetting = WideLayout.defaultValue

    var body: some View {
        GeometryReader { g in
            if WideLayout.isWide(width: g.size.width, sizeClass: sizeClass, setting: wideSetting) {
                WideRoot(tab: $tab, showSettings: $showSettings)
            } else {
                tabs
            }
        }
        // Colors are read when views draw, so a new look rebuilds the pages (the sheet stays open).
        .id(look.appearance)
        .sensoryFeedback(.selection, trigger: tab)
        .onChange(of: tab, initial: true) { _, t in TabBarState.shared.currentTab = t }
        .task { await store.refreshIfStale() }
        .sheet(isPresented: $showPlus) { PlusSheet(reason: "Listening to the briefings is part of Scout Plus.") }
        .task { Plus.share() }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(store)
                .environmentObject(look)
                .environmentObject(weather)
                .environmentObject(tube)
        }
        .onOpenURL { open($0) }
        // the simulator screenshots start the app on a page (-scoutStartURL scout://stocks)
        .task {
            if let s = UserDefaults.standard.string(forKey: "scoutStartURL"), let url = URL(string: s) {
                try? await Task.sleep(for: .seconds(2))
                open(url)
            }
        }
    }

    /// Widget taps open a page: scout://today, scout://news?section=Tech, scout://story/<id>,
    /// scout://stocks, scout://history. Settings closes and the page starts from its top
    /// (or the story), wherever you'd left it.
    private func open(_ url: URL) {
            showSettings = false
            if url.host == "plus" { showPlus = true; return }    // a locked widget button
            DeepLink.pending = url          // for a page that isn't on screen yet (a cold start)
            NotificationCenter.default.post(name: .scoutShowPage, object: url)
            switch url.host {
            case "news", "story": tab = 1
            case "stocks": tab = 2
            case "history", "saved": tab = 3
            default: tab = 0
            }
    }

    /// The phone layout: the four tabs along the bottom.
    private var tabs: some View {
        TabView(selection: Binding(get: { tab }, set: { new in
            // tapping the tab you're already on goes back to the top of its page
            if new == tab { NotificationCenter.default.post(name: .scoutScrollTop, object: new) }
            tab = new
        })) {
            // Inside each tab, controls stay in the ink; only the tab bar uses the accent.
            TodayView(showSettings: $showSettings)
                .storyTab(0)
                .nowPlayingInset()
                .storyZoomScope()
                .tint(Theme.ink)
                .tabItem { Label("Today", systemImage: "newspaper") }
                .tag(0)
            NewsView(showSettings: $showSettings)
                .storyTab(1)
                .nowPlayingInset()
                .storyZoomScope()
                .tint(Theme.ink)
                .tabItem { Label("Briefings", systemImage: "list.bullet.rectangle.portrait") }
                .tag(1)
            StocksView(showSettings: $showSettings)
                .storyTab(2)
                .nowPlayingInset()
                .storyZoomScope()
                .tint(Theme.ink)
                .tabItem { Label("Stocks", systemImage: "chart.line.uptrend.xyaxis") }
                .tag(2)
            HistoryView(showSettings: $showSettings)
                .storyTab(3)
                .nowPlayingInset()
                .storyZoomScope()
                .tint(Theme.ink)
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
                .tag(3)
        }
        // iOS 26: the tab bar shrinks to a circle while you scroll down, and what's playing sits
        // beside it (or above it, full width, when it's open)
        .modifier(PlayerTabBar())
        // the tab you're on is highlighted in the accent
        .tint(Theme.accent)
    }
}

extension Notification.Name {
    /// A widget was tapped: the named page shows its top (story pages close).
    static let scoutShowPage = Notification.Name("scoutShowPage")
    /// The tab that's already showing was tapped again: its page goes back to the top.
    static let scoutScrollTop = Notification.Name("scoutScrollTop")
}

/// The last widget link, kept until the page it's for has opened it.
@MainActor
enum DeepLink {
    static var pending: URL?
}


/// The tab bar: always open, except while audio plays, when it shrinks as you scroll down (iOS 26)
/// with the player as its accessory (iOS 26.1).
private struct PlayerTabBar: ViewModifier {
    @ObservedObject private var speaker = Speaker.shared
    @ObservedObject private var bar = TabBarState.shared

    func body(content: Content) -> some View {
        if #available(iOS 26.1, *) {
            // the tab bar stays open, and shrinks to a circle beside the player only while audio plays
            content
                .tabBarMinimizeBehavior(speaker.now != nil ? .onScrollDown : .never)
                .tabViewBottomAccessory(isEnabled: speaker.now != nil && !bar.storyOnScreen) { NowPlayingAccessory() }
        } else if #available(iOS 26, *) {
            content.tabBarMinimizeBehavior(speaker.now != nil ? .onScrollDown : .never)
        } else {
            content
        }
    }
}

private struct ScoutTabKey: EnvironmentKey { static let defaultValue = 0 }

extension EnvironmentValues {
    /// Which tab a page is in (0 Today, 1 Briefings, 2 Stocks, 3 History).
    var scoutTab: Int {
        get { self[ScoutTabKey.self] }
        set { self[ScoutTabKey.self] = newValue }
    }
}

extension View {
    /// A tab hides its tab bar while one of its stories is open. It's set here, on the tab, rather
    /// than on the story, so the tab bar comes straight back as soon as you start going back.
    func storyTab(_ tab: Int) -> some View { modifier(StoryTab(tab: tab)) }
}

private struct StoryTab: ViewModifier {
    let tab: Int
    @ObservedObject private var bar = TabBarState.shared

    func body(content: Content) -> some View {
        content
            .environment(\.scoutTab, tab)
            .toolbar(bar.storyPages[tab, default: 0] > 0 ? .hidden : .visible, for: .tabBar)
    }
}
