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

    /// The files `FileStorage` would use, so either reads what the other wrote.
    private func url(_ key: String) -> URL { directory.appendingPathComponent(FileStorage.fileName(for: key)) }

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
