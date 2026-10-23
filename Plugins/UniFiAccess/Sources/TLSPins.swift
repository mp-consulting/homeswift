import Foundation
import Homeswift
import HomeswiftNetwork
import Logging
import NIOConcurrencyHelpers

/// A SHA-256 fingerprint in the spelling the Homebridge plugin stored and logged it: uppercase, colon-separated.
/// nil for anything that is not a SHA-256 fingerprint.
func colonFingerprint(_ fingerprint: String?) -> String? {
    let hex = Array(HTTPClient.normalizeFingerprint(fingerprint ?? "").uppercased())
    guard hex.count == 64 else { return nil }
    return stride(from: 0, to: 64, by: 2).map { String(hex[$0..<$0 + 2]) }.joined(separator: ":")
}

/// The pinned controller certificates, by address (`unifi-access-tls-pins.json`): the same file format as the
/// Homebridge plugin's, so a copied file keeps its pins. The plugin and its settings page share it, whichever
/// connects to a controller first.
final class TLSPinStore: Sendable {
    let url: URL
    private let logger: Logger
    private let pins = NIOLockedValueBox<[String: String]?>(nil)

    init(url: URL, logger: Logger) {
        self.url = url
        self.logger = logger
    }

    func pin(for address: String) -> String? {
        pins.withLockedValue { cached in
            if cached == nil { cached = load() }
            return cached?[Self.key(address)]
        }
    }

    /// Pins a fingerprint and writes the file, readable by the owner only.
    func set(_ fingerprint: String, for address: String) {
        guard let normalized = colonFingerprint(fingerprint) else { return }
        pins.withLockedValue { cached in
            // Read the file again first: another instance may have pinned since.
            var current = load()
            current[Self.key(address)] = normalized
            cached = current
            do {
                let data = try JSONSerialization.data(withJSONObject: current, options: [.prettyPrinted, .sortedKeys])
                try OwnerOnlyFile.write(data + Data("\n".utf8), to: url)
            } catch {
                logger.error("Unable to save the pinned TLS certificate fingerprint to \(url.path): \(error).")
            }
        }
    }

    private static func key(_ address: String) -> String { address.trimmingCharacters(in: .whitespaces).lowercased() }

    private func load() -> [String: String] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            logger.error("Unable to parse pinned TLS certificate fingerprints in \(url.path).")
            return [:]
        }
        var result: [String: String] = [:]
        for (address, value) in object {
            if let fingerprint = colonFingerprint(value as? String) { result[Self.key(address)] = fingerprint }
        }
        return result
    }
}
