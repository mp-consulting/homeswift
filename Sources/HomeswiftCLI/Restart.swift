import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// Replaces this process with a fresh copy of itself: same binary, same arguments, same PID, so launchd,
/// systemd and `brew services` see a bridge that never went away. Everything must be stopped first.
enum Restart {
    static func exec() -> Never {
        let path = Bundle.main.executablePath ?? CommandLine.arguments[0]
        var arguments: [UnsafeMutablePointer<CChar>?] = CommandLine.arguments.map { strdup($0) }
        arguments.append(nil)
        execv(path, arguments)
        // Only on failure: a service manager with keep-alive brings the bridge back.
        FileHandle.standardError.write(Data("homeswift: restart failed (\(String(cString: strerror(errno)))); exiting for the service manager to start it again\n".utf8))
        // A failure status: a unit with Restart=on-failure (or launchd's SuccessfulExit = false) starts it again too.
        exit(1)
    }
}
