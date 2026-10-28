import Foundation
import HomeswiftPlugin

/// For working on the pages: the web files read from a checkout on every request instead of the copies compiled
/// in, and a watcher that tells open pages when one changes, so a stylesheet swaps in place and a script or page
/// reloads (`HOMESWIFT_WEB_ROOT=<checkout>`). The UI's files are `Sources/HomeswiftUI/Web`, a plugin's
/// `Plugins/<platform>/Web`.
final class LiveWebFiles: Sendable {
    let root: URL
    static let types = [
        "html": "text/html; charset=utf-8", "js": "text/javascript; charset=utf-8", "css": "text/css; charset=utf-8",
        "svg": "image/svg+xml", "json": "application/json", "webmanifest": "application/manifest+json", "png": "image/png", "webp": "image/webp",
    ]

    init(root: URL) {
        self.root = root.standardizedFileURL
    }

    var uiDirectory: URL { root.appendingPathComponent("Sources/HomeswiftUI/Web") }

    func directory(platform: String?) -> URL {
        platform.map { root.appendingPathComponent("Plugins").appendingPathComponent($0).appendingPathComponent("Web") } ?? uiDirectory
    }

    /// The file as it is on disk now; nil for a name that leaves the directory, a hidden file, or no such file.
    /// A file that exists but cannot be read goes to `unreadable` (macOS keeps ~/Documents from processes the
    /// person has not allowed), and the compiled-in copy is served instead.
    func file(_ name: String, platform: String?, unreadable: (URL, any Error) -> Void = { _, _ in }) -> WebFile? {
        let parts = name.split(separator: "/")
        guard !parts.isEmpty, !parts.contains(where: { $0 == ".." || $0.hasPrefix(".") }) else { return nil }
        if let platform, platform.contains("/") || platform.hasPrefix(".") { return nil }
        let url = directory(platform: platform).appendingPathComponent(name)
        do {
            let type = Self.types[url.pathExtension] ?? "application/octet-stream"
            if ["png", "webp"].contains(url.pathExtension) { return WebFile(contentType: type, base64: try Data(contentsOf: url).base64EncodedString()) }
            let text = try String(contentsOf: url, encoding: .utf8)
            return WebFile(contentType: type, body: text)
        } catch {
            if FileManager.default.fileExists(atPath: url.path) { unreadable(url, error) }
            return nil
        }
    }

    /// Every web file under the root with its modification date, keyed by its path in the checkout.
    func snapshot() -> [String: Date] {
        let manager = FileManager.default
        var directories = [uiDirectory]
        let plugins = root.appendingPathComponent("Plugins")
        for name in (try? manager.contentsOfDirectory(atPath: plugins.path)) ?? [] where !name.hasPrefix(".") {
            directories.append(plugins.appendingPathComponent(name).appendingPathComponent("Web"))
        }
        var dates: [String: Date] = [:]
        for directory in directories {
            for name in (try? manager.contentsOfDirectory(atPath: directory.path)) ?? [] where !name.hasPrefix(".") {
                let url = directory.appendingPathComponent(name)
                guard let date = (try? manager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else { continue }
                let relative = String(url.path.dropFirst(root.path.count + 1))
                dates[relative] = date
            }
        }
        return dates
    }

    /// Polls the files and calls `changed` with the checkout path of each one that changed or appeared.
    func watch(every interval: Duration = .milliseconds(400), _ changed: @escaping @Sendable (String) -> Void) -> Task<Void, Never> {
        Task.detached { [self] in
            var known = snapshot()
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                let now = snapshot()
                for (path, date) in now where known[path] != date { changed(path) }
                known = now
            }
        }
    }
}
