import Foundation
import Testing

@testable import Homeswift

struct OwnerOnlyFileTests {
    @Test func writesAtomicallyOwnerOnly() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-owner-only-\(UUID().uuidString)/nested")
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let url = directory.appendingPathComponent("state.json")
        try OwnerOnlyFile.write(Data("one".utf8), to: url)
        try OwnerOnlyFile.write(Data("two".utf8), to: url)
        #expect(try Data(contentsOf: url) == Data("two".utf8))
        // No temporary file is left behind.
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["state.json"])
        #if !os(Windows)
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int == 0o600)
        #expect(try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int == 0o700)
        #endif
        #expect(throws: (any Error).self) { try OwnerOnlyFile.write(Data(), to: URL(fileURLWithPath: "/dev/null/impossible/file")) }
    }
}
