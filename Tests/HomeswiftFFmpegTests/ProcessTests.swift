import Foundation
import Logging
import NIOConcurrencyHelpers
import Testing

@testable import Homeswift
@testable import HomeswiftFFmpeg

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// The process tests run /bin/sh in place of FFmpeg: the "command line" is a shell script.

@Suite struct FfmpegExecTests {
    @Test func returnsNilWhenTheProcessCannotStart() async {
        let logs = LogRecorder()
        let options = FfmpegOptions(FfmpegOptionsConfig(
            codecSupport: FfmpegCodecs(ffmpegExec: "/nonexistent/ffmpeg", log: logs.logger, ffmpegVersion: "8.0"), hardwareDecoding: false,
            hardwareTranscoding: false, log: logs.logger, name: { "Test Camera" }
        ))
        let exec = FfmpegExec(options, commandLineArgs: ["-version"], logErrors: false)
        #expect(await exec.exec() == nil)
        #expect(logs.messages(.error) == ["FFmpeg failed to start: unable to find '/nonexistent/ffmpeg'."])
    }

    @Test func returnsTheResultOfANormalExit() async throws {
        let (logs, options) = shellOptions()
        let exec = FfmpegExec(options, commandLineArgs: ["-c", "printf 'ffmpeg output'; echo progress >&2"], logErrors: false)
        let result = try #require(await exec.exec())
        #expect(result.exitCode == 0)
        #expect(String(decoding: result.stdout, as: UTF8.self) == "ffmpeg output")
        #expect(String(decoding: result.stderr, as: UTF8.self) == "progress\n")
        #expect(!exec.hasError)
        #expect(logs.messages(.debug).contains("FFmpeg process ended (Normal)."))
    }

    @Test func feedsStandardInput() async throws {
        let (_, options) = shellOptions()
        let exec = FfmpegExec(options, commandLineArgs: ["-c", "cat; echo done >&2"])
        let input = Data((0..<200_000).map { UInt8($0 % 251) })
        let result = try #require(await exec.exec(input))
        #expect(result.exitCode == 0)
        #expect(result.stdout == input)
    }

    @Test func reportsAFailedRun() async throws {
        let (logs, options) = shellOptions()
        let exec = FfmpegExec(options, commandLineArgs: ["-c", "echo 'Invalid data found' >&2; exit 3"])
        let result = try #require(await exec.exec())
        #expect(result.exitCode == 3)
        // stop() before the exit is handled makes an exit with a non-zero code an error, which logErrors reports.
        #expect(exec.hasError)
        #expect(logs.messages(.error).first == "FFmpeg process ended unexpectedly with an exit code of 3.")
        #expect(logs.messages(.error).contains("Invalid data found"))
    }

    @Test func killsTheProcessAndReturnsNilOnTimeout() async {
        let (logs, options) = shellOptions()
        // A stalled input never exits: only the timeout ends it.
        let exec = FfmpegExec(options, commandLineArgs: ["-c", "exec sleep 30"], logErrors: false)
        let start = ContinuousClock.now
        #expect(await exec.exec(timeout: 300) == nil)
        #expect(ContinuousClock.now - start < .seconds(5))
        #expect(logs.messages(.debug).contains("FFmpeg command timed out after 300 ms. Terminating."))
        #expect(await eventually { !exec.isRunning })
    }

    @Test func doesNotKillAProcessThatEndsInTime() async throws {
        let (_, options) = shellOptions()
        let exec = FfmpegExec(options, commandLineArgs: ["-c", "printf snapshot"], logErrors: false)
        let result = try #require(await exec.exec(timeout: 5000))
        #expect(result.exitCode == 0)
        #expect(String(decoding: result.stdout, as: UTF8.self) == "snapshot")
    }
}

@Suite struct FfmpegProcessTests {
    @Test func redactsPasswordsAndKeysFromCommandLines() throws {
        for redaction in try TypeScriptFixture.load().redactions {
            #expect(redactCommandLine(redaction.args) == redaction.redacted)
        }
        #expect(redactCommandLine(["-srtp_out_suite", "AES_CM_128_HMAC_SHA1_80", "-srtp_out_params", "c2VjcmV0a2V5", "srtp://10.0.0.3:5000"])
            == "-srtp_out_suite AES_CM_128_HMAC_SHA1_80 -srtp_out_params *** srtp://10.0.0.3:5000")
    }

    @Test func logsTheCommandLineWithoutPasswords() async {
        let (logs, options) = shellOptions()
        let process = FfmpegProcess(options, commandLineArgs: ["-c", "exit 0", "http://user:hunter2@camera/audio.cgi"])
        process.start()
        let logged = logs.messages(.debug).joined(separator: "\n")
        #expect(logged.contains("FFmpeg command (version: 8.0): /bin/sh -c exit 0 http://user:***@camera/audio.cgi"))
        #expect(!logged.contains("hunter2"))
        _ = await waitForExit(process)
    }

    @Test func boundsTheStandardErrorLogAndResetsItForEachProcess() async throws {
        let (_, options) = shellOptions()
        let process = FfmpegProcess(options, commandLineArgs: [
            "-c", "i=0; while [ $i -lt 500 ]; do echo \"line $i\" >&2; i=$((i+1)); done; exec sleep 30",
        ])
        process.start()
        #expect(await eventually { process.stderrLog.last == "line 499" })
        #expect(process.stderrLog.count == 100)
        #expect(process.stderrLog.first == "line 400")
        let status = await waitForExit(process) { process.stop() }
        #expect(status?.signal == "SIGTERM")
        #expect(!process.hasError)

        // A restarted instance starts with fresh diagnostics.
        process.start(["-c", "exec sleep 30"])
        #expect(process.stderrLog.isEmpty)
        process.stop()
        _ = await waitForExit(process)
    }

    @Test func turnsNonPrintableCharactersIntoLineBreaks() async {
        let (_, options) = shellOptions()
        let process = FfmpegProcess(options, commandLineArgs: ["-c", "printf 'frame=1\\rframe=2\\r\\nlast\\n' >&2; exec sleep 30"])
        process.start()
        #expect(await eventually { process.stderrLog == ["frame=1", "frame=2", "last"] })
        process.stop()
        _ = await waitForExit(process)
    }

    @Test func startsAndReportsTheStart() async throws {
        let (logs, options) = shellOptions()
        let process = FfmpegProcess(options, commandLineArgs: ["-c", "echo ready >&2; exec sleep 30"])
        process.start()
        try await process.waitForStart()
        #expect(process.isStarted)
        #expect(process.isRunning)
        #expect(process.processIdentifier != nil)
        #expect(logs.messages(.debug).contains("FFmpeg process started."))
        let status = await waitForExit(process) { process.stop() }
        #expect(status == FfmpegExitStatus(exitCode: nil, signal: "SIGTERM"))
        #expect(process.isEnded)
        #expect(!process.isStarted)
        #expect(!process.isRunning)
        #expect(logs.messages(.debug).contains("FFmpeg process ended (Expected)."))
    }

    @Test func reportsAProcessThatEndsBeforeStarting() async {
        let (logs, options) = shellOptions()
        let messages = NIOLockedValueBox<[String]>([])
        let process = FfmpegProcess(options, commandLineArgs: ["-c", "exit 4"])
        process.start(errorHandler: { message in messages.withLockedValue { $0.append(message) } })
        await #expect(throws: FfmpegProcessError.self) { try await process.waitForStart() }
        #expect(process.hasError)
        #expect(messages.withLockedValue { $0 } == ["Test Camera: FFmpeg process ended  unexpectedly with exit code 4 and signal null."])
        #expect(logs.messages(.error).first == "FFmpeg process ended unexpectedly with an exit code of 4.")
        #expect(logs.messages(.error).contains("FFmpeg (8.0) command that errored out was: /bin/sh -c exit 4"))
    }

    @Test func reportsAProcessThatCannotStart() async {
        let logs = LogRecorder()
        let options = FfmpegOptions(FfmpegOptionsConfig(
            codecSupport: FfmpegCodecs(ffmpegExec: "homeswift-no-such-ffmpeg", log: logs.logger, ffmpegVersion: "8.0"), hardwareDecoding: false,
            hardwareTranscoding: false, log: logs.logger, name: { "Test Camera" }
        ))
        let messages = NIOLockedValueBox<[String]>([])
        let process = FfmpegProcess(options, commandLineArgs: ["-version"])
        process.start(errorHandler: { message in messages.withLockedValue { $0.append(message) } })
        #expect(!process.isRunning)
        #expect(messages.withLockedValue { $0 } == ["Error: unable to find 'homeswift-no-such-ffmpeg'"])
        await #expect(throws: FfmpegProcessError.endedBeforeStart("Error: unable to find 'homeswift-no-such-ffmpeg'")) { try await process.waitForStart() }
    }

    @Test func doesNotLetASupersededProcessClobberTheNewOne() async throws {
        let (_, options) = shellOptions()
        let process = FfmpegProcess(options, commandLineArgs: ["-c", "echo one >&2; exec sleep 30"])
        process.start()
        let first = try #require(process.processIdentifier)
        // Restart while the first process still runs.
        process.start(["-c", "echo two >&2; exec sleep 30"])
        let second = try #require(process.processIdentifier)
        #expect(first != second)
        kill(first, SIGTERM)
        try await Task.sleep(for: .milliseconds(500))
        // The late exit of the old process leaves the new one alone.
        #expect(process.processIdentifier == second)
        #expect(process.isRunning)
        process.stop()
        _ = await waitForExit(process)
        #expect(!process.isRunning)
    }

    @Test func doesNotArmTheKillTimerForAnEndedProcess() async {
        let (_, options) = shellOptions()
        let process = FfmpegProcess(options, commandLineArgs: ["-c", "echo x >&2"])
        process.start()
        #expect(await eventually { !process.isRunning })
        process.stop()
        #expect(process.base.withLockedValue { $0.killTimer == nil })
    }

    @Test func killsAProcessThatIgnoresTERM() async throws {
        let (logs, options) = shellOptions()
        // The shell traps TERM and keeps running: only the SIGKILL failsafe ends it, after FFMPEG_INPUT_TIMEOUT.
        let process = FfmpegProcess(options, commandLineArgs: ["-c", "trap '' TERM; echo up >&2; while :; do sleep 0.1; done"])
        process.start()
        try await process.waitForStart()
        let start = ContinuousClock.now
        let status = await waitForExit(process, timeout: .seconds(15)) { process.stop() }
        #expect(status?.signal == "SIGKILL")
        #expect(ContinuousClock.now - start >= .milliseconds(FFMPEG_INPUT_TIMEOUT - 500))
        #expect(logs.messages(.debug).contains("FFmpeg process ended (Killed)."))
    }

    @Test func endsTheProcessWithItsObject() async throws {
        let (_, options) = shellOptions()
        var process: FfmpegProcess? = FfmpegProcess(options, commandLineArgs: ["-c", "echo up >&2; exec sleep 30"])
        process?.start()
        try await process?.waitForStart()
        let pid = try #require(process?.processIdentifier)
        #expect(kill(pid, 0) == 0)
        process = nil
        #expect(await eventually { kill(pid, 0) != 0 })
    }

    @Test func writesStandardInputAndReadsStandardOutput() async throws {
        let (_, options) = shellOptions()
        let process = FfmpegProcess(options, commandLineArgs: ["-c", "echo ready >&2; cat"])
        process.start()
        let output = NIOLockedValueBox(Data())
        let listener = try #require(process.onStdout { data in output.withLockedValue { $0.append(data) } })
        #expect(process.isStdinWritable)
        try await process.writeStdin(Data("hello ".utf8))
        try await process.writeStdin(Data("world".utf8))
        #expect(await eventually { output.withLockedValue { $0 } == Data("hello world".utf8) })
        process.offStdout(listener)
        try await process.writeStdin(Data("ignored".utf8))
        process.endStdin()
        #expect(!process.isStdinWritable)
        await #expect(throws: FfmpegProcessError.stdinClosed) { try await process.writeStdin(Data("late".utf8)) }
        let status = await waitForExit(process)
        #expect(status?.exitCode == 0)
        #expect(output.withLockedValue { $0 } == Data("hello world".utf8))
        await #expect(throws: FfmpegProcessError.notRunning) { try await process.writeStdin(Data()) }
    }

    @Test func survivesWritingToAProcessThatClosedItsInput() async throws {
        let (_, options) = shellOptions()
        let process = FfmpegProcess(options, commandLineArgs: ["-c", "exec 0<&-; echo closed >&2; exec sleep 30"])
        process.start()
        try await process.waitForStart()
        // EPIPE, not SIGPIPE: the test process survives.
        await #expect(throws: FfmpegProcessError.stdinClosed) {
            for _ in 0..<64 { try await process.writeStdin(Data(count: 65536)) }
        }
        process.stop()
        _ = await waitForExit(process)
    }

    @Test func logsFFmpegOutputWhenDebugging() async {
        let (logs, options) = shellOptions(debug: true)
        let process = FfmpegProcess(options, commandLineArgs: ["-c", "echo 'Input #0, rtsp, from rtsp://admin:pw@cam/s' >&2"])
        process.start()
        _ = await waitForExit(process)
        #expect(logs.messages(.info).contains("Input #0, rtsp, from rtsp://admin:***@cam/s"))
        #expect(logs.messages(.info).first?.hasPrefix("FFmpeg command (version: 8.0): /bin/sh") == true)
    }
}

@Suite struct FfmpegLivestreamProcessTests {
    private func livestream(_ options: FfmpegOptions) -> FfmpegLivestreamProcess {
        let process = FfmpegLivestreamProcess(
            options, recordingConfig: recordingConfiguration(), livestreamOptions: FMp4LivestreamOptions(url: "rtsp://127.0.0.1/test", enableAudio: false)
        )
        // cat echoes what we write: we play FFmpeg's fMP4 output through standard input.
        process.start(["-c", "echo ready >&2; exec cat"])
        return process
    }

    @Test func accumulatesTheInitSegmentAndEmitsMediaSegments() async throws {
        let (_, options) = shellOptions()
        let process = livestream(options)
        let segments = NIOLockedValueBox<[Data]>([])
        process.segmentEvents.on { segment in segments.withLockedValue { $0.append(segment) } }
        let ftyp = box("ftyp", Data("iso5".utf8))
        let moov = box("moov", bytes(16, 1))
        let moof = box("moof", bytes(8, 2))
        let mdat = box("mdat", bytes(4, 3))
        try await process.writeStdin(ftyp + moov + moof + mdat)
        #expect(await eventually { segments.withLockedValue { $0.count } == 2 })
        #expect(process.initSegment == ftyp + moov)
        #expect(segments.withLockedValue { $0 } == [moof, mdat])
        process.stop()
        _ = await waitForExit(process)
    }

    @Test func treatsABoxSizeBelowTheHeaderSizeAsFatal() async throws {
        let (logs, options) = shellOptions()
        let process = livestream(options)
        let segments = NIOLockedValueBox<[Data]>([])
        process.segmentEvents.on { segment in segments.withLockedValue { $0.append(segment) } }
        var corrupt = Data(count: BOX_HEADER_SIZE)
        corrupt.replaceSubrange(4..<8, with: Array("free".utf8))
        let exited = NIOLockedValueBox(false)
        process.onceExit { _ in exited.withLockedValue { $0 = true } }
        try await process.writeStdin(corrupt)
        #expect(await eventually { logs.messages(.error).contains("Invalid fMP4 box size (0) detected in the FFmpeg output stream. Ending this session.") })
        // The session is stopped, and later output ignored.
        #expect(await eventually { exited.withLockedValue { $0 } })
        #expect(segments.withLockedValue { $0 }.isEmpty)
    }

    @Test func resetsTheInitSegmentWhenRestarted() async throws {
        let (_, options) = shellOptions()
        let process = livestream(options)
        let firstInit = box("ftyp", Data("old!".utf8)) + box("moov", bytes(4, 1))
        try await process.writeStdin(firstInit + box("moof", bytes(4, 2)))
        #expect(await eventually { process.initSegment == firstInit })
        process.stop()
        _ = await waitForExit(process)

        process.start(["-c", "echo ready >&2; exec cat"])
        let segments = NIOLockedValueBox<[Data]>([])
        process.segmentEvents.on { segment in segments.withLockedValue { $0.append(segment) } }
        let secondFtyp = box("ftyp", Data("new!".utf8))
        let secondMoov = box("moov", bytes(4, 9))
        try await process.writeStdin(secondFtyp + secondMoov)
        try await Task.sleep(for: .milliseconds(200))
        // The new ftyp and moov are the new init segment, not media segments, and nothing stale is served.
        #expect(segments.withLockedValue { $0 }.isEmpty)
        #expect(process.initSegment == nil)
        let secondMoof = box("moof", bytes(4, 6))
        try await process.writeStdin(secondMoof)
        #expect(await eventually { segments.withLockedValue { $0.count } == 1 })
        #expect(process.initSegment == secondFtyp + secondMoov)
        #expect(segments.withLockedValue { $0 } == [secondMoof])
        process.stop()
        _ = await waitForExit(process)
    }

    @Test func emitsCloseOncePerProcessLifecycle() async {
        let (_, options) = shellOptions()
        let process = livestream(options)
        let closes = NIOLockedValueBox(0)
        process.closeEvents.on { closes.withLockedValue { $0 += 1 } }
        process.stop()
        _ = await waitForExit(process)
        process.stop()
        #expect(closes.withLockedValue { $0 } == 1)
        // A restarted instance can emit close again.
        process.start(["-c", "exec cat"])
        process.stop()
        _ = await waitForExit(process)
        #expect(closes.withLockedValue { $0 } == 2)
    }

    @Test func sharesOnePendingInitSegmentWait() async throws {
        let (_, options) = shellOptions()
        let process = livestream(options)
        async let first = process.getInitSegment()
        async let second = process.getInitSegment()
        #expect(await eventually { process.pendingInitSegmentWaits == 2 })
        let initSegment = box("ftyp", bytes(4)) + box("moov", bytes(4))
        try await process.writeStdin(initSegment + box("moof", bytes(4)))
        #expect(try await first == initSegment)
        #expect(try await second == initSegment)
        #expect(process.pendingInitSegmentWaits == 0)
        // Once it is there, it is returned at once.
        #expect(try await process.getInitSegment() == initSegment)
        process.stop()
        _ = await waitForExit(process)
    }

    @Test func releasesAPendingWaitWhenStopped() async throws {
        let (_, options) = shellOptions()
        let process = livestream(options)
        let pending = Task { try await process.getInitSegment() }
        #expect(await eventually { process.pendingInitSegmentWaits == 1 })
        process.stop()
        await #expect(throws: FfmpegLivestreamError.aborted) { try await pending.value }
        #expect(process.pendingInitSegmentWaits == 0)
        _ = await waitForExit(process)
    }

    @Test func releasesAPendingWaitWhenTheProcessExits() async throws {
        let (_, options) = shellOptions()
        let process = livestream(options)
        let pending = Task { try await process.getInitSegment() }
        #expect(await eventually { process.pendingInitSegmentWaits == 1 })
        process.endStdin()
        await #expect(throws: FfmpegLivestreamError.aborted) { try await pending.value }
        #expect(process.pendingInitSegmentWaits == 0)
    }

    @Test func rejectsAtOnceWithoutAProcess() async {
        let (_, options) = shellOptions()
        let process = FfmpegLivestreamProcess(options, recordingConfig: recordingConfiguration(), livestreamOptions: FMp4LivestreamOptions(url: "rtsp://x"))
        await #expect(throws: FfmpegLivestreamError.noActiveProcess) { try await process.getInitSegment() }
        #expect(process.pendingInitSegmentWaits == 0)
    }
}

@Suite struct FfmpegRecordingProcessTests {
    private func recording(_ options: FfmpegOptions) -> FfmpegRecordingProcess {
        let process = FfmpegRecordingProcess(options, recordingConfig: recordingConfiguration())
        #expect(process.commandLineArgs.contains("pipe:0"))
        process.start(["-c", "echo ready >&2; exec cat"])
        return process
    }

    @Test func yieldsTheInitSegmentThenMoofMdatPairs() async throws {
        let (_, options) = shellOptions()
        let process = recording(options)
        let ftyp = box("ftyp", Data("iso5".utf8))
        let moov = box("moov", bytes(16, 1))
        let moof = box("moof", bytes(8, 2))
        let mdat = box("mdat", bytes(100, 3))
        var iterator = process.segmentGenerator().makeAsyncIterator()
        try await process.writeStdin(ftyp + moov + moof)
        #expect(await iterator.next() == ftyp + moov)
        // A fragment is only complete with its mdat, even when it arrives in pieces.
        let fragment = mdat
        try await process.writeStdin(fragment.prefix(50))
        try await Task.sleep(for: .milliseconds(100))
        try await process.writeStdin(fragment.suffix(from: 50))
        #expect(await iterator.next() == moof + mdat)
        process.stop()
        #expect(await iterator.next() == nil)
        #expect(!process.isTimedOut)
        _ = await waitForExit(process)
    }

    @Test func endsWithALastPacketWhenFFmpegFallsSilent() async throws {
        let (_, options) = shellOptions()
        let process = recording(options)
        let initSegment = box("ftyp", bytes(4)) + box("moov", bytes(4))
        try await process.writeStdin(initSegment)
        var packets: [RecordingPacket] = []
        let start = ContinuousClock.now
        for try await packet in process.recordingPackets() {
            packets.append(packet)
        }
        // Nothing within HKSV_TIMEOUT after the init segment.
        #expect(ContinuousClock.now - start >= .milliseconds(HKSV_TIMEOUT - 200))
        #expect(process.isTimedOut)
        #expect(packets.map(\.data) == [initSegment, Data([0])])
        #expect(packets.map(\.isLast) == [false, true])
        process.stop()
        _ = await waitForExit(process)
    }

    @Test func logsKnownHKSVErrorsBriefly() async {
        let (logs, options) = shellOptions()
        let process = FfmpegRecordingProcess(options, recordingConfig: recordingConfiguration())
        process.start(["-c", "echo 'moov atom not found' >&2; exit 1"])
        _ = await waitForExit(process)
        #expect(logs.messages(.error) == [
            "FFmpeg ended unexpectedly due to issues processing the media stream. This error can be safely ignored - it will occur occasionally."
        ])
    }
}

/// A streaming delegate that records what the process asks of it.
final class RecordingStreamingDelegate: HomebridgeStreamingDelegate {
    let calls = NIOLockedValueBox<[String]>([])
    let errorMessage: String?

    init(errorMessage: String? = nil) {
        self.errorMessage = errorMessage
    }

    func adjustProbeSize() { calls.withLockedValue { $0.append("adjustProbeSize") } }
    func ffmpegErrorCheck(_ logEntry: [String]) -> String? { logEntry.contains("known failure") ? errorMessage : nil }
    func stopStream(_ sessionId: String) { calls.withLockedValue { $0.append("stopStream \(sessionId)") } }
    func forceStopStreamingSession(_ sessionId: String) { calls.withLockedValue { $0.append("forceStop \(sessionId)") } }

    var recorded: [String] { calls.withLockedValue { $0 } }
}

@Suite struct FfmpegStreamingProcessTests {
    @Test func closesTheHealthSocketOnStop() async throws {
        let (_, options) = shellOptions()
        let process = FfmpegStreamingProcess(
            delegate: RecordingStreamingDelegate(), sessionId: "session-1", ffmpegOptions: options, commandLineArgs: ["-c", "echo up >&2; exec sleep 30"],
            returnPort: FfmpegReturnPort(addressVersion: .ipv4, port: 0)
        )
        #expect(await process.waitForHealthSocket())
        process.stop()
        #expect(process.isHealthSocketClosed)
        #expect(process.healthSocketPort == nil)
        _ = await waitForExit(process)
    }

    @Test func closesTheHealthSocketWhenTheProcessExitsOnItsOwn() async throws {
        let (_, options) = shellOptions()
        let process = FfmpegStreamingProcess(
            delegate: RecordingStreamingDelegate(), sessionId: "session-2", ffmpegOptions: options, commandLineArgs: ["-c", "echo up >&2; sleep 3"],
            returnPort: FfmpegReturnPort(addressVersion: .ipv4, port: 0)
        )
        #expect(await process.waitForHealthSocket())
        #expect(await eventually { process.isHealthSocketClosed })
    }

    @Test func stopsAnInactiveStream() async throws {
        let (logs, options) = shellOptions()
        let delegate = RecordingStreamingDelegate()
        let process = FfmpegStreamingProcess(
            delegate: delegate, sessionId: "session-3", ffmpegOptions: options, commandLineArgs: ["-c", "echo up >&2; exec sleep 30"],
            returnPort: FfmpegReturnPort(addressVersion: .ipv4, port: 0)
        )
        #expect(await process.waitForHealthSocket())
        let port = try #require(process.healthSocketPort)
        try await sendUDP(Data([0x80, 0xC8, 0, 0]), to: port)
        // Nothing more for FFMPEG_INPUT_TIMEOUT: the session is stopped.
        #expect(await eventually(timeout: .seconds(8)) { delegate.recorded == ["forceStop session-3", "stopStream session-3"] })
        #expect(logs.messages(.debug).contains("Video stream appears to be inactive for 5 seconds. Stopping stream."))
        process.stop()
        _ = await waitForExit(process)
    }

    @Test func reportsAFailureBeforeTheStartToTheWaiter() async {
        let (_, options) = shellOptions()
        let delegate = RecordingStreamingDelegate()
        let process = FfmpegStreamingProcess(
            delegate: delegate, sessionId: "s", ffmpegOptions: options, commandLineArgs: ["-c", "exit 1"], awaitingStart: true
        )
        await #expect(throws: FfmpegProcessError.endedBeforeStart("Test Camera: FFmpeg process ended  unexpectedly with exit code 1 and signal null.")) {
            try await process.waitForStart()
        }
        #expect(delegate.recorded == ["stopStream s"])
    }

    @Test func forceStopsTheSessionWhenFFmpegFailsAfterStarting() async throws {
        let (_, options) = shellOptions()
        let delegate = RecordingStreamingDelegate()
        let process = FfmpegStreamingProcess(
            delegate: delegate, sessionId: "s", ffmpegOptions: options, commandLineArgs: ["-c", "echo up >&2; sleep 0.3; exit 1"], awaitingStart: true
        )
        try await process.waitForStart()
        #expect(await eventually { delegate.recorded.count == 3 })
        #expect(delegate.recorded == ["stopStream s", "forceStop s", "stopStream s"])
    }

    @Test func letsThePluginExplainKnownErrors() async {
        let (logs, options) = shellOptions()
        let delegate = RecordingStreamingDelegate(errorMessage: "The camera is offline.")
        let process = FfmpegStreamingProcess(delegate: delegate, sessionId: "s", ffmpegOptions: options, commandLineArgs: ["-c", "echo 'known failure' >&2; exit 1"])
        _ = await waitForExit(process)
        #expect(await eventually { logs.messages(.error) == ["The camera is offline."] })
    }

    @Test func adjustsTheProbeSize() async {
        let (logs, options) = shellOptions()
        let delegate = RecordingStreamingDelegate()
        let process = FfmpegStreamingProcess(
            delegate: delegate, sessionId: "s", ffmpegOptions: options,
            commandLineArgs: ["-c", "echo '[h264] not enough frames to estimate rate; consider increasing probesize' >&2; exit 1"]
        )
        _ = await waitForExit(process)
        #expect(await eventually { delegate.recorded.contains("adjustProbeSize") })
        #expect(logs.messages(.error).isEmpty)
    }
}
