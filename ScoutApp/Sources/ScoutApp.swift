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
    private static let refreshID = "com.ralphgeb.scout.refresh"

    init() {
        // iOS wakes the app in the background now and then; each time Scout checks for a new
        // briefing, posts the morning notification if one's arrived, and refreshes the widget.
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshID, using: nil) { task in
            Self.scheduleRefresh()
            let work = Task {
                if let data = try? await Feed.fetch(Feed.briefing), let b = Feed.decodeBriefing(data) {
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
            RootView()
                .environmentObject(store)
                .environmentObject(look)
                .environmentObject(weather)
                .environmentObject(tube)
                .environmentObject(stocks)
                .preferredColorScheme(look.appearance.mode.colorScheme)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                Task {
                    await store.refreshIfStale()
                    // you've seen this one in the app, so it won't notify later
                    Notifier.markSeen(store.briefing)
                }
                Task { await weather.refresh() }
                Task { await tube.refresh() }
            case .background:
                Self.scheduleRefresh()
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
    @State private var showTopics = !Shared.hasChosenTopic
    @State private var tab = 0
    /// When you last looked at Rumours, for the badge of new ones.
    @AppStorage("rumours.seen") private var rumoursSeen = Date.now.timeIntervalSince1970

    var body: some View {
        TabView(selection: $tab) {
            TodayView(showSettings: $showSettings)
                .tabItem { Label("Today", systemImage: "newspaper") }
                .tag(0)
            NewsView(showSettings: $showSettings)
                .tabItem { Label("News", systemImage: "list.bullet.rectangle.portrait") }
                .tag(1)
            StocksView(showSettings: $showSettings)
                .tabItem { Label("Stocks", systemImage: "chart.line.uptrend.xyaxis") }
                .tag(4)
            RumoursView(showSettings: $showSettings)
                .tabItem { Label("Rumours", systemImage: "dot.radiowaves.left.and.right") }
                .badge(tab == 2 ? 0 : newRumours)
                .tag(2)
            SavedView(showSettings: $showSettings)
                .tabItem { Label("Saved", systemImage: "bookmark") }
                .tag(3)
        }
        // Colors are read when views draw, so a new look rebuilds the pages (the sheet stays open).
        .id(look.appearance)
        .tint(Theme.ink)
        .sensoryFeedback(.selection, trigger: tab)
        .onChange(of: tab) { old, new in
            if old == 2 || new == 2 { rumoursSeen = Date.now.timeIntervalSince1970 }
        }
        .task { await store.refreshIfStale() }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(store)
                .environmentObject(look)
                .environmentObject(weather)
                .preferredColorScheme(look.appearance.mode.colorScheme)
        }
        .sheet(isPresented: $showTopics) {
            TopicPicker()
                .environmentObject(store)
                .presentationDetents([.medium, .large])
                .interactiveDismissDisabled(!Shared.hasChosenTopic)
                .preferredColorScheme(look.appearance.mode.colorScheme)
        }
        .onOpenURL { url in
            // Widget taps open a page: scout://today, scout://news, scout://stocks, scout://rumours, scout://saved
            switch url.host {
            case "news": tab = 1
            case "stocks": tab = 4
            case "rumours": tab = 2
            case "saved": tab = 3
            default: tab = 0
            }
        }
    }

    private var newRumours: Int {
        let seen = Date(timeIntervalSince1970: rumoursSeen)
        return store.stories.filter { $0.isRumour && ($0.firstSeen ?? .distantPast) > seen }.count
    }
}
