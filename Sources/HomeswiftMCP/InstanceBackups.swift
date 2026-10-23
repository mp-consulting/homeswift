import Foundation
import Homeswift
import HomeswiftAI
import HomeswiftPlugin
import Logging

/// Backups of the whole instance, after the Homebridge UI's (homebridge-config-ui-x's backup module): an archive of
/// the storage directory (config.json, each bridge's HomeKit identity and pairings, the accessory caches, the plugins'
/// own files, the web UI's users and certificate, the MCP audit log), kept in a folder by the daily schedule or on
/// demand, downloadable, and restorable from an upload.
///
/// The archive is a plain tar (`Tar`): `info.json` (what made it, when) and `storage/…`. Names in `excludedNames`, at
/// any depth, are never archived and never restored, so a crafted archive cannot plant them either. A restore is
/// checked whole (paths, types, config.json) and staged in `.restore-pending/`; the next start of homeswift applies it
/// before reading anything (`applyPendingRestore`), so the running bridge cannot write its state over the restored one.
public struct InstanceBackups: Sendable {
    /// One archive in the backups folder: `homeswift-backup-<instance>.<milliseconds>.tar`.
    public struct Backup: Sendable, Equatable {
        public var id: String
        public var instanceID: String
        public var date: Date
        public var fileName: String
        public var bytes: Int
        public var url: URL
    }

    /// What a staged restore holds.
    public struct Staged: Sendable {
        public var created: String?
        public var version: String?
        public var bridge: String?
        public var files: Int
        public var skipped: [String]
    }

    public struct BackupError: Error, CustomStringConvertible, Equatable {
        public let description: String
        public init(_ description: String) { self.description = description }
    }

    /// Never archived, never restored, at any depth: the scheduled backups themselves, what is rebuilt as the bridge
    /// runs (its log, its metrics), the web UI's sessions (logins stay with the machine that made them), a staged
    /// restore, and what other systems put next to config.json (upstream's list: packaging, caches, NAS metadata).
    public static let excludedNames: Set<String> = [
        "instance-backups", "logs", "metrics", "ui-sessions.json", pendingName, ".DS_Store",
        "accessory-history", "recordings", "node_modules", ".git", ".cache", ".venv", ".npm", ".npmrc", "package.json", "package-lock.json",
        "pnpm-lock.yaml", "FFmpeg", "fdk-aac", ".homebridge.sock", "#recycle", "@eaDir", "nssm.exe", "homebridge.log", "startup.sh",
        ".docker.env", "docker-compose.yml", ".uix-secrets", ".uix-hb-service-homebridge-startup.json",
    ]

    /// Files larger than this are left out of an archive, with a warning (upstream's limit).
    public static let maxFileSize = 10 * 1024 * 1024
    /// The largest archive a restore takes: the web UI's upload limit too.
    public static let maxArchiveSize = 64 * 1024 * 1024
    /// How long scheduled backups are kept by default.
    public static let defaultRetentionDays = 7
    static let pendingName = ".restore-pending"
    static let format = "homeswift-backup"

    public let storage: URL
    public let folder: URL
    /// The folder is one the user named (`scheduledBackupPath`): it must exist already.
    public let customFolder: Bool
    /// The bridge's device ID without colons: archives of several instances can share a folder.
    public let instanceID: String
    let logger: Logger

    public init(storage: URL, folder: URL? = nil, instanceID: String, logger: Logger = Logger(label: "homeswift.backup")) {
        self.storage = storage
        self.folder = folder ?? storage.appendingPathComponent("instance-backups")
        customFolder = folder != nil
        let bare = instanceID.filter { $0.isLetter || $0.isNumber }
        self.instanceID = bare.isEmpty ? "homeswift" : String(bare.prefix(32))
        self.logger = logger
    }

    /// Whether a name is left out: an excluded name, or a file being written (`OwnerOnlyFile`'s `.<name>.tmp-…`).
    public static func isExcluded(_ name: String) -> Bool {
        excludedNames.contains(name) || (name.hasPrefix(".") && name.contains(".tmp-"))
    }

    // MARK: Making one

    /// The archive of the storage directory as it is now, and the files it left out for their size.
    public func makeArchive(info: [String: JSONValue] = [:], now: Date = Date()) throws -> (data: Data, skipped: [String]) {
        let manager = FileManager.default
        let root = storage.resolvingSymlinksInPath().standardizedFileURL
        let folderPath = folder.resolvingSymlinksInPath().standardizedFileURL.path
        guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey], options: []) else {
            throw BackupError("cannot read \(storage.path)")
        }
        var writer = Tar.Writer()
        var description = info
        description["format"] = .string(Self.format)
        description["timestamp"] = .string(Timestamp.iso8601(now))
        description["homeswift"] = .string(PluginHost.version)
        #if os(macOS)
        description["platform"] = "macOS"
        #else
        description["platform"] = "Linux"
        #endif
        try writer.append(Tar.Entry(path: "info.json", data: JSONValue.object(description).encoded(pretty: true), modified: now))
        try writer.append(Tar.Entry(path: "storage", kind: .directory, modified: now))
        var skipped: [String] = []
        var total = 0
        while let url = enumerator.nextObject() as? URL {
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(root.path + "/") else { continue }
            let relative = String(path.dropFirst(root.path.count + 1))
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
            if Self.isExcluded(url.lastPathComponent) || path == folderPath || values?.isSymbolicLink == true {
                // Links, sockets and pipes are not archived: a restore must only ever write plain files.
                if values?.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            if values?.isDirectory == true {
                try writer.append(Tar.Entry(path: "storage/\(relative)", kind: .directory, modified: now))
            } else if values?.isRegularFile == true {
                let size = values?.fileSize ?? 0
                guard size <= Self.maxFileSize else {
                    logger.warning("Backup leaves out a file larger than 10 MB", metadata: ["file": "\(relative)", "bytes": "\(size)"])
                    skipped.append(relative)
                    continue
                }
                guard let data = try? Data(contentsOf: url) else { continue }
                total += data.count
                try writer.append(Tar.Entry(path: "storage/\(relative)", data: data, modified: (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? now))
            }
        }
        let data = writer.data
        if data.count > Self.maxArchiveSize {
            logger.error("The backup is larger than a restore accepts (64 MB)", metadata: ["bytes": "\(data.count)"])
        }
        return (data, skipped)
    }

    /// The folder, made owner-only when it is the default one; a folder the user named must exist and be writable.
    func ensureFolder() throws {
        let manager = FileManager.default
        if customFolder {
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw BackupError("the backup folder \(folder.path) does not exist")
            }
            guard manager.isWritableFile(atPath: folder.path) else { throw BackupError("the backup folder \(folder.path) is not writable") }
        } else {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        }
    }

    /// Makes an archive and keeps it in the folder, owner-only.
    @discardableResult
    public func create(info: [String: JSONValue] = [:], now: Date = Date()) throws -> Backup {
        try ensureFolder()
        let (data, _) = try makeArchive(info: info, now: now)
        var milliseconds = Int((now.timeIntervalSince1970 * 1000).rounded())
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent(fileName(milliseconds)).path) { milliseconds += 1 }
        let url = folder.appendingPathComponent(fileName(milliseconds))
        try OwnerOnlyFile.write(data, to: url)
        return Backup(id: "\(instanceID).\(milliseconds)", instanceID: instanceID, date: Date(timeIntervalSince1970: Double(milliseconds) / 1000),
                      fileName: url.lastPathComponent, bytes: data.count, url: url)
    }

    func fileName(_ milliseconds: Int) -> String { "homeswift-backup-\(instanceID).\(milliseconds).tar" }

    /// A download's name: the same shape as the kept ones.
    public func downloadName(now: Date = Date()) -> String { fileName(Int((now.timeIntervalSince1970 * 1000).rounded())) }

    // MARK: The folder

    /// The archives in the folder, newest first.
    public func list() throws -> [Backup] {
        try ensureFolder()
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        return names.compactMap { name -> Backup? in
            guard let id = Self.id(fromFileName: name) else { return nil }
            let parts = id.split(separator: ".")
            guard parts.count == 2, let milliseconds = Double(parts[1]) else { return nil }
            let url = folder.appendingPathComponent(name)
            let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            return Backup(id: id, instanceID: String(parts[0]), date: Date(timeIntervalSince1970: milliseconds / 1000), fileName: name, bytes: bytes, url: url)
        }.sorted { $0.date > $1.date }
    }

    /// `homeswift-backup-<instance>.<ms>.tar` → `<instance>.<ms>`.
    static func id(fromFileName name: String) -> String? {
        guard name.hasPrefix("homeswift-backup-"), name.hasSuffix(".tar") else { return nil }
        let id = String(name.dropFirst("homeswift-backup-".count).dropLast(4))
        return isValidID(id) ? id : nil
    }

    /// An id names a file in the folder and nothing else: letters and digits, a dot, digits.
    public static func isValidID(_ id: String) -> Bool {
        let parts = id.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 2 && (1...32).contains(parts[0].count) && parts[0].allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
            && (1...16).contains(parts[1].count) && parts[1].allSatisfy { $0.isASCII && $0.isNumber }
    }

    public func backup(id: String) throws -> Backup {
        guard Self.isValidID(id) else { throw BackupError("not a backup id: \(id)") }
        guard let found = try list().first(where: { $0.id == id }) else { throw BackupError("no backup \(id)") }
        return found
    }

    public func delete(id: String) throws {
        try FileManager.default.removeItem(at: try backup(id: id).url)
    }

    /// Removes this instance's archives older than `days`; answers their names. Archives of other instances in a
    /// shared folder are theirs to prune.
    @discardableResult
    public func prune(keepingDays days: Int, now: Date = Date()) -> [String] {
        let old = ((try? list()) ?? []).filter { $0.instanceID == instanceID && now.timeIntervalSince($0.date) >= Double(days) * 86400 }
        for backup in old { try? FileManager.default.removeItem(at: backup.url) }
        return old.map(\.fileName)
    }

    // MARK: Restoring

    var pending: URL { storage.appendingPathComponent(Self.pendingName) }

    /// Checks an archive and stages its files for the next start: a tar of regular files and directories under
    /// relative paths, with this format's `info.json` and a `storage/config.json` homeswift can run. Anything else
    /// is refused before a file is written; excluded names are skipped.
    public func stageRestore(_ archive: Data) throws -> Staged {
        guard archive.count <= Self.maxArchiveSize else { throw BackupError("the archive is larger than 64 MB") }
        let entries: [Tar.Entry]
        do {
            entries = try Tar.read(archive)
        } catch let error as Tar.FormatError {
            throw BackupError("not a homeswift backup: \(error.description)")
        }
        guard let infoEntry = entries.first(where: { $0.path == "info.json" && $0.kind == .file }),
              let info = try? JSONValue(data: infoEntry.data), info["format"]?.stringValue == Self.format else {
            throw BackupError("not a homeswift backup: it has no info.json from homeswift (an archive made by Backups › Download)")
        }
        guard let configEntry = entries.first(where: { $0.path == "storage/config.json" && $0.kind == .file }) else {
            throw BackupError("the backup has no config.json")
        }
        let configuration: HomeswiftConfiguration
        do {
            configuration = try HomeswiftConfiguration.decode(configEntry.data)
            try configuration.validate()
        } catch {
            throw BackupError("the backup's config.json cannot run: \(error)")
        }
        let manager = FileManager.default
        try? manager.removeItem(at: pending)
        try manager.createDirectory(at: pending, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var files = 0
        var skipped: Set<String> = []
        do {
            for entry in entries where entry.path.hasPrefix("storage/") {
                let relative = String(entry.path.dropFirst("storage/".count))
                try Tar.checkPath(relative)
                let parts = relative.split(separator: "/").map(String.init)
                if let excluded = parts.first(where: Self.isExcluded) {
                    skipped.insert(excluded)
                    continue
                }
                let target = pending.appendingPathComponent(relative)
                if entry.kind == .directory {
                    try manager.createDirectory(at: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                } else {
                    try OwnerOnlyFile.write(entry.data, to: target)
                    files += 1
                }
            }
        } catch {
            try? manager.removeItem(at: pending)
            throw error
        }
        return Staged(created: info["timestamp"]?.stringValue, version: info["homeswift"]?.stringValue, bridge: configuration.bridge.name, files: files, skipped: skipped.sorted())
    }

    /// Whether a restore waits for the next start.
    public var hasPendingRestore: Bool { FileManager.default.fileExists(atPath: pending.appendingPathComponent("config.json").path) }

    /// Drops a staged restore.
    public func cancelPendingRestore() { try? FileManager.default.removeItem(at: pending) }

    /// Applies a staged restore, at start, before config.json is read: the files go over the storage directory's
    /// (those the backup does not have stay), then config.json keeps this machine's bridge and web UI ports, as
    /// upstream does, so the bridge and the page stay where they were. A staged tree with a link in it is refused
    /// whole. Answers what it did, for the log; nil when nothing was staged.
    @discardableResult
    public static func applyPendingRestore(storage: URL, logger: Logger) -> String? {
        let manager = FileManager.default
        let pending = storage.appendingPathComponent(pendingName)
        guard manager.fileExists(atPath: pending.appendingPathComponent("config.json").path) else { return nil }
        defer { try? manager.removeItem(at: pending) }
        let root = pending.resolvingSymlinksInPath().standardizedFileURL
        guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey], options: []) else { return nil }
        var files: [(relative: String, url: URL)] = []
        while let url = enumerator.nextObject() as? URL {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(root.path + "/") else { continue }
            let relative = String(path.dropFirst(root.path.count + 1))
            if values?.isSymbolicLink == true {
                logger.error("The staged restore holds a link; nothing was restored", metadata: ["path": "\(relative)"])
                return nil
            }
            if relative.split(separator: "/").contains(where: { isExcluded(String($0)) }) {
                if values?.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            if values?.isRegularFile == true { files.append((relative, url)) }
        }
        let configURL = storage.appendingPathComponent("config.json")
        let current = (try? JSONValue(data: Data(contentsOf: configURL))) ?? [:]
        var restored = 0
        for (relative, url) in files where relative != "config.json" {
            guard let data = try? Data(contentsOf: url) else { continue }
            do {
                try OwnerOnlyFile.write(data, to: storage.appendingPathComponent(relative))
                restored += 1
            } catch {
                logger.error("Could not restore a file", metadata: ["file": "\(relative)", "error": "\(error)"])
            }
        }
        if let data = try? Data(contentsOf: pending.appendingPathComponent("config.json")), let config = try? JSONValue(data: data) {
            do {
                try OwnerOnlyFile.write(keepingPorts(of: current, in: config).encoded(pretty: true), to: configURL)
                restored += 1
            } catch {
                logger.error("Could not restore config.json", metadata: ["error": "\(error)"])
            }
        }
        let summary = "Restored \(restored) file(s) from a backup"
        logger.warning("\(summary); homeswift starts on the restored configuration")
        return summary
    }

    /// The restored config.json with the current bridge port and web UI block's port, and the current web UI block
    /// when the backup has none: the page that restored it stays reachable where it was.
    static func keepingPorts(of current: JSONValue, in restored: JSONValue) -> JSONValue {
        guard var root = restored.objectValue else { return restored }
        if var bridge = root["bridge"]?.objectValue {
            if let port = current["bridge"]?["port"], !port.isNull { bridge["port"] = port } else { bridge.removeValue(forKey: "port") }
            root["bridge"] = .object(bridge)
        }
        let currentUI = current["platforms"]?.arrayValue?.first { $0["platform"]?.stringValue == "HomeswiftUI" }
        var platforms = root["platforms"]?.arrayValue ?? []
        if let currentUI {
            if let index = platforms.firstIndex(where: { $0["platform"]?.stringValue == "HomeswiftUI" }), var block = platforms[index].objectValue {
                if let port = currentUI["port"], !port.isNull { block["port"] = port } else { block.removeValue(forKey: "port") }
                platforms[index] = .object(block)
            } else {
                platforms.append(currentUI)
            }
        }
        root["platforms"] = .array(platforms)
        return .object(root)
    }
}
