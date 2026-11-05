import Foundation
import HomeswiftNetwork

/// `synoacltool -get`'s output for `path`, or nil off a Synology NAS or when the tool fails. DSM checks a shared
/// folder's ACL instead of its mode bits, and shows a user the ACL names the mode 0777, so `StoragePermissions` reads
/// the entries to tell the package's own grant from access given to others. The tool is in /usr/syno/bin, which is not
/// on a package user's PATH.
func synologyACL(_ path: String) -> String? {
    let tool = "/usr/syno/bin/synoacltool"
    guard FileManager.default.isExecutableFile(atPath: tool),
        let output = try? ChildProcess.run(tool, arguments: ["-get", path]), output.status == 0
    else { return nil }
    return output.text
}
