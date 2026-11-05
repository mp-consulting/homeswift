import Foundation
import Homeswift
import Testing

@testable import HomeswiftPlugin

@Suite(.timeLimit(.minutes(1)))
struct StoragePermissionsTests {
    typealias Status = StoragePermissions.Status

    /// A file system of statuses; a chmod changes the mode and, as DSM does, drops a Synology ACL.
    final class FakeFiles: @unchecked Sendable {
        var statuses: [String: Status]
        var changed: [String] = []
        let chmodDropsACL: Bool

        init(_ statuses: [String: Status], chmodDropsACL: Bool = true) {
            self.statuses = statuses
            self.chmodDropsACL = chmodDropsACL
        }

        func inspect(_ path: String) -> Status? { statuses[path] }

        func changeMode(_ path: String, _ mode: UInt32) -> Bool {
            guard var status = statuses[path], status.ownedByCurrentUser else { return false }
            changed.append((path as NSString).lastPathComponent)
            status.mode = mode
            if chmodDropsACL { status.aclAttributes.removeAll { !$0.hasPrefix("system.posix_acl") } }
            statuses[path] = status
            return true
        }
    }

    let storage = URL(fileURLWithPath: "/volume1/homeswift")
    func path(_ name: String) -> String { storage.appendingPathComponent(name).path }

    func secure(_ files: FakeFiles) -> [StoragePermissions.Finding] {
        StoragePermissions.secure(storage: storage, inspect: files.inspect, changeMode: files.changeMode)
    }

    @Test func ownerOnlyFilesAreLeftAlone() {
        let files = FakeFiles([
            storage.path: Status(mode: 0o700, isDirectory: true),
            path("secrets.key"): Status(mode: 0o600),
            path("vault.json"): Status(mode: 0o400),
        ])
        #expect(secure(files).isEmpty)
        #expect(files.changed.isEmpty)
        #expect(StoragePermissions.warning([]) == nil)
    }

    @Test func aReadableKeyIsSetBackToOwnerOnly() {
        let files = FakeFiles([
            storage.path: Status(mode: 0o755, isDirectory: true),
            path("secrets.key"): Status(mode: 0o644),
            path("config.json"): Status(mode: 0o660),
            path("logs.txt"): Status(mode: 0o644),
        ])
        #expect(secure(files).isEmpty)
        #expect(files.changed == ["config.json", "secrets.key"])
        #expect(files.statuses[path("secrets.key")]?.mode == 0o600)
    }

    /// DSM: a shared folder's files show 0777 and carry the share's ACL.
    @Test func aSharedFolderIsReported() throws {
        let files = FakeFiles(
            [
                storage.path: Status(mode: 0o777, isDirectory: true, ownedByCurrentUser: false, aclAttributes: ["system.syno_acl_self"]),
                path("secrets.key"): Status(mode: 0o777, aclAttributes: ["system.syno_acl_self"]),
                path("vault.json"): Status(mode: 0o777, aclAttributes: ["system.syno_acl_self"]),
            ], chmodDropsACL: false)
        let findings = secure(files)
        #expect(findings.map(\.path) == [storage.path, path("secrets.key"), path("vault.json")])
        #expect(files.changed == ["secrets.key", "vault.json"])
        // The mode is the owner's now; the ACL a chmod did not drop is still reported.
        #expect(findings[1] == .init(path: path("secrets.key"), mode: 0o600, openMode: false, acl: ["system.syno_acl_self"]))
        let warning = try #require(StoragePermissions.warning(findings))
        #expect(warning.contains("secrets.key (ACL system.syno_acl_self)"))
        #expect(warning.contains("/volume1/homeswift (mode 777; ACL system.syno_acl_self)"))
    }

    @Test func aChmodThatDropsTheACLLeavesOnlyTheDirectory() {
        let files = FakeFiles([
            storage.path: Status(mode: 0o777, isDirectory: true, ownedByCurrentUser: false),
            path("secrets.key"): Status(mode: 0o777, aclAttributes: ["system.syno_acl_self"]),
        ])
        #expect(secure(files).map(\.path) == [storage.path])
    }

    @Test func aFileOfAnotherUserIsReportedNotChanged() {
        let files = FakeFiles([path("vault.json"): Status(mode: 0o644, ownedByCurrentUser: false)])
        #expect(secure(files) == [.init(path: path("vault.json"), mode: 0o644, openMode: true, acl: [])])
        #expect(files.changed.isEmpty)
    }

    /// A POSIX ACL's mask is the group bits: at 0600 its named entries grant nothing.
    @Test func posixACLsFollowTheMode() {
        #expect(StoragePermissions.finding(path: "k", status: Status(mode: 0o600, aclAttributes: ["system.posix_acl_access"])) == nil)
        #expect(StoragePermissions.finding(path: "d", status: Status(mode: 0o700, isDirectory: true, aclAttributes: ["system.posix_acl_default"])) == nil)
        #expect(StoragePermissions.finding(path: "k", status: Status(mode: 0o640, aclAttributes: ["system.posix_acl_access"]))?.openMode == true)
        #expect(StoragePermissions.finding(path: "k", status: Status(mode: 0o600, aclAttributes: ["system.nfs4_acl"]))?.acl == ["system.nfs4_acl"])
        // A directory others can list but not write keeps its files' contents to their modes.
        #expect(StoragePermissions.finding(path: "d", status: Status(mode: 0o755, isDirectory: true)) == nil)
        #expect(StoragePermissions.finding(path: "d", status: Status(mode: 0o775, isDirectory: true))?.openMode == true)
    }

    /// `synoacltool -get` on a DSM 7 package's data share: DSM's grant to the package user alone.
    static let packageShareACL = """
        ACL version: 1
        Archive: has_ACL,is_support_ACL
        Owner: [homeswift(user)]
        ---------------------
                 [0] user:homeswift:allow:rwxpdDaARWc--:fd-- (level:0)

        """

    /// The same share after another account and the administrators were given access in Control Panel.
    static let sharedWithOthersACL = """
        ACL version: 1
        Archive: has_ACL,is_support_ACL
        Owner: [root(user)]
        ---------------------
                 [0] user:homeswift:allow:rwxpdDaARWc--:fd-- (level:0)
                 [1] user:alice:allow:r-x---a-R-c--:fd-- (level:0)
                 [2] group:administrators:allow:rwxpdDaARWc--:fd-- (level:0)
                 [3] everyone:*:deny:rwxpdDaARWc--:fd-- (level:0)

        """

    func secure(_ files: FakeFiles, acl: [String: String]) -> [StoragePermissions.Finding] {
        StoragePermissions.secure(
            storage: storage, user: "homeswift", inspect: files.inspect, changeMode: files.changeMode,
            readDSMACL: { acl[$0] })
    }

    @Test func dsmEntriesAreRead() {
        #expect(StoragePermissions.dsmEntries(Self.packageShareACL) == ["user:homeswift:allow:rwxpdDaARWc--:fd--"])
        #expect(StoragePermissions.dsmEntries("(synoacltool.c, 596)It's Linux mode").isEmpty)
        #expect(
            StoragePermissions.dsmEntriesForOthers(Self.sharedWithOthersACL, user: "homeswift", ownedByUser: false) == [
                "user:alice:allow:r-x---a-R-c--:fd--", "group:administrators:allow:rwxpdDaARWc--:fd--",
            ])
        #expect(StoragePermissions.dsmEntriesForOthers("[0] owner:*:allow:rwx:fd--", user: "homeswift", ownedByUser: true).isEmpty)
        #expect(StoragePermissions.dsmEntriesForOthers("[0] owner:*:allow:rwx:fd--", user: "homeswift", ownedByUser: false).count == 1)
    }

    /// DSM shows the package user 0777 on its share, whose only entry is its own: nothing to report.
    @Test func thePackageShareIsNotReported() {
        let files = FakeFiles([
            storage.path: Status(mode: 0o777, isDirectory: true, aclAttributes: ["system.syno_acl_self"]),
            path("secrets.key"): Status(mode: 0o600),
        ])
        #expect(secure(files, acl: [storage.path: Self.packageShareACL]).isEmpty)
    }

    @Test func aShareGivenToOthersNamesThem() throws {
        let files = FakeFiles([
            storage.path: Status(mode: 0o777, isDirectory: true, ownedByCurrentUser: false, aclAttributes: ["system.syno_acl_self"])
        ])
        let findings = secure(files, acl: [storage.path: Self.sharedWithOthersACL])
        #expect(findings.map(\.path) == [storage.path])
        let warning = try #require(StoragePermissions.warning(findings))
        #expect(warning.contains("/volume1/homeswift (ACL user:alice:allow:r-x---a-R-c--:fd--, group:administrators:allow:rwxpdDaARWc--:fd--)"))
    }

    /// Without synoacltool's answer the ACL and the mode are reported as before.
    @Test func anUnreadableDSMACLIsReported() {
        let files = FakeFiles([
            storage.path: Status(mode: 0o777, isDirectory: true, aclAttributes: ["system.syno_acl_self"])
        ])
        #expect(secure(files, acl: [:]).first?.openMode == true)
    }

    @Test func aclNamesComeFromTheAttributeList() {
        let list = Array("user.comment\0system.posix_acl_access\0system.SYNO_ACL\0".utf8)
        #expect(StoragePermissions.aclNames(inList: list) == ["system.posix_acl_access", "system.SYNO_ACL"])
        #expect(StoragePermissions.aclNames(inList: []).isEmpty)
    }

    /// The real file system: a key written group-readable is owner-only after `secure`.
    @Test func theRealFileSystem() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-permissions-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try OwnerOnlyFile.write(Data("{}".utf8), to: directory.appendingPathComponent(SecretBox.fileName))
        let key = directory.appendingPathComponent(SecretBox.fileName).path
        #expect(StoragePermissions.inspect(key)?.mode == 0o600)
        #expect(StoragePermissions.changeMode(key, 0o644))
        #expect(StoragePermissions.secure(storage: directory).isEmpty)
        #expect(StoragePermissions.inspect(key)?.mode == 0o600)
        #expect(StoragePermissions.inspect(directory.path)?.isDirectory == true)
    }
}
