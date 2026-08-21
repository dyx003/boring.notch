//
//  WeatherView.swift
//  boringNotch
//

import Defaults
@preconcurrency import CoreLocation
import Foundation
import SwiftUI

struct WeatherSnapshot: Equatable {
    let locationName: String
    let country: String?
    let temperature: Double
    let apparentTemperature: Double?
    let highTemperature: Double
    let lowTemperature: Double
    let weatherCode: Int
    let isDay: Bool
    let fetchedAt: Date

    var locationDisplayName: String {
        if let country,
           !country.isEmpty,
           country.caseInsensitiveCompare(locationName) != .orderedSame {
            return "\(locationName), \(country)"
        }
        return locationName
    }

    var conditionDescription: String {
        switch weatherCode {
        case 0: return "Clear sky"
        case 1: return "Mainly clear"
        case 2: return "Partly cloudy"
        case 3: return "Overcast"
        case 45, 48: return "Foggy"
        case 51...57: return "Drizzle"
        case 61...67: return "Rain"
        case 71...77: return "Snow"
        case 80...82: return "Rain showers"
        case 85...86: return "Snow showers"
        case 95...99: return "Thunderstorm"
        default: return "Unknown"
        }
    }

    var localizedConditionDescription: String {
        guard Locale.current.languageCode?.hasPrefix("zh") == true else {
            return conditionDescription
        }

        switch weatherCode {
        case 0: return "晴"
        case 1: return "基本晴"
        case 2: return "大部多云"
        case 3: return "阴"
        case 45, 48: return "雾"
        case 51...57: return "毛毛雨"
        case 61...67: return "下雨"
        case 71...77: return "下雪"
        case 80...82: return "阵雨"
        case 85...86: return "阵雪"
        case 95...99: return "雷雨"
        default: return "未知"
        }
    }

    var symbolName: String {
        switch weatherCode {
        case 0:
            return isDay ? "sun.max.fill" : "moon.stars.fill"
        case 1...3:
            return isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 45, 48:
            return "cloud.fog.fill"
        case 51...67, 80...82:
            return "cloud.rain.fill"
        case 71...77, 85...86:
            return "cloud.snow.fill"
        case 95...99:
            return "cloud.bolt.rain.fill"
        default:
            return "cloud.fill"
        }
    }

    static let preview = WeatherSnapshot(
        locationName: "Shanghai",
        country: "China",
        temperature: 26,
        apparentTemperature: 28,
        highTemperature: 29,
        lowTemperature: 21,
        weatherCode: 1,
        isDay: true,
        fetchedAt: .now
    )
}

private enum WeatherServiceError: LocalizedError {
    case invalidURL
    case noLocationFound
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return String(localized: "Unable to create the weather request.")
        case .noLocationFound:
            return String(localized: "City not found. Try another city name.")
        case .invalidResponse:
            return String(localized: "The weather service returned an invalid response.")
        }
    }
}

private enum WeatherLocationError: LocalizedError {
    case denied
    case unavailable

    var errorDescription: String? {
        switch self {
        case .denied:
            return String(localized: "Location access is denied. Set a city manually or enable Location Services.")
        case .unavailable:
            return String(localized: "Current location is temporarily unavailable.")
        }
    }
}

private struct ReverseGeocodingResponse: Decodable {
    let city: String?
    let locality: String?
    let principalSubdivision: String?
    let countryName: String?
}

private struct ReverseGeocodingService {
    func resolve(_ location: CLLocation) async -> (name: String, country: String?)? {
        guard var components = URLComponents(
            string: "https://api.bigdatacloud.net/data/reverse-geocode-client"
        ) else { return nil }

        components.queryItems = [
            URLQueryItem(name: "latitude", value: location.coordinate.latitude.description),
            URLQueryItem(name: "longitude", value: location.coordinate.longitude.description),
            URLQueryItem(name: "localityLanguage", value: Locale.current.languageCode ?? "en")
        ]

        guard let url = components.url else { return nil }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode) else {
                return nil
            }

            let result = try JSONDecoder().decode(ReverseGeocodingResponse.self, from: data)
            let name = [result.city, result.locality, result.principalSubdivision, result.countryName]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }

            guard let name else { return nil }
            return (name, result.countryName)
        } catch {
            return nil
        }
    }
}

@MainActor
private final class WeatherLocationProvider: NSObject, @MainActor CLLocationManagerDelegate {
    private let locationManager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private let fallbackGeocoder = ReverseGeocodingService()
    private var authorizationContinuation: CheckedContinuation<Void, Error>?
    private var locationContinuation: CheckedContinuation<CLLocation, Error>?

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    func currentLocation() async throws -> CLLocation {
        try await requestAuthorizationIfNeeded()

        return try await withCheckedThrowingContinuation { continuation in
            locationContinuation = continuation
            locationManager.requestLocation()
        }
    }

    func placemark(for location: CLLocation) async -> CLPlacemark? {
        for attempt in 0..<3 {
            do {
                if let placemark = try await geocoder.reverseGeocodeLocation(location).first {
                    return placemark
                }
            } catch {
                // Retry transient geocoding failures before using the network fallback.
            }

            if attempt < 2 {
                try? await Task.sleep(nanoseconds: 350_000_000)
            }
        }
        return nil
    }

    func locationDetails(for location: CLLocation) async -> (name: String, country: String?) {
        if let placemark = await placemark(for: location),
           let name = [
               placemark.locality,
               placemark.subLocality,
               placemark.subAdministrativeArea,
               placemark.administrativeArea,
               placemark.name,
               placemark.country
           ]
           .compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) })
           .first(where: { !$0.isEmpty }) {
            return (name, placemark.country)
        }

        if let fallback = await fallbackGeocoder.resolve(location) {
            return fallback
        }

        return (
            String(
                format: "%.4f, %.4f",
                location.coordinate.latitude,
                location.coordinate.longitude
            ),
            nil
        )
    }

    private func requestAuthorizationIfNeeded() async throws {
        switch locationManager.authorizationStatus {
        case .authorized, .authorizedAlways, .authorizedWhenInUse:
            return
        case .denied, .restricted:
            throw WeatherLocationError.denied
        case .notDetermined:
            try await withCheckedThrowingContinuation { continuation in
                authorizationContinuation = continuation
                locationManager.requestWhenInUseAuthorization()
            }
        @unknown default:
            throw WeatherLocationError.unavailable
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard let continuation = authorizationContinuation else { return }

        switch manager.authorizationStatus {
        case .authorized, .authorizedAlways, .authorizedWhenInUse:
            authorizationContinuation = nil
            continuation.resume()
        case .denied, .restricted:
            authorizationContinuation = nil
            continuation.resume(throwing: WeatherLocationError.denied)
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last, let continuation = locationContinuation else { return }
        locationContinuation = nil
        continuation.resume(returning: location)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard let continuation = locationContinuation else { return }
        locationContinuation = nil
        continuation.resume(throwing: error)
    }
}

private struct OpenMeteoLocationResponse: Decodable {
    let results: [OpenMeteoLocation]?
}

private struct OpenMeteoLocation: Decodable {
    let name: String
    let country: String?
    let latitude: Double
    let longitude: Double
}

private struct OpenMeteoForecastResponse: Decodable {
    let current: OpenMeteoCurrent
    let daily: OpenMeteoDaily
}

private struct OpenMeteoCurrent: Decodable {
    let temperature_2m: Double
    let apparent_temperature: Double?
    let weather_code: Int
    let is_day: Int?
}

private struct OpenMeteoDaily: Decodable {
    let temperature_2m_max: [Double]
    let temperature_2m_min: [Double]
}

private struct OpenMeteoWeatherService {
    func fetchWeather(for city: String) async throws -> WeatherSnapshot {
        let location = try await geocode(city)
        return try await fetchWeather(
            latitude: location.latitude,
            longitude: location.longitude,
            locationName: location.name,
            country: location.country
        )
    }

    func fetchWeather(
        latitude: Double,
        longitude: Double,
        locationName: String,
        country: String?
    ) async throws -> WeatherSnapshot {
        let forecastURL = try makeURL(
            base: "https://api.open-meteo.com/v1/forecast",
            queryItems: [
                URLQueryItem(name: "latitude", value: String(latitude)),
                URLQueryItem(name: "longitude", value: String(longitude)),
                URLQueryItem(
                    name: "current",
                    value: "temperature_2m,apparent_temperature,weather_code,is_day"
                ),
                URLQueryItem(
                    name: "daily",
                    value: "temperature_2m_max,temperature_2m_min"
                ),
                URLQueryItem(name: "temperature_unit", value: "celsius"),
                URLQueryItem(name: "timezone", value: "auto"),
                URLQueryItem(name: "forecast_days", value: "1")
            ]
        )

        let forecast: OpenMeteoForecastResponse = try await fetch(forecastURL)
        guard let high = forecast.daily.temperature_2m_max.first,
              let low = forecast.daily.temperature_2m_min.first else {
            throw WeatherServiceError.invalidResponse
        }

        return WeatherSnapshot(
            locationName: locationName,
            country: country,
            temperature: forecast.current.temperature_2m,
            apparentTemperature: forecast.current.apparent_temperature,
            highTemperature: high,
            lowTemperature: low,
            weatherCode: forecast.current.weather_code,
            isDay: forecast.current.is_day != 0,
            fetchedAt: .now
        )
    }

    private func geocode(_ city: String) async throws -> OpenMeteoLocation {
        let url = try makeURL(
            base: "https://geocoding-api.open-meteo.com/v1/search",
            queryItems: [
                URLQueryItem(name: "name", value: city),
                URLQueryItem(name: "count", value: "1"),
                URLQueryItem(name: "language", value: Locale.current.languageCode ?? "en"),
                URLQueryItem(name: "format", value: "json")
            ]
        )

        let response: OpenMeteoLocationResponse = try await fetch(url)
        guard let location = response.results?.first else {
            throw WeatherServiceError.noLocationFound
        }
        return location
    }

    private func makeURL(base: String, queryItems: [URLQueryItem]) throws -> URL {
        guard var components = URLComponents(string: base) else {
            throw WeatherServiceError.invalidURL
        }
        components.queryItems = queryItems
        guard let url = components.url else {
            throw WeatherServiceError.invalidURL
        }
        return url
    }

    private func fetch<T: Decodable>(_ url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw WeatherServiceError.invalidResponse
        }

        return try JSONDecoder().decode(T.self, from: data)
    }
}

@MainActor
final class WeatherManager: ObservableObject {
    static let shared = WeatherManager()

    @Published private(set) var snapshot: WeatherSnapshot?
    @Published private(set) var cityName = Defaults[.weatherCity]
    @Published private(set) var usesCurrentLocation = Defaults[.weatherUseCurrentLocation]
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private let service = OpenMeteoWeatherService()
    private let locationProvider = WeatherLocationProvider()
    private var lastRefresh: Date?

    func refreshIfNeeded() async {
        guard usesCurrentLocation
            || !cityName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        if let lastRefresh, Date.now.timeIntervalSince(lastRefresh) < 1_800,
           snapshot != nil {
            return
        }

        await refresh()
    }

    func refresh() async {
        let city = cityName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard usesCurrentLocation || !city.isEmpty else {
            snapshot = nil
            errorMessage = nil
            return
        }

        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            if usesCurrentLocation {
                let location = try await locationProvider.currentLocation()
                let locationDetails = await locationProvider.locationDetails(for: location)

                snapshot = try await service.fetchWeather(
                    latitude: location.coordinate.latitude,
                    longitude: location.coordinate.longitude,
                    locationName: locationDetails.name,
                    country: locationDetails.country
                )
            } else {
                snapshot = try await service.fetchWeather(for: city)
            }
            lastRefresh = .now
        } catch {
            // Keep weather usable when location services are denied or unavailable.
            if usesCurrentLocation, !city.isEmpty {
                do {
                    snapshot = try await service.fetchWeather(for: city)
                    lastRefresh = .now
                    errorMessage = String(localized: "Using saved city because current location is unavailable.")
                    return
                } catch {
                    errorMessage = error.localizedDescription
                }
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }

    func setUseCurrentLocation(_ enabled: Bool) async {
        Defaults[.weatherUseCurrentLocation] = enabled
        usesCurrentLocation = enabled
        snapshot = nil
        lastRefresh = nil
        errorMessage = nil
        await refresh()
    }

    func updateCity(_ city: String) async {
        let trimmedCity = city.trimmingCharacters(in: .whitespacesAndNewlines)
        Defaults[.weatherCity] = trimmedCity
        Defaults[.weatherUseCurrentLocation] = false
        cityName = trimmedCity
        usesCurrentLocation = false
        snapshot = nil
        lastRefresh = nil
        errorMessage = nil
        await refresh()
    }
}

private enum WeatherCardStyle {
    static let accent = Color(red: 0.48, green: 0.82, blue: 0.48)
    static let warm = Color(red: 0.98, green: 0.60, blue: 0.25)
    static let cool = Color(red: 0.40, green: 0.77, blue: 0.97)
    static let background = Color.black
}

struct WeatherCardView: View {
    @ObservedObject private var weatherManager = WeatherManager.shared
    @State private var showingDetails = false

    var body: some View {
        GeometryReader { geometry in
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Button {
                    showingDetails = weatherManager.snapshot != nil
                } label: {
                    cardContent(at: context.date, width: geometry.size.width)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .contentShape(Rectangle())
                }
                .frame(width: geometry.size.width, height: geometry.size.width)
                .buttonStyle(.plain)
                .disabled(weatherManager.snapshot == nil)
                .onAppear {
                    Task { await weatherManager.refreshIfNeeded() }
                }
                .popover(isPresented: $showingDetails, arrowEdge: .top) {
                    if let snapshot = weatherManager.snapshot {
                        WeatherDetailView(snapshot: snapshot)
                    }
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    @ViewBuilder
    private func cardContent(at date: Date, width: CGFloat) -> some View {
        let isCompact = width < 190
        let horizontalPadding = isCompact ? 12.0 : 18.0
        let verticalPadding = isCompact ? 12.0 : 16.0
        let headerFontSize = min(20.0, max(14.0, width * 0.07))
        let temperatureFontSize = min(88.0, max(48.0, width * 0.27))
        let highLowFontSize = min(30.0, max(18.0, width * 0.10))

        VStack(spacing: 0) {
            HStack(spacing: 6) {
                if let snapshot = weatherManager.snapshot {
                    HStack(spacing: 4) {
                        Image(systemName: snapshot.symbolName)
                            .font(.system(size: headerFontSize, weight: .semibold))
                            .symbolRenderingMode(.monochrome)
                            .foregroundStyle(.white)
                        Text(snapshot.localizedConditionDescription)
                            .font(.system(size: headerFontSize, weight: .semibold, design: .rounded))
                            .foregroundStyle(WeatherCardStyle.accent)
                            .lineLimit(1)
                            .allowsTightening(true)
                            .minimumScaleFactor(0.45)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)
                } else {
                    Text("—")
                        .font(.system(size: headerFontSize, weight: .semibold, design: .rounded))
                        .foregroundStyle(WeatherCardStyle.accent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text(clockText(for: date))
                    .font(.system(size: headerFontSize, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .frame(minHeight: 24)

            if let snapshot = weatherManager.snapshot {
                Text("\(snapshot.temperature, specifier: "%.0f")°")
                    .font(.system(size: temperatureFontSize, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.65)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .center)

                HStack(spacing: 0) {
                    highLowRow(
                        icon: "arrow.up",
                        label: String(localized: "最高"),
                        value: snapshot.highTemperature,
                        color: WeatherCardStyle.warm,
                        valueFontSize: highLowFontSize
                    )
                    Spacer(minLength: isCompact ? 18 : 32)
                    highLowRow(
                        icon: "arrow.down",
                        label: String(localized: "最低"),
                        value: snapshot.lowTemperature,
                        color: WeatherCardStyle.cool,
                        valueFontSize: highLowFontSize
                    )
                }
                .frame(maxWidth: .infinity, alignment: .center)
            } else if weatherManager.isLoading {
                statusText(
                    icon: "location.fill",
                    title: weatherManager.usesCurrentLocation
                        ? String(localized: "Locating…")
                        : String(localized: "Loading weather…"),
                    detail: nil
                )
            } else if weatherManager.usesCurrentLocation {
                statusText(
                    icon: "location.slash.fill",
                    title: String(localized: "Unknown"),
                    detail: String(localized: "Weather unavailable")
                )
            } else if weatherManager.cityName.isEmpty {
                statusText(
                    icon: "location.slash.fill",
                    title: String(localized: "Unknown"),
                    detail: String(localized: "Set a city in Settings")
                )
            } else {
                statusText(
                    icon: "location.slash.fill",
                    title: weatherManager.cityName,
                    detail: String(localized: "Weather unavailable")
                )
            }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(WeatherCardStyle.background)
    }

    private func highLowRow(
        icon: String,
        label: String,
        value: Double,
        color: Color,
        valueFontSize: CGFloat
    ) -> some View {
        VStack(spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(color)
                Text(label)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.52))
            }
            Text("\(value, specifier: "%.0f")°")
                .font(.system(size: valueFontSize, weight: .semibold, design: .rounded))
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity)
    }

    private func clockText(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private func statusText(icon: String, title: String, detail: String?) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(WeatherCardStyle.warm)

            Text(title)
                .foregroundStyle(WeatherCardStyle.warm)
                .lineLimit(1)
                .layoutPriority(1)

            if let detail {
                Text(detail)
                    .foregroundStyle(.white.opacity(0.68))
                    .lineLimit(1)
            }
        }
        .font(.system(size: 11, weight: .medium, design: .rounded))
    }
}

struct WeatherHeaderView: View {
    @EnvironmentObject private var vm: BoringViewModel
    @ObservedObject private var weatherManager = WeatherManager.shared

    var body: some View {
        Button {
            vm.toggleWeatherPreview()
        } label: {
            HStack(spacing: 5) {
                if let snapshot = weatherManager.snapshot {
                Image(systemName: snapshot.symbolName)
                        .font(.system(size: 13, weight: .medium))
                        .symbolRenderingMode(.multicolor)
                    Text("\(snapshot.temperature, specifier: "%.0f")°")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .fixedSize(horizontal: true, vertical: false)
                } else if weatherManager.isLoading {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: "cloud.sun.fill")
                        .font(.system(size: 13, weight: .medium))
                    Text("—")
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .frame(height: 30)
            .fixedSize(horizontal: true, vertical: false)
            .background(Capsule().fill(Color.black))
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
        .onAppear {
            Task { await weatherManager.refreshIfNeeded() }
        }
    }
}

private struct WeatherDetailView: View {
    let snapshot: WeatherSnapshot
    @ObservedObject private var weatherManager = WeatherManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: snapshot.symbolName)
                    .font(.system(size: 30))
                    .symbolRenderingMode(.multicolor)
                VStack(alignment: .leading) {
                    Text(snapshot.locationDisplayName)
                        .font(.headline)
                    Text(snapshot.localizedConditionDescription)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            detailRow(String(localized: "Temperature"), value: "\(String(format: "%.0f", snapshot.temperature))°C")
            if let apparentTemperature = snapshot.apparentTemperature {
                detailRow(String(localized: "Feels like"), value: "\(String(format: "%.0f", apparentTemperature))°C")
            }
            detailRow(
                String(localized: "Today"),
                value: "H \(String(format: "%.0f", snapshot.highTemperature))°  L \(String(format: "%.0f", snapshot.lowTemperature))°"
            )

            Button(String(localized: "Refresh")) {
                Task { await weatherManager.refresh() }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(16)
        .frame(width: 250)
    }

    private func detailRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
        .font(.subheadline)
    }
}

#Preview("Weather card") {
    WeatherCardView()
        .frame(width: 150, height: 130)
}
