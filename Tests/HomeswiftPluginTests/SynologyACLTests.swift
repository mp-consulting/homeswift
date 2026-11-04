import Foundation
import Testing

/// The Synology package's `app/acl.sh` under /bin/sh, against a fake synoacltool that prints what DSM 7 printed.
@Suite(.timeLimit(.minutes(1)))
struct SynologyACLTests {
    static let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Synology/package/app/acl.sh").path

    /// `synoacltool -get /volume1/homeswift/secrets.key` on a DSM 7 NAS: the shared folder's inherited ACL.
    static let inherited = """
        ACL version: 1
        Archive: is_inherit,is_support_ACL
        Owner: [homeswift(user)]
        ---------------------
        \t [0] group:administrators:allow:rwxpdDaARWc--:---- (level:1)
        \t [1] user:homeswift:allow:rwxpdDaARWc--:---- (level:1)

        """
    static let ownACL = """
        ACL version: 1
        Archive: has_ACL,is_support_ACL
        Owner: [joe(user)]
        ---------------------
        [0] user:joe:allow:rwxpdDaARWcCo:fd-- (level:0)

        """
    static let none = """
        ACL version: 1
        Archive: is_support_ACL
        Owner: [homeswift(user)]
        ---------------------

        """

    struct Run {
        var status: Int32
        var output: String
        var error: String
    }

    func shell(_ command: String, input: String = "", in directory: URL? = nil) throws -> Run {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", ". \"\(Self.script)\"; \(command)"]
        if let directory { process.currentDirectoryURL = directory }
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let error = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Run(status: process.terminationStatus, output: String(decoding: output, as: UTF8.self), error: String(decoding: error, as: UTF8.self))
    }

    @Test func entriesAndArchiveFlagsAreAnACL() throws {
        #expect(try shell("acl_has_entries", input: Self.inherited).status == 0)
        #expect(try shell("acl_has_entries", input: Self.ownACL).status == 0)
        #expect(try shell("acl_has_entries", input: Self.none).status != 0)
        #expect(try shell("acl_has_entries", input: "").status != 0)
    }

    /// A directory with secrets.key and a fake synoacltool: -get prints the inherited ACL while `acl-<name>` exists,
    /// -del removes it unless `stuck` exists. Each call is logged.
    func directory(stuck: Bool) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-acl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: directory.appendingPathComponent("secrets.key"))
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: directory.appendingPathComponent("secrets.key").path)
        try Data().write(to: directory.appendingPathComponent("acl-secrets.key"))
        try Data(Self.inherited.utf8).write(to: directory.appendingPathComponent("inherited.txt"))
        if stuck { try Data().write(to: directory.appendingPathComponent("stuck")) }
        let tool = directory.appendingPathComponent("synoacltool")
        try Data("""
            #!/bin/sh
            dir=$(dirname "$0"); name=$(basename "$2")
            echo "$1 $2" >> "$dir/calls"
            case $1 in
                -get) if [ -f "$dir/acl-$name" ]; then cat "$dir/inherited.txt"; else echo "Archive: is_support_ACL"; fi ;;
                -del) [ -f "$dir/stuck" ] || rm -f "$dir/acl-$name"; echo "unknown error: [900]" >&2; exit 1 ;;
            esac

            """.utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        return directory
    }

    @Test func theInheritedACLIsRemovedAndTheFileMadeOwnerOnly() throws {
        let directory = try directory(stuck: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let run = try shell("SYNOACLTOOL=\"$(pwd -P)/synoacltool\"; secure_secrets secrets.key vault.json", in: directory)
        #expect(run.status == 0)
        #expect(run.error.isEmpty)
        let calls = try String(contentsOf: directory.appendingPathComponent("calls"), encoding: .utf8)
        #expect(calls.components(separatedBy: "\n").filter { !$0.isEmpty }.map { $0.components(separatedBy: " ")[0] } == ["-get", "-del", "-get"])
        // By its full path, as synoacltool takes it.
        #expect(calls.contains("-del /") && calls.contains("/secrets.key"))
        let mode = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("secrets.key").path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
    }

    @Test func anACLThatStaysIsReportedWithTheCommandToRun() throws {
        let directory = try directory(stuck: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let run = try shell("SYNOACLTOOL=\"$(pwd -P)/synoacltool\"; secure_secrets secrets.key", in: directory)
        #expect(run.status == 0)
        #expect(run.error.contains("secrets.key keeps the shared folder's ACL"))
        #expect(run.error.contains("/synoacltool -del /") && run.error.contains("sudo homeswift restart"))
    }

    @Test func withoutSynoacltoolTheFileIsStillMadeOwnerOnly() throws {
        let directory = try directory(stuck: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(try shell("SYNOACLTOOL=; secure_secrets secrets.key", in: directory).status == 0)
        let mode = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("secrets.key").path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
    }
}
