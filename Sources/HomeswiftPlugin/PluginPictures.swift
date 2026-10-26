import Foundation
import Homeswift

/// Pictures a person gives a plugin's page (a scene's tile): kept in the plugin's directory, one file each, by key.
/// A picture comes and goes as a `data:` URL, the only form a plugin page's JSON carries; it is checked to be a
/// JPEG, PNG or WebP by its first bytes, not by what it claims, and kept under `maximumSize`.
///
/// ```swift
/// let pictures = context.pictures("scene-pictures")
/// let version = try pictures.save(key: scene.id, dataURL: body["data"]?.stringValue ?? "")
/// let url = pictures.dataURL(key: scene.id)
/// ```
public final class PluginPictures: Sendable {
    public enum Failure: Error, CustomStringConvertible, Equatable {
        case notAnImage
        case tooLarge(limit: Int)
        case badKey

        public var description: String {
            switch self {
            case .notAnImage: "the picture must be a JPEG, PNG or WebP image"
            case .tooLarge(let limit): "the picture is larger than \(limit / 1024) KB"
            case .badKey: "the picture has no valid name"
            }
        }
    }

    /// Larger pictures are refused: the page shrinks them before it sends them.
    public static let maximumSize = 1024 * 1024

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// Keeps a picture from a `data:image/…;base64,…` URL under `key`, replacing the one it had; answers its version.
    @discardableResult
    public func save(key: String, dataURL: String) throws -> String {
        guard let name = Self.fileName(key) else { throw Failure.badKey }
        guard let comma = dataURL.firstIndex(of: ","), dataURL.hasPrefix("data:"), dataURL[..<comma].hasSuffix(";base64") else { throw Failure.notAnImage }
        // Larger than the limit once decoded: base64 is 4 characters for 3 bytes.
        guard dataURL.count - dataURL.distance(from: dataURL.startIndex, to: comma) <= Self.maximumSize / 3 * 4 + 4 else { throw Failure.tooLarge(limit: Self.maximumSize) }
        guard let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])) else { throw Failure.notAnImage }
        guard data.count <= Self.maximumSize else { throw Failure.tooLarge(limit: Self.maximumSize) }
        guard let kind = Self.kind(of: data) else { throw Failure.notAnImage }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for other in Self.kinds where other.ext != kind.ext { try? FileManager.default.removeItem(at: file(name, other.ext)) }
        try OwnerOnlyFile.write(data, to: file(name, kind.ext))
        return version(of: name) ?? "1"
    }

    /// The picture as a `data:` URL, or nil.
    public func dataURL(key: String) -> String? {
        guard let name = Self.fileName(key) else { return nil }
        for kind in Self.kinds {
            if let data = try? Data(contentsOf: file(name, kind.ext)) { return "data:\(kind.type);base64,\(data.base64EncodedString())" }
        }
        return nil
    }

    /// A short token that changes when the picture does (its file's modification time), or nil without one.
    public func version(key: String) -> String? {
        Self.fileName(key).flatMap(version(of:))
    }

    public func remove(key: String) {
        guard let name = Self.fileName(key) else { return }
        for kind in Self.kinds { try? FileManager.default.removeItem(at: file(name, kind.ext)) }
    }

    /// Every key with a picture, and its version.
    public func versions() -> [String: String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        var result: [String: String] = [:]
        for name in names {
            let url = directory.appendingPathComponent(name)
            let key = url.deletingPathExtension().lastPathComponent
            guard Self.kinds.contains(where: { $0.ext == url.pathExtension }), let version = version(of: key) else { continue }
            result[key] = version
        }
        return result
    }

    // MARK: Files

    static let kinds: [(ext: String, type: String)] = [("jpg", "image/jpeg"), ("png", "image/png"), ("webp", "image/webp")]

    /// The image's kind from its first bytes: JPEG `FF D8 FF`, PNG's signature, WebP `RIFF….WEBP`.
    static func kind(of data: Data) -> (ext: String, type: String)? {
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return kinds[0] }
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return kinds[1] }
        if bytes.count == 12, bytes.starts(with: Array("RIFF".utf8)), Array(bytes[8..<12]) == Array("WEBP".utf8) { return kinds[2] }
        return nil
    }

    /// The key as a file name: letters, digits, `-` and `_` only (scene ids are UUIDs), so a key never leaves the directory.
    static func fileName(_ key: String) -> String? {
        guard !key.isEmpty, key.count <= 128, key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        return key
    }

    private func file(_ name: String, _ ext: String) -> URL { directory.appendingPathComponent("\(name).\(ext)") }

    private func version(of name: String) -> String? {
        for kind in Self.kinds {
            let path = file(name, kind.ext).path
            if let date = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date {
                return String(Int(date.timeIntervalSince1970 * 1000), radix: 36)
            }
        }
        return nil
    }
}

extension PluginContext {
    /// A picture store in a directory of the plugin's storage, by name: see `PluginPictures`.
    public func pictures(_ name: String) -> PluginPictures {
        PluginPictures(directory: storageDirectory.appendingPathComponent(name, isDirectory: true))
    }
}
