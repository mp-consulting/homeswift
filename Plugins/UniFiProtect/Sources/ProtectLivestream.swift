import Foundation
import HomeswiftNetwork
import NIOConcurrencyHelpers

/// The livestream protocol of the controller: a WebSocket of fMP4 boxes in small packets, each a type byte,
/// a 24-bit big-endian length and the payload. Packets can span WebSocket messages and a message can hold
/// several; a segment is the MOOF, MDAT, video and audio packets between a begin and an end packet.
struct ProtectLivestreamParser: Sendable {
    enum Frame: UInt8, CaseIterable {
        case timestamp = 247
        case codecInformation = 248
        case beginSegment = 249
        case initSegment = 250
        case moof = 251
        case video = 252
        case audio = 253
        case mdat = 254
        case endSegment = 255
    }

    enum Output: Sendable, Equatable {
        case codec(String)
        case initSegment(Data)
        /// A complete segment, and its MOOF and MDAT parts.
        case segment(Data, moof: Data, mdat: Data)
        /// The decode timestamps of the frames of the next segment, as in its `tfdt` box.
        case timestamps([UInt64])
    }

    struct InvalidHeader: Error, Equatable {
        let header: UInt8
    }

    private var remaining = Data()
    private var moof: [Data] = []
    private var mdat: [Data] = []
    private var video: [Data] = []
    private var audio: [Data] = []

    /// Consumes a WebSocket message. Throws on a packet type that does not exist: framing is lost and the
    /// rest of the stream cannot be read.
    mutating func feed(_ message: Data) throws -> [Output] {
        var packet = remaining.isEmpty ? message : remaining + message
        remaining = Data()
        packet = Data(packet)
        var outputs: [Output] = []
        var offset = packet.startIndex
        while true {
            if packet.endIndex - offset < 4 {
                remaining = Data(packet[offset...])
                break
            }
            let header = packet[offset]
            guard let frame = Frame(rawValue: header) else { throw InvalidHeader(header: header) }
            let length = Int(packet[offset + 1]) << 16 | Int(packet[offset + 2]) << 8 | Int(packet[offset + 3])
            guard packet.endIndex - offset >= 4 + length else {
                remaining = Data(packet[offset...])
                break
            }
            let data = Data(packet[(offset + 4)..<(offset + 4 + length)])
            switch frame {
            case .audio: audio.append(data)
            case .endSegment:
                let moofData = moof.reduce(Data(), +), mdatData = mdat.reduce(Data(), +)
                outputs.append(.segment(moofData + mdatData + video.reduce(Data(), +) + audio.reduce(Data(), +), moof: moofData, mdat: mdatData))
            case .codecInformation: outputs.append(.codec(String(decoding: data, as: UTF8.self)))
            case .beginSegment:
                moof = []
                mdat = []
                video = []
                audio = []
            case .initSegment: outputs.append(.initSegment(data))
            case .timestamp:
                var stamps: [UInt64] = []
                var index = data.startIndex
                while index + 8 <= data.endIndex {
                    stamps.append(data[index..<(index + 8)].reduce(UInt64(0)) { $0 << 8 | UInt64($1) })
                    index += 8
                }
                outputs.append(.timestamps(stamps))
            case .mdat: mdat.append(data)
            case .moof: moof.append(data)
            case .video: video.append(data)
            }
            offset += 4 + length
        }
        return outputs
    }
}

/// One livestream session (`ProtectLivestream`): asks the controller for the WebSocket of a camera channel
/// and lens, parses its packets, and hands segments to its observers, or to `stream` in stream mode. A
/// heartbeat closes a session that sends nothing for ten seconds; `close` is observed exactly once per
/// session, whatever ended it.
final class ProtectLivestream: @unchecked Sendable {
    struct Options: Sendable {
        /// Maximum payload of each WebSocket message.
        var chunkSize = 4096
        /// Ask for decode timestamps (`timestamps` events).
        var emitTimestamps = false
        /// A second lens of the device, such as a package camera.
        var lens = 0
        /// For the controller's logs; `<camera>-<channel>` by default.
        var requestId: String?
        /// Milliseconds of each segment; 100 at least.
        var segmentLength = 100
        /// Deliver segments through `stream` instead of observers.
        var useStream = false
    }

    enum Event: Sendable {
        case codec(String)
        case initSegment(Data)
        case segment(Data)
        case timestamps([UInt64])
        case close
    }

    enum LivestreamError: Error, Equatable {
        /// The session ended before the initialization segment came (`AbortError`).
        case aborted
        case noSession
    }

    static let heartbeatTimeout = 10_000

    private struct Session {
        var socket: (any WebSocketConnection)?
        var tasks: [Task<Void, Never>] = []
        var generation = 0
    }

    private struct State {
        var session = Session()
        var initSegment: Data?
        var codec: String?
        var observers: [Int: @Sendable (Event) -> Void] = [:]
        var nextObserver = 0
        var initWaiters: [CheckedContinuation<Data, any Error>] = []
        var streamContinuation: AsyncStream<Data>.Continuation?
        var stream: AsyncStream<Data>?
        var isActive = false
    }

    private let api: ProtectAPI
    private let log: ProtectLog
    private let state = NIOLockedValueBox(State())

    init(api: ProtectAPI, log: ProtectLog) {
        self.api = api
        self.log = log
    }

    var initSegment: Data? { state.withLockedValue { $0.initSegment } }
    var codec: String { state.withLockedValue { $0.codec ?? "" } }
    /// The segments, in stream mode; finishes when the session ends.
    var stream: AsyncStream<Data>? { state.withLockedValue { $0.stream } }
    var isActive: Bool { state.withLockedValue { $0.isActive } }

    @discardableResult
    func observe(_ handler: @escaping @Sendable (Event) -> Void) -> Int {
        state.withLockedValue { state in
            state.nextObserver += 1
            state.observers[state.nextObserver] = handler
            return state.nextObserver
        }
    }

    func removeObserver(_ token: Int) {
        _ = state.withLockedValue { $0.observers.removeValue(forKey: token) }
    }

    func removeAllObservers() {
        state.withLockedValue { $0.observers = [:] }
    }

    /// Starts a session, stopping any running one. False when the controller gave no WebSocket.
    func start(cameraID: String, channel: Int, options: Options = Options()) async -> Bool {
        stop()
        let generation = state.withLockedValue { state -> Int in
            state.session.generation += 1
            state.initSegment = nil
            state.isActive = true
            return state.session.generation
        }
        let requestId = options.requestId ?? "\(cameraID)-\(channel)"
        var parameters: [(String, String)] = [("allowPartialGOP", ""), ("camera", cameraID), ("channel", String(channel)), ("chunkSize", String(options.chunkSize))]
        if options.emitTimestamps { parameters.append(("extendedVideoMetadata", "")) }
        parameters += [
            ("fragmentDurationMillis", String(max(options.segmentLength, 100))), ("lens", String(options.lens)), ("progressive", ""),
            ("rebaseTimestampsToZero", "true"), ("requestId", requestId), ("type", "fmp4"), ("useWallClock", "false"),
        ]
        guard let endpoint = await api.getWsEndpoint("livestream", parameters: parameters), let url = URL(string: endpoint) else {
            log.error("\(requestId): unable to retrieve the livestream websocket API endpoint from the UniFi Protect controller.")
            teardown(generation: generation)
            return false
        }
        let socket: any WebSocketConnection
        do {
            socket = try await api.openWebSocket(url)
        } catch {
            log.error("\(requestId): error while connecting to the livestream websocket API: \(error)")
            teardown(generation: generation)
            return false
        }
        let stillCurrent = state.withLockedValue { state -> Bool in
            guard state.session.generation == generation, state.isActive else { return false }
            state.session.socket = socket
            if options.useStream {
                let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
                state.stream = stream
                state.streamContinuation = continuation
            }
            return true
        }
        guard stillCurrent else {
            await socket.close()
            return false
        }
        let lastMessage = NIOLockedValueBox(ContinuousClock.now)
        let reader = Task { [weak self] in
            var parser = ProtectLivestreamParser()
            do {
                for try await message in socket.messages {
                    lastMessage.withLockedValue { $0 = ContinuousClock.now }
                    guard let self else { return }
                    do {
                        for output in try parser.feed(message.data) where self.isCurrent(generation) {
                            self.deliver(output, useStream: options.useStream)
                        }
                    } catch let error as ProtectLivestreamParser.InvalidHeader {
                        self.log.error("Invalid header found while decoding the livestream: \(error.header)")
                        self.teardown(generation: generation)
                        return
                    } catch {}
                }
            } catch {
                // A dropped connection ends the session like a close.
            }
            self?.teardown(generation: generation)
        }
        let timeout = Duration.milliseconds(Int(Double(Self.heartbeatTimeout) * api.timeScale))
        let heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled, let self else { return }
                if ContinuousClock.now - lastMessage.withLockedValue({ $0 }) > timeout {
                    self.log.error("\(requestId): the livestream API is not responding.")
                    await socket.close()
                    return
                }
            }
        }
        // Stopped (or ended by the controller) since the socket opened: the session is dead, and says so.
        let alive = state.withLockedValue { state -> Bool in
            guard state.session.generation == generation, state.isActive else { return false }
            state.session.tasks = [reader, heartbeat]
            return true
        }
        guard alive else {
            reader.cancel()
            heartbeat.cancel()
            await socket.close()
            return false
        }
        return true
    }

    /// Ends the session: `close` goes to the observers once, a pending `getInitSegment()` fails.
    func stop() {
        let generation = state.withLockedValue { $0.session.generation }
        teardown(generation: generation)
    }

    /// The initialization segment: at once when it came, else when it comes. Fails when the session ends
    /// first, or when there is no session.
    func getInitSegment() async throws -> Data {
        enum Pending { case ready(Data), wait, none }
        return try await withCheckedThrowingContinuation { continuation in
            let pending = state.withLockedValue { state -> Pending in
                if let segment = state.initSegment { return .ready(segment) }
                guard state.isActive else { return .none }
                state.initWaiters.append(continuation)
                return .wait
            }
            switch pending {
            case .ready(let segment): continuation.resume(returning: segment)
            case .none: continuation.resume(throwing: LivestreamError.noSession)
            case .wait: break
            }
        }
    }

    private func isCurrent(_ generation: Int) -> Bool {
        state.withLockedValue { $0.session.generation == generation && $0.isActive }
    }

    private func deliver(_ output: ProtectLivestreamParser.Output, useStream: Bool) {
        let (observers, continuation, waiters) = state.withLockedValue { state -> ([@Sendable (Event) -> Void], AsyncStream<Data>.Continuation?, [CheckedContinuation<Data, any Error>]) in
            var waiters: [CheckedContinuation<Data, any Error>] = []
            switch output {
            case .codec(let codec): state.codec = codec
            case .initSegment(let segment):
                state.initSegment = segment
                waiters = state.initWaiters
                state.initWaiters = []
            default: break
            }
            return (Array(state.observers.values), state.streamContinuation, waiters)
        }
        switch output {
        case .codec(let codec):
            log.debug("Livestream codec information: \(codec)")
            if !useStream { observers.forEach { $0(.codec(codec)) } }
        case .initSegment(let segment):
            waiters.forEach { $0.resume(returning: segment) }
            if useStream {
                continuation?.yield(segment)
            } else {
                observers.forEach { $0(.initSegment(segment)) }
            }
        case .segment(let segment, _, _):
            // The Homebridge plugin also emits a segment's MOOF and MDAT apart; nothing here listens to them.
            if useStream {
                continuation?.yield(segment)
            } else {
                observers.forEach { $0(.segment(segment)) }
            }
        case .timestamps(let stamps):
            observers.forEach { $0(.timestamps(stamps)) }
        }
    }

    private func teardown(generation: Int) {
        let ended = state.withLockedValue { state -> (socket: (any WebSocketConnection)?, tasks: [Task<Void, Never>], waiters: [CheckedContinuation<Data, any Error>], continuation: AsyncStream<Data>.Continuation?, observers: [@Sendable (Event) -> Void], hadSession: Bool)? in
            guard state.session.generation == generation, state.isActive else { return nil }
            let result = (state.session.socket, state.session.tasks, state.initWaiters, state.streamContinuation, Array(state.observers.values), state.session.socket != nil)
            state.isActive = false
            state.session.socket = nil
            state.session.tasks = []
            state.initWaiters = []
            state.streamContinuation = nil
            state.stream = nil
            return result
        }
        guard let ended else { return }
        ended.tasks.forEach { $0.cancel() }
        ended.waiters.forEach { $0.resume(throwing: LivestreamError.aborted) }
        ended.continuation?.finish()
        if let socket = ended.socket { Task { await socket.close() } }
        if ended.hadSession { ended.observers.forEach { $0(.close) } }
    }
}
