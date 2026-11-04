import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// Whether the bridge's own files are its alone. `OwnerOnlyFile` writes them 0600, but a directory can grant more
/// than the mode bits say: a NAS's shared folder hands its files an ACL (DSM shows them `-rwxrwxrwx+`), and other
/// accounts with access to the share then read `secrets.key` and the vault it opens. At start-up the bridge sets its
/// files that are wider back to 0600 (a chmod is also what makes DSM drop an inherited ACL) and warns about what is
/// still open to others.
public enum StoragePermissions {
    /// What `stat` and the extended attributes say about a path.
    public struct Status: Sendable, Equatable {
        /// The permission bits (`st_mode & 0o7777`).
        public var mode: UInt32
        public var isDirectory: Bool
        /// Owned by the user the bridge runs as: only then can it change the mode.
        public var ownedByCurrentUser: Bool
        /// Extended attribute names that hold an access control list.
        public var aclAttributes: [String]

        public init(mode: UInt32, isDirectory: Bool = false, ownedByCurrentUser: Bool = true, aclAttributes: [String] = []) {
            self.mode = mode
            self.isDirectory = isDirectory
            self.ownedByCurrentUser = ownedByCurrentUser
            self.aclAttributes = aclAttributes
        }
    }

    /// A path others can reach, and how.
    public struct Finding: Sendable, Equatable, CustomStringConvertible {
        public var path: String
        public var mode: UInt32
        /// The group or other bits grant access (for the directory: writing, which replaces its files).
        public var openMode: Bool
        /// An ACL that mode bits do not bound (not POSIX's, whose mask the mode is), such as DSM's or NFSv4's.
        public var acl: [String]

        public var description: String {
            var reasons: [String] = []
            if openMode { reasons.append("mode \(String(mode, radix: 8))") }
            if !acl.isEmpty { reasons.append("ACL \(acl.joined(separator: ", "))") }
            return "\(path) (\(reasons.joined(separator: "; ")))"
        }
    }

    /// The files whose reading gives away the bridge: the vault's key and the vault, config.json, the HomeKit
    /// identity and pairings, the web UI's accounts, sessions and tokens, its certificate's key.
    public static let sensitiveNames: Set<String> = [
        SecretBox.fileName, CredentialVault.fileName, "config.json", "homeswift.json",
        "ui-users.json", "ui-sessions.json", "ui-oauth.json", "ui-api-tokens.json", "ui-key.pem",
    ]

    /// POSIX ACLs follow the mode: a chmod sets their mask, so the mode bits are what they grant.
    static let boundedACLs: Set<String> = ["system.posix_acl_access", "system.posix_acl_default"]

    /// What is open to others in `status`, or nil when only the owner can reach it.
    public static func finding(path: String, status: Status) -> Finding? {
        let mask: UInt32 = status.isDirectory ? 0o022 : 0o077
        let openMode = status.mode & mask != 0
        let acl = status.aclAttributes.filter { !boundedACLs.contains($0) }
        guard openMode || !acl.isEmpty else { return nil }
        return Finding(path: path, mode: status.mode, openMode: openMode, acl: acl)
    }

    /// Sets the sensitive files in `storage` that others can reach back to 0600 when the bridge owns them, then
    /// says what is still open: those files and the directory itself.
    public static func secure(
        storage: URL,
        names: Set<String> = sensitiveNames,
        inspect: (String) -> Status? = Self.inspect,
        changeMode: (String, UInt32) -> Bool = Self.changeMode
    ) -> [Finding] {
        var findings: [Finding] = []
        if let status = inspect(storage.path), let found = finding(path: storage.path, status: status) {
            findings.append(found)
        }
        for name in names.sorted() {
            let path = storage.appendingPathComponent(name).path
            guard var status = inspect(path), !status.isDirectory else { continue }
            if status.mode & 0o077 != 0 || !status.aclAttributes.filter({ !boundedACLs.contains($0) }).isEmpty,
                status.ownedByCurrentUser, changeMode(path, 0o600)
            {
                status = inspect(path) ?? status
            }
            if let found = finding(path: path, status: status) { findings.append(found) }
        }
        return findings
    }

    /// The warning for `findings`, or nil when there are none.
    public static func warning(_ findings: [Finding]) -> String? {
        guard !findings.isEmpty else { return nil }
        return "Other accounts can reach the bridge's secrets: \(findings.map(\.description).joined(separator: ", ")). "
            + "Keep the data directory to the bridge's user (chmod 700, no ACL; on a Synology NAS, docs/synology.md, \"Security\")"
    }

    public static func inspect(_ path: String) -> Status? {
        #if os(Windows)
        return nil
        #else
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        // The file type's bits (S_IFMT, S_IFREG, S_IFDIR), whose imported types differ between Darwin and Glibc.
        let type = UInt32(info.st_mode) & 0o170000
        // A link is not followed: the bridge writes its files in place of one.
        guard type == 0o100000 || type == 0o040000 else { return nil }
        return Status(
            mode: UInt32(info.st_mode) & 0o7777,
            isDirectory: type == 0o040000,
            ownedByCurrentUser: info.st_uid == geteuid(),
            aclAttributes: aclAttributes(path)
        )
        #endif
    }

    public static func changeMode(_ path: String, _ mode: UInt32) -> Bool {
        #if os(Windows)
        return false
        #else
        return chmod(path, mode_t(mode)) == 0
        #endif
    }

    /// The extended attributes on `path` whose name says they are an ACL (Linux; macOS's ACLs are not attributes).
    static func aclAttributes(_ path: String) -> [String] {
        #if os(Linux)
        // glibc's llistxattr, looked up (a nil handle is RTLD_DEFAULT) rather than imported: not every Glibc
        // module map has sys/xattr.h.
        typealias ListAttributes = @convention(c) (UnsafePointer<CChar>?, UnsafeMutablePointer<CChar>?, Int) -> Int
        guard let symbol = dlsym(nil, "llistxattr") else { return [] }
        let list = unsafeBitCast(symbol, to: ListAttributes.self)
        let size = list(path, nil, 0)
        guard size > 0 else { return [] }
        var buffer = [CChar](repeating: 0, count: size)
        let read = list(path, &buffer, size)
        guard read > 0, read <= size else { return [] }
        return aclNames(inList: buffer.prefix(read).map { UInt8(bitPattern: $0) })
        #else
        return []
        #endif
    }

    /// The names in a `listxattr` list (each one ending in a zero byte) that hold an ACL.
    static func aclNames(inList bytes: [UInt8]) -> [String] {
        bytes.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }.filter { $0.lowercased().contains("acl") }
    }
}
