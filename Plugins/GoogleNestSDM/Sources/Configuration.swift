import Foundation
import HomeswiftPlugin

extension GoogleNestSDMPlugin {
    /// The `homebridge-google-nest-sdm` block, with its option names (docs/clean-room/GoogleNestSDM.md, 1.2). Every key is
    /// optional here: Setup writes the account's, and a Homebridge block's `clientSecret` and `refreshToken` move into the
    /// vault (`canonicalSettings`). Booleans and numbers written as strings (the Homebridge README's example) are read too.
    public struct Configuration: Decodable, Sendable {
        public var name: String?
        public var clientId: String?
        /// Secret: read from a Homebridge block, kept in the vault by Setup.
        public var clientSecret: String?
        public var projectId: String?
        /// Secret: read from a Homebridge block, kept in the vault by Setup.
        public var refreshToken: String?
        /// `projects/<gcp-project-id>/subscriptions/<subscription-id>`.
        public var subscriptionId: String?
        public var gcpProjectId: String?
        /// The live streams' video encoder and its options, split on whitespace; `copy` sends the camera's H.264 as it is.
        public var vEncoder: String?
        public var showFan: Bool?
        /// Seconds the fan runs when turned on, 1 to 43200; 900 when absent.
        public var fanDuration: Int?
        public var analyzeDuration: Int?
        public var probeSize: Int?

        enum CodingKeys: String, CodingKey {
            case name, clientId, clientSecret, projectId, refreshToken, subscriptionId, gcpProjectId, vEncoder, showFan, fanDuration, analyzeDuration, probeSize
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            func text(_ key: CodingKeys) -> String? {
                (try? container.decodeIfPresent(String.self, forKey: key))?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyText
            }
            func number(_ key: CodingKeys) -> Int? {
                if let value = try? container.decodeIfPresent(Int.self, forKey: key) { return value }
                if let value = try? container.decodeIfPresent(Double.self, forKey: key), value.isFinite { return Int(value) }
                return text(key).flatMap { Int($0) }
            }
            func flag(_ key: CodingKeys) -> Bool? {
                if let value = try? container.decodeIfPresent(Bool.self, forKey: key) { return value }
                switch text(key)?.lowercased() {
                case "true", "1", "yes": return true
                case "false", "0", "no": return false
                default: return nil
                }
            }
            name = text(.name)
            clientId = text(.clientId)
            clientSecret = text(.clientSecret)
            projectId = text(.projectId)
            refreshToken = text(.refreshToken)
            subscriptionId = text(.subscriptionId)
            gcpProjectId = text(.gcpProjectId)
            vEncoder = text(.vEncoder)
            showFan = flag(.showFan)
            fanDuration = number(.fanDuration)
            analyzeDuration = number(.analyzeDuration)
            probeSize = number(.probeSize)
        }

        init() {}
    }
}

/// What the plugin reads from its settings once: the camera options and the fan's.
struct NestOptions: Sendable {
    static let defaultEncoder = "libx264 -preset ultrafast -tune zerolatency"
    static let defaultFanDuration = 900
    static let fanDurationRange = 1...43200

    var encoder: [String]
    var analyzeDuration: Int
    var probeSize: Int
    var showFan: Bool
    /// nil when the block's is outside 1 to 43200: fan writes then fail, as the Homebridge plugin's do.
    var fanDuration: Int?
    var debug: Bool

    init(_ configuration: GoogleNestSDMPlugin.Configuration, debug: Bool) {
        encoder = (configuration.vEncoder ?? Self.defaultEncoder).split(whereSeparator: \.isWhitespace).map(String.init)
        analyzeDuration = configuration.analyzeDuration ?? 15_000_000
        probeSize = configuration.probeSize ?? 100_000_000
        showFan = configuration.showFan ?? false
        let duration = configuration.fanDuration ?? Self.defaultFanDuration
        fanDuration = Self.fanDurationRange.contains(duration) ? duration : nil
        self.debug = debug
    }

    /// `vEncoder` is exactly `copy`: no transcoding.
    var copiesVideo: Bool { encoder == ["copy"] }
}

extension String {
    var nonEmptyText: String? { isEmpty ? nil : self }
}

extension Optional where Wrapped == String {
    var nonEmptyText: String? { self.flatMap { $0.isEmpty ? nil : $0 } }
}
