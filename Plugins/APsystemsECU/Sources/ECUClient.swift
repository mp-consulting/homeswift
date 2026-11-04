import Foundation
import HomeswiftNetwork

/// Sends one request to an ECU and answers its frame, whole (3.1): connect, send, read the bytes the header announces,
/// close. Tests answer from memory.
protocol ECUExchanging: Sendable {
    func exchange(_ request: [UInt8], host: String, port: Int) async throws -> [UInt8]
}

/// Reads the ECU-C's CT clamps (3.9). Tests answer from memory.
protocol ECUMeterReading: Sendable {
    func meter(host: String) async throws -> ECUMeter
}

/// Why an exchange failed, besides a frame that does not check.
enum ECUTransportError: Error, Equatable, CustomStringConvertible, Sendable {
    case timeout
    /// The ECU closed the connection before the frame was whole (or sent nothing).
    case closed(received: Int)

    var description: String {
        switch self {
        case .timeout: "no answer in time"
        case .closed(let received): received == 0 ? "the ECU closed the connection without answering" : "the ECU closed the connection after \(received) bytes"
        }
    }
}

/// The TCP side: a fresh connection for each request, as every ECU model wants, the connect tried `retries` times.
struct ECUClient: ECUExchanging {
    typealias Connect = @Sendable (_ host: String, _ port: Int, _ timeout: Duration) async throws -> any ByteStream

    var retries: Int
    /// Between connect attempts.
    var retryDelay: Duration
    var connectTimeout: Duration
    /// For the whole answer, from the request on.
    var readTimeout: Duration
    var connect: Connect

    init(
        retries: Int = 2, retryDelay: Duration = .seconds(2), connectTimeout: Duration = .seconds(5), readTimeout: Duration = .seconds(5),
        connect: @escaping Connect = { host, port, timeout in try await TCPStream.connect(host: host, port: port, timeout: timeout) }
    ) {
        self.retries = max(1, retries)
        self.retryDelay = retryDelay
        self.connectTimeout = connectTimeout
        self.readTimeout = readTimeout
        self.connect = connect
    }

    func exchange(_ request: [UInt8], host: String, port: Int) async throws -> [UInt8] {
        let stream = try await connected(host: host, port: port)
        do {
            let frame = try await Self.withTimeout(readTimeout) {
                try await stream.send(request)
                var reader = ECUFrameReader()
                for try await chunk in stream.incoming {
                    if let frame = try reader.append(chunk) { return frame }
                }
                // Closed early: what came, for the length check to name (an ECU that answered nothing is an error of its own).
                guard !reader.bytes.isEmpty else { throw ECUTransportError.closed(received: 0) }
                return reader.bytes
            }
            await stream.close()
            return frame
        } catch {
            await stream.close()
            throw error
        }
    }

    /// A connection, tried `retries` times while it is refused or unreachable, `retryDelay` apart.
    private func connected(host: String, port: Int) async throws -> any ByteStream {
        var attempt = 1
        while true {
            do {
                return try await connect(host, port, connectTimeout)
            } catch let error as HTTPClientError {
                guard attempt < retries, case .cannotConnect = error else { throw error }
                attempt += 1
                try await Task.sleep(for: retryDelay)
            }
        }
    }

    /// `operation`, or `ECUTransportError.timeout` once `timeout` passes.
    static func withTimeout<T: Sendable>(_ timeout: Duration, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw ECUTransportError.timeout
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw ECUTransportError.timeout }
            return first
        }
    }
}

/// The ECU-C's CT clamps, in W per phase: the production clamps and the grid clamps (positive while importing, as
/// inferred from consumed = production + grid; docs/clean-room/APsystemsECU.md, 3.9). nil where the ECU gave nothing.
struct ECUMeter: Sendable, Equatable {
    var production: [Double]?
    var grid: [Double]?

    /// All the grid phases, nil without them.
    var gridPower: Double? { grid.map { $0.reduce(0, +) } }
    /// The home's use, production + grid on each phase; nil without the grid clamps.
    var homePower: Double? {
        guard let grid else { return nil }
        let production = self.production ?? []
        return (0..<max(grid.count, production.count)).reduce(0) { sum, phase in
            sum + (phase < grid.count ? grid[phase] : 0) + (phase < production.count ? production[phase] : 0)
        }
    }

    /// The JSON of `/index.php/meter/old_meter_power_graph`: arrays `power1` (production) and `power2` (grid), each
    /// element with `powerA`, `powerB`, `powerC`; the last element of each counts.
    static func parse(_ data: Data) throws -> ECUMeter {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ECUFrameError.malformed("meter answer") }
        func phases(_ key: String) -> [Double]? {
            guard let list = object[key] as? [Any], let last = list.last as? [String: Any] else { return nil }
            let values = ["powerA", "powerB", "powerC"].compactMap { name -> Double? in
                let value: Double? = switch last[name] {
                case let number as Double: number
                case let number as Int: Double(number)
                case let number as NSNumber: number.doubleValue
                case let text as String: Double(text.trimmingCharacters(in: .whitespaces))
                default: nil
                }
                // A reading of the house, so within what a house draws: a value past it is not one.
                guard let value, value.isFinite, abs(value) < 1_000_000 else { return nil }
                return value
            }
            return values.isEmpty ? nil : values
        }
        return ECUMeter(production: phases("power1"), grid: phases("power2"))
    }
}

/// The meter over the ECU-C's local web site.
struct ECUMeterClient: ECUMeterReading {
    /// nil: a plain HTTP client made for the request (an instance that never reads a meter makes none).
    var http: (any HTTPSending)?
    var timeout: Duration = .seconds(15)

    func meter(host: String) async throws -> ECUMeter {
        let http = self.http ?? HTTPClient(maximumBodySize: 512 * 1024)
        let address = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        guard let url = URL(string: "http://\(address)/index.php/meter/old_meter_power_graph") else { throw HTTPClientError.invalidURL(host) }
        let response = try await http.send(HTTPRequest(url: url, headers: [("X-Requested-With", "XMLHttpRequest")], timeout: timeout))
        guard response.isSuccess else { throw ECUFrameError.malformed("meter status \(response.status)") }
        return try ECUMeter.parse(response.body)
    }
}
