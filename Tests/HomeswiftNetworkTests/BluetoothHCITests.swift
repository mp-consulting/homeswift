import Foundation
import Testing

import NIOConcurrencyHelpers

@testable import HomeswiftNetwork

/// The bytes Linux's Bluetooth central sends and reads, against noble's hci-socket bindings and the Bluetooth
/// Core specification's layouts; on every platform.
@Suite struct HCITests {
    /// Govee's control characteristic, a 128-bit UUID off the Bluetooth base.
    static let goveeControl = "000102030405060708090a0b0c0d1910"

    static func bytes(_ hex: String) -> [UInt8] {
        let digits = Array(hex.replacingOccurrences(of: " ", with: ""))
        return stride(from: 0, to: digits.count - 1, by: 2).compactMap { UInt8(String(digits[$0...$0 + 1]), radix: 16) }
    }

    @Test func commandsAreWrittenAsNobleWritesThem() {
        // hci.js setScanParameters (legacy and extended, LE 1M only) and setScanEnabled.
        #expect(HCI.setScanParameters(extended: false) == Self.bytes("01 0b20 07 01 1200 1200 00 00"))
        #expect(HCI.setScanParameters(extended: true) == Self.bytes("01 4120 08 00 00 01 01 1200 1200"))
        #expect(HCI.setScanEnable(true, filterDuplicates: false, extended: false) == Self.bytes("01 0c20 02 01 00"))
        #expect(HCI.setScanEnable(false, filterDuplicates: true, extended: false) == Self.bytes("01 0c20 02 00 01"))
        #expect(HCI.setScanEnable(true, filterDuplicates: true, extended: true) == Self.bytes("01 4220 06 01 01 0000 0000"))
        #expect(HCI.command(HCI.readBDAddr) == Self.bytes("01 0910 00"))
        // struct hci_filter: event packets; command complete, command status; LE meta.
        #expect(HCI.socketFilter == Self.bytes("10000000 00c00000 00000040 00000000"))
    }

    @Test func socketAddressesFollowTheKernelStructs() throws {
        #expect(BluetoothSocketAddress.hci(device: 1) == Self.bytes("1f00 0100 0000"))
        let address = try #require(BluetoothAddress.bytes("A4:C1:38:12:34:56"))
        #expect(address == Self.bytes("563412 38c1a4"))
        // Family, PSM 0, address, the ATT channel, public or random, padding.
        #expect(BluetoothSocketAddress.l2cap(address: address, random: false) == Self.bytes("1f00 0000 563412 38c1a4 0400 01 00"))
        #expect(BluetoothSocketAddress.l2cap(address: address, random: true)[12] == 2)
    }

    @Test func addressesAreNormalised() {
        #expect(BluetoothAddress.normalized("A4C138123456") == "a4:c1:38:12:34:56")
        #expect(BluetoothAddress.normalized("a4-c1-38-12-34-56") == "a4:c1:38:12:34:56")
        #expect(BluetoothAddress.normalized("a4:c1:38:12:34") == nil)
        #expect(BluetoothAddress.normalized("zz:c1:38:12:34:56") == nil)
        #expect(BluetoothAddress.string(Self.bytes("563412 38c1a4")[...]) == "a4:c1:38:12:34:56")
        #expect(BluetoothAddress.looksRandom("c4:00:00:00:00:01"))
        #expect(!BluetoothAddress.looksRandom("a4:c1:38:12:34:56"))
    }

    @Test func commandCompletionsAndStatuses() {
        // Read BD_ADDR complete: one command allowed, opcode 0x1009, success, the address.
        #expect(HCI.parse(Self.bytes("04 0e 0a 01 0910 00 563412 38c1a4")) == .commandComplete(opcode: 0x1009, status: 0, parameters: Self.bytes("56341238c1a4")))
        // LE Create Connection refused at once: status first, then the opcode.
        #expect(HCI.parse(Self.bytes("04 0f 04 0c 01 0d20")) == .commandStatus(opcode: 0x200d, status: 0x0c))
        #expect(HCI.parse(Self.bytes("04 0e 0a 01 0910")) == nil)   // truncated
        #expect(HCI.parse(Self.bytes("02 4000 0500")) == nil)   // ACL data
    }

    /// An H5075's advertisement: flags, its name, the EC88 service, the reading as manufacturer data.
    static let h5075Report = bytes(
        "04 3e 2b 02 01" + "00 00 563412 38c1a4 1f"
            + "020106" + "0d09 475648353037355f33343536" + "0303 88ec" + "09ff 88ec000341a36400" + "c4")

    @Test func legacyAdvertisingReports() throws {
        guard case .advertisingReports(let reports)? = HCI.parse(Self.h5075Report) else { Issue.record("not a report"); return }
        let report = try #require(reports.first)
        #expect(reports.count == 1)
        #expect(report.address == "a4:c1:38:12:34:56" && !report.randomAddress && !report.isScanResponse && report.rssi == -60)
        var data = AdvertisingData()
        data.merge(report.data)
        #expect(data.localName == "GVH5075_3456")
        #expect(data.services == ["ec88"])
        #expect(data.manufacturerData == Self.bytes("88ec000341a36400"))
        #expect(data.advertises(anyOf: ["ec88", "0001"]))
        #expect(!data.advertises(anyOf: ["fe95"]))
    }

    @Test func scanResponsesAddToTheAdvertisement() throws {
        // A random address advertising the 0001 service, then its scan response with the name and the reading.
        let advertisement = Self.bytes("04 3e 13 02 01" + "00 01 010000 0000c4 07" + "020106 03030100" + "b0")
        let response = Self.bytes("04 3e 1c 02 01" + "04 01 010000 0000c4 10" + "0709 475648353130" + "07ff 0100 01 0203 04" + "b2")
        var cache = AdvertisementCache()
        for packet in [advertisement, response] {
            guard case .advertisingReports(let reports)? = HCI.parse(packet) else { Issue.record("not a report"); return }
            for report in reports { _ = cache.add(report) }
        }
        let entry = try #require(cache.entries["c4:00:00:00:00:01"])
        #expect(entry.randomAddress && entry.rssi == -78)
        #expect(entry.data.services == ["0001"] && entry.data.localName == "GVH510")
        #expect(entry.data.manufacturerData == Self.bytes("010001020304"))
    }

    @Test func extendedAdvertisingReports() throws {
        // Legacy, scannable, connectable (0x13), random address, 1M, no secondary PHY, SID ff, TX 7f, RSSI -80.
        let packet = Self.bytes(
            "04 3e 1e 0d 01" + "1300 01 010000 0000c4 01 00 ff 7f b0 0000 00 000000000000 04" + "0303 0100")
        guard case .advertisingReports(let reports)? = HCI.parse(packet) else { Issue.record("not a report"); return }
        #expect(reports == [HCI.AdvertisingReport(address: "c4:00:00:00:00:01", randomAddress: true, isScanResponse: false, data: Self.bytes("03030100"), rssi: -80)])
    }

    @Test func malformedReportsStopAtTheDamage() {
        // Two reports announced, the second cut short: the first stands.
        let packet = Self.bytes("04 3e 13 02 02" + "00 00 563412 38c1a4 03 0303 88 c4" + "00 00 5634")
        guard case .advertisingReports(let reports)? = HCI.parse(packet) else { Issue.record("not a report"); return }
        #expect(reports.count == 1)
        // Structures longer than what is left are not read.
        var data = AdvertisingData()
        data.merge(reports[0].data)
        data.merge(Self.bytes("0509 4142"))
        #expect(data.services.isEmpty && data.localName == nil)
    }

    @Test func uuidsReadAsCoreBluetoothKeysThem() {
        #expect(ATT.uuidString(Self.bytes("002a")[...]) == "2a00")
        #expect(ATT.uuidString(Self.bytes("1019 0d0c 0b0a 0908 0706 0504 0302 0100")[...]) == Self.goveeControl)
        // On the Bluetooth base UUID, a 128-bit UUID is its 16-bit alias.
        #expect(ATT.uuidString(Self.bytes("fb349b5f80000080 0010000088ec0000")[...]) == "ec88")
    }

    @Test func characteristicsAreDiscoveredAcrossTheHandleRange() throws {
        var discovery = CharacteristicDiscovery()
        #expect(discovery.request == Self.bytes("08 0100 ffff 0328"))
        // Two 16-bit characteristics (Device Name, Appearance).
        try discovery.receive(Self.bytes("09 07 0200 02 0300 002a 0400 02 0500 012a"))
        #expect(discovery.request == Self.bytes("08 0600 ffff 0328"))
        // Govee's control characteristic: read, write without response, notify.
        try discovery.receive(Self.bytes("09 15 1000 16 1100 1019 0d0c 0b0a 0908 0706 0504 0302 0100"))
        #expect(discovery.request == Self.bytes("08 1200 ffff 0328"))
        // Attribute not found ends the discovery.
        try discovery.receive(Self.bytes("01 08 1200 0a"))
        #expect(discovery.request == nil)
        #expect(discovery.characteristics.map(\.uuid) == ["2a00", "2a01", Self.goveeControl])
        #expect(discovery.characteristics.last == ATT.Characteristic(declaration: 0x10, properties: 0x16, valueHandle: 0x11, uuid: Self.goveeControl))
    }

    @Test func discoveryFailsOnOtherErrors() {
        var discovery = CharacteristicDiscovery()
        #expect(throws: CharacteristicDiscovery.Failure.error(request: 0x08, code: 0x05)) { try discovery.receive(Self.bytes("01 08 0100 05")) }
        #expect(throws: CharacteristicDiscovery.Failure.self) { try discovery.receive(Self.bytes("0b 00")) }
    }

    @Test func discoveryFailsWhenThePeripheralGoesBackwards() throws {
        var discovery = CharacteristicDiscovery()
        try discovery.receive(Self.bytes("09 07 0200 02 0300 002a 0400 02 0500 012a"))
        // Asked from handle 6 on, an answer ending at handle 3 would ask from 4 again, forever.
        #expect(throws: CharacteristicDiscovery.Failure.self) { try discovery.receive(Self.bytes("09 07 0200 02 0300 002a")) }
    }

    @Test func writesAndThePeripheralsOwnPDUs() {
        // A colour frame to the control characteristic's value handle, as a write command.
        let frame = Self.bytes("3305 02ff0000 0000000000000000000000000000")
        #expect(ATT.write(handle: 0x11, value: frame) == Self.bytes("52 1100") + frame)
        // The peripheral's MTU request gets the default MTU; other requests are refused; indications confirmed.
        #expect(ATT.classify(Self.bytes("02 0002")) == .request(answer: Self.bytes("03 1700")))
        #expect(ATT.classify(Self.bytes("0a 0300")) == .request(answer: Self.bytes("01 0a 0000 06")))
        #expect(ATT.classify(Self.bytes("1d 1100 aa")) == .value(handle: 0x11, value: [0xaa], confirm: [0x1e]))
        #expect(ATT.classify(Self.bytes("1b 1100 aabb")) == .value(handle: 0x11, value: [0xaa, 0xbb], confirm: nil))
        #expect(ATT.classify(Self.bytes("52 1100 01")) == nil)
        #expect(ATT.classify(Self.bytes("09 07 0200 02 0300 002a")) == .response(Self.bytes("09 07 0200 02 0300 002a")))
    }
}

/// Service data, the ATT requests notifications need, and the scan several plugins share.
@Suite struct BluetoothSharedTests {
    static func bytes(_ hex: String) -> [UInt8] { HCITests.bytes(hex) }

    @Test func serviceDataIsKeptByUUID() {
        var data = AdvertisingData()
        // Flags; 16-bit service data fd3d (SwitchBot's), then 128-bit service data.
        data.merge(Self.bytes("020106 06 16 3dfd 54 00 64" + " 13 21 fb349b5f80000080 0010 0000 aabb0000 0102"))
        #expect(data.serviceData["fd3d"] == [0x54, 0x00, 0x64])
        #expect(data.serviceData["0000bbaa00001000800000805f9b34fb"] == nil)
        #expect(data.serviceData["bbaa"] == [0x01, 0x02])
        #expect(data.services == ["fd3d", "bbaa"])
    }

    @Test func notificationRequestsFollowTheCoreSpecification() {
        // Write Request: opcode 0x12, handle, value; Find Information: 0x04, start, end.
        #expect(ATT.writeRequest(handle: 0x0013, value: [0x01, 0x00]) == Self.bytes("12 1300 0100"))
        #expect(ATT.findInformation(start: 0x0013, end: 0xffff) == Self.bytes("04 1300 ffff"))
        // A response in 16-bit format: the CCCD (2902) at 0x0013, a user description (2901) at 0x0014.
        let found = ATT.information(Self.bytes("05 01 1300 0229 1400 0129"))
        #expect(found?.map(\.handle) == [0x13, 0x14])
        #expect(found?.map(\.uuid) == ["2902", "2901"])
        #expect(ATT.information(Self.bytes("09 07")) == nil)
        #expect(ATT.errorCode(Self.bytes("01 04 1300 0a"), request: ATT.findInformationRequest) == ATT.attributeNotFound)
        #expect(ATT.errorCode(Self.bytes("01 12 1300 03"), request: ATT.findInformationRequest) == nil)
        // The write response is a response to this client.
        #expect(ATT.classify([ATT.writeResponse]) == .response([0x13]))
    }

    @Test func pluginsShareOneScan() async throws {
        let base = ShareRecorder()
        let hub = BLEScanHub(base: base)
        let govee = Collected()
        let switchBot = Collected()
        try await hub.start(UUID(), services: ["EC88"], allowDuplicates: true) { govee.add($0) }
        #expect(base.scans.last?.services == ["ec88"])
        let other = UUID()
        try await hub.start(other, services: ["fd3d"], allowDuplicates: false) { switchBot.add($0) }
        // The union, with duplicates since one of them wants them.
        #expect(base.scans.last?.services == ["ec88", "fd3d"] && base.scans.last?.duplicates == true)
        base.advertise(BLEAdvertisement(identifier: "a", serviceData: ["fd3d": [1]], rssi: -50))
        base.advertise(BLEAdvertisement(identifier: "b", serviceUUIDs: ["ec88"], rssi: -50))
        try await eventually { govee.ids == ["b"] && switchBot.ids == ["a"] }
        await hub.stop(other)
        #expect(base.scans.last?.services == ["ec88"])
    }
}

/// A central that records the scans it is asked for.
final class ShareRecorder: BLECentral, @unchecked Sendable {
    private let lock = NIOLock()
    private var _scans: [(services: [String], duplicates: Bool)] = []
    private var onDiscover: (@Sendable (BLEAdvertisement) -> Void)?
    var scans: [(services: [String], duplicates: Bool)] { lock.withLock { _scans } }
    func advertise(_ advertisement: BLEAdvertisement) { lock.withLock { onDiscover }?(advertisement) }

    var state: String { "poweredOn" }
    func waitForPoweredOn(timeout: Duration) async -> Bool { true }
    func startScanning(services: [String], allowDuplicates: Bool, onDiscover: @escaping @Sendable (BLEAdvertisement) -> Void) async throws {
        lock.withLock {
            _scans.append((services, allowDuplicates))
            self.onDiscover = onDiscover
        }
    }
    func stopScanning() async { lock.withLock { onDiscover = nil } }
    func connect(_ target: BLETarget) async throws -> any BLEConnection { throw BLEError.notFound }
    func reset() async {}
}

final class Collected: @unchecked Sendable {
    private let lock = NIOLock()
    private var _ids: [String] = []
    var ids: [String] { lock.withLock { _ids } }
    func add(_ advertisement: BLEAdvertisement) { lock.withLock { _ids.append(advertisement.identifier) } }
}

@Suite struct QueueWaitTests {
    final class Box<T: Sendable>: @unchecked Sendable {
        private let lock = NIOLock()
        private var _value: T?
        var value: T? { lock.withLock { _value } }
        func set(_ value: T) { lock.withLock { _value = value } }
    }

    let queue = DispatchQueue(label: "test.queue-wait")

    /// The case `withTaskCancellationHandler` alone gets wrong: the task was cancelled before the wait parked.
    @Test func aTaskCancelledBeforeItWaitsDoesNotHang() async throws {
        let wait = QueueWait<Bool>(queue: queue)
        let result = Box<Bool>()
        Task {
            withUnsafeCurrentTask { $0?.cancel() }
            result.set(await wait.wait(cancelled: false) { _ in })
        }
        try await eventually { result.value == false }
    }

    @Test func endsWithTheValueOrTheCancellation() async throws {
        let parked = Box<QueueWait<Bool>>()
        let result = Box<Bool>()
        let wait = QueueWait<Bool>(queue: queue)
        Task { result.set(await wait.wait(cancelled: false) { parked.set($0) }) }
        try await eventually { parked.value != nil }
        queue.async {
            parked.value?.resume(true)
            parked.value?.resume(false)
        }
        try await eventually { result.value == true }

        let cancelled = Box<Bool>()
        let other = QueueWait<Bool>(queue: queue)
        let task = Task { cancelled.set(await other.wait(cancelled: false) { _ in }) }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        try await eventually { cancelled.value == false }
    }
}

@Suite struct BluetoothPermissionTests {
    #if canImport(CoreBluetooth)
    /// macOS lets a binary use Bluetooth only with a usage description in its Info.plist: the one the
    /// `homeswift` binary embeds has it, and the check finds it there.
    @Test func bluetoothPermissionIsFoundInTheBinarysInfoPlist() throws {
        #expect(!CoreBluetoothCentral.isPermitted(infoDictionary: nil))
        #expect(!CoreBluetoothCentral.isPermitted(infoDictionary: ["NSBluetoothAlwaysUsageDescription": ""]))
        #expect(CoreBluetoothCentral.isPermitted(infoDictionary: ["NSBluetoothAlwaysUsageDescription": "Govee lights"]))

        let source = URL(fileURLWithPath: #filePath).appendingPathComponent("../../../Sources/HomeswiftCLI/Info.plist").standardizedFileURL
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: source), format: nil) as? [String: Any]
        #expect(CoreBluetoothCentral.isPermitted(infoDictionary: plist))

        // The built binary, when this build has one: its __TEXT,__info_plist section, which is what Bundle.main
        // reads for a command-line tool.
        let products = Bundle.allBundles.map(\.bundleURL).first { $0.pathExtension == "xctest" }?.deletingLastPathComponent()
        if let binary = products?.appendingPathComponent("homeswift"), FileManager.default.fileExists(atPath: binary.path) {
            let embedded = CFBundleCopyInfoDictionaryForURL(binary as CFURL) as? [String: Any]
            #expect(CoreBluetoothCentral.isPermitted(infoDictionary: embedded))
        }
    }

    /// macOS asks the responsible process: a test run from a shell has the app that opened it (Terminal, an IDE)
    /// as such, which the check reads from its `.app` bundle; run on its own it is nil.
    @Test func theResponsibleAppIsReadFromItsBundle() {
        guard let app = CoreBluetoothCentral.responsibleApp else { return }
        #expect(FileManager.default.fileExists(atPath: app.path))
        if app.path.hasSuffix(".app") { #expect(app.infoDictionary?["CFBundleIdentifier"] != nil) }
    }
    #endif
}
