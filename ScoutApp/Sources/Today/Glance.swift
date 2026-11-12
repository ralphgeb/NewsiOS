import SwiftUI

/// Today's first card: the weather and the metro side by side on one line, like the top of a
/// newspaper. Tap it to open the next hours' forecast and any disruption, line by line.
/// Either half can be turned off (Edit on Today, or Settings); the other then fills the card.
struct GlanceCard: View {
    var showWeather = true
    var showTube = true
    @EnvironmentObject private var weather: WeatherModel
    @EnvironmentObject private var tube: TubeService
    @AppStorage("glance.open") private var isOpen = false
    @AppStorage("weather.showRain") private var showRain = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.snappy) { isOpen.toggle() } } label: {
                HStack(spacing: 0) {
                    if showWeather { weatherHalf.frame(maxWidth: .infinity, alignment: .leading) }
                    if showWeather && showTube {
                        Rectangle().fill(Theme.hairline).frame(width: 0.5, height: 38).padding(.horizontal, 14)
                    }
                    if showTube { tubeHalf.frame(maxWidth: .infinity, alignment: .leading) }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.tertiary)
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                        .padding(.leading, 10)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilitySummary)
            .accessibilityHint(isOpen ? "Folds the details away" : "Shows the forecast and line status")

            if isOpen {
                VStack(alignment: .leading, spacing: 16) {
                    if showWeather, let r = weather.report, r.hours.count > 4 {
                        Rectangle().fill(Theme.hairline).frame(height: 0.5)
                        weatherDetails(r)
                    }
                    if showTube {
                        Rectangle().fill(Theme.hairline).frame(height: 0.5)
                        HStack(spacing: 7) {
                            Image(systemName: "tram.fill").font(.system(size: 12, weight: .semibold))
                            Text(tube.city.network).font(.system(size: 14, weight: .heavy))
                            Spacer()
                            if let f = tube.fetched {
                                Text(Format.time(f)).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.tertiary)
                            }
                        }
                        .foregroundStyle(Theme.text)
                        TubeCard(embedded: true)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .task { await weather.refresh() }
        .task { await tube.refresh() }
        .sensoryFeedback(.impact(weight: .light), trigger: isOpen)
    }

    // MARK: The two halves

    @ViewBuilder
    private var weatherHalf: some View {
        if weather.needsPermission {
            HStack(spacing: 10) {
                WeatherIcon(name: "partly-day", size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Weather").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.text)
                    Text("Tap to allow location").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
                }
            }
            .onTapGesture { weather.requestPermission() }
        } else if let r = weather.report {
            HStack(spacing: 10) {
                WeatherIcon(name: WeatherCode.icon(r.code, day: r.isDay), size: 32)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(Int(r.temperature.rounded()))°")
                            .font(Theme.number(26, weight: .bold)).tracking(-0.8)
                            .foregroundStyle(Theme.text)
                            .contentTransition(.numericText())
                        if let h = r.high, let l = r.low {
                            Text("\(Int(h.rounded()))° / \(Int(l.rounded()))°")
                                .font(Theme.number(12, weight: .semibold)).foregroundStyle(Theme.secondary)
                        }
                    }
                    Text(weatherLine(r))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle((r.rainChance ?? 0) >= 40 ? Theme.accent : Theme.secondary)
                        .lineLimit(1)
                }
            }
        } else {
            HStack(spacing: 10) {
                WeatherIcon(name: "cloudy", size: 30, color: Theme.tertiary)
                Text(weather.failed ? "Weather unavailable" : "Weather…")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.secondary)
            }
        }
    }

    /// "Cloudy · London", or the rain when it's likely.
    private func weatherLine(_ r: WeatherModel.Report) -> String {
        if let rain = r.rainChance, rain >= 40 { return "\(rain)% chance of rain" }
        return "\(WeatherCode.label(r.code, day: r.isDay)) · \(r.place)"
    }

    @ViewBuilder
    private var tubeHalf: some View {
        let bad = tube.lines.filter { $0.level > 0 }.sorted { $0.level > $1.level }
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: "tram.fill").font(.system(size: 10, weight: .bold))
                Text(tube.city.network.uppercased()).font(.system(size: 10, weight: .heavy)).tracking(0.8)
            }
            .foregroundStyle(Theme.secondary)
            if tube.lines.isEmpty {
                Text(tube.failed ? "Unavailable" : "Checking…")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.secondary)
            } else if bad.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(Color(red: 0.18, green: 0.62, blue: 0.42))
                    Text("Good service").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.text)
                }
            } else {
                HStack(spacing: 6) {
                    HStack(spacing: -3) {
                        ForEach(bad.prefix(5)) { line in
                            Circle().fill(line.colour).frame(width: 12, height: 12)
                                .overlay(Circle().stroke(Theme.card, lineWidth: 1.5))
                        }
                    }
                    Text(tubeLine(bad))
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(bad.contains { $0.level == 2 } ? Theme.accent : Theme.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
        }
    }

    /// "Central: minor delays", or "3 lines delayed".
    private func tubeLine(_ bad: [TubeService.Line]) -> String {
        if bad.count == 1, let l = bad.first { return "\(l.name.replacingOccurrences(of: " line", with: "")): \(l.status.lowercased())" }
        return "\(bad.count) lines \(bad.contains { $0.level == 2 } ? "disrupted" : "delayed")"
    }

    private var accessibilitySummary: String {
        var parts: [String] = []
        if showWeather, let r = weather.report {
            parts.append("\(Int(r.temperature.rounded())) degrees, \(WeatherCode.label(r.code, day: r.isDay)) in \(r.place)")
        }
        if showTube {
            let bad = tube.lines.filter { $0.level > 0 }
            parts.append(tube.lines.isEmpty ? "\(tube.city.network) status loading" : bad.isEmpty ? "\(tube.city.network): good service" : "\(tube.city.network): \(tubeLine(bad))")
        }
        return parts.joined(separator: ". ")
    }

    // MARK: Opened

    private func weatherDetails(_ r: WeatherModel.Report) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(showRain ? rainSummary(r.hours) : tempSummary(r.hours))
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondary).lineLimit(1)
                Spacer()
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
            Group {
                if showRain { RainChart(hours: r.hours) } else { HoursChart(hours: r.hours) }
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.snappy) { showRain.toggle() } }
            if weather.isDenied {
                Text("Location is off, so this is London. Change it in the Settings app.")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.tertiary)
            }
        }
        .sensoryFeedback(.selection, trigger: showRain)
    }

    private func tempSummary(_ hours: [WeatherModel.Hour]) -> String {
        guard let hi = hours.max(by: { $0.temperature < $1.temperature }),
              let lo = hours.min(by: { $0.temperature < $1.temperature }) else { return "Next 24 hours" }
        let t = { (h: WeatherModel.Hour) in h.time.formatted(.dateTime.hour(.defaultDigits(amPM: .abbreviated))) }
        return "Warmest \(Int(hi.temperature.rounded()))° at \(t(hi)) · coolest \(Int(lo.temperature.rounded()))° at \(t(lo))"
    }

    private func rainSummary(_ hours: [WeatherModel.Hour]) -> String {
        guard let top = hours.max(by: { $0.rainChance < $1.rainChance }), top.rainChance >= 15 else {
            return "No rain expected in the next 24 hours"
        }
        return "Rain most likely at \(top.time.formatted(.dateTime.hour(.defaultDigits(amPM: .abbreviated)))) (\(top.rainChance)%)"
    }
}
