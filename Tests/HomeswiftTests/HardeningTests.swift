import Foundation
import Logging
import NIOConcurrencyHelpers
import NIOCore
import Testing

@testable import Homeswift

/// A snapshot handler that never looks at cancellation: it answers after `delay` whatever happens.
final class StubbornSnapshotDelegate: CameraStreamingDelegate, @unchecked Sendable {
    let delay: TimeInterval
    init(delay: TimeInterval) { self.delay = delay }

    func handleSnapshotRequest(_ request: SnapshotRequest) async throws -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { continuation.resume() }
        }
        return Data([0xFF, 0xD8])
    }

    func prepareStream(_ request: PrepareStreamRequest) async throws -> PrepareStreamResponse {
        PrepareStreamResponse(video: .init(port: 50000, ssrc: 1, srtpKey: Data(count: 16), srtpSalt: Data(count: 14)))
    }

    func handleStreamRequest(_ request: StreamingRequest) async throws {}
}

/// Controller input that used to trap or race: camera, HomeKit Data Stream, Adaptive Lighting.
@Suite(.timeLimit(.minutes(1)))
struct CameraHardeningTests {
    static func context(_ owner: AnyObject, local: String) -> HAPRequestContext {
        HAPRequestContext(
            connectionID: ObjectIdentifier(owner), controllerID: "controller", localAddress: local, remoteAddress: "192.168.1.20", sharedSecret: nil,
            connection: nil)
    }

    /// A Setup Endpoints write from a controller of `version` at `address`.
    static func setupEndpoints(version: IPAddressVersion, address: String) -> String {
        let srtp = HAPTLV.encode((1, .byte(2)), (2, .data(Data())), (3, .data(Data())))
        return HAPTLV.encode(
            (1, .data(HAPTLV.uuidBytes(CameraTLVTests.session))),
            (3, .data(HAPTLV.encode(
                (1, .byte(version == .ipv6 ? 1 : 0)), (2, .data(Data(address.utf8))), (3, .data(HAPTLV.uint16(51000))), (4, .data(HAPTLV.uint16(51002)))))),
            (4, .data(srtp)), (5, .data(srtp))
        ).base64EncodedString()
    }

    @Test func snapshotTimeoutHoldsAgainstADelegateThatIgnoresCancellation() async throws {
        let camera = try CameraController(
            CameraControllerOptions(delegate: StubbornSnapshotDelegate(delay: 60), streamingOptions: CameraStreamingOptions(video: CameraTLVTests.video)),
            extraEventTriggers: [], logger: CameraTLVTests.logger, snapshotTimeouts: (.milliseconds(50), .milliseconds(200)))
        let start = ContinuousClock.now
        await #expect(throws: HAPStatusError(.operationTimedOut)) {
            _ = try await camera.handleSnapshotRequest(height: 720, width: 1280)
        }
        // A task group would have waited the delegate's minute; a busy test runner may take a few seconds anyway.
        #expect(ContinuousClock.now - start < .seconds(20))

        // A delegate in time still answers.
        let quick = try CameraController(
            CameraControllerOptions(delegate: FakeStreamingDelegate(), streamingOptions: CameraStreamingOptions(video: CameraTLVTests.video)),
            extraEventTriggers: [], logger: CameraTLVTests.logger, snapshotTimeouts: (.milliseconds(50), .milliseconds(200)))
        #expect(try await quick.handleSnapshotRequest(height: 720, width: 1280) == FakeStreamingDelegate().image)
    }

    @Test func concurrentSetupEndpointsClaimTheStreamOnce() async throws {
        let delegate = FakeStreamingDelegate()
        let rtp = try CameraTLVTests.management(delegate)
        let owners = (0..<8).map { _ in NSObject() }
        let contexts = owners.map { Self.context($0, local: "192.168.1.10") }
        let setup = Self.setupEndpoints(version: .ipv4, address: "192.168.1.20")
        // The race is narrow: it takes many rounds to see it.
        var doubleClaims = 0
        for _ in 0..<2000 {
            let before = delegate.prepares.withLockedValue { $0.count }
            await withTaskGroup(of: Void.self) { group in
                for context in contexts {
                    group.addTask { try? await rtp.handleSetupEndpoints(.string(setup), context: context) }
                }
            }
            if delegate.prepares.withLockedValue({ $0.count }) - before != 1 { doubleClaims += 1 }
            rtp.handleSessionClosed()
        }
        #expect(doubleClaims == 0, "two controllers claimed one stream")
        withExtendedLifetime(owners) {}
    }

    @Test func answersAnAddressOfTheVersionTheControllerAsked() async throws {
        let delegate = FakeStreamingDelegate()
        let rtp = try CameraTLVTests.management(delegate)
        let owner = NSObject()
        try await rtp.handleSetupEndpoints(.string(Self.setupEndpoints(version: .ipv6, address: "fd00::20")), context: Self.context(owner, local: "fd00::10"))
        #expect(delegate.prepares.withLockedValue { $0.last?.addressVersion } == .ipv6)
        let read = try await rtp.service.characteristic(.setupEndpoints).readHandler?()
        let response = try #require(read?.stringValue.flatMap { Data(base64Encoded: $0) })
        let address = try HAPTLV.decode(try #require(try HAPTLV.decode(response)[3]))
        #expect(address[1] == Data([1]))
        #expect(address[2] == Data("fd00::10".utf8))
        rtp.handleSessionClosed()

        // An IPv6 controller on a connection over IPv4: an IPv6 address of the same interface, or an error, never
        // the IPv4 address labelled IPv6. 192.0.2.10 (TEST-NET-1) is on no interface here.
        await #expect(throws: HAPStatusError(.serviceCommunicationFailure)) {
            try await rtp.handleSetupEndpoints(.string(Self.setupEndpoints(version: .ipv6, address: "fd00::20")), context: Self.context(owner, local: "192.0.2.10"))
        }
        #expect(rtp.streamStatus == .available)
        withExtendedLifetime(owner) {}
    }

    @Test func findsTheOtherVersionOnTheConnectionsInterface() throws {
        func address(_ string: String) throws -> SocketAddress { try SocketAddress(ipAddress: string, port: 0) }
        let devices: [(name: String, address: SocketAddress)] = [
            ("en1", try address("10.0.0.2")), ("en1", try address("2001:db8::99")),
            ("en0", try address("fe80::1")), ("en0", try address("192.168.1.10")), ("en0", try address("2001:db8::10")),
            ("en2", try address("172.16.0.2")), ("en2", try address("fe80::2")),
        ]
        #expect(HAPRequestContext.address(of: .ipv6, onInterfaceOf: "192.168.1.10", devices: devices) == "2001:db8::10")
        #expect(HAPRequestContext.address(of: .ipv4, onInterfaceOf: "2001:db8::10", devices: devices) == "192.168.1.10")
        #expect(HAPRequestContext.address(of: .ipv4, onInterfaceOf: "2001:db8::99", devices: devices) == "10.0.0.2")
        // Only a link-local address: that one, as HAP-NodeJS falls back to it.
        #expect(HAPRequestContext.address(of: .ipv6, onInterfaceOf: "172.16.0.2", devices: devices) == "fe80::2")
        #expect(HAPRequestContext.address(of: .ipv6, onInterfaceOf: "192.0.2.10", devices: devices) == nil)
        // The connection's own address when it has the version asked for.
        #expect(Self.context(NSObject(), local: "192.168.1.10").localAddress(for: .ipv4) == "192.168.1.10")
    }

    @Test func requireAdminRefusesControllersWithoutAdminPermissions() throws {
        let owner = NSObject()
        let user = HAPRequestContext(connectionID: ObjectIdentifier(owner), controllerID: "user", isAdmin: false, localAddress: nil, remoteAddress: nil, sharedSecret: nil, connection: nil)
        let admin = HAPRequestContext(connectionID: ObjectIdentifier(owner), controllerID: "admin", isAdmin: true, localAddress: nil, remoteAddress: nil, sharedSecret: nil, connection: nil)
        #expect(throws: HAPStatusError(.insufficientPrivileges)) { try HAPRequestContext.$current.withValue(user) { try HAPRequestContext.requireAdmin() } }
        try HAPRequestContext.$current.withValue(admin) { try HAPRequestContext.requireAdmin() }
        // The plugin's own writes.
        try HAPRequestContext.requireAdmin()
    }
}

/// HDS bytes from a controller: errors, never traps.
@Suite struct HDSHardeningTests {
    static func little<T: FixedWidthInteger>(_ value: T) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }

    @Test func hugeLengthsThrow() {
        // utf8Length64 and dataLength64 with lengths past Int and past the data.
        #expect(throws: HDSCodingError.endOfData) { try HDSReader.decode(Data([HDSTag.utf8Length64]) + Self.little(UInt64.max)) }
        #expect(throws: HDSCodingError.endOfData) { try HDSReader.decode(Data([HDSTag.dataLength64]) + Self.little(UInt64.max)) }
        #expect(throws: HDSCodingError.endOfData) { try HDSReader.decode(Data([HDSTag.dataLength64]) + Self.little(UInt64(Int.max))) }
        #expect(throws: HDSCodingError.endOfData) { try HDSReader.decode(Data([HDSTag.utf8Length64]) + Self.little(UInt64(Int.max - 4))) }
        #expect(throws: HDSCodingError.endOfData) { try HDSReader.decode(Data([HDSTag.dataLength32]) + Self.little(UInt32.max)) }
    }

    @Test func floatKeysOutsideInt64BecomeStrings() throws {
        func key(_ number: Double) throws -> String? {
            let data = Data([HDSTag.dictionaryLengthStart + 1, HDSTag.float64]) + Self.little(number.bitPattern) + Data([HDSTag.integerRangeStart])
            return try HDSReader.decode(data).dictionaryValue?.entries.first?.key
        }
        #expect(try key(1e19) == "1e+19")
        #expect(try key(.infinity) == "Infinity")
        #expect(try key(-.infinity) == "-Infinity")
        #expect(try key(.nan) == "NaN")
        #expect(try key(42) == "42")
        #expect(try key(2.5) == "2.5")
        // Values too: an integral double outside Int64 is not an integer.
        #expect(HDSValue.double(1e19).intValue == nil)
        #expect(HDSValue.double(.infinity).intValue == nil)
    }

    @Test func nestingIsLimited() throws {
        let arrayOfOne = HDSTag.arrayLengthStart + 1
        let deep = Data(repeating: arrayOfOne, count: HDSReader.maxDepth) + Data([HDSTag.null])
        _ = try HDSReader.decode(deep)
        #expect(throws: HDSCodingError.tooDeep) { try HDSReader.decode(Data(repeating: arrayOfOne, count: HDSReader.maxDepth + 1) + Data([HDSTag.null])) }
        // A whole frame of nested tags used to recurse once per byte.
        #expect(throws: HDSCodingError.tooDeep) { try HDSReader.decode(Data(repeating: HDSTag.arrayTerminated, count: 200_000)) }
        #expect(throws: HDSCodingError.tooDeep) { try HDSReader.decode(Data(repeating: HDSTag.dictionaryLengthStart + 1, count: 200_000)) }
        // Dropped as a message, without a trap.
        #expect(HDSFrame.message(from: Data([0]) + Data(repeating: arrayOfOne, count: 100_000)) == nil)
    }

    @Test func dataThatLooksLikeTheOldTerminatorMarkerIsData() throws {
        let data = Data([HDSTag.arrayTerminated, HDSTag.dataLengthStart + 3, 0xFF, 0x03, 0xFF, HDSTag.terminator])
        #expect(try HDSReader.decode(data) == .array([.data(Data([0xFF, 0x03, 0xFF]))]))
        // A terminator outside a terminated container is invalid.
        #expect(throws: HDSCodingError.invalidTag(HDSTag.terminator, at: 0)) { try HDSReader.decode(Data([HDSTag.terminator])) }
    }
}

/// Adaptive Lighting TLVs from a controller: clamped or refused, never a trap.
@Suite(.timeLimit(.minutes(1)))
struct AdaptiveLightingHardeningTests {
    static let all = Data(repeating: 0xFF, count: 8)

    static func entry(temperature: Float = 200, factor: Float = 0.5, offset: Data = HAPTLV.variableUInt(1000), duration: Data? = nil) -> Data {
        var entry = HAPTLV.encode((1, .data(HAPTLV.float32(factor))), (2, .data(HAPTLV.float32(temperature))), (3, .data(offset)))
        if let duration { entry.append(HAPTLV.encode((4, .data(duration)))) }
        return entry
    }

    /// An update of the transition configuration for the colour temperature (iid 11).
    static func update(startTime: Data = Data(count: 8), entries: [Data], adjustmentIID: Data = HAPTLV.variableUInt(10), iid: Data = HAPTLV.variableUInt(11)) -> HAPValue {
        let curve = HAPTLV.encode(
            (1, .list(entries)), (2, .data(adjustmentIID)),
            (3, .data(HAPTLV.encode((1, .data(HAPTLV.uint32(10))), (2, .data(HAPTLV.uint32(100)))))))
        let configuration = HAPTLV.encode(
            (1, .data(iid)),
            (2, .data(HAPTLV.encode((1, .data(Data(repeating: 0xAB, count: 16))), (2, .data(startTime))))),
            (3, .byte(1)), (5, .data(curve)), (6, .data(HAPTLV.uint16(60000))), (8, .data(HAPTLV.uint32(600_000))))
        return .string(HAPTLV.encode((2, .data(HAPTLV.encode((1, .data(configuration)))))).base64EncodedString())
    }

    @Test func hugeTimesAndIIDsAreClamped() throws {
        let clock = AdaptiveLightingTests.Clock()
        let controller = AdaptiveLightingTests.controller(AdaptiveLightingTests.lightbulb(), mode: .manual, clock: clock)
        _ = try controller.handleTransitionControlWrite(Self.update(
            startTime: Self.all,
            entries: [Self.entry(offset: Self.all, duration: Self.all), Self.entry(offset: Self.all, duration: Self.all), Self.entry(offset: Self.all)],
            adjustmentIID: Self.all))
        let active = try #require(controller.activeTransition)
        #expect(active.transitionStartMillis == AdaptiveLightingController.epoch2001Millis + AdaptiveLightingController.maxStartMillis)
        #expect(active.transitionCurve.allSatisfy { $0.transitionTime == Int(UInt32.max) })
        #expect(active.brightnessCharacteristicIID == Int.max)
        // The schedule's arithmetic runs without overflow.
        _ = controller.currentTransitionPoint()
        _ = controller.transitionControlResponse()
        clock.now = Int.max / 4
        _ = controller.currentTransitionPoint()

        // An eight-byte iid in a read.
        #expect(throws: HAPStatusError(.invalidValueInRequest)) {
            try controller.handleTransitionControlWrite(.string(HAPTLV.encode((1, .data(HAPTLV.encode((1, .data(Self.all)))))).base64EncodedString()))
        }
        // And in an update: no such characteristic.
        #expect(throws: HAPStatusError(.invalidValueInRequest)) {
            try controller.handleTransitionControlWrite(Self.update(entries: [Self.entry(), Self.entry()], iid: Self.all))
        }
    }

    @Test func nonFiniteCurveValuesAreRefused() throws {
        let controller = AdaptiveLightingTests.controller(AdaptiveLightingTests.lightbulb(), mode: .manual, clock: AdaptiveLightingTests.Clock())
        #expect(throws: (any Error).self) {
            try controller.handleTransitionControlWrite(Self.update(entries: [Self.entry(temperature: .infinity), Self.entry()]))
        }
        #expect(throws: (any Error).self) {
            try controller.handleTransitionControlWrite(Self.update(entries: [Self.entry(), Self.entry(factor: .nan)]))
        }
        #expect(!controller.isAdaptiveLightingActive)
    }

    @Test func hugeTemperaturesAreClampedToTheCharacteristic() {
        let controller = AdaptiveLightingTests.controller(AdaptiveLightingTests.lightbulb(), mode: .automatic, clock: AdaptiveLightingTests.Clock(), shift: Int.max)
        let huge = AdaptiveLightingController.TransitionCurveEntry(temperature: 3e38, brightnessAdjustmentFactor: 3e38, transitionTime: 0)
        let point = AdaptiveLightingController.TransitionPoint(lowerBoundTimeOffset: 0, transitionOffset: 0, lowerBound: huge, upperBound: huge)
        let range = AdaptiveLightingController.BrightnessAdjustmentRange(minBrightnessValue: 0, maxBrightnessValue: 100)
        #expect(controller.currentTemperature(point, brightness: 100, range: range, bounds: (140, 500)) == 500)
        let negative = AdaptiveLightingController.TransitionCurveEntry(temperature: -3e38, brightnessAdjustmentFactor: 0, transitionTime: 0)
        let low = AdaptiveLightingController.TransitionPoint(lowerBoundTimeOffset: 0, transitionOffset: 0, lowerBound: negative, upperBound: negative)
        let shifted = AdaptiveLightingTests.controller(AdaptiveLightingTests.lightbulb(), mode: .automatic, clock: AdaptiveLightingTests.Clock(), shift: Int.min)
        #expect(shifted.currentTemperature(low, brightness: 50, range: range, bounds: (140, 500)) == 140)
    }

    @Test func aSavedScheduleWithHugeTimesIsClamped() throws {
        let saved = #"{"activeTransition":{"iid":11,"transitionStartMillis":9223372036854775807,"timeMillisOffset":-9223372036854775808,"transitionId":"0f7f5c26-8c8f-4d7a-9b8e-3c2a1d0e9f8b","transitionStartBuffer":"ffffffffffffffff","brightnessCharacteristicIID":10,"brightnessAdjustmentRange":{"minBrightnessValue":10,"maxBrightnessValue":100},"transitionCurve":[{"temperature":150,"brightnessAdjustmentFactor":0.5,"transitionTime":9223372036854775807,"duration":9223372036854775807},{"temperature":200,"brightnessAdjustmentFactor":0.25,"transitionTime":9223372036854775807},{"temperature":300,"brightnessAdjustmentFactor":0,"transitionTime":9223372036854775807}],"updateInterval":9223372036854775807,"notifyIntervalThreshold":9223372036854775807}}"#
        let controller = AdaptiveLightingTests.controller(AdaptiveLightingTests.lightbulb(), mode: .manual, clock: AdaptiveLightingTests.Clock())
        try controller.deserialize(Data(saved.utf8))
        let active = try #require(controller.activeTransition)
        #expect(active.transitionCurve.allSatisfy { $0.transitionTime == Int(UInt32.max) })
        #expect(active.updateInterval == Int(UInt32.max))
        _ = controller.currentTransitionPoint()
        _ = controller.transitionControlResponse()
    }
}

/// What a client that never pairs may cost the HAP server: bodies before pair verify, idle connections.
@Suite(.timeLimit(.minutes(1)))
struct ConnectionHardeningTests {
    let server: HAPServer

    init() throws {
        let lamp = Accessory(id: "lamp-1", name: "Lamp", category: .lightbulb, services: [Service(.lightbulb)])
        server = try HAPServer(
            bridge: Accessory(id: "bridge", name: "Test Bridge", category: .bridge, services: []), accessories: [lamp], storage: MemoryStorage(),
            options: .init(setupCode: SetupCode("031-45-154"), port: 0, advertise: false, logger: testLogger))
    }

    var connectionCount: Int { server.state.withLockedValue { $0.connections.count } }

    func waitForConnections(_ count: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while connectionCount != count, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(connectionCount == count)
    }

    @Test func dropsALargeBodyBeforePairVerify() async throws {
        try await server.start()
        let controller = TestController()
        try await controller.connect(port: server.port!)
        await #expect(throws: (any Error).self) {
            _ = try await controller.request("POST", "/pair-setup", body: Data(count: HAPConnection.maxUnverifiedBody), contentType: "application/pairing+tlv8")
        }
        // Pairing itself fits.
        let paired = TestController()
        try await paired.connect(port: server.port!)
        try await paired.pairSetup(code: "031-45-154")
        await controller.close()
        await paired.close()
        await server.stop()
    }

    @Test func closesConnectionsIdleForAnHourOnceThereAreSixteen() async throws {
        try await server.start()
        var controllers: [TestController] = []
        for _ in 0..<(HAPServer.idleConnectionLimit - 1) {
            let controller = TestController()
            try await controller.connect(port: server.port!)
            controllers.append(controller)
        }
        try await waitForConnections(HAPServer.idleConnectionLimit - 1)
        // Below the limit, idle connections stay.
        server.closeIdleConnections(now: .now() + .hours(2))
        try await Task.sleep(for: .milliseconds(100))
        #expect(connectionCount == HAPServer.idleConnectionLimit - 1)

        let last = TestController()
        try await last.connect(port: server.port!)
        controllers.append(last)
        try await waitForConnections(HAPServer.idleConnectionLimit)
        // At the limit, connections active within the hour stay; those idle longer go.
        server.closeIdleConnections()
        try await Task.sleep(for: .milliseconds(100))
        #expect(connectionCount == HAPServer.idleConnectionLimit)
        server.closeIdleConnections(now: .now() + .hours(2))
        try await waitForConnections(0)
        for controller in controllers { await controller.close() }
        await server.stop()
    }
}
