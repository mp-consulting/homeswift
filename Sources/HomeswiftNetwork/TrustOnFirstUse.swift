import Foundation
import NIOConcurrencyHelpers

extension HTTPClient {
    /// Trust on first use for a device with a self-signed certificate: `.any` until a first certificate is seen,
    /// then `.pinned` to it, so a different certificate later is refused. A refused certificate is reported once,
    /// so the log says it once and not on every retry.
    ///
    /// ```swift
    /// let trust = HTTPClient.TrustOnFirstUse(pinned: saved) { fingerprint in store.set(fingerprint, for: host) }
    /// let response = try await trust.client.send(request)
    /// if trust.observe(response.certificateFingerprint) { logger.info("Pinned \(host)'s certificate") }
    /// ```
    public final class TrustOnFirstUse: Sendable {
        private struct State {
            var fingerprint: String?
            var reported: Set<String> = []
            /// The client for `fingerprint`, made once: a new one would build its TLS context again for each request.
            var client: HTTPClient?
        }

        private let state: NIOLockedValueBox<State>
        private let onPinned: (@Sendable (String) -> Void)?

        /// `pinned` is a fingerprint saved earlier, in any spelling; `onPinned` keeps a new pin (its argument is lowercase
        /// hex, as `fingerprint`).
        public init(pinned: String? = nil, onPinned: (@Sendable (String) -> Void)? = nil) {
            state = NIOLockedValueBox(State(fingerprint: Self.valid(pinned)))
            self.onPinned = onPinned
        }

        /// The pinned SHA-256 fingerprint, lowercase hex; nil until the first certificate.
        public var fingerprint: String? { state.withLockedValue { $0.fingerprint } }

        /// How to connect now: any certificate the first time, exactly the pinned one after.
        public var tls: HTTPClient.TLS { fingerprint.map { .pinned($0) } ?? .any }

        /// A client connecting with `tls`, kept until the pin changes (pinned, or reset), so its TLS context is built
        /// once rather than for every request.
        public var client: HTTPClient {
            state.withLockedValue { state in
                let tls: HTTPClient.TLS = state.fingerprint.map { .pinned($0) } ?? .any
                if let client = state.client, client.tls == tls { return client }
                let client = HTTPClient(tls: tls)
                state.client = client
                return client
            }
        }

        /// Records the certificate a connection saw (`HTTPResponse.certificateFingerprint`). Returns true when it was
        /// pinned now, after calling `onPinned`; false when one was pinned already or `presented` is not a fingerprint.
        @discardableResult
        public func observe(_ presented: String?) -> Bool {
            guard let actual = Self.valid(presented) else { return false }
            let pinned = state.withLockedValue { state -> Bool in
                guard state.fingerprint == nil else { return false }
                state.fingerprint = actual
                return true
            }
            if pinned { onPinned?(actual) }
            return pinned
        }

        /// A connection refused because the certificate is not the pinned one (`HTTPClientError.certificateMismatch`).
        /// Returns true the first time this certificate is reported, when the caller should tell the user.
        public func reportMismatch(observed: String) -> Bool {
            guard let actual = Self.valid(observed) else { return false }
            return state.withLockedValue { $0.reported.insert(actual).inserted }
        }

        /// Forgets the pin, so the next certificate is trusted again (the user accepted a new one).
        public func reset() {
            state.withLockedValue { $0 = State() }
        }

        private static func valid(_ fingerprint: String?) -> String? {
            let normalized = HTTPClient.normalizeFingerprint(fingerprint ?? "")
            return normalized.count == 64 ? normalized : nil
        }
    }
}
