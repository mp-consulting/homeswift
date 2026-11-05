import Foundation

// The Baichuan commands of a standalone battery camera (docs/clean-room/ReolinkBattery.md): identity (80, 114), the
// abilities that tell a battery camera (199), the battery (253), the snapshot (109), live media (3, 4) and the webhook
// that pushes events without a connection (806, 807).

extension Baichuan {
    /// The stream codes of header byte 13 and the `handle`s of a media start (ReolinkBattery.md 4.1, 5.1).
    enum MediaStream: Sendable {
        case main, sub

        var code: UInt32 { self == .sub ? 1 : 0 }
        var handle: Int { self == .sub ? 256 : 0 }
        var name: String { self == .sub ? "subStream" : "mainStream" }
        var snapName: String { self == .sub ? "sub" : "main" }
    }

    /// The live stream's start (`cmd_id` 3) or, without `stream`, its stop (`cmd_id` 4).
    static func previewBody(channel: Int, stream: MediaStream, start: Bool) -> String {
        """
        <?xml version="1.0" encoding="UTF-8" ?>
        <body>
        <Preview version="1.1">
        <channelId>\(channel)</channelId>
        <handle>\(stream.handle)</handle>
        \(start ? "<streamType>\(stream.name)</streamType>\n" : "")</Preview>
        </body>

        """
    }

    /// The snapshot request (`cmd_id` 109, ReolinkBattery.md 7).
    static func snapBody(channel: Int, stream: MediaStream) -> String {
        """
        <?xml version="1.0" encoding="UTF-8" ?>
        <body>
        <Snap version="1.1">
        <channelId>\(channel)</channelId>
        <logicChannel>\(channel)</logicChannel>
        <time>0</time>
        <fullFrame>0</fullFrame>
        <streamType>\(stream.snapName)</streamType>
        </Snap>
        </body>

        """
    }

    /// The webhook's setting (`cmd_id` 807, ReolinkBattery.md 6.1); `url` nil unsubscribes.
    static func webhookBody(url: String?) -> String {
        """
        <?xml version="1.0" encoding="UTF-8" ?>
        <body>
        <HaCfg version="1.1">
        <enable>\(url == nil ? 0 : 1)</enable>
        <url>\(url.map(BXParser.escape) ?? "")</url>
        <verify_cert>0</verify_cert>
        </HaCfg>
        </body>

        """
    }

    /// The `encryptLen` of a binary message's extension (any case); nil without one.
    static func encryptLength(_ xml: String) -> Int? {
        guard let root = try? BXParser.parse(xml) else { return nil }
        let element = ([root] + root.descendants).first { $0.name.lowercased() == "encryptlen" }
        return element.flatMap { Int($0.text.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    /// Whether an extension switches its message id to binary (`binaryData` 1).
    static func isBinary(_ xml: String?) -> Bool {
        guard let xml, let root = try? BXParser.parse(xml) else { return false }
        return root.first("binaryData")?.text.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }
}

/// What a battery camera says of itself (ReolinkBattery.md 2.3).
struct ReolinkBatteryIdentity: Sendable, Equatable, Codable {
    var uid: String
    var name: String
    var model: String
    var serial: String
    var hardware: String
    var firmware: String
}

/// What the abilities (`cmd_id` 199) and the login reply say of the device.
struct ReolinkBaichuanKind: Sendable, Equatable {
    /// Ability `battery` on channel 0 and not an NVR or a hub.
    var isBatteryCamera: Bool
    /// `netPort & 0x40`: Baichuan V3 over UDP-TCP, which the plugin does not speak (2.1).
    var udpOnly: Bool
}

extension BaichuanSession {
    /// A host command (`ch_id` 250) and its reply's XML.
    func hostRequest(_ command: UInt32, body: String? = nil, timeout: Double = BaichuanSession.requestTimeout) async throws -> String {
        let reply = try await request(command: command, channel: Baichuan.hostChannel, body: body, encryption: .aes, timeout: timeout)
        return try replyText(reply)
    }

    /// The device's kind, from the login reply's `DeviceInfo` and the abilities.
    func batteryKind() async throws -> ReolinkBaichuanKind {
        let reply = try await request(command: 199, channel: Baichuan.hostChannel, body: nil, encryption: .aes)
        let xml = try replyText(reply)
        let root = xml.isEmpty ? nil : try? BXParser.parse(xml)
        let abilities = root.map(BaichuanEvents.abilities) ?? [:]
        let type = deviceInfo?.value("type")?.lowercased() ?? ""
        let netPort = root?.first("netPort").flatMap { Int($0.text.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? abilities[0]?["netPort"] ?? 0
        return ReolinkBaichuanKind(isBatteryCamera: (abilities[0]?["battery"] ?? 0) > 0 && !ReolinkHostInfo.multiChannelTypes.contains(type),
                                   udpOnly: netPort & 0x40 != 0)
    }

    /// `VersionInfo` (`cmd_id` 80) and the UID (`cmd_id` 114).
    func batteryIdentity() async throws -> ReolinkBatteryIdentity {
        let version = try? BXParser.parse(try await hostRequest(80))
        let info = version?.first("VersionInfo")
        let uidXML = try await hostRequest(114)
        guard let uid = (try? BXParser.parse(uidXML))?.first("uid")?.text.trimmingCharacters(in: .whitespacesAndNewlines), !uid.isEmpty else {
            throw ReolinkError.invalidResponse("the camera gave no UID")
        }
        return ReolinkBatteryIdentity(uid: uid, name: info?.value("name") ?? "", model: info?.value("type") ?? "", serial: info?.value("serialNumber") ?? "",
                                      hardware: info?.value("hardwareVersion") ?? "", firmware: info?.value("firmwareVersion") ?? "")
    }

    /// `BatteryInfo` (`cmd_id` 253) of a channel.
    func battery(channel: Int) async throws -> ReolinkBatteryReport? {
        let xml = try await channelRequest(command: 253, channel: channel)
        guard !xml.isEmpty, let root = try? BXParser.parse(xml) else { return nil }
        return ReolinkBatteryReport.reports(root).first?.report
    }

    /// The webhook (`cmd_id` 806): nil when the firmware has none (a status other than 200).
    func webhook() async throws -> (enabled: Bool, url: String)? {
        let xml: String
        do {
            xml = try await hostRequest(806)
        } catch BaichuanError.status {
            return nil
        }
        let root = xml.isEmpty ? nil : try? BXParser.parse(xml)
        return (root?.first("enable")?.text.trimmingCharacters(in: .whitespacesAndNewlines) == "1",
                root?.first("url")?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
    }

    /// Writes the webhook (`cmd_id` 807), then reads it back: true when it says what was written.
    func setWebhook(url: String?) async throws -> Bool {
        _ = try await hostRequest(807, body: Baichuan.webhookBody(url: url))
        guard let current = try await webhook() else { return false }
        return url.map { current.enabled && current.url == $0 } ?? !current.enabled
    }

    /// A JPEG by `cmd_id` 109 (ReolinkBattery.md 7): the reply's `pictureSize`, then binary parts (status 200) up to the
    /// last (201), on any message number. One at a time.
    func snapshot(channel: Int, stream: Baichuan.MediaStream, timeout: Double) async throws -> Data {
        let (parts, continuation) = AsyncStream.makeStream(of: BaichuanBinaryEvent.self)
        guard setCommandSink(109, { continuation.yield($0) }) else { throw ReolinkError.invalidResponse("a snapshot is already in progress") }
        defer {
            removeCommandSink(109)
            continuation.finish()
        }
        let reply = try await request(command: 109, channel: UInt8(clamping: channel + 1), extension: Baichuan.channelExtension(channel),
                                      body: Baichuan.snapBody(channel: channel, stream: stream), encryption: .aes, timeout: timeout)
        let xml = (try? replyText(reply)) ?? ""
        let expected = (try? BXParser.parse(xml))?.first("pictureSize").flatMap { Int($0.text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        var image: [UInt8] = []
        let timer = Task {
            try? await Task.sleep(for: .seconds(timeout))
            continuation.finish()
        }
        defer { timer.cancel() }
        // The parts, the reply's own first when it carries some (`BaichuanSession.received`).
        var finished = false
        for await part in parts {
            guard case .data(let status, let payload) = part else { break }
            image += payload
            if status == 201 {
                finished = true
                break
            }
            if status.map({ $0 != 200 }) ?? false { throw BaichuanError.status(status ?? 0) }
            if image.count > Baichuan.maximumBody { throw BaichuanError.tooLarge(image.count) }
        }
        guard finished else { throw BaichuanError.timeout }
        if let expected, expected != image.count { log.debug("Snapshot: \(image.count) bytes where the camera announced \(expected).") }
        // Accepted when it is a whole JPEG, whatever `pictureSize` said (neolink tolerates a mismatch).
        guard image.starts(with: [0xFF, 0xD8]), image.suffix(2).elementsEqual([0xFF, 0xD9]) else {
            throw ReolinkError.invalidResponse("the snapshot is not a JPEG")
        }
        return Data(image)
    }

    /// Starts a live stream (`cmd_id` 3, ReolinkBattery.md 5.1): the counter it runs on (for `stopMedia`), and the binary
    /// payloads in `sink`.
    func startMedia(channel: Int, stream: Baichuan.MediaStream, timeout: Double, sink: @escaping BinarySink) async throws -> UInt32 {
        let chID = UInt8(clamping: channel + 1)
        let counter = stream.code | (nextCounter() & 0xFFFF) << 8
        setBinarySink(command: 3, channel: chID, counter: counter, sink)
        do {
            // The reply's own binary (the info frame, usually) reaches `sink` first (`BaichuanSession.received`).
            try await request(command: 3, channel: chID, extension: Baichuan.channelExtension(channel),
                              body: Baichuan.previewBody(channel: channel, stream: stream, start: true), encryption: .aes, timeout: timeout, fixedCounter: counter)
        } catch {
            removeBinarySink(command: 3, channel: chID, counter: counter)
            throw error
        }
        return counter
    }

    /// Stops a live stream (`cmd_id` 4, the start's bytes 12 to 15), waiting at most 2 s for its reply.
    func stopMedia(channel: Int, stream: Baichuan.MediaStream, counter: UInt32) async {
        let chID = UInt8(clamping: channel + 1)
        removeBinarySink(command: 3, channel: chID, counter: counter)
        _ = try? await request(command: 4, channel: chID, extension: Baichuan.channelExtension(channel),
                               body: Baichuan.previewBody(channel: channel, stream: stream, start: false), encryption: .aes, timeout: 2, fixedCounter: counter)
    }
}
