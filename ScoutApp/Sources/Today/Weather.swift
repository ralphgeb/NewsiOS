import Charts
import CoreLocation
import SwiftUI
import WeatherKit

/// Weather for Today from Apple WeatherKit, like the calendar app: your location once you allow
/// it (or London), now and the next 24 hours. Open-Meteo stands in if WeatherKit can't answer.
@MainActor
final class WeatherModel: NSObject, ObservableObject {
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
        let fromApple: Bool
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
    @Published private(set) var status: CLAuthorizationStatus

    private let manager = CLLocationManager()
    private var waiting: CheckedContinuation<CLLocation?, Never>?
    private var placeCache: (CLLocation, String)?
    private static let london = CLLocation(latitude: 51.5072, longitude: -0.1276)

    override init() {
        status = .notDetermined
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        status = manager.authorizationStatus
    }

    var mode: Mode { Mode(rawValue: UserDefaults.standard.string(forKey: Self.modeKey) ?? "") ?? .location }

    /// True until you've said yes or no to location (the card offers the button).
    var needsPermission: Bool { mode == .location && status == .notDetermined }
    var isDenied: Bool { mode == .location && (status == .denied || status == .restricted) }

    func requestPermission() { manager.requestWhenInUseAuthorization() }

    /// Fetches again when the weather is more than fifteen minutes old, or when forced.
    func refresh(force: Bool = false) async {
        if !force, let r = report, Date.now.timeIntervalSince(r.fetched) < 15 * 60 { return }
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let spot = await location()
        let place = await placeName(spot)
        var fresh = await Self.apple(spot, place: place)
        if fresh == nil { fresh = try? await Self.openMeteo(spot, place: place) }
        if let r = fresh {
            report = r
            failed = false
        } else {
            failed = report == nil
        }
    }

    private func location() async -> CLLocation {
        guard mode == .location else { return Self.london }
        guard status == .authorizedWhenInUse || status == .authorizedAlways else { return Self.london }
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

    fileprivate func authorizationChanged(_ new: CLAuthorizationStatus) async {
        let was = status
        status = new
        if new != was { await refresh(force: true) }
    }

    // MARK: Sources

    /// One WeatherKit call: now, the next 24 hours and today's high and low.
    private static func apple(_ spot: CLLocation, place: String) async -> Report? {
        do {
            let (now, hourly, daily) = try await WeatherService.shared.weather(for: spot, including: .current, .hourly, .daily)
            let start = Date.now.addingTimeInterval(-3600)
            let hours = hourly.forecast.filter { $0.date > start }.prefix(25).map {
                Hour(time: $0.date, temperature: $0.temperature.converted(to: .celsius).value,
                     code: wmoCode($0.condition), isDay: $0.isDaylight)
            }
            let today = daily.forecast.first
            return Report(place: place, temperature: now.temperature.converted(to: .celsius).value,
                          code: wmoCode(now.condition), isDay: now.isDaylight,
                          high: today?.highTemperature.converted(to: .celsius).value,
                          low: today?.lowTemperature.converted(to: .celsius).value,
                          rainChance: today.map { Int(($0.precipitationChance * 100).rounded()) },
                          hours: Array(hours), fetched: .now, fromApple: true)
        } catch {
            return nil
        }
    }

    /// The calendar app's mapping from WeatherKit conditions to the codes the icons use.
    private static func wmoCode(_ condition: WeatherCondition) -> Int {
        switch condition.rawValue {
        case "clear", "hot", "frigid": return 0
        case "mostlyClear": return 1
        case "partlyCloudy": return 2
        case "mostlyCloudy", "cloudy", "windy", "breezy", "blowingDust": return 3
        case "foggy", "haze", "smoky": return 45
        case "drizzle": return 51
        case "freezingDrizzle": return 56
        case "rain": return 63
        case "sunShowers": return 80
        case "heavyRain": return 65
        case "freezingRain": return 66
        case "sleet", "wintryMix", "hail": return 67
        case "snow", "flurries", "heavySnow", "blizzard", "blowingSnow", "sunFlurries": return 73
        case "thunderstorms", "isolatedThunderstorms", "scatteredThunderstorms", "strongStorms",
             "tropicalStorm", "hurricane": return 95
        default: return 3
        }
    }

    private struct OpenMeteo: Decodable {
        struct Current: Decodable { let temperature2m: Double; let weatherCode: Int; let isDay: Int }
        struct Hourly: Decodable { let time: [String]; let temperature2m: [Double?]; let weatherCode: [Int?]; let isDay: [Int?] }
        struct Daily: Decodable { let temperature2mMax: [Double?]; let temperature2mMin: [Double?]; let precipitationProbabilityMax: [Int?]? }
        let utcOffsetSeconds: Int
        let current: Current
        let hourly: Hourly
        let daily: Daily
    }

    private static func openMeteo(_ spot: CLLocation, place: String) async throws -> Report {
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
        let r = try d.decode(OpenMeteo.self, from: data)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        f.timeZone = TimeZone(secondsFromGMT: r.utcOffsetSeconds)
        let start = Date.now.addingTimeInterval(-3600)
        var hours: [Hour] = []
        for (i, s) in r.hourly.time.enumerated() {
            guard let t = f.date(from: s), t > start, hours.count < 25,
                  let temp = r.hourly.temperature2m[safe: i] ?? nil else { continue }
            hours.append(Hour(time: t, temperature: temp, code: (r.hourly.weatherCode[safe: i] ?? nil) ?? 3,
                              isDay: ((r.hourly.isDay[safe: i] ?? nil) ?? 1) == 1))
        }
        return Report(place: place, temperature: r.current.temperature2m, code: r.current.weatherCode,
                      isDay: r.current.isDay == 1, high: r.daily.temperature2mMax.first ?? nil,
                      low: r.daily.temperature2mMin.first ?? nil,
                      rainChance: r.daily.precipitationProbabilityMax?.first ?? nil, hours: hours, fetched: .now, fromApple: false)
    }
}

extension WeatherModel: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let last = locations.last
        Task { @MainActor in self.finish(last) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.finish(nil) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in await self.authorizationChanged(status) }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

/// WMO weather codes as words and as the calendar app's thin-line icons.
enum WeatherCode {
    static func icon(_ code: Int, day: Bool) -> String {
        switch code {
        case 0: return day ? "clear-day" : "clear-night"
        case 1, 2: return day ? "partly-day" : "partly-night"
        case 3: return "cloudy"
        case 45, 48: return "fog"
        case 51, 53, 55, 56, 57: return "drizzle"
        case 61, 63, 80, 81: return "rain"
        case 65, 82: return "heavy-rain"
        case 66, 67: return "sleet"
        case 71, 73, 75, 77, 85, 86: return "snow"
        case 95, 96, 99: return "thunder"
        default: return "cloudy"
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
        case 66, 67: return "Sleet"
        case 61...64, 80, 81: return "Rain"
        case 71...77, 85, 86: return "Snow"
        case 95...: return "Thunderstorms"
        default: return "Cloudy"
        }
    }
}

/// Draws one of the thin-line weather icons (48 x 48 grid), in the ink.
struct WeatherIcon: View {
    let name: String
    var size: CGFloat = 40
    var color: Color = Theme.ink

    var body: some View {
        PolylineShape(d: WeatherIconData.paths[name] ?? "")
            .stroke(color, style: StrokeStyle(lineWidth: max(1.2, size / 48 * 1.7), lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Reads the icons' tiny path format: "M x y L x y … Z".
struct PolylineShape: Shape {
    let d: String

    func path(in rect: CGRect) -> Path {
        let k = min(rect.width, rect.height) / 48
        func point(_ x: Substring, _ y: Substring) -> CGPoint {
            CGPoint(x: rect.minX + (Double(x) ?? 0) * k, y: rect.minY + (Double(y) ?? 0) * k)
        }
        var path = Path()
        let t = d.split(separator: " ")
        var i = 0
        while i < t.count {
            switch t[i] {
            case "M" where i + 2 < t.count:
                path.move(to: point(t[i + 1], t[i + 2])); i += 3
            case "L" where i + 2 < t.count:
                path.addLine(to: point(t[i + 1], t[i + 2])); i += 3
            case "Z":
                path.closeSubpath(); i += 1
            default:
                i += 1
            }
        }
        return path
    }
}

/// Now, today's high and low, and the next 24 hours as a temperature line with an icon every
/// four hours. Tap to refresh.
struct WeatherCard: View {
    @EnvironmentObject private var weather: WeatherModel
    @State private var attribution: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if weather.needsPermission {
                permission
            } else if let r = weather.report {
                report(r)
            } else {
                HStack(spacing: 10) {
                    WeatherIcon(name: "cloudy", size: 26, color: Theme.tertiary)
                    Text(weather.failed ? "Weather unavailable. Tap to try again." : "Loading the weather…")
                        .font(.system(size: 14)).foregroundStyle(Theme.secondary)
                    Spacer()
                }
            }
        }
        .scoutCard()
        .contentShape(Rectangle())
        .onTapGesture { Task { await weather.refresh(force: true) } }
        .task { await weather.refresh() }
        .task { attribution = try? await WeatherService.shared.attribution.legalPageURL }
    }

    private var permission: some View {
        HStack(spacing: 14) {
            WeatherIcon(name: "partly-day", size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text("Weather where you are").font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.ink)
                Text("Allow your location for the forecast here. It stays on this iPhone.")
                    .font(.system(size: 13)).foregroundStyle(Theme.secondary)
                Button { weather.requestPermission() } label: {
                    Text("Allow location")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 14).frame(height: 30)
                        .background(Theme.ink, in: Capsule())
                        .foregroundStyle(Theme.background)
                }
                .buttonStyle(PressStyle())
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
    }

    private func report(_ r: WeatherModel.Report) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                WeatherIcon(name: WeatherCode.icon(r.code, day: r.isDay), size: 52)
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(Int(r.temperature.rounded()))°")
                        .font(Theme.number(44, weight: .bold))
                        .tracking(-1)
                        .foregroundStyle(Theme.ink)
                        .contentTransition(.numericText())
                    Text(WeatherCode.label(r.code, day: r.isDay))
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.ink.opacity(0.75))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    HStack(spacing: 4) {
                        if weather.mode == .location, r.place != "London" {
                            Image(systemName: "location.fill").font(.system(size: 9))
                        }
                        Text(r.place).lineLimit(1)
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    if let h = r.high, let l = r.low {
                        Text("H \(Int(h.rounded()))°  L \(Int(l.rounded()))°")
                            .font(Theme.number(13, weight: .medium)).foregroundStyle(Theme.secondary)
                    }
                    if let rain = r.rainChance, rain >= 20 {
                        Text("\(rain)% rain").font(Theme.number(13, weight: .medium)).foregroundStyle(Theme.accent)
                    }
                }
            }
            if r.hours.count > 4 { HoursChart(hours: r.hours) }
            HStack(spacing: 6) {
                if weather.isDenied {
                    Text("Location is off, so this is London. Change it in the Settings app.")
                } else if r.fromApple {
                    Text("\u{F8FF} Weather")
                    if let attribution { Link("Data sources", destination: attribution).underline() }
                } else {
                    Text("Weather by Open-Meteo")
                }
                Spacer()
                if weather.isLoading { ProgressView().controlSize(.mini) }
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.tertiary)
        }
    }
}

/// The next 24 hours: a smooth temperature line, with an icon, time and temperature every four hours.
private struct HoursChart: View {
    let hours: [WeatherModel.Hour]

    var body: some View {
        let marks = stride(from: 0, to: hours.count, by: 4).map { hours[$0] }
        let temps = hours.map(\.temperature)
        let lo = (temps.min() ?? 0) - 1.5, hi = (temps.max() ?? 1) + 1.5
        VStack(spacing: 8) {
            Chart {
                ForEach(hours) { h in
                    AreaMark(x: .value("Time", h.time), yStart: .value("Low", lo), yEnd: .value("Temp", h.temperature))
                        .foregroundStyle(LinearGradient(colors: [Theme.ink.opacity(0.12), Theme.ink.opacity(0)], startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.catmullRom)
                    LineMark(x: .value("Time", h.time), y: .value("Temp", h.temperature))
                        .foregroundStyle(Theme.ink)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                        .interpolationMethod(.catmullRom)
                }
                if let first = hours.first {
                    PointMark(x: .value("Time", first.time), y: .value("Temp", first.temperature))
                        .foregroundStyle(Theme.accent).symbolSize(40)
                }
            }
            .chartYScale(domain: lo...hi)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 46)
            HStack(spacing: 0) {
                ForEach(Array(marks.enumerated()), id: \.offset) { i, h in
                    VStack(spacing: 5) {
                        Text(i == 0 ? "Now" : h.time.formatted(.dateTime.hour(.defaultDigits(amPM: .abbreviated))))
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(i == 0 ? Theme.accent : Theme.secondary)
                        WeatherIcon(name: WeatherCode.icon(h.code, day: h.isDay), size: 24, color: Theme.ink.opacity(0.85))
                        Text("\(Int(h.temperature.rounded()))°").font(Theme.number(14)).foregroundStyle(Theme.ink)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }
}
