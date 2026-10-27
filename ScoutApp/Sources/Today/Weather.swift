import CoreLocation
import SwiftUI

/// Live weather for Today, from Open-Meteo (free, no key). Your location by default, or London.
@MainActor
final class WeatherService: NSObject, ObservableObject {
    struct Hour: Identifiable {
        let time: Date
        let temperature: Double
        let code: Int
        let isDay: Bool
        var id: Date { time }
    }

    struct Report {
        let place: String
        let temperature: Double
        let code: Int
        let isDay: Bool
        let high: Double?
        let low: Double?
        let rainChance: Int?
        let hours: [Hour]
        let fetched: Date
    }

    enum Mode: String, CaseIterable, Identifiable {
        case location, london
        var id: String { rawValue }
        var title: String { self == .location ? "My location" : "London" }
    }

    static let modeKey = "weather.mode"
    @Published private(set) var report: Report?
    @Published private(set) var failed = false
    @Published private(set) var isLoading = false

    private let manager = CLLocationManager()
    private var waiting: CheckedContinuation<CLLocation?, Never>?
    private var placeCache: (CLLocation, String)?
    private static let london = CLLocation(latitude: 51.5072, longitude: -0.1276)

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    var mode: Mode { Mode(rawValue: UserDefaults.standard.string(forKey: Self.modeKey) ?? "") ?? .location }

    /// Fetches again when the weather is more than ten minutes old, or when forced.
    func refresh(force: Bool = false) async {
        if !force, let r = report, Date.now.timeIntervalSince(r.fetched) < 10 * 60 { return }
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let spot = await location()
        let place = await placeName(spot)
        do {
            report = try await Self.fetch(spot, place: place)
            failed = false
        } catch {
            failed = report == nil
        }
    }

    private func location() async -> CLLocation {
        guard mode == .location else { return Self.london }
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()   // asks once; the answer refreshes the card
            return Self.london
        case .denied, .restricted:
            return Self.london
        default:
            break
        }
        if let last = manager.location, Date.now.timeIntervalSince(last.timestamp) < 3 * 3600 { return last }
        let found = await withCheckedContinuation { (c: CheckedContinuation<CLLocation?, Never>) in
            waiting?.resume(returning: nil)
            waiting = c
            manager.requestLocation()
        }
        return found ?? Self.london
    }

    private func placeName(_ spot: CLLocation) async -> String {
        if spot === Self.london { return "London" }
        if let cached = placeCache, cached.0.distance(from: spot) < 3000 { return cached.1 }
        let marks = try? await CLGeocoder().reverseGeocodeLocation(spot)
        let name = marks?.first?.locality ?? marks?.first?.name ?? "Here"
        placeCache = (spot, name)
        return name
    }

    fileprivate func finish(_ location: CLLocation?) {
        waiting?.resume(returning: location)
        waiting = nil
    }

    // MARK: Open-Meteo

    private struct Response: Decodable {
        struct Current: Decodable { let temperature2m: Double; let weatherCode: Int; let isDay: Int }
        struct Hourly: Decodable { let time: [String]; let temperature2m: [Double]; let weatherCode: [Int]; let isDay: [Int] }
        struct Daily: Decodable { let temperature2mMax: [Double]; let temperature2mMin: [Double]; let precipitationProbabilityMax: [Int?]? }
        let utcOffsetSeconds: Int
        let current: Current
        let hourly: Hourly
        let daily: Daily
    }

    private static func fetch(_ spot: CLLocation, place: String) async throws -> Report {
        var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        c.queryItems = [
            .init(name: "latitude", value: String(format: "%.3f", spot.coordinate.latitude)),
            .init(name: "longitude", value: String(format: "%.3f", spot.coordinate.longitude)),
            .init(name: "current", value: "temperature_2m,weather_code,is_day"),
            .init(name: "hourly", value: "temperature_2m,weather_code,is_day"),
            .init(name: "daily", value: "temperature_2m_max,temperature_2m_min,precipitation_probability_max"),
            .init(name: "timezone", value: "auto"),
            .init(name: "forecast_days", value: "2"),
        ]
        let (data, _) = try await URLSession.shared.data(from: c.url!)
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        let r = try d.decode(Response.self, from: data)

        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        f.timeZone = TimeZone(secondsFromGMT: r.utcOffsetSeconds)
        let times = r.hourly.time.map { f.date(from: $0) }
        // every two hours for the next ten
        let start = times.firstIndex { ($0 ?? .distantPast) > .now } ?? 0
        var hours: [Hour] = []
        for i in stride(from: start, to: min(start + 10, times.count), by: 2) {
            guard let t = times[i], i < r.hourly.temperature2m.count, i < r.hourly.weatherCode.count else { continue }
            hours.append(Hour(time: t, temperature: r.hourly.temperature2m[i], code: r.hourly.weatherCode[i],
                              isDay: (r.hourly.isDay.indices.contains(i) ? r.hourly.isDay[i] : 1) == 1))
        }
        return Report(place: place, temperature: r.current.temperature2m, code: r.current.weatherCode,
                      isDay: r.current.isDay == 1, high: r.daily.temperature2mMax.first, low: r.daily.temperature2mMin.first,
                      rainChance: r.daily.precipitationProbabilityMax?.first ?? nil, hours: hours, fetched: .now)
    }
}

extension WeatherService: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let last = locations.last
        Task { @MainActor in self.finish(last) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.finish(nil) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            if status == .authorizedWhenInUse || status == .authorizedAlways { await self.refresh(force: true) }
        }
    }
}

/// WMO weather codes, as SF Symbols and words.
enum WeatherCode {
    static func symbol(_ code: Int, day: Bool) -> String {
        switch code {
        case 0: return day ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: return day ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51...57: return "cloud.drizzle.fill"
        case 65, 82: return "cloud.heavyrain.fill"
        case 61...67, 80...82: return "cloud.rain.fill"
        case 71...77, 85, 86: return "cloud.snow.fill"
        case 95...: return "cloud.bolt.rain.fill"
        default: return "cloud.fill"
        }
    }

    static func label(_ code: Int, day: Bool) -> String {
        switch code {
        case 0: return day ? "Sunny" : "Clear"
        case 1: return day ? "Mostly sunny" : "Mostly clear"
        case 2: return "Partly cloudy"
        case 3: return "Cloudy"
        case 45, 48: return "Foggy"
        case 51...57: return "Drizzle"
        case 65, 82: return "Heavy rain"
        case 61...67, 80...82: return "Rain"
        case 71...77, 85, 86: return "Snow"
        case 95...: return "Thunderstorms"
        default: return "Cloudy"
        }
    }
}

/// Now, today's high and low, and the next ten hours. Tap to refresh.
struct WeatherCard: View {
    @EnvironmentObject private var weather: WeatherService

    var body: some View {
        Button { Task { await weather.refresh(force: true) } } label: {
            content.scoutCard()
        }
        .buttonStyle(PressStyle())
        .task { await weather.refresh() }
        .accessibilityHint("Refreshes the weather")
    }

    @ViewBuilder
    private var content: some View {
        if let r = weather.report {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    HStack(spacing: 5) {
                        if weather.mode == .location, r.place != "London" {
                            Image(systemName: "location.fill").font(.system(size: 9))
                                .foregroundStyle(Theme.secondary)
                        }
                        Text(r.place).scoutLabel()
                    }
                    Spacer()
                    if weather.isLoading { ProgressView().controlSize(.mini) }
                }
                HStack(alignment: .center, spacing: 14) {
                    Text("\(Int(r.temperature.rounded()))°")
                        .font(Theme.number(48, weight: .light))
                        .foregroundStyle(Theme.ink)
                        .contentTransition(.numericText())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(WeatherCode.label(r.code, day: r.isDay))
                            .font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.ink)
                        HStack(spacing: 8) {
                            if let h = r.high, let l = r.low {
                                Text("H \(Int(h.rounded()))°  L \(Int(l.rounded()))°")
                            }
                            if let rain = r.rainChance, rain >= 20 {
                                Text("\(rain)% rain")
                            }
                        }
                        .font(Theme.number(13, weight: .medium)).foregroundStyle(Theme.secondary)
                    }
                    Spacer()
                    Image(systemName: WeatherCode.symbol(r.code, day: r.isDay))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Theme.ink, Theme.accent)
                        .font(.system(size: 34))
                }
                if !r.hours.isEmpty {
                    HStack(spacing: 0) {
                        ForEach(r.hours) { h in
                            VStack(spacing: 6) {
                                Text(h.time.formatted(.dateTime.hour(.defaultDigits(amPM: .abbreviated))))
                                    .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondary)
                                Image(systemName: WeatherCode.symbol(h.code, day: h.isDay))
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(Theme.ink.opacity(0.8), Theme.accent)
                                    .font(.system(size: 17))
                                    .frame(height: 22)
                                Text("\(Int(h.temperature.rounded()))°").font(Theme.number(15)).foregroundStyle(Theme.ink)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.top, 2)
                }
            }
        } else {
            HStack(spacing: 10) {
                Image(systemName: weather.failed ? "cloud.slash" : "cloud").foregroundStyle(Theme.tertiary)
                Text(weather.failed ? "Weather unavailable. Tap to try again." : "Loading the weather…")
                    .font(.system(size: 14)).foregroundStyle(Theme.secondary)
                Spacer()
            }
        }
    }
}
