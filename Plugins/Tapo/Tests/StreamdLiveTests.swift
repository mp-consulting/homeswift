import Foundation
import HomeswiftNetwork
import Testing

@testable import HomeswiftTapo

/// A real camera, only when asked: `TAPO_LIVE_HOST` (its address), `TAPO_LIVE_PASSWORD_FILE` (a file holding the
/// owner's cloud password), `TAPO_LIVE_OUTPUT` (where the MPEG-TS goes) and optionally `TAPO_LIVE_RESOLUTION` (`HD` or
/// `VGA`) and `TAPO_LIVE_BYTES`. Skipped otherwise, as in CI.
struct StreamdLiveTests {
    static let environment = ProcessInfo.processInfo.environment

    @Test(.enabled(if: environment["TAPO_LIVE_HOST"] != nil), .timeLimit(.minutes(1)))
    func recordsASampleFromARealCamera() async throws {
        let host = try #require(Self.environment["TAPO_LIVE_HOST"])
        let passwordFile = try #require(Self.environment["TAPO_LIVE_PASSWORD_FILE"])
        let output = try #require(Self.environment["TAPO_LIVE_OUTPUT"])
        let password = try String(contentsOfFile: passwordFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let resolution = Streamd.Resolution(rawValue: Self.environment["TAPO_LIVE_RESOLUTION"] ?? "HD") ?? .hd
        let wanted = Int(Self.environment["TAPO_LIVE_BYTES"] ?? "") ?? 4 * 1024 * 1024
        var logger = testLogger
        logger.logLevel = .trace
        let client = StreamdClient(host: host, password: { password }, connect: { host, port, timeout in
            try await TCPStream.connect(host: host, port: port, timeout: timeout)
        }, logger: logger)
        let started = ContinuousClock.now
        let session = try await client.open(resolution: resolution)
        let opened = ContinuousClock.now - started
        var sample = Data()
        for try await data in session.stream {
            sample.append(data)
            if sample.count >= wanted { break }
        }
        await session.close()
        try sample.write(to: URL(fileURLWithPath: output))
        print("Streamd live: session \(session.sessionID ?? "?"), opened in \(opened), \(sample.count) bytes in \(ContinuousClock.now - started)")
        #expect(sample.first == 0x47)
    }
}
