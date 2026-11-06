import Foundation
import HomeswiftNetwork
import HomeswiftPlugin

/// The weather now at a place, in HomeKit's and Eve's units.
struct WeatherReport: Sendable, Equatable {
    /// °C, 2 m above the ground.
    var temperature: Double
    /// %, relative.
    var humidity: Double
    /// hPa, at sea level.
    var pressure: Double
    /// km/h, 10 m above the ground.
    var windSpeed: Double
    /// mm of rain and showers in the last hour.
    var rainLastHour: Double
    /// The UV index, 0 and up.
    var uvIndex: Double
    /// The WMO weather code Open-Meteo reports (0 clear … 99 thunderstorm with hail).
    var weatherCode: Int
    /// Whether it rains now: rain or showers in the last quarter of an hour, or a rainy weather code.
    var isRaining: Bool

    /// The condition in a few English words, as Eve's Condition characteristic shows it (the web UI translates them).
    var condition: String { WeatherCode.condition(weatherCode) }
}

/// The WMO weather interpretation codes Open-Meteo uses (its documentation's table, "WMO Weather interpretation codes").
enum WeatherCode {
    static func condition(_ code: Int) -> String {
        switch code {
        case 0: "Clear sky"
        case 1: "Mainly clear"
        case 2: "Partly cloudy"
        case 3: "Overcast"
        case 45, 48: "Fog"
        case 51, 53, 55: "Drizzle"
        case 56, 57: "Freezing drizzle"
        case 61, 63, 65: "Rain"
        case 66, 67: "Freezing rain"
        case 71, 73, 75, 77: "Snow"
        case 80, 81, 82: "Rain showers"
        case 85, 86: "Snow showers"
        case 95: "Thunderstorm"
        case 96, 99: "Thunderstorm with hail"
        default: "Unknown"
        }
    }

    /// The codes of rain in any form: drizzle, rain, freezing rain, showers and thunderstorms.
    static func isRain(_ code: Int) -> Bool {
        (51...67).contains(code) || (80...82).contains(code) || (95...99).contains(code)
    }
}

/// Where the plugin gets the weather; tests use a fake.
protocol WeatherAPI: Sendable {
    func current(at location: Location) async throws -> WeatherReport
}

/// Open-Meteo's forecast API (https://open-meteo.com/en/docs): free, no key. The request carries the Location's
/// coordinates rounded to two decimals (about a kilometre, finer than the models' grid), never its name.
struct OpenMeteo: WeatherAPI {
    struct Failure: Error, CustomStringConvertible {
        var description: String
    }

    var http: any HTTPSending = HTTPClient(tls: .system)
    var base = "https://api.open-meteo.com/v1/forecast"

    static let currentFields = [
        "temperature_2m", "relative_humidity_2m", "rain", "showers", "weather_code", "pressure_msl", "wind_speed_10m", "uv_index",
    ]

    static func rounded(_ value: Double) -> String {
        String(format: "%.2f", (value * 100).rounded() / 100)
    }

    func url(for location: Location) -> URL? {
        var components = URLComponents(string: base)
        components?.queryItems = [
            URLQueryItem(name: "latitude", value: Self.rounded(location.latitude)),
            URLQueryItem(name: "longitude", value: Self.rounded(location.longitude)),
            URLQueryItem(name: "current", value: Self.currentFields.joined(separator: ",")),
            // The last hour's rain: its four quarters.
            URLQueryItem(name: "minutely_15", value: "precipitation"),
            URLQueryItem(name: "past_minutely_15", value: "4"),
            URLQueryItem(name: "forecast_minutely_15", value: "0"),
            URLQueryItem(name: "wind_speed_unit", value: "kmh"),
            URLQueryItem(name: "timezone", value: "GMT"),
        ]
        return components?.url
    }

    func current(at location: Location) async throws -> WeatherReport {
        guard let url = url(for: location) else { throw Failure(description: "no request for that location") }
        let response = try await http.send(HTTPRequest(url: url, headers: [("Accept", "application/json")], timeout: .seconds(20)))
        guard response.isSuccess else {
            let reason = (try? JSONDecoder().decode(ErrorAnswer.self, from: response.body))?.reason
            throw Failure(description: "Open-Meteo answered \(response.status)\(reason.map { ": \($0)" } ?? "")")
        }
        return try Self.report(from: response.body)
    }

    private struct ErrorAnswer: Decodable {
        var reason: String?
    }

    private struct Answer: Decodable {
        struct Current: Decodable {
            var temperature_2m: Double?
            var relative_humidity_2m: Double?
            var rain: Double?
            var showers: Double?
            var weather_code: Int?
            var pressure_msl: Double?
            var wind_speed_10m: Double?
            var uv_index: Double?
        }

        struct Minutely: Decodable {
            var precipitation: [Double?]?
        }

        var current: Current?
        var minutely_15: Minutely?
    }

    /// The report in an Open-Meteo answer; a missing reading is 0, except the temperature, which it always has.
    static func report(from body: Data) throws -> WeatherReport {
        let answer: Answer
        do {
            answer = try JSONDecoder().decode(Answer.self, from: body)
        } catch {
            throw Failure(description: "Open-Meteo's answer did not read: \(error)")
        }
        guard let current = answer.current, let temperature = current.temperature_2m else {
            throw Failure(description: "Open-Meteo's answer has no current temperature")
        }
        let code = current.weather_code ?? -1
        let lastHour = (answer.minutely_15?.precipitation ?? []).compactMap { $0 }.reduce(0, +)
        let rainingNow = (current.rain ?? 0) + (current.showers ?? 0) > 0
        return WeatherReport(
            temperature: temperature, humidity: current.relative_humidity_2m ?? 0, pressure: current.pressure_msl ?? 0,
            windSpeed: current.wind_speed_10m ?? 0, rainLastHour: lastHour, uvIndex: current.uv_index ?? 0, weatherCode: code,
            isRaining: rainingNow || WeatherCode.isRain(code))
    }
}
