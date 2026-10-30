import Foundation
import Homeswift
import Matter

/// The Matter node's state (fabrics, operational keys, the passcode verifier, endpoint numbers) as files under
/// `matter/`, one per key, written with `OwnerOnlyFile` like every file the bridge keeps.
public actor MatterFileStorage: MatterStorage {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// The node's keys are plain names; anything else is hex-encoded so it cannot leave the directory.
    private func url(_ key: String) -> URL {
        let plain = !key.isEmpty && !key.hasPrefix(".") && key.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0))
        }
        return directory.appendingPathComponent(plain ? key : "x-" + Secrets.hex(Array(key.utf8)))
    }

    public func value(for key: String) -> [UInt8]? {
        (try? Data(contentsOf: url(key))).map(Array.init)
    }

    public func setValue(_ value: [UInt8]?, for key: String) throws {
        guard let value else {
            try? FileManager.default.removeItem(at: url(key))
            return
        }
        try OwnerOnlyFile.write(Data(value), to: url(key))
    }
}
