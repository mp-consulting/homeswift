import Foundation
import Testing
@testable import HomeswiftNetwork
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

@Suite struct ChildProcessTests {
    @Test func runsAToolWithItsInputAndReturnsWhatItPrinted() throws {
        let run = try ChildProcess.run("/bin/sh", arguments: ["-c", "read line; echo \"out $line\"; echo err >&2; exit 3"], input: Data("hello\n".utf8))
        #expect(run.termination == .exited(3))
        #expect(run.text == "out hello\n")
        #expect(run.errorText == "err\n")
    }

    @Test func passesTheEnvironmentGiven() throws {
        let run = try ChildProcess.run("/bin/sh", arguments: ["-c", "echo \"$HOMESWIFT_CHILD\""], environment: ["HOMESWIFT_CHILD": "yes", "PATH": "/usr/bin:/bin"])
        #expect(run.text == "yes\n")
    }

    @Test func aMissingToolIsAnError() {
        #expect(throws: ChildProcessError.self) { try ChildProcess.run("/nonexistent/tool") }
    }

    /// Descriptors the parent has open, close-on-exec or not, stay out of the child: only 0, 1 and 2 are its own.
    @Test func theChildGetsNoOtherDescriptor() throws {
        var ends: [Int32] = [0, 0]
        #expect(pipe(&ends) == 0)
        defer { for fd in ends { close(fd) } }
        let run = try ChildProcess.run("/bin/sh", arguments: ["-c", "test -e /dev/fd/\(ends[1]) && echo open || echo closed"])
        #expect(run.text == "closed\n")
    }

    /// The threads Swift's concurrency runs on block signals: a child started from one still ends on SIGTERM.
    @Test func aChildStartedFromATaskEndsOnASignal() async throws {
        let child = try ChildProcess.launch("/bin/sh", arguments: ["-c", "exec sleep 30"])
        #expect(child.isRunning)
        #expect(child.signal(SIGTERM))
        #expect(await child.wait() == .signaled(SIGTERM))
        #expect(!child.isRunning)
        #expect(!child.signal(SIGTERM))
        #expect(child.termination == .signaled(SIGTERM))
    }

    @Test func reportsTheExitToItsHandlerAndItsWaiters() async throws {
        let (stream, continuation) = AsyncStream.makeStream(of: ChildProcess.Termination.self)
        let child = try ChildProcess.launch("/bin/sh", arguments: ["-c", "exit 7"]) { continuation.yield($0); continuation.finish() }
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == .exited(7))
        #expect(await child.wait() == .exited(7))
        #expect(child.waitUntilExit() == .exited(7))
    }

    #if os(Linux)
    @Test func listsTheOpenDescriptors() {
        var ends: [Int32] = [0, 0]
        #expect(pipe(&ends) == 0)
        defer { for fd in ends { close(fd) } }
        let open = ChildProcess.openDescriptors()
        #expect(open.contains(ends[0]) && open.contains(ends[1]))
        #expect(open.contains(0))
    }
    #endif
}

#if canImport(Glibc)
extension ChildProcessTests {
    /// glibc 2.34 and later close the other descriptors in the child itself, with no moment for one to slip through.
    @Test func closesTheOtherDescriptorsInTheChildWithAModernGlibc() throws {
        var buffer = [CChar](repeating: 0, count: 64)
        _ = confstr(Int32(_CS_GNU_LIBC_VERSION), &buffer, buffer.count)
        // "glibc 2.39"
        let text = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let version = text.split(separator: " ").last.map { $0.split(separator: ".").compactMap { Int($0) } } ?? []
        try #require(version.count >= 2, "\(text)")
        guard (version[0], version[1]) >= (2, 34) else { return }
        #expect(ChildProcess.closesOtherDescriptorsInTheChild)
    }
}
#endif
