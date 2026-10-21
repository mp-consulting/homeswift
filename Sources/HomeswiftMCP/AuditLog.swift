import Foundation
import HomeswiftAI
import Logging
import NIOConcurrencyHelpers

/// One JSON object per line for every write tool call, with the arguments redacted; rotates at 5 MB and
/// keeps three old files.
public final class AuditLog: Sendable {
    public struct Entry: Sendable {
        public var date = Date()
        public var tool: String
        public var arguments: JSONValue
        public var ok: Bool
        public var error: String?
        public var session: String
        public var client: String
        public var principal: String
        public var scope: Scope
        public var dryRun = false
        public var notConfirmed = false

        public init(tool: String, arguments: JSONValue, ok: Bool, error: String? = nil, session: String, client: String, principal: String, scope: Scope, dryRun: Bool = false, notConfirmed: Bool = false) {
            self.tool = tool
            self.arguments = arguments
            self.ok = ok
            self.error = error
            self.session = session
            self.client = client
            self.principal = principal
            self.scope = scope
            self.dryRun = dryRun
            self.notConfirmed = notConfirmed
        }

        var json: JSONValue {
            var object: [String: JSONValue] = [
                "ts": .string(ISO8601DateFormatter().string(from: date)),
                "tool": .string(tool),
                "args": Redaction.redactSecrets(arguments),
                "ok": .bool(ok),
                "session": .string(session),
                "client": .string(client),
                "principal": .string(principal),
                "scope": .string(scope.rawValue),
            ]
            if let error { object["error"] = .string(Redaction.redactText(error)) }
            if dryRun { object["dryRun"] = true }
            if notConfirmed { object["notConfirmed"] = true }
            return .object(object)
        }
    }

    public let url: URL
    public let maxBytes: Int
    public let keep: Int
    private let lock = NIOLock()
    private let logger: Logger

    public init(url: URL, maxBytes: Int = 5 * 1024 * 1024, keep: Int = 3, logger: Logger = Logger(label: "homeswift.mcp")) {
        self.url = url
        self.maxBytes = maxBytes
        self.keep = keep
        self.logger = logger
    }

    public func record(_ entry: Entry) {
        lock.withLock {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                rotateIfNeeded()
                let line = entry.json.encoded() + Data("\n".utf8)
                if let handle = try? FileHandle(forWritingTo: url) {
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: line)
                } else {
                    try line.write(to: url, options: .atomic)
                    #if !os(Windows)
                    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                    #endif
                }
            } catch {
                logger.warning("Could not write the audit log", metadata: ["path": "\(url.path)", "error": "\(error)"])
            }
        }
    }

    private func rotateIfNeeded() {
        let manager = FileManager.default
        guard let size = try? manager.attributesOfItem(atPath: url.path)[.size] as? Int, size >= maxBytes else { return }
        for index in stride(from: keep, through: 1, by: -1) {
            let older = url.appendingPathExtension("\(index)")
            try? manager.removeItem(at: older)
            let newer = index == 1 ? url : url.appendingPathExtension("\(index - 1)")
            if manager.fileExists(atPath: newer.path) { try? manager.moveItem(at: newer, to: older) }
        }
    }
}
