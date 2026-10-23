import Crypto
import Foundation
import NIOCore
import NIOPosix
import Testing

@testable import Homeswift

/// A HomeKit Data Stream client: the controller's side of the socket.
final class HDSTestClient: @unchecked Sendable {
    private var channel: (any Channel)!
    private var iterator: AsyncStream<ByteBuffer>.AsyncIterator!
    private var buffer = Data()
    private var pending: [HDSFrame.Sealed] = []
    private let writeKey: SymmetricKey
    private let readKey: SymmetricKey
    private var writeCounter: UInt64 = 0
    private var readCounter: UInt64 = 0

    init(controllerToAccessory: SymmetricKey, accessoryToController: SymmetricKey) {
        writeKey = controllerToAccessory
        readKey = accessoryToController
    }

    func connect(port: Int) async throws {
        let (stream, continuation) = AsyncStream.makeStream(of: ByteBuffer.self)
        channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(TestController.Inbound(continuation)) }
            }
            .connect(host: "127.0.0.1", port: port).get()
        iterator = stream.makeAsyncIterator()
    }

    func send(header: HDSDictionary, message: HDSDictionary = [:]) async throws {
        try await send(payload: HDSFrame.payload(header: header, message: message))
    }

    /// Any payload, valid or not.
    func send(payload: Data) async throws {
        let frame = try HDSFrame.seal(payload: payload, key: writeKey, counter: writeCounter)
        writeCounter += 1
        try await channel.writeAndFlush(ByteBuffer(bytes: frame))
    }

    func next() async throws -> HDSFrame.Message {
        while true {
            pending += try HDSFrame.split(&buffer)
            if !pending.isEmpty {
                let frame = pending.removeFirst()
                let plaintext = try HDSFrame.open(frame, key: readKey, counter: readCounter)
                readCounter += 1
                if let message = HDSFrame.message(from: plaintext) { return message }
                continue
            }
            guard let bytes = await iterator.next() else { throw ChannelError.eof }
            buffer.append(contentsOf: bytes.readableBytesView)
        }
    }

    func close() async { try? await channel.close() }
}

@Suite(.timeLimit(.minutes(1)))
struct CameraServerTests {
    let streaming = FakeStreamingDelegate()
    let recording = FakeRecordingDelegate()
    let camera: CameraController
    let accessory: Accessory
    let motion = Service(.motionSensor)
    let server: HAPServer

    init() throws {
        camera = try DoorbellController(CameraControllerOptions(
            cameraStreamCount: 2, delegate: streaming,
            streamingOptions: CameraStreamingOptions(video: CameraTLVTests.video, audio: CameraTLVTests.audio),
            recording: CameraRecordingSetup(options: CameraTLVTests.recordingOptions, delegate: recording),
            sensors: CameraSensorOptions(motion: .service(motion))), name: "Front Door")
        accessory = Accessory(id: "camera-1", name: "Front Door", category: .videoDoorbell, services: [motion])
        accessory.configureController(camera)
        server = try HAPServer(
            accessory: accessory, storage: MemoryStorage(),
            options: .init(setupCode: SetupCode("031-45-154"), port: 0, advertise: false, logger: testLogger))
    }

    private func pairedController() async throws -> TestController {
        try await server.start()
        let controller = TestController()
        try await controller.connect(port: server.port!)
        try await controller.pairSetup(code: "031-45-154")
        try await controller.pairVerify()
        return controller
    }

    private func iid(_ service: ServiceType, _ type: CharacteristicType, subtype: String? = nil) throws -> Int {
        try #require(accessory.service(service, subtype: subtype)?[type]).iid
    }

    private func write(_ controller: TestController, _ iid: Int, _ value: Any, response: Bool = false) async throws -> TestController.Message {
        var item: [String: Any] = ["aid": 1, "iid": iid, "value": value]
        if response { item["r"] = true }
        return try await controller.json("PUT", "/characteristics", ["characteristics": [item]])
    }

    private func read(_ controller: TestController, _ iid: Int) async throws -> Any? {
        let response = try await controller.request("GET", "/characteristics?id=1.\(iid)")
        return ((response.json as? [String: Any])?["characteristics"] as? [[String: Any]])?.first?["value"]
    }

    @Test func publishesTheCameraServices() async throws {
        let controller = try await pairedController()
        let response = try await controller.request("GET", "/accessories")
        let services = try #require(((response.json as? [String: Any])?["accessories"] as? [[String: Any]])?.first?["services"] as? [[String: Any]])
        let types = services.compactMap { $0["type"] as? String }
        // Information, the motion sensor, the doorbell, two streams, microphone, speaker, recording, operating mode, data stream, protocol.
        for type in ["3E", "85", "121", "110", "112", "113", "204", "21A", "129", "A2"] { #expect(types.contains(type), "missing service \(type)") }
        #expect(types.filter { $0 == "110" }.count == 2)
        let doorbell = try #require(services.first { $0["type"] as? String == "121" })
        #expect(doorbell["primary"] as? Bool == true)
        let recordingService = try #require(services.first { $0["type"] as? String == "204" })
        #expect((recordingService["linked"] as? [Int])?.count == 2)
        await controller.close()
        await server.stop()
    }

    @Test func streamsAndSnapshotsOverHAP() async throws {
        let controller = try await pairedController()
        let setup = try iid(.cameraRTPStreamManagement, .setupEndpoints, subtype: "0")
        let selected = try iid(.cameraRTPStreamManagement, .selectedRTPStreamConfiguration, subtype: "0")
        let status = try iid(.cameraRTPStreamManagement, .streamingStatus, subtype: "0")

        #expect(try await write(controller, setup, "ARCKPHsuH01OapsMLV6PGjt8AxkBAQACDDE5Mi4xNjguMS4yMAMCOMcEAjrHBCUBAQACEKGhoaGhoaGhoaGhoaGhoaEDDqKioqKioqKioqKioqKiBSUBAQACELGxsbGxsbGxsbGxsbGxsbEDDrKysrKysrKysrKysrKy").status == 204)
        let prepare = try #require(streaming.prepares.withLockedValue { $0.first })
        #expect(prepare.sourceAddress == "127.0.0.1")
        let answer = try #require(try await read(controller, setup) as? String)
        let tlv = try HAPTLV.decode(try #require(Data(base64Encoded: answer)))
        #expect(tlv[2] == Data([0]))
        let address = try HAPTLV.decode(try #require(tlv[3]))
        #expect(address[2] == Data("127.0.0.1".utf8))
        #expect(address[3] == HAPTLV.uint16(50000))
        #expect(try await read(controller, status) as? String == "AQEB")

        #expect(try await write(controller, selected, "ARUBEIo8ey4fTU5qmwwtXo8aO3wCAQECNAEBAAIJAQEBAgECAwEAAwsBAgAFAgLQAgMBHgQXAQFjAgQEAwIBAwIrAQQEAAAAPwUCYgUDLAEBAgIMAQEBAgEAAwEBBAEeAxYBAW4CBA0MCwoDAhgABAQAAKBABgENBAEA").status == 204)
        guard case .start(let start)? = streaming.requests.withLockedValue({ $0.last }) else {
            Issue.record("no start request")
            return
        }
        #expect(start.video.width == 1280)

        let snapshot = try await controller.json("POST", "/resource", ["resource-type": "image", "image-width": 640, "image-height": 360, "reason": 1])
        #expect(snapshot.status == 200)
        #expect(snapshot.body == streaming.image)
        #expect(streaming.snapshots.withLockedValue { $0 } == [SnapshotRequest(height: 360, width: 640, reason: .event)])

        // Event snapshots off: an event snapshot is refused.
        _ = try await write(controller, try iid(.cameraOperatingMode, .eventSnapshotsActive), 0)
        let refused = try await controller.json("POST", "/resource", ["resource-type": "image", "image-width": 640, "image-height": 360, "reason": 1])
        #expect(refused.status == 207)
        #expect((refused.json as? [String: Any])?["status"] as? Int == HAPStatus.notAllowedInCurrentState.rawValue)

        // The stream ends with the connection.
        await controller.close()
        try await Task.sleep(for: .milliseconds(200))
        #expect(streaming.requests.withLockedValue { $0.last } == .stop(sessionID: CameraTLVTests.session))
        await server.stop()
    }

    @Test func ringsTheDoorbell() async throws {
        let controller = try await pairedController()
        let event = try iid(.doorbell, .programmableSwitchEvent)
        let subscribe = try await controller.json("PUT", "/characteristics", ["characteristics": [["aid": 1, "iid": event, "ev": true]]])
        #expect(subscribe.status == 204)
        (camera as? DoorbellController)?.ringDoorbell()
        let message = try await controller.nextMessage()
        #expect(message.startLine.hasPrefix("EVENT/1.0 200"))
        let value = ((message.json as? [String: Any])?["characteristics"] as? [[String: Any]])?.first?["value"] as? Int
        #expect(value == 0)
        #expect(try await read(controller, event) is NSNull)
        await controller.close()
        await server.stop()
    }

    @Test func servesARecordingOverHomeKitDataStream() async throws {
        let initialization = Data(repeating: 0x01, count: 100)
        let fragment = Data(repeating: 0x02, count: 0x40000 + 10)
        recording.packets = [RecordingPacket(data: initialization), RecordingPacket(data: fragment, isLast: true)]
        let controller = try await pairedController()
        let selected = "AR0BBKAPAAACCAMAAAAAAAAAAwsBAQACBgEEoA8AAAIkAQEAAhIBAQECAQIDBNAHAAAEBKAPAAADCwECgAcCAjgEAwEeAxQBAQACDwEBAQIBAAMBAQQEQAAAAA=="
        #expect(try await write(controller, try iid(.cameraRecordingManagement, .selectedCameraRecordingConfiguration), selected).status == 204)
        #expect(try await write(controller, try iid(.cameraRecordingManagement, .active), 1).status == 204)
        #expect(recording.active.withLockedValue { $0 } == [true])
        #expect(camera.isRecordingActive)

        var salt = Data(count: 32)
        for index in salt.indices { salt[index] = UInt8(index) }
        let setup = HAPTLV.encode((1, .byte(0)), (2, .byte(0)), (3, .data(salt)))
        let response = try await write(controller, try iid(.dataStreamTransportManagement, .setupDataStreamTransport), setup.base64EncodedString(), response: true)
        #expect(response.status == 207)
        let value = try #require(((response.json as? [String: Any])?["characteristics"] as? [[String: Any]])?.first?["value"] as? String)
        let answer = try HAPTLV.decode(try #require(Data(base64Encoded: value)))
        #expect(answer[1] == Data([0]))
        let port = Int(HAPTLV.readUInt(try HAPTLV.decode(try #require(answer[2]))[1] ?? Data()))
        let accessorySalt = try #require(answer[3])
        #expect(accessorySalt.count == 32)
        // A read returns the response without the salt.
        #expect(try await read(controller, try iid(.dataStreamTransportManagement, .setupDataStreamTransport)) as? String
            == HAPTLV.encode((1, .byte(0)), (2, .data(HAPTLV.encode((1, .data(HAPTLV.uint16(UInt16(port)))))))).base64EncodedString())

        let keys = HDSFrame.keys(sharedSecret: try #require(controller.sharedSecret), controllerKeySalt: salt, accessoryKeySalt: accessorySalt)
        let hds = HDSTestClient(controllerToAccessory: keys.controllerToAccessory, accessoryToController: keys.accessoryToController)
        try await hds.connect(port: port)
        try await hds.send(header: ["protocol": "control", "request": "hello", "id": .int64(1)])
        #expect(try await hds.next() == HDSFrame.Message(kind: .response(id: 1, status: 0), protocol: "control", topic: "hello", message: [:]))

        try await hds.send(
            header: ["protocol": "dataSend", "request": "open", "id": .int64(7)],
            message: ["target": "controller", "type": "ipcamera.recording", "streamId": .int(3), "reason": "motion"])
        #expect(try await hds.next() == HDSFrame.Message(kind: .response(id: 7, status: 0), protocol: "dataSend", topic: "open", message: ["status": .int(0)]))

        var chunks: [HDSDictionary] = []
        while chunks.count < 3 {
            let message = try await hds.next()
            #expect(message.kind == .event)
            #expect(message.topic == "data")
            chunks.append(message.message)
        }
        func metadata(_ chunk: HDSDictionary) -> HDSDictionary? {
            guard case .array(let packets)? = chunk["packets"], case .dictionary(let packet)? = packets.first else { return nil }
            return packet["metadata"]?.dictionaryValue
        }
        func data(_ chunk: HDSDictionary) -> Data? {
            guard case .array(let packets)? = chunk["packets"], case .dictionary(let packet)? = packets.first, case .data(let data)? = packet["data"] else { return nil }
            return data
        }
        #expect(metadata(chunks[0])?["dataType"] == "mediaInitialization")
        #expect(data(chunks[0]) == initialization)
        #expect(chunks[0]["endOfStream"] == .bool(false))
        #expect(metadata(chunks[1])?["dataType"] == "mediaFragment")
        #expect(metadata(chunks[1])?["dataSequenceNumber"] == .int(2))
        #expect(metadata(chunks[1])?["dataTotalSize"] == .int(Int64(fragment.count)))
        #expect(metadata(chunks[1])?["isLastDataChunk"] == .bool(false))
        #expect(chunks[1]["endOfStream"] == nil)
        #expect(metadata(chunks[2])?["dataChunkSequenceNumber"] == .int(2))
        #expect(metadata(chunks[2])?["isLastDataChunk"] == .bool(true))
        #expect(chunks[2]["endOfStream"] == .bool(true))
        #expect((data(chunks[1]) ?? Data()) + (data(chunks[2]) ?? Data()) == fragment)

        try await hds.send(header: ["protocol": "dataSend", "event": "ack"], message: ["streamId": .int(3), "endOfStream": .bool(true)])
        for _ in 0..<50 where recording.acknowledged.withLockedValue({ $0.isEmpty }) { try await Task.sleep(for: .milliseconds(20)) }
        #expect(recording.acknowledged.withLockedValue { $0 } == [3])

        // A second open while recording is turned off is refused with "not allowed".
        _ = try await write(controller, try iid(.cameraRecordingManagement, .active), 0)
        try await hds.send(header: ["protocol": "dataSend", "request": "open", "id": .int64(8)], message: ["target": "controller", "type": "ipcamera.recording", "streamId": .int(4)])
        #expect(try await hds.next() == HDSFrame.Message(kind: .response(id: 8, status: 6), protocol: "dataSend", topic: "open", message: ["status": .int(1)]))

        // The data stream ends with the HAP connection.
        await controller.close()
        await #expect(throws: (any Error).self) { _ = try await hds.next() }
        await server.stop()
    }

    /// A second controller, paired through the first without admin permissions, as the Home app pairs other users.
    private func userController(through admin: TestController) async throws -> TestController {
        let user = TestController(identifier: "user", signingKey: .init())
        var add = TLV8()
        add.append(.state, 1)
        add.append(.method, 3)
        add.append(.identifier, Data(user.identifier.utf8))
        add.append(.publicKey, user.signingKey.publicKey.rawRepresentation)
        add.append(.permissions, 0)
        #expect(try await admin.tlv("/pairings", add).byte(.error) == nil)
        user.accessoryLTPK = admin.accessoryLTPK
        try await user.connect(port: server.port!)
        try await user.pairVerify()
        return user
    }

    private func status(_ message: TestController.Message) -> Int? {
        ((message.json as? [String: Any])?["characteristics"] as? [[String: Any]])?.first?["status"] as? Int
    }

    /// The HAP connection of the server's side for the controller's (the only one open).
    private func serverConnection() throws -> HAPConnection {
        try #require(server.state.withLockedValue { Array($0.connections.values) }.first)
    }

    private func setupDataStream(_ controller: TestController) async throws -> HDSTestClient {
        var salt = Data(count: 32)
        for index in salt.indices { salt[index] = UInt8(index) }
        let setup = HAPTLV.encode((1, .byte(0)), (2, .byte(0)), (3, .data(salt)))
        let response = try await write(controller, try iid(.dataStreamTransportManagement, .setupDataStreamTransport), setup.base64EncodedString(), response: true)
        let value = try #require(((response.json as? [String: Any])?["characteristics"] as? [[String: Any]])?.first?["value"] as? String)
        let answer = try HAPTLV.decode(try #require(Data(base64Encoded: value)))
        let port = Int(HAPTLV.readUInt(try HAPTLV.decode(try #require(answer[2]))[1] ?? Data()))
        let keys = HDSFrame.keys(sharedSecret: try #require(controller.sharedSecret), controllerKeySalt: salt, accessoryKeySalt: try #require(answer[3]))
        let hds = HDSTestClient(controllerToAccessory: keys.controllerToAccessory, accessoryToController: keys.accessoryToController)
        try await hds.connect(port: port)
        try await hds.send(header: ["protocol": "control", "request": "hello", "id": .int64(1)])
        #expect(try await hds.next().kind == .response(id: 1, status: 0))
        return hds
    }

    @Test func refusesAdminOnlyWritesFromOtherUsers() async throws {
        let admin = try await pairedController()
        let user = try await userController(through: admin)
        let selected = "AR0BBKAPAAACCAMAAAAAAAAAAwsBAQACBgEEoA8AAAIkAQEAAhIBAQECAQIDBNAHAAAEBKAPAAADCwECgAcCAjgEAwEeAxQBAQACDwEBAQIBAAMBAQQEQAAAAA=="
        // HAP-NodeJS's `adminOnlyAccess: [Access.WRITE]` characteristics of a camera.
        let writes: [(ServiceType, CharacteristicType, String?, Any)] = [
            (.cameraRTPStreamManagement, .active, "0", 0),
            (.cameraRTPStreamManagement, .active, "1", 0),
            (.cameraRecordingManagement, .active, nil, 1),
            (.cameraRecordingManagement, .selectedCameraRecordingConfiguration, nil, selected),
            (.cameraOperatingMode, .homeKitCameraActive, nil, 0),
            (.cameraOperatingMode, .eventSnapshotsActive, nil, 0),
            (.cameraOperatingMode, .periodicSnapshotsActive, nil, 0),
        ]
        for (service, type, subtype, value) in writes {
            let characteristic = try #require(accessory.service(service, subtype: subtype)?[type])
            let before = characteristic.value
            let response = try await write(user, characteristic.iid, value)
            #expect(status(response) == HAPStatus.insufficientPrivileges.rawValue, "\(service.name) \(type.name)")
            #expect(characteristic.value == before, "\(service.name) \(type.name)")
        }
        #expect(recording.active.withLockedValue { $0 }.isEmpty)
        #expect(recording.configurations.withLockedValue { $0 }.isEmpty)
        // Other characteristics stay open to every user.
        #expect(try await write(user, try iid(.microphone, .mute), true).status == 204)
        // An admin may.
        for (service, type, subtype, value) in writes {
            let response = try await write(admin, try iid(service, type, subtype: subtype), value)
            #expect(response.status == 204, "\(service.name) \(type.name)")
        }
        #expect(recording.active.withLockedValue { $0 } == [true])
        await user.close()
        await admin.close()
        await server.stop()
    }

    @Test func streamsAndDataStreamsLeaveNoCloseHandlerBehind() async throws {
        let controller = try await pairedController()
        let connection = try serverConnection()
        func handlers() -> Int { connection.shared.withLockedValue { $0.closeHandlers.count } }
        let setup = try iid(.cameraRTPStreamManagement, .setupEndpoints, subtype: "0")
        let selected = try iid(.cameraRTPStreamManagement, .selectedRTPStreamConfiguration, subtype: "0")
        for _ in 0..<3 {
            #expect(try await write(controller, setup, "ARCKPHsuH01OapsMLV6PGjt8AxkBAQACDDE5Mi4xNjguMS4yMAMCOMcEAjrHBCUBAQACEKGhoaGhoaGhoaGhoaGhoaEDDqKioqKioqKioqKioqKiBSUBAQACELGxsbGxsbGxsbGxsbGxsbEDDrKysrKysrKysrKysrKy").status == 204)
            #expect(handlers() == 1)
            // End.
            #expect(try await write(controller, selected, "ARUBEIo8ey4fTU5qmwwtXo8aO3wCAQA=").status == 204)
            #expect(handlers() == 0)
        }

        // A data stream session holds one handler on the HAP connection while its socket is open.
        for _ in 0..<2 {
            let hds = try await setupDataStream(controller)
            #expect(handlers() == 1)
            await hds.close()
            for _ in 0..<100 where handlers() != 0 { try await Task.sleep(for: .milliseconds(10)) }
            #expect(handlers() == 0)
        }
        await controller.close()
        await server.stop()
    }

    @Test func dropsDataStreamMessagesThatDoNotDecode() async throws {
        recording.packets = []
        let controller = try await pairedController()
        let hds = try await setupDataStream(controller)
        // A header length past the payload, a header of nested arrays, a 64-bit length: dropped, the socket stays.
        try await hds.send(payload: Data([200, 1, 2]))
        try await hds.send(payload: Data([100]) + Data(repeating: HDSTag.arrayLengthStart + 1, count: 100) + Data(repeating: 0, count: 1000))
        try await hds.send(payload: Data([9, HDSTag.utf8Length64]) + Data(repeating: 0xFF, count: 8) + HDSWriter.encode([:] as HDSDictionary))
        try await hds.send(header: ["protocol": "dataSend", "request": "open", "id": .int64(5)], message: ["target": "controller", "type": "ipcamera.recording", "streamId": .int(1)])
        // Recording is off: refused, but answered.
        #expect(try await hds.next() == HDSFrame.Message(kind: .response(id: 5, status: 6), protocol: "dataSend", topic: "open", message: ["status": .int(1)]))
        await hds.close()
        await controller.close()
        await server.stop()
    }

    @Test func oneOfTwoHubsOpeningAtOnceIsBusy() async throws {
        recording.packets = []
        let controller = try await pairedController()
        let selected = "AR0BBKAPAAACCAMAAAAAAAAAAwsBAQACBgEEoA8AAAIkAQEAAhIBAQECAQIDBNAHAAAEBKAPAAADCwECgAcCAjgEAwEeAxQBAQACDwEBAQIBAAMBAQQEQAAAAA=="
        #expect(try await write(controller, try iid(.cameraRecordingManagement, .selectedCameraRecordingConfiguration), selected).status == 204)
        #expect(try await write(controller, try iid(.cameraRecordingManagement, .active), 1).status == 204)
        let first = try await setupDataStream(controller)
        let second = try await setupDataStream(controller)
        let open: HDSDictionary = ["target": "controller", "type": "ipcamera.recording", "streamId": .int(2)]
        async let a: Void = first.send(header: ["protocol": "dataSend", "request": "open", "id": .int64(1)], message: open)
        async let b: Void = second.send(header: ["protocol": "dataSend", "request": "open", "id": .int64(1)], message: open)
        _ = try await (a, b)
        let answers = [try await first.next(), try await second.next()].map(\.message["status"])
        #expect(answers.filter { $0 == .int(0) }.count == 1)
        // HDSProtocolSpecificErrorReason.busy
        #expect(answers.filter { $0 == .int(2) }.count == 1)
        await first.close()
        await second.close()
        await controller.close()
        await server.stop()
    }

    @Test func savesAndRestoresTheRecordingState() async throws {
        try await camera.recordingManagement?.recordingManagementService.characteristic(.active).write(.int(1), origin: nil)
        let data = try #require(camera.serialize())
        let restoredDelegate = FakeRecordingDelegate()
        let restored = try CameraController(CameraControllerOptions(
            delegate: FakeStreamingDelegate(), streamingOptions: CameraStreamingOptions(video: CameraTLVTests.video),
            recording: CameraRecordingSetup(options: CameraTLVTests.recordingOptions, delegate: restoredDelegate)))
        try restored.deserialize(data)
        #expect(restoredDelegate.active.withLockedValue { $0 } == [true])
        #expect(restored.isRecordingActive)
        #expect(restored.controllerID == "camera")
    }
}
