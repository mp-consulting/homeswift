import Foundation
import HomeswiftFFmpeg
import HomeswiftNetwork
import HomeswiftPlugin
import NIOConcurrencyHelpers
import Testing

@testable import Homeswift
@testable import HomeswiftReolink

// docs/clean-room/ReolinkTalk.md: section 9's vectors, Talks against the fake Baichuan devices (201, 202, 11), and the
// Speaker a camera, an NVR's channel or a battery camera gets only when its talk ability says it can.

/// The talk ability fixture of 9.4, with its values replaceable.
func talkAbilityXML(duplex: String = "FDX", mode: String = "followVideoStream", type: String = "adpcm", rate: Int = 16000, length: Int = 1024) -> String {
    """
    <?xml version="1.0" encoding="UTF-8" ?>
    <body>
    <TalkAbility version="1.1">
    <duplexList><duplex>\(duplex)</duplex></duplexList>
    <audioStreamModeList><audioStreamMode>\(mode)</audioStreamMode></audioStreamModeList>
    <audioConfigList><audioConfig><priority>0</priority><audioType>\(type)</audioType><sampleRate>\(rate)</sampleRate>
    <samplePrecision>16</samplePrecision><lengthPerEncoder>\(length)</lengthPerEncoder><soundTrack>mono</soundTrack></audioConfig></audioConfigList>
    </TalkAbility>
    </body>
    """
}

@Suite(.timeLimit(.minutes(1))) struct ReolinkTalkTests {
    static let config = ReolinkTalkConfig(duplex: "FDX", audioStreamMode: "followVideoStream", sampleRate: 16000, lengthPerEncoder: 1024)
    static let timing = ReolinkTiming(scale: 0.002)
    /// A 1 kHz tone at 16 kHz, as ReturnAudio.md 8.2.
    static func tone(_ count: Int) -> [Int16] { (0..<count).map { Int16((8000 * sin(2 * Double.pi * 1000 * Double($0) / 16000)).rounded()) } }

    // MARK: Vectors (9)

    @Test func headersFromTheSpec() {
        let ext = Baichuan.channelExtension(0).utf8.count
        let config = Baichuan.talkConfigBody(channel: 0, config: Self.config).utf8.count
        let binary = Baichuan.talkExtension(channel: 0).utf8.count
        #expect([ext, config, binary] == [Int]([104, 394, 131]))
        #expect(hex(Baichuan.header(command: 10, bodyLength: ext, channel: 1, counter: 0x14, extensionLength: ext))
            == "f0 de bc 0a 0a 00 00 00 68 00 00 00 01 14 00 00 00 00 14 64 68 00 00 00")
        #expect(hex(Baichuan.header(command: 201, bodyLength: ext + config, channel: 1, counter: 0x15, extensionLength: ext))
            == "f0 de bc 0a c9 00 00 00 f2 01 00 00 01 15 00 00 00 00 14 64 68 00 00 00")
        #expect(hex(Baichuan.header(command: 202, bodyLength: binary + 528, channel: 1, counter: 0x16, extensionLength: binary))
            == "f0 de bc 0a ca 00 00 00 93 02 00 00 01 16 00 00 00 00 14 64 83 00 00 00")
        #expect(hex(Baichuan.header(command: 202, bodyLength: binary + 4 * 528, channel: 1, counter: 0x16, extensionLength: binary))
            == "f0 de bc 0a ca 00 00 00 c3 08 00 00 01 16 00 00 00 00 14 64 83 00 00 00")
        #expect(hex(Baichuan.header(command: 11, bodyLength: ext, channel: 1, counter: 0x17, extensionLength: ext))
            == "f0 de bc 0a 0b 00 00 00 68 00 00 00 01 17 00 00 00 00 14 64 68 00 00 00")
        // The 422 reply, as the framer reads it.
        var framer = BaichuanFramer()
        let reply = framer.push(bytes("f0 de bc 0a c9 00 00 00 00 00 00 00 01 15 00 00 a6 01 14 64 00 00 00 00"))
        guard case .success(let message)? = reply.first else {
            Issue.record("no message")
            return
        }
        #expect(message.command == 201 && message.status == 422 && message.messageID == BaichuanMessage.messageID(channel: 1, counter: 0x15))
    }

    @Test func mediaFramesFromTheSpec() {
        var encoder = IMAADPCMEncoder()
        let block = encoder.encodeBlock(Self.tone(2050)[0..<1025])
        let frame = Baichuan.adpcmFrame(block)
        #expect(frame.count == 528)
        #expect(hex(Array(frame.prefix(22))) == "30 31 77 62 08 02 08 02 00 01 00 01 00 00 00 00 77 77 77 e7 bc 99")
        #expect(Array(frame.dropFirst(12)) == block)
        let small = Baichuan.adpcmFrame([UInt8](repeating: 0, count: 260))
        #expect(small.count == 272 && hex(Array(small.prefix(12))) == "30 31 77 62 08 01 08 01 00 01 80 00")
        let padded = Baichuan.adpcmFrame([UInt8](repeating: 1, count: 258))
        #expect(padded.count == 272 && hex(Array(padded.prefix(12))) == "30 31 77 62 06 01 06 01 00 01 7f 00")
        #expect(padded.suffix(2) == [0, 0])
    }

    @Test func theTalkAbilityFixture() {
        #expect(ReolinkTalkAbility.parse(talkAbilityXML()) == .supported(Self.config))
        #expect(Self.config.blockBytes == 516 && Self.config.samplesPerBlock == 1025)
        #expect(ReolinkTalkAbility.parse(talkAbilityXML(duplex: "HDX")).config == nil)
        #expect(ReolinkTalkAbility.parse(talkAbilityXML(type: "aac")).config == nil)
        #expect(ReolinkTalkAbility.parse(talkAbilityXML(duplex: "HDX", mode: "mixAudioStream", rate: 8000, length: 512))
            == .supported(ReolinkTalkConfig(duplex: "HDX", audioStreamMode: "mixAudioStream", sampleRate: 8000, lengthPerEncoder: 512)))
        #expect(ReolinkTalkAbility.parse(talkAbilityXML(rate: 44100)).config == nil)
        #expect(ReolinkTalkAbility.parse(talkAbilityXML(length: 1023)).config == nil)
        #expect(ReolinkTalkAbility.parse("").config == nil)
        // The abilities that allow asking (2.1).
        #expect(ReolinkTalkAbility.permitted(httpTalk: 1, baichuan: [:], channel: 0, multiChannel: true))
        #expect(ReolinkTalkAbility.permitted(httpTalk: 0, baichuan: [2: ["ipcAudioTalk": 1]], channel: 2, multiChannel: true))
        #expect(!ReolinkTalkAbility.permitted(httpTalk: 0, baichuan: [0: ["audioTalk": 1]], channel: 1, multiChannel: true))
        #expect(ReolinkTalkAbility.permitted(httpTalk: 0, baichuan: [0: ["audioTalk": 1]], channel: 0, multiChannel: false))
        #expect(!ReolinkTalkAbility.permitted(httpTalk: 0, baichuan: [:], channel: 0, multiChannel: false))
    }

    // MARK: Talks (5)

    /// A Talk of `samples` in 20 ms frames, all already there.
    static func talk(_ samples: [Int16], volume: Int = 100) -> Talk {
        let (frames, input) = AsyncStream.makeStream(of: PCMFrame.self)
        for start in stride(from: 0, to: samples.count, by: 320) {
            input.yield(PCMFrame(samples: Array(samples[start..<min(samples.count, start + 320)]), offset: start))
        }
        input.finish()
        return Talk(sessionID: "session", format: ReturnAudioFormat(sampleRate: 16000), frames: frames, volume: volume)
    }

    /// A Talk of `samples` fed as the talker takes them, as live audio comes: a block's samples once it has taken the
    /// blocks before it but two, so none waits beyond the queue. It stops when the Talk does.
    static func paced(_ samples: [Int16], to talker: ReolinkTalker) async -> Talk {
        let (frames, input) = AsyncStream.makeStream(of: PCMFrame.self)
        let base = await talker.blocksTaken
        Task {
            for (block, start) in stride(from: 0, to: samples.count, by: 1025).enumerated() {
                _ = await eventually { await talker.blocksTaken - base >= block - 2 }
                let end = min(samples.count, start + 1025)
                for frame in stride(from: start, to: end, by: 320) {
                    if case .terminated = input.yield(PCMFrame(samples: Array(samples[frame..<min(end, frame + 320)]), offset: frame)) { return }
                }
            }
            input.finish()
        }
        return Talk(sessionID: "session", format: ReturnAudioFormat(sampleRate: 16000), frames: frames, volume: 100)
    }

    static func session(_ camera: FakeBaichuanCamera) async throws -> BaichuanSession {
        let session = BaichuanSession(host: "192.168.1.20", port: 9000, username: "admin", password: "secret", connect: { _, _, _ in camera }, log: testLogger,
                                      timing: timing)
        try await session.openOnce()
        return session
    }

    static func talker(_ session: BaichuanSession, channel: Int = 0, retriesWaking: Bool = false) -> ReolinkTalker {
        ReolinkTalker(channel: channel, config: config, link: ReolinkTalkLink(withSession: { body in try await body(session) }, retriesWaking: retriesWaking),
                      name: "Driveway", log: testLogger, timing: timing)
    }

    /// The frames the camera should get for `samples`: blocks of 1025 samples, the last padded with zeros.
    static func expectedFrames(_ samples: [Int16]) -> [[UInt8]] {
        var padded = samples
        padded += [Int16](repeating: 0, count: (1025 - samples.count % 1025) % 1025)
        var encoder = IMAADPCMEncoder()
        return stride(from: 0, to: padded.count, by: 1025).map { Baichuan.adpcmFrame(encoder.encodeBlock(padded[$0..<($0 + 1025)])) }
    }

    @Test func aSecondOfTalkIsSixteenMessagesOnOneNumber() async throws {
        let camera = FakeBaichuanCamera()
        let session = try await Self.session(camera)
        let talker = Self.talker(session)
        let samples = Self.tone(16000)
        await talker.handle(await Self.paced(samples, to: talker))
        #expect(camera.talkCommands == [201] + [UInt32](repeating: 202, count: 16) + [11])
        #expect(camera.bodies(201) == [Baichuan.talkConfigBody(channel: 0, config: Self.config)])
        let audio = camera.raw(202)
        #expect(audio.map(\.payload) == Self.expectedFrames(samples))
        // One message number for the Talk (3.3), `ch_id` channel + 1, the extension's length in bytes 20 to 23.
        #expect(Set(audio.map { Array($0.header[12..<16]) }).count == 1)
        #expect(audio.allSatisfy { $0.header[12] == 1 && Baichuan.readUInt32($0.header, 20) == 131 && Baichuan.readUInt32($0.header, 8) == 659 })
        let start = try #require(camera.raw(201).first), stop = try #require(camera.raw(11).first)
        #expect(Array(start.header[12..<16]) != Array(audio[0].header[12..<16]) && Array(stop.header[12..<16]) != Array(audio[0].header[12..<16]))
        let ext = camera.state.withLockedValue { $0.received.first { $0.command == 202 }?.ext }
        #expect(ext == Baichuan.talkExtension(channel: 0))
        #expect(await talker.isTalking == false)
        await session.stop()
    }

    @Test func theVolumeScalesTheSamples() async throws {
        let camera = FakeBaichuanCamera()
        let session = try await Self.session(camera)
        let samples = Self.tone(1025)
        await Self.talker(session).handle(Self.talk(samples, volume: 50))
        #expect(camera.raw(202).map(\.payload) == Self.expectedFrames(PCMVolume.scale(samples, volume: 50)))
        await session.stop()
    }

    @Test func anOpenTalkIsStoppedFirst() async throws {
        let camera = FakeBaichuanCamera()
        camera.state.withLockedValue { $0.statuses[201] = [422] }
        let session = try await Self.session(camera)
        await Self.talker(session).handle(Self.talk(Self.tone(1025)))
        #expect(camera.talkCommands == [201, 11, 201, 202, 11])
        await session.stop()
    }

    @Test func aRefusedFormatIsAskedWithTheBareChannelOnce() async throws {
        // Refused twice: no audio, the `ch_id` back to channel + 1.
        let camera = FakeBaichuanCamera()
        camera.state.withLockedValue { $0.statuses[201] = [400, 400] }
        let session = try await Self.session(camera)
        let talker = Self.talker(session, channel: 1)
        await talker.handle(Self.talk(Self.tone(1025)))
        #expect(camera.talkCommands == [201, 201])
        #expect(camera.raw(201).map { $0.header[12] } == [2, 1])
        // Taken with the bare channel: the Talk's other messages and the next Talks use it.
        camera.state.withLockedValue { $0.statuses[201] = [400] }
        await talker.handle(Self.talk(Self.tone(1025)))
        #expect(camera.raw(201).map { $0.header[12] } == [2, 1, 2, 1])
        #expect(camera.raw(202).map { $0.header[12] } == [1] && camera.raw(11).map { $0.header[12] } == [1])
        #expect(camera.bodies(201).allSatisfy { $0.contains("<channelId>1</channelId>") })
        await talker.handle(Self.talk(Self.tone(1025)))
        #expect(camera.raw(201).map { $0.header[12] } == [2, 1, 2, 1, 1])
        await session.stop()
    }

    @Test func aWakingHubChannelIsAskedAgain() async throws {
        let camera = FakeBaichuanCamera()
        camera.state.withLockedValue { $0.statuses[201] = [400, 400] }
        let session = try await Self.session(camera)
        await Self.talker(session, retriesWaking: true).handle(Self.talk(Self.tone(1025)))
        #expect(camera.talkCommands == [201, 201, 201, 202, 11])
        #expect(camera.raw(201).allSatisfy { $0.header[12] == 1 })
        await session.stop()
    }

    @Test func refusedAudioEndsTheTalkAndTheNextGroupsFourFrames() async throws {
        let camera = FakeBaichuanCamera()
        camera.state.withLockedValue { $0.statuses[202] = [200, 400] }
        let session = try await Self.session(camera)
        let talker = Self.talker(session)
        await talker.handle(await Self.paced(Self.tone(16000), to: talker))
        #expect(camera.talkCommands == [201, 202, 202, 11])
        await talker.handle(await Self.paced(Self.tone(16000), to: talker))
        // 16 blocks in messages of 4 frames: 2112 bytes of binary each (9.2).
        let grouped = camera.raw(202).dropFirst(2)
        #expect(grouped.count == 4 && grouped.allSatisfy { $0.payload.count == 2112 && Baichuan.readUInt32($0.header, 8) == 2243 })
        await session.stop()
    }

    @Test func audioWithoutAnAnswerEndsTheTalk() async throws {
        let camera = FakeBaichuanCamera()
        camera.state.withLockedValue { $0.silent = [202] }
        let session = try await Self.session(camera)
        await Self.talker(session).handle(Self.talk(Self.tone(16000)))
        #expect(camera.talkCommands == [201, 202, 11])
        await session.stop()
    }

    @Test func aDroppedSessionEndsTheTalkWithoutAStop() async throws {
        let camera = FakeBaichuanCamera()
        let session = try await Self.session(camera)
        let talker = Self.talker(session)
        let (frames, input) = AsyncStream.makeStream(of: PCMFrame.self)
        let running = Task { await talker.handle(Talk(sessionID: "s", format: ReturnAudioFormat(sampleRate: 16000), frames: frames, volume: 100)) }
        input.yield(PCMFrame(samples: Self.tone(1100), offset: 0))
        #expect(await eventually { camera.raw(202).count == 1 })
        #expect(await talker.isTalking)
        camera.drop()
        #expect(await eventually { await !session.isOpen })
        input.yield(PCMFrame(samples: Self.tone(1100), offset: 1100))
        input.finish()
        await running.value
        #expect(camera.raw(11).isEmpty)
    }

    @Test func talksTakeTurns() async throws {
        let camera = FakeBaichuanCamera()
        let session = try await Self.session(camera)
        let talker = Self.talker(session)
        let (frames, input) = AsyncStream.makeStream(of: PCMFrame.self)
        let first = Task { await talker.handle(Talk(sessionID: "s", format: ReturnAudioFormat(sampleRate: 16000), frames: frames, volume: 100)) }
        #expect(await eventually { camera.raw(201).count == 1 })
        let second = Task { await talker.handle(Self.talk(Self.tone(1025))) }
        // The second waits for the first's stop.
        #expect(await eventually { await talker.talks == 1 })
        #expect(camera.raw(201).count == 1)
        input.yield(PCMFrame(samples: Self.tone(500), offset: 0))
        input.finish()
        await first.value
        await second.value
        #expect(camera.talkCommands == [201, 202, 11, 201, 202, 11])
        // A siren waits for a Talk to end.
        #expect(await talker.waitUntilIdle(timeout: .seconds(1)))
        await session.stop()
    }

    // MARK: The plugin

    static func environment(_ answers: [String: @Sendable (JSONValue?) -> JSONValue], abilities: String? = nil, talk: String? = talkAbilityXML()) -> ReolinkEnvironment {
        let environment = ReolinkEnvironment(answers)
        environment.prepareCamera.withLockedValue {
            $0 = { camera in
                if let abilities { camera.answer(199) { _, _ in abilities } }
                if let talk { camera.answer(10) { _, _ in talk } }
            }
        }
        return environment
    }

    static func hasSpeaker(_ accessory: Accessory) -> Bool { accessory.services.contains { $0.type.uuid == ServiceType.speaker.uuid } }

    @Test func aCameraTalksWhenAskedAndAble() async throws {
        let environment = Self.environment(answers(adding: ["talk": 1]))
        let host = try await environment.start(["devices": [["host": "192.168.1.20", "password": "secret", "cameras": ["0": ["twoWayAudio": true]]]]])
        defer { Task { await host.stop() } }
        #expect(await eventually { await environment.plugin?.camera(host: "192.168.1.20", channel: 0) != nil })
        let accessory = try #require(environment.accessory(host, ReolinkPluginTests.cameraID))
        #expect(Self.hasSpeaker(accessory))
        let camera = try #require(await environment.plugin?.camera(host: "192.168.1.20", channel: 0))
        let talker = try #require(camera.talker)
        let device = try #require(environment.camera)
        #expect(device.talkCommands == [10])
        await talker.handle(Self.talk(Self.tone(2050)))
        #expect(device.talkCommands == [10, 201, 202, 202, 11])
    }

    @Test func offByDefaultAndOnlyWhereTheAbilitySaysSo() async throws {
        // Off: never asked, no Speaker.
        let off = Self.environment(answers(adding: ["talk": 1]))
        let first = try await off.start()
        #expect(await eventually { off.accessory(first, ReolinkPluginTests.cameraID) != nil })
        #expect(!Self.hasSpeaker(try #require(off.accessory(first, ReolinkPluginTests.cameraID))))
        #expect(off.camera?.talkCommands == [])
        await first.stop()
        // On, but half duplex: asked, no Speaker.
        let half = Self.environment(answers(adding: ["talk": 1]), talk: talkAbilityXML(duplex: "HDX"))
        let second = try await half.start(["devices": [["host": "192.168.1.20", "password": "secret", "cameras": ["0": ["twoWayAudio": true]]]]])
        #expect(await eventually { half.accessory(second, ReolinkPluginTests.cameraID) != nil })
        #expect(!Self.hasSpeaker(try #require(half.accessory(second, ReolinkPluginTests.cameraID))))
        #expect(half.camera?.talkCommands == [10])
        await second.stop()
        // On, without a talk ability: not asked.
        let none = Self.environment(cameraAnswers())
        let third = try await none.start(["devices": [["host": "192.168.1.20", "password": "secret", "cameras": ["0": ["twoWayAudio": true]]]]])
        defer { Task { await third.stop() } }
        #expect(await eventually { none.accessory(third, ReolinkPluginTests.cameraID) != nil })
        #expect(!Self.hasSpeaker(try #require(none.accessory(third, ReolinkPluginTests.cameraID))))
        #expect(none.camera?.talkCommands == [])
    }

    @Test func anNVRChannelTalksByItsOwnAbility() async throws {
        let abilities = """
            <?xml version="1.0" encoding="UTF-8" ?>
            <body>
            <AbilityInfo version="1.1">
            <system>
            <item><chnID>0</chnID><ptzType>0</ptzType></item>
            <item><chnID>1</chnID><ipcAudioTalk>1</ipcAudioTalk></item>
            </system>
            </AbilityInfo>
            </body>
            """
        let environment = Self.environment(ReolinkPluginTests.nvrAnswers(online: [0, 1]), abilities: abilities)
        let host = try await environment.start(["devices": [["host": "192.168.1.20", "password": "secret",
                                                              "cameras": ["0": ["twoWayAudio": true], "1": ["twoWayAudio": true]]]]])
        defer { Task { await host.stop() } }
        let gate = "Reolink:95270000ABCDEFGH:95270000AAAAAAAA", yard = "Reolink:95270000ABCDEFGH:95270000BBBBBBBB"
        #expect(await eventually { await environment.plugin?.camera(host: "192.168.1.20", channel: 1) != nil })
        #expect(!Self.hasSpeaker(try #require(environment.accessory(host, gate))))
        #expect(Self.hasSpeaker(try #require(environment.accessory(host, yard))))
        let device = try #require(environment.camera)
        // Asked on the yard's channel only: `ch_id` 2, channel 1 in the extension.
        #expect(device.raw(10).map { $0.header[12] } == [2])
        let talker = try #require(await environment.plugin?.camera(host: "192.168.1.20", channel: 1)?.talker)
        await talker.handle(Self.talk(Self.tone(1025)))
        #expect(device.bodies(201).first?.contains("<channelId>1</channelId>") == true)
        #expect(device.raw(202).map { $0.header[12] } == [2])
    }

    @Test func aBatteryCameraTalksAndStaysAwakeOnlyWhileItDoes() async throws {
        let environment = ReolinkEnvironment(scale: 0.01)
        let device = FakeBatteryCamera()
        device.state.withLockedValue { $0.talks = true }
        environment.batteryCamera.withLockedValue { $0 = device }
        let host = try await environment.start(["devices": [["host": "192.168.1.50", "password": "secret", "batteryCamera": true,
                                                              "cameras": ["0": ["twoWayAudio": true]]]]])
        defer { Task { await host.stop() } }
        #expect(await eventually { environment.accessory(host, ReolinkBatteryTests.accessoryID) != nil })
        #expect(Self.hasSpeaker(try #require(environment.accessory(host, ReolinkBatteryTests.accessoryID))))
        // Asked once, kept: a new start does not wake the camera for it.
        let plugin = try #require(environment.plugin)
        let records = await plugin.batteryRecords
        #expect(records[FakeBatteryCamera.uid]?.talk == Self.config)
        #expect(device.count(10) == 1)
        let runtime = try #require(await plugin.batteryRuntimes["192.168.1.50"])
        // The camera sleeps again once idle.
        #expect(await eventually { await runtime.host.isAwake == false })
        let talker = try #require(runtime.camera.talker)
        let (frames, input) = AsyncStream.makeStream(of: PCMFrame.self)
        let talk = Task { await talker.handle(Talk(sessionID: "s", format: ReturnAudioFormat(sampleRate: 16000), frames: frames, volume: 100)) }
        input.yield(PCMFrame(samples: Self.tone(1025), offset: 0))
        #expect(await eventually { device.count(202) == 1 })
        // Longer than the idle close: still awake while the Talk runs.
        try await Task.sleep(for: ReolinkTiming(scale: 0.01).seconds(ReolinkBatteryHost.idleClose) * 3)
        #expect(await runtime.host.isAwake)
        input.finish()
        await talk.value
        #expect(device.count(11) == 1)
        #expect(await eventually { await runtime.host.isAwake == false })
        await host.stop()

        let again = try await environment.start(["devices": [["host": "192.168.1.50", "password": "secret", "batteryCamera": true,
                                                               "cameras": ["0": ["twoWayAudio": true]]]]])
        defer { Task { await again.stop() } }
        #expect(await eventually { environment.accessory(again, ReolinkBatteryTests.accessoryID) != nil })
        #expect(Self.hasSpeaker(try #require(environment.accessory(again, ReolinkBatteryTests.accessoryID))))
        #expect(device.count(10) == 1)
    }
}
