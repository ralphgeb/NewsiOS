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
        /// Chance of rain or snow that hour, 0–100.
        let rainChance: Int
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
        // the shared copy for this area first, then Apple Weather on the phone, then Open-Meteo
        let tz = mode == .london ? "Europe/London" : TimeZone.current.identifier
        var fresh = await Self.shared(spot, place: place, timeZone: tz)
        if fresh == nil { fresh = await Self.apple(spot, place: place) }
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

    private struct SharedWeather: Decodable {
        struct Now: Decodable { let temp: Double; let cond: String; let day: Bool }
        struct HourJSON: Decodable { let t: String; let temp: Double; let cond: String; let day: Bool; let rain: Int }
        let current: Now
        let high: Double?
        let low: Double?
        let rain: Int?
        let hours: [HourJSON]
    }

    /// The Scout service's copy for this area: Apple Weather fetched once every 30 minutes and shared
    /// by everyone nearby, so the phones make far fewer WeatherKit calls.
    private static func shared(_ spot: CLLocation, place: String, timeZone: String) async -> Report? {
        guard let base = StocksRequests.url,
              var c = URLComponents(url: base.appending(path: "weather"), resolvingAgainstBaseURL: false) else { return nil }
        c.queryItems = [
            // about 1 km is plenty: the service shares one forecast per ~5 km square
            .init(name: "lat", value: String(format: "%.2f", spot.coordinate.latitude)),
            .init(name: "lon", value: String(format: "%.2f", spot.coordinate.longitude)),
            .init(name: "tz", value: timeZone),
        ]
        guard let url = c.url, let result = try? await URLSession.shared.data(from: url),
              (result.1 as? HTTPURLResponse)?.statusCode == 200,
              let w = try? JSONDecoder().decode(SharedWeather.self, from: result.0) else { return nil }
        let hours = w.hours.compactMap { h in
            ISODate.parse(h.t).map { Hour(time: $0, temperature: h.temp, code: wmoCode(h.cond), isDay: h.day, rainChance: h.rain) }
        }
        guard !hours.isEmpty else { return nil }
        return Report(place: place, temperature: w.current.temp, code: wmoCode(w.current.cond), isDay: w.current.day,
                      high: w.high, low: w.low, rainChance: w.rain, hours: hours, fetched: .now, fromApple: true)
    }

    /// One WeatherKit call: now, the next 24 hours and today's high and low.
    private static func apple(_ spot: CLLocation, place: String) async -> Report? {
        do {
            let (now, hourly, daily) = try await WeatherService.shared.weather(for: spot, including: .current, .hourly, .daily)
            let start = Date.now.addingTimeInterval(-3600)
            let hours = hourly.forecast.filter { $0.date > start }.prefix(25).map {
                Hour(time: $0.date, temperature: $0.temperature.converted(to: .celsius).value,
                     code: wmoCode($0.condition.rawValue), isDay: $0.isDaylight,
                     rainChance: Int(($0.precipitationChance * 100).rounded()))
            }
            let today = daily.forecast.first
            return Report(place: place, temperature: now.temperature.converted(to: .celsius).value,
                          code: wmoCode(now.condition.rawValue), isDay: now.isDaylight,
                          high: today?.highTemperature.converted(to: .celsius).value,
                          low: today?.lowTemperature.converted(to: .celsius).value,
                          rainChance: today.map { Int(($0.precipitationChance * 100).rounded()) },
                          hours: Array(hours), fetched: .now, fromApple: true)
        } catch {
            return nil
        }
    }

    /// The calendar app's mapping from WeatherKit conditions to the codes the icons use.
    private static func wmoCode(_ condition: String) -> Int {
        switch condition {
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
        struct Hourly: Decodable {
            let time: [String]; let temperature2m: [Double?]; let weatherCode: [Int?]; let isDay: [Int?]
            let precipitationProbability: [Int?]?
        }
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
            .init(name: "hourly", value: "temperature_2m,weather_code,is_day,precipitation_probability"),
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
                              isDay: ((r.hourly.isDay[safe: i] ?? nil) ?? 1) == 1,
                              rainChance: (r.hourly.precipitationProbability?[safe: i] ?? nil) ?? 0))
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

/// Now, today's high and low, and the next 24 hours: the temperature line with a reading every four
/// hours, or (tap it) the chance of rain hour by hour. Pull Today down to refresh.
struct WeatherCard: View {
    @EnvironmentObject private var weather: WeatherModel
    @State private var attribution: URL?
    @AppStorage("weather.showRain") private var showRain = false
    /// Tap the top of the card to fold away the chart, like the metro card, so more news fits.
    @AppStorage("weather.compact") private var compact = false

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
        .task { await weather.refresh() }
        .task { attribution = try? await WeatherService.shared.attribution.legalPageURL }
    }

    private var permission: some View {
        HStack(spacing: 14) {
            WeatherIcon(name: "partly-day", size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text("Weather where you are").font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.text)
                Text("Allow your location for the forecast here. Only your rough area is used, and it isn't kept.")
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
        VStack(alignment: .leading, spacing: compact ? 10 : 14) {
            Button {
                withAnimation(.snappy) { compact.toggle() }
            } label: {
            HStack(alignment: .center, spacing: 14) {
                WeatherIcon(name: WeatherCode.icon(r.code, day: r.isDay), size: compact ? 36 : 52)
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(Int(r.temperature.rounded()))°")
                        .font(Theme.number(compact ? 30 : 44, weight: .bold))
                        .tracking(-1)
                        .foregroundStyle(Theme.text)
                        .contentTransition(.numericText())
                    Text(WeatherCode.label(r.code, day: r.isDay))
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text.opacity(0.75))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    HStack(spacing: 4) {
                        if weather.mode == .location, r.place != "London" {
                            Image(systemName: "location.fill").font(.system(size: 9))
                        }
                        Text(r.place).lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Theme.tertiary)
                            .rotationEffect(.degrees(compact ? 0 : 180))
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    if let h = r.high, let l = r.low {
                        Text("H \(Int(h.rounded()))°  L \(Int(l.rounded()))°")
                            .font(Theme.number(13, weight: .medium)).foregroundStyle(Theme.secondary)
                    }
                    if let rain = r.rainChance, rain >= 20 {
                        Text("\(rain)% rain").font(Theme.number(13, weight: .medium)).foregroundStyle(Theme.accent)
                    }
                }
            }
            .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(compact ? "Shows the next 24 hours" : "Folds away the chart")
            .sensoryFeedback(.impact(weight: .light), trigger: compact)
            if r.hours.count > 4, !compact {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(showRain ? rainSummary(r.hours) : tempSummary(r.hours))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(1)
                        Spacer()
                        chartSwitch
                    }
                    Group {
                        if showRain { RainChart(hours: r.hours) } else { HoursChart(hours: r.hours) }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.snappy) { showRain.toggle() } }
                    .transition(.opacity)
                }
                .sensoryFeedback(.selection, trigger: showRain)
            }
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

extension WeatherCard {
    /// Temperature or rain, as a small two-way switch.
    private var chartSwitch: some View {
        HStack(spacing: 2) {
            ForEach([false, true], id: \.self) { rain in
                Button { withAnimation(.snappy) { showRain = rain } } label: {
                    Image(systemName: rain ? "drop.fill" : "thermometer.medium")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 32, height: 22)
                        .background(showRain == rain ? Theme.ink : Color.clear, in: Capsule())
                        .foregroundStyle(showRain == rain ? Theme.background : Theme.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(rain ? "Chance of rain" : "Temperature")
            }
        }
        .padding(2)
        .background(Theme.track, in: Capsule())
    }

    /// "Warmest 15° at 2pm, coolest 8° at 5am"
    private func tempSummary(_ hours: [WeatherModel.Hour]) -> String {
        guard let hi = hours.max(by: { $0.temperature < $1.temperature }),
              let lo = hours.min(by: { $0.temperature < $1.temperature }) else { return "Next 24 hours" }
        let t = { (h: WeatherModel.Hour) in h.time.formatted(.dateTime.hour(.defaultDigits(amPM: .abbreviated))) }
        return "Warmest \(Int(hi.temperature.rounded()))° at \(t(hi)) · coolest \(Int(lo.temperature.rounded()))° at \(t(lo))"
    }

    /// "Rain most likely at 3pm (60%)", or none expected.
    private func rainSummary(_ hours: [WeatherModel.Hour]) -> String {
        guard let top = hours.max(by: { $0.rainChance < $1.rainChance }), top.rainChance >= 15 else {
            return "No rain expected in the next 24 hours"
        }
        return "Rain most likely at \(top.time.formatted(.dateTime.hour(.defaultDigits(amPM: .abbreviated)))) (\(top.rainChance)%)"
    }
}

/// Lines the chart up with the row of columns under it: each four-hour mark sits in the middle of
/// its column.
private func columnDomain(_ hours: [WeatherModel.Hour]) -> ClosedRange<Date> {
    let first = hours.first?.time ?? .now
    let columns = Double((hours.count + 3) / 4)
    return first.addingTimeInterval(-2 * 3600)...first.addingTimeInterval((4 * columns - 2) * 3600)
}

/// Time and icon under each four-hour mark.
private struct HourColumns<Extra: View>: View {
    let hours: [WeatherModel.Hour]
    @ViewBuilder var extra: (WeatherModel.Hour) -> Extra

    var body: some View {
        let marks = stride(from: 0, to: hours.count, by: 4).map { hours[$0] }
        HStack(spacing: 0) {
            ForEach(Array(marks.enumerated()), id: \.offset) { i, h in
                VStack(spacing: 5) {
                    Text(i == 0 ? "Now" : h.time.formatted(.dateTime.hour(.defaultDigits(amPM: .abbreviated))))
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(i == 0 ? Theme.accent : Theme.secondary)
                    extra(h)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

/// The next 24 hours: a smooth temperature line with a faint dot every hour, a bold dot and
/// reading every four hours, and an icon under each.
private struct HoursChart: View {
    let hours: [WeatherModel.Hour]

    var body: some View {
        let temps = hours.map(\.temperature)
        let lo = (temps.min() ?? 0) - 2, hi = (temps.max() ?? 1) + 3
        let marks = Set(stride(from: 0, to: hours.count, by: 4).map { hours[$0].time })
        VStack(spacing: 6) {
            Chart {
                ForEach(hours) { h in
                    AreaMark(x: .value("Time", h.time), yStart: .value("Low", lo), yEnd: .value("Temp", h.temperature))
                        .foregroundStyle(LinearGradient(colors: [Theme.ink.opacity(0.14), Theme.ink.opacity(0)], startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.catmullRom)
                    LineMark(x: .value("Time", h.time), y: .value("Temp", h.temperature))
                        .foregroundStyle(Theme.ink)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                        .interpolationMethod(.catmullRom)
                }
                ForEach(hours) { h in
                    let isMark = marks.contains(h.time)
                    let isNow = h.time == hours.first?.time
                    PointMark(x: .value("Time", h.time), y: .value("Temp", h.temperature))
                        .foregroundStyle(isNow ? Theme.accent : Theme.ink.opacity(isMark ? 1 : 0.25))
                        .symbolSize(isNow ? 55 : (isMark ? 30 : 8))
                        .annotation(position: .top, spacing: 3) {
                            if isMark {
                                Text("\(Int(h.temperature.rounded()))°")
                                    .font(Theme.number(12, weight: .bold))
                                    .foregroundStyle(isNow ? Theme.accent : Theme.text)
                            }
                        }
                }
            }
            .chartXScale(domain: columnDomain(hours))
            .chartYScale(domain: lo...hi)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 76)
            HourColumns(hours: hours) { h in
                WeatherIcon(name: WeatherCode.icon(h.code, day: h.isDay), size: 24, color: Theme.ink.opacity(0.85))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(hours.enumerated().filter { $0.offset % 4 == 0 }
            .map { "\($0.element.time.formatted(date: .omitted, time: .shortened)) \(Int($0.element.temperature.rounded())) degrees" }
            .joined(separator: ", "))
    }
}

/// The chance of rain hour by hour, as bars that grow darker as rain gets likelier.
private struct RainChart: View {
    let hours: [WeatherModel.Hour]

    var body: some View {
        let marks = Set(stride(from: 0, to: hours.count, by: 4).map { hours[$0].time })
        VStack(spacing: 6) {
            Chart {
                RuleMark(y: .value("Half", 50))
                    .foregroundStyle(Theme.ink.opacity(0.12))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                ForEach(hours) { h in
                    BarMark(x: .value("Time", h.time, unit: .hour), y: .value("Chance", max(h.rainChance, 2)), width: .ratio(0.62))
                        .foregroundStyle(h.rainChance >= 50 ? Theme.accent : Theme.ink.opacity(0.18 + 0.5 * Double(h.rainChance) / 100))
                        .cornerRadius(3)
                        .annotation(position: .top, spacing: 2) {
                            if marks.contains(h.time) {
                                Text("\(h.rainChance)%")
                                    .font(Theme.number(11, weight: .bold))
                                    .foregroundStyle(h.rainChance >= 50 ? Theme.accent : Theme.secondary)
                            }
                        }
                }
            }
            .chartXScale(domain: columnDomain(hours))
            .chartYScale(domain: 0...115)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 76)
            HourColumns(hours: hours) { h in
                Image(systemName: h.rainChance >= 50 ? "drop.fill" : "drop")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(h.rainChance >= 50 ? Theme.accent : Theme.ink.opacity(0.35 + 0.5 * Double(h.rainChance) / 100))
                    .frame(height: 24)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(hours.enumerated().filter { $0.offset % 4 == 0 }
            .map { "\($0.element.time.formatted(date: .omitted, time: .shortened)) \($0.element.rainChance) percent chance of rain" }
            .joined(separator: ", "))
    }
}
