import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers

@testable import Homeswift
@testable import HomeswiftReolink

let testLogger: Logger = {
    var logger = Logger(label: "homeswift")
    logger.logLevel = ProcessInfo.processInfo.environment["HOMESWIFT_TEST_LOG"].flatMap(Logger.Level.init(rawValue:)) ?? .warning
    return logger
}()

/// Polls `condition` until it holds or `timeout` passes.
func eventually(timeout: Duration = .seconds(10), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

func bytes(_ hex: String) -> [UInt8] {
    let digits = hex.filter(\.isHexDigit)
    var result: [UInt8] = []
    var index = digits.startIndex
    while index < digits.endIndex {
        let next = digits.index(index, offsetBy: 2)
        result.append(UInt8(digits[index..<next], radix: 16)!)
        index = next
    }
    return result
}

func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined(separator: " ") }

// MARK: HTTP

/// A Reolink device's HTTP API in memory: logins and tokens, each command answered from `answers` (by command name, the
/// param given), `Snap` with a JPEG. It counts requests and the commands it got, and notes when two overlap.
final class FakeReolinkHTTP: HTTPSending, @unchecked Sendable {
    struct State {
        var answers: [String: @Sendable (JSONValue?) -> JSONValue] = [:]
        var tokens = 0
        var token: String?
        var lease = 3600
        var requests: [(cmd: String, body: JSONValue?)] = []
        var commands: [String] = []
        var logins = 0
        var logouts = 0
        var inFlight = 0
        var overlapped = false
        var password = "secret"
        var expireNext = false
        var unreachable = false
        var loginReply: JSONValue?
        var delay: Duration = .zero
        var batchErrorOnce = false
    }

    let state = NIOLockedValueBox(State())

    init(_ answers: [String: @Sendable (JSONValue?) -> JSONValue] = [:]) {
        state.withLockedValue { $0.answers = answers }
    }

    func answer(_ cmd: String, _ value: JSONValue) {
        state.withLockedValue { $0.answers[cmd] = { _ in value } }
    }

    var commands: [String] { state.withLockedValue { $0.commands } }
    var requestCount: Int { state.withLockedValue { $0.requests.count } }
    var logins: Int { state.withLockedValue { $0.logins } }

    func count(_ cmd: String) -> Int { state.withLockedValue { $0.commands.filter { $0 == cmd }.count } }

    func send(_ request: HomeswiftNetwork.HTTPRequest) async throws -> HomeswiftNetwork.HTTPResponse {
        let (unreachable, delay) = state.withLockedValue { state -> (Bool, Duration) in
            if state.inFlight > 0 { state.overlapped = true }
            state.inFlight += 1
            return (state.unreachable, state.delay)
        }
        defer { state.withLockedValue { $0.inFlight -= 1 } }
        if unreachable { throw HTTPClientError.cannotConnect(host: request.url.host ?? "", port: 443, code: 61, reason: "refused") }
        if delay > .zero { try await Task.sleep(for: delay) }
        let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        let cmd = query["cmd"] ?? ""
        let body = request.body.flatMap { try? JSONValue(data: $0) }
        state.withLockedValue { $0.requests.append((cmd, body)) }
        func json(_ value: JSONValue) -> HomeswiftNetwork.HTTPResponse {
            HomeswiftNetwork.HTTPResponse(status: 200, headers: [("Content-Type", "text/html")], body: value.encoded())
        }
        switch cmd {
        case "Login":
            return json(state.withLockedValue { state -> JSONValue in
                state.logins += 1
                if let reply = state.loginReply { return reply }
                let password = body?[0]?["param"]?["User"]?["password"]?.stringValue
                guard password == state.password else {
                    return [["cmd": "Login", "code": 1, "error": ["rspCode": -7, "detail": "login failed"]]]
                }
                state.tokens += 1
                state.token = "token\(state.tokens)"
                return [["cmd": "Login", "code": 0, "value": ["Token": ["leaseTime": .number(Double(state.lease)), "name": .string(state.token!)]]]]
            })
        case "Logout":
            state.withLockedValue {
                $0.logouts += 1
                $0.token = nil
            }
            return HomeswiftNetwork.HTTPResponse(status: 200, body: Data("ok".utf8))
        default:
            break
        }
        let valid = state.withLockedValue { state -> Bool in
            if state.expireNext {
                state.expireNext = false
                state.token = nil
            }
            return state.token != nil && query["token"] == state.token
        }
        if cmd == "Snap" {
            state.withLockedValue { $0.commands.append("Snap") }
            guard valid else { return json([["cmd": "Snap", "code": 1, "error": ["rspCode": -6, "detail": "please login first"]]]) }
            return HomeswiftNetwork.HTTPResponse(status: 200, headers: [("Content-Type", "image/jpeg")], body: Data("JPEG\(query["channel"] ?? "")\(query["snapType"] ?? "")".utf8))
        }
        guard valid else {
            let text = "[ { \"cmd\" : \"\(cmd)\", \"code\" : 1, \"error\" : { \"detail\" : \"please login first\", \"rspCode\" : -6 } } ]"
            return HomeswiftNetwork.HTTPResponse(status: 200, headers: [("Content-Type", "text/html")], body: Data(text.utf8))
        }
        let items = body?.arrayValue ?? []
        let batchError = state.withLockedValue { state -> Bool in
            defer { if items.count > 1 { state.batchErrorOnce = false } }
            return state.batchErrorOnce && items.count > 1
        }
        if batchError { return json([["cmd": JSONValue.string(cmd), "code": 1, "error": ["rspCode": -4, "detail": "param error"]]]) }
        let replies: [JSONValue] = items.map { item in
            let name = item["cmd"]?.stringValue ?? ""
            let answer = state.withLockedValue { state -> (@Sendable (JSONValue?) -> JSONValue)? in
                state.commands.append(name)
                return state.answers[name]
            }
            guard let answer else { return ["cmd": .string(name), "code": 1, "error": ["rspCode": -9, "detail": "not support"]] }
            return answer(item["param"])
        }
        return json(.array(replies))
    }
}

/// The answers of a single wired camera with a floodlight, a siren, IR lights and AI detections.
func cameraAnswers(model: String = "RLC-810A", doorbell: Bool = false) -> [String: @Sendable (JSONValue?) -> JSONValue] {
    func ok(_ cmd: String, _ value: JSONValue) -> @Sendable (JSONValue?) -> JSONValue { { _ in ["cmd": .string(cmd), "code": 0, "value": value] } }
    return [
        "GetDevInfo": ok("GetDevInfo", ["DevInfo": ["model": .string(model), "name": "Driveway", "serial": "00000000000001", "hardVer": "IPC_523128M8MP",
                                                    "firmVer": "v3.1.0.2368_23062508", "exactType": "IPC", "type": "IPC", "channelNum": 1, "itemNo": ""]]),
        "GetChannelstatus": ok("GetChannelstatus", ["count": 1, "status": [["channel": 0, "name": "Driveway", "online": 1, "typeInfo": .string(model)]]]),
        "GetLocalLink": ok("GetLocalLink", ["LocalLink": ["mac": "EC:71:DB:00:00:01"]]),
        "GetNetPort": ok("GetNetPort", ["NetPort": ["rtspPort": 554, "rtmpPort": 1935, "rtspEnable": 1]]),
        "GetP2p": ok("GetP2p", ["P2p": ["uid": "95270000ABCDEFGH"]]),
        "GetUser": ok("GetUser", ["User": [["userName": "admin", "level": "admin"]]]),
        "GetAbility": ok("GetAbility", ["Ability": ["rtsp": ["permit": 0, "ver": 1], "abilityChn": [[
            "floodLight": ["permit": 0, "ver": 1], "ledControl": ["permit": 0, "ver": 1], "alarmAudio": ["permit": 0, "ver": 1], "supportAiAnimal": ["permit": 0, "ver": 0],
        ]]]]),
        "GetEnc": ok("GetEnc", ["Enc": ["mainStream": ["vType": "h265", "width": 3840, "height": 2160, "frameRate": 25],
                                        "subStream": ["vType": "h264", "width": 640, "height": 360, "frameRate": 15]]]),
        "GetMdState": ok("GetMdState", ["state": 0]),
        "GetAiState": ok("GetAiState", ["channel": 0, "people": ["alarm_state": 0, "support": 1], "vehicle": ["alarm_state": 0, "support": 1],
                                        "dog_cat": ["alarm_state": 0, "support": 1]]),
        "GetEvents": ok("GetEvents", ["channel": 0, "ai": ["people": ["alarm_state": 0, "support": 1], "vehicle": ["alarm_state": 0, "support": 1],
                                                           "dog_cat": ["alarm_state": 0, "support": 1]],
                                      "md": ["alarm_state": 0, "support": 1], "visitor": ["alarm_state": 0, "support": doorbell ? 1 : 0]]),
        "GetWhiteLed": ok("GetWhiteLed", ["WhiteLed": ["channel": 0, "state": 0, "bright": 80]]),
        "GetIrLights": ok("GetIrLights", ["IrLights": ["state": "Auto"]]),
        "GetAudioAlarm": ok("GetAudioAlarm", ["Audio": ["schedule": ["enable": 1]]]),
        "SetWhiteLed": ok("SetWhiteLed", ["rspCode": 200]),
        "SetIrLights": ok("SetIrLights", ["rspCode": 200]),
        "AudioAlarmPlay": ok("AudioAlarmPlay", ["rspCode": 200]),
    ]
}

// MARK: Baichuan

/// A Reolink device's Baichuan side in memory: it answers the nonce, checks the login's hashes, takes the subscription
/// and the keepalive, records siren bodies, and pushes events.
final class FakeBaichuanCamera: ByteStream, @unchecked Sendable {
    let incoming: AsyncThrowingStream<[UInt8], any Error>
    private let continuation: AsyncThrowingStream<[UInt8], any Error>.Continuation
    let nonce = "0a1b2c3d4e5f6a7b"
    let username: String
    let password: String
    let accountDevice: Bool
    struct State {
        var received: [(command: UInt32, channel: UInt8, ext: String, body: String)] = []
        var closed = false
    }

    let state = NIOLockedValueBox(State())

    init(username: String = "admin", password: String = "secret", accountDevice: Bool = false) {
        self.username = username
        self.password = password
        self.accountDevice = accountDevice
        (incoming, continuation) = AsyncThrowingStream.makeStream()
    }

    var key: [UInt8] { Baichuan.aesKey(nonce: nonce, password: password) }
    var commands: [UInt32] { state.withLockedValue { $0.received.map(\.command) } }
    var sirenBodies: [String] { state.withLockedValue { $0.received.filter { $0.command == 263 }.map(\.body) } }
    var isClosed: Bool { state.withLockedValue { $0.closed } }

    func send(_ bytes: [UInt8]) async throws {
        guard bytes.count >= 20, bytes.starts(with: Baichuan.magic) else { return }
        let command = Baichuan.readUInt32(bytes, 4)
        let channel = bytes[12]
        let counter = UInt32(bytes[13]) | UInt32(bytes[14]) << 8 | UInt32(bytes[15]) << 16
        if bytes[18] == 0x14, bytes[19] == 0x65 {
            let xml = "<?xml version=\"1.0\" encoding=\"UTF-8\" ?>\n<body>\n<Encryption version=\"1.1\">\n<type>md5</type>\n<nonce>\(nonce)</nonce>\n"
                + (accountDevice ? "<sigVer>v3</sigVer>\n" : "") + "</Encryption>\n</body>\n"
            reply(command: 1, channel: channel, counter: counter, status: 200, body: Baichuan.xor(Array(xml.utf8), offset: channel))
            return
        }
        let extensionLength = Int(Baichuan.readUInt32(bytes, 20))
        let body = Array(bytes[24...])
        let ext = Array(body.prefix(extensionLength))
        let rest = Array(body.dropFirst(extensionLength))
        if command == 1 {
            let text = String(decoding: Baichuan.xor(rest, offset: channel), as: UTF8.self)
            state.withLockedValue { $0.received.append((command, channel, "", text)) }
            let good = text.contains(Baichuan.md5mod(username + nonce)) && text.contains(Baichuan.md5mod(password + nonce))
            let info = "<?xml version=\"1.0\" encoding=\"UTF-8\" ?>\n<body>\n<DeviceInfo version=\"1.1\">\n<type>ipc</type>\n<channelNum>1</channelNum>\n</DeviceInfo>\n</body>\n"
            reply(command: 1, channel: channel, counter: counter, status: good ? 200 : 401, body: good ? Baichuan.xor(Array(info.utf8), offset: channel) : [])
            return
        }
        let decrypt = { (piece: [UInt8]) in String(decoding: (try? Baichuan.aes(piece, key: self.key, decrypt: true)) ?? [], as: UTF8.self) }
        state.withLockedValue { $0.received.append((command, channel, decrypt(ext), decrypt(rest))) }
        reply(command: command, channel: channel, counter: counter, status: 200, body: [])
    }

    private func reply(command: UInt32, channel: UInt8, counter: UInt32, status: UInt16, body: [UInt8]) {
        var header = Baichuan.header(command: command, bodyLength: body.count, channel: channel, counter: counter, extensionLength: 0)
        header[16] = UInt8(status & 0xFF)
        header[17] = UInt8(status >> 8)
        continuation.yield(header + body)
    }

    /// Pushes an event (`cmd_id` 33 by default), AES-encrypted.
    func push(_ xml: String, command: UInt32 = 33) {
        let body = (try? Baichuan.aes(Array(xml.utf8), key: key, decrypt: false)) ?? []
        reply(command: command, channel: Baichuan.subscribeChannel, counter: 0, status: 200, body: body)
    }

    /// The device drops the connection.
    func drop() {
        continuation.finish()
    }

    func close() async {
        state.withLockedValue { $0.closed = true }
        continuation.finish()
    }
}

/// An `AlarmEvent` list as 5.4.1 shows it.
func alarmXML(channel: Int = 0, status: String, ai: String = "none") -> String {
    """
    <?xml version="1.0" encoding="UTF-8" ?>
    <body>
    <AlarmEventList version="1.1">
    <AlarmEvent version="1.1">
    <channelId>\(channel)</channelId>
    <status>\(status)</status>
    <AItype>\(ai)</AItype>
    </AlarmEvent>
    </AlarmEventList>
    </body>
    """
}
