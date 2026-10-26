import Foundation
import HomeswiftAI
import HomeswiftMCP
import HomeswiftPlugin
import NIOHTTP1

// The config import's API, for administrators: check a Homebridge config.json, browse the bridge's storage folder
// for one, and save it. Text (pasted or uploaded) crosses the network, so it is accepted only over HTTPS or from a
// loopback address; a file the server reads itself ("server") never crosses the browser. Every reply carries
// codes, not sentences, for the page to word. Saving is audited like the other writes (UIServer's audit log).
extension UIServer {
    /// The import routes, or a 404 for an unknown one under `/api/import`.
    func importAPI(_ route: [String], _ request: Request) async throws -> Reply {
        let storage = catalog.storageDirectory
        do {
            switch (request.method, route) {
            case (.GET, ["import", "browse"]):
                return try importBrowse(request.query["path"] ?? "", storage: storage)
            case (.POST, ["import", "check"]):
                return try await importCheck(request, storage: storage, save: false)
            case (.POST, ["import", "save"]):
                return try await importCheck(request, storage: storage, save: true)
            default:
                return .error(404, "no such import route")
            }
        } catch let error as ImportRouteError {
            return .error(400, error.description)
        }
    }

    /// Checks the posted config, and when `save` is set and it is valid, writes it into config.json: the platforms
    /// are appended, the bridge is set only for an empty config (`HomebridgeImport.check` decides), and the
    /// secrets are sealed with the bridge's key, which is made here on the first save.
    private func importCheck(_ request: Request, storage: URL, save: Bool) async throws -> Reply {
        guard let body = try? JSONValue(data: request.body) else { return .error(400, "the request body is not JSON") }
        guard let source = body["source"]?.stringValue, ["paste", "upload", "server"].contains(source) else {
            return .error(400, "source must be paste, upload or server")
        }
        let data: Data
        if source == "server" {
            guard let path = body["path"]?.stringValue else { return .error(400, "path is required for a server file") }
            data = try readServerFile(path, storage: storage)
        } else {
            guard let text = body["text"]?.stringValue else { return .error(400, "text is required") }
            guard isSecure(request) || HostName.isLoopback(request.remote) else {
                return .error(403, "a config sent as text needs HTTPS; upload it from the server instead")
            }
            guard text.utf8.count <= HomebridgeImport.maxBytes else { return .error(413, "the config is over 1 MB") }
            data = Data(text.utf8)
        }

        let existing = try catalog.readConfig()
        // The check validates the merged config as it will run, so the existing sealed secrets are opened for it.
        let checked = try HomebridgeImport.check(data, registry: catalog.host.registry, existing: SecretBox.revealed(existing, storage: storage))
        guard save else { return .json(try encodedJSON(checked.report)) }
        guard checked.report.valid, let additions = checked.additions else { return .json(try encodedJSON(checked.report), status: 422) }
        // The checked values are plain: `writeConfig` seals them as it writes the file, and the running bridge gets the
        // secrets opened, so the plugins start with them.
        let merged = HomebridgeImport.merge(existing, additions: additions)
        let applied: JSONValue
        do {
            applied = try await catalog.applySealed(merged, expecting: existing)
        } catch let changed as ConfigChanged {
            return .error(409, changed.description)
        }
        var answer = try encodedJSON(checked.report).objectValue ?? [:]
        for key in ["backup", "note", "restartNeeded"] { answer[key] = applied[key] ?? .null }
        return .json(.object(answer))
    }

    /// The folders and .json files directly inside `path` (relative to the storage folder), folders first.
    private func importBrowse(_ path: String, storage: URL) throws -> Reply {
        let folder = try Self.storageURL(path, storage: storage)
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder), isFolder.boolValue else {
            return .error(404, "not a folder in the storage folder")
        }
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let children = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        var entries: [JSONValue] = []
        for child in children.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
            let name = child.lastPathComponent
            let values = try child.resourceValues(forKeys: Set(keys))
            let isDirectory = values.isDirectory == true
            // The key and the bridge's and the UI's own state are not configuration: they are never listed or read.
            guard isDirectory || (name.hasSuffix(".json") && !Self.isStateFile(name)) else { continue }
            let relative = path.isEmpty ? name : "\(path)/\(name)"
            entries.append(.object([
                "name": .string(name),
                "path": .string(relative),
                "kind": .string(isDirectory ? "folder" : "file"),
                "size": .number(Double(values.fileSize ?? 0)),
                "modified": .string(values.contentModificationDate.map { Timestamp.iso8601($0) } ?? ""),
            ]))
        }
        let folders = entries.filter { $0["kind"]?.stringValue == "folder" }
        let files = entries.filter { $0["kind"]?.stringValue == "file" }
        return .json(.object(["path": .string(path), "entries": .array(folders + files)]))
    }

    /// The bytes of a .json file under the storage folder, at most the import's limit.
    private func readServerFile(_ path: String, storage: URL) throws -> Data {
        let url = try Self.storageURL(path, storage: storage)
        guard url.pathExtension == "json", !Self.isStateFile(url.lastPathComponent) else { throw ImportRouteError.notAConfig }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw ImportRouteError.notAConfig }
        guard (values.fileSize ?? 0) <= HomebridgeImport.maxBytes else { throw ImportRouteError.tooLarge }
        return try Data(contentsOf: url)
    }

    /// The bridge's state (its signing key and pairings), the UI's state, and the key for sealed secrets: never a config.
    static func isStateFile(_ name: String) -> Bool {
        // Case-insensitive: the default macOS volume resolves `UI-users.json` to `ui-users.json`.
        let lowered = name.lowercased()
        return lowered == SecretBox.fileName || lowered == "homeswift.json" || lowered.hasPrefix("ui-")
    }

    /// `relative` under `storage`, with links resolved: a path that leaves the storage folder is refused.
    static func storageURL(_ relative: String, storage: URL) throws -> URL {
        guard !relative.contains("\0"), !relative.hasPrefix("/") else { throw ImportRouteError.outsideStorage }
        let base = storage.resolvingSymlinksInPath().standardizedFileURL
        let target = relative.isEmpty ? base : base.appendingPathComponent(relative).resolvingSymlinksInPath().standardizedFileURL
        guard target.path == base.path || target.path.hasPrefix(base.path + "/") else { throw ImportRouteError.outsideStorage }
        return target
    }

    private func encodedJSON<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONValue(encoding: value)
    }
}

enum ImportRouteError: Error, CustomStringConvertible {
    case outsideStorage
    case notAConfig
    case tooLarge

    var description: String {
        switch self {
        case .outsideStorage: "the path is outside the bridge's storage folder"
        case .notAConfig: "the file is not a .json file"
        case .tooLarge: "the file is over 1 MB"
        }
    }
}
