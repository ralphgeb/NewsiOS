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
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            // Inside each tab, controls stay in the ink; only the tab bar uses the accent.
            TodayView(showSettings: $showSettings)
                .tint(Theme.ink)
                .tabItem { Label("Today", systemImage: "newspaper") }
                .tag(0)
            NewsView(showSettings: $showSettings)
                .tint(Theme.ink)
                .tabItem { Label("News", systemImage: "list.bullet.rectangle.portrait") }
                .tag(1)
            StocksView(showSettings: $showSettings)
                .tint(Theme.ink)
                .tabItem { Label("Stocks", systemImage: "chart.line.uptrend.xyaxis") }
                .tag(2)
            HistoryView(showSettings: $showSettings)
                .tint(Theme.ink)
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
                .tag(3)
        }
        // Colors are read when views draw, so a new look rebuilds the pages (the sheet stays open).
        .id(look.appearance)
        // the tab you're on is highlighted in the accent
        .tint(Theme.accent)
        .sensoryFeedback(.selection, trigger: tab)
        .task { await store.refreshIfStale() }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(store)
                .environmentObject(look)
                .environmentObject(weather)
                .environmentObject(tube)
        }
        .onOpenURL { url in
            // Widget taps open a page: scout://today, scout://news, scout://stocks, scout://history.
            // Settings closes and the page goes back to its top, wherever you'd left it.
            showSettings = false
            NotificationCenter.default.post(name: .scoutShowPage, object: url.host ?? "today")
            switch url.host {
            case "news": tab = 1
            case "stocks": tab = 2
            case "history", "saved": tab = 3
            default: tab = 0
            }
        }
    }
}

extension Notification.Name {
    /// A widget was tapped: the named page shows its top (story pages close).
    static let scoutShowPage = Notification.Name("scoutShowPage")
}
