import Foundation
import Homeswift
import HomeswiftNetwork
import Logging
import NIOConcurrencyHelpers

/// A SHA-256 fingerprint as the Homebridge plugin writes it (Node's `fingerprint256`): upper-case hex pairs
/// separated by colons. nil for anything that is not 32 bytes of hex.
func normalizeFingerprint(_ fingerprint: String?) -> String? {
    let hex = Array(HTTPClient.normalizeFingerprint(fingerprint ?? "").uppercased())
    guard hex.count == 64 else { return nil }
    return stride(from: 0, to: 64, by: 2).map { String(hex[$0..<$0 + 2]) }.joined(separator: ":")
}

/// Trust on first use for one controller (`ProtectTlsPin`, on `HTTPClient.TrustOnFirstUse`): the first
/// certificate seen is pinned, and any other one is refused before a request, and so a password or cookie, is
/// sent. Only used when `verifyTls` is off, since UniFi consoles ship with self-signed certificates.
final class ProtectTLSPin: Sendable {
    struct Options: Sendable {
        var pinnedFingerprint: String?
        /// Called once when a new fingerprint is pinned, to persist it.
        var onFingerprint: (@Sendable (String) -> Void)?
        /// Called the first time a given mismatched fingerprint is seen.
        var onFingerprintMismatch: (@Sendable (_ expected: String, _ actual: String) -> Void)?

        init(pinnedFingerprint: String? = nil, onFingerprint: (@Sendable (String) -> Void)? = nil, onFingerprintMismatch: (@Sendable (String, String) -> Void)? = nil) {
            self.pinnedFingerprint = pinnedFingerprint
            self.onFingerprint = onFingerprint
            self.onFingerprintMismatch = onFingerprintMismatch
        }
    }

    private let trust: HTTPClient.TrustOnFirstUse
    private let options: Options
    private let log: ProtectLog

    init(log: ProtectLog, options: Options = Options()) {
        trust = HTTPClient.TrustOnFirstUse(pinned: options.pinnedFingerprint)
        self.options = options
        self.log = log
    }

    /// The pinned fingerprint, as the Homebridge plugin writes it.
    var fingerprint: String? { normalizeFingerprint(trust.fingerprint) }

    /// The TLS policy for the next connection: the pinned certificate, or any one on first contact.
    var policy: HTTPClient.TLS { trust.tls }

    /// Pins the certificate a first contact presented.
    func accept(host: String, presented: String?) {
        guard trust.observe(presented), let actual = fingerprint else { return }
        log.info("Trusting and pinning the TLS certificate presented by \(host) (SHA-256 fingerprint: \(actual)).")
        options.onFingerprint?(actual)
    }

    /// Reports a certificate that is not the pinned one, once per certificate.
    func reportMismatch(host: String, observed: String) {
        guard let actual = normalizeFingerprint(observed), let expected = fingerprint, trust.reportMismatch(observed: observed) else { return }
        log.error("The TLS certificate presented by \(host) does not match the pinned certificate. Refusing to connect - no credentials have been sent. "
            + "Expected SHA-256 fingerprint: \(expected). Received: \(actual). This can happen when the controller certificate is regenerated, or it may indicate that someone is "
            + "intercepting your connection.")
        options.onFingerprintMismatch?(expected, actual)
    }
}

/// The controllers' pinned fingerprints, by address, in `unifi-protect-tls-pins.json` (the file the
/// Homebridge plugin keeps in its storage path, same format), written owner-only.
final class ProtectTLSPinStore: Sendable {
    let url: URL
    private let onError: @Sendable (String) -> Void
    private let pins = NIOLockedValueBox<[String: String]?>(nil)

    init(url: URL, onError: @escaping @Sendable (String) -> Void = { _ in }) {
        self.url = url
        self.onError = onError
    }

    func get(_ address: String) -> String? {
        pins.withLockedValue { cached in
            if cached == nil { cached = load() }
            return cached?[key(address)]
        }
    }

    func set(_ address: String, fingerprint: String) {
        guard let normalized = normalizeFingerprint(fingerprint) else { return }
        pins.withLockedValue { cached in
            // Read the file again first: the settings page or another instance may have pinned since.
            var current = load()
            current[key(address)] = normalized
            cached = current
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                var data = try encoder.encode(current)
                data.append(0x0A)
                try OwnerOnlyFile.write(data, to: url)
            } catch {
                onError("Unable to save the pinned TLS certificate fingerprint to \(url.path): \(error).")
            }
        }
    }

    private func key(_ address: String) -> String {
        address.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// The file's pins; the caller holds the lock.
    private func load() -> [String: String] {
        var result: [String: String] = [:]
        guard FileManager.default.fileExists(atPath: url.path) else { return result }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            onError("Unable to read pinned TLS certificate fingerprints from \(url.path): \(error).")
            return result
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            onError("Unable to parse pinned TLS certificate fingerprints in \(url.path).")
            return result
        }
        for (address, value) in object {
            if let normalized = normalizeFingerprint(value as? String) { result[key(address)] = normalized }
        }
        return result
    }
}

/// Counts consecutive API errors and, past a threshold, pauses all requests for a while (`CircuitBreaker`).
struct CircuitBreaker: Sendable {
    enum State: Equatable {
        /// Below the threshold: the request goes ahead.
        case closed
        /// The threshold was just crossed: refuse, tell the user, drop the connections.
        case tripped
        /// Still paused.
        case open
        /// The pause is over and the count reset: go ahead, logging in again first.
        case resumed
    }

    let errorLimit: Int
    /// The pause.
    let retryInterval: Duration
    private(set) var errorCount = 0
    private(set) var isThrottled = false
    private var throttleStart: ContinuousClock.Instant?
    private let now: @Sendable () -> ContinuousClock.Instant

    init(errorLimit: Int, retryInterval: Duration, now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.errorLimit = errorLimit
        self.retryInterval = retryInterval
        self.now = now
    }

    var isOverLimit: Bool { errorCount >= errorLimit }

    mutating func check() -> State {
        guard isOverLimit else { return .closed }
        let now = now()
        guard isThrottled, let start = throttleStart else {
            throttleStart = now
            isThrottled = true
            return .tripped
        }
        if now - start < retryInterval { return .open }
        errorCount = 0
        isThrottled = false
        return .resumed
    }

    mutating func recordFailure() { errorCount += 1 }

    mutating func recordSuccess() {
        errorCount = 0
        isThrottled = false
    }
}
