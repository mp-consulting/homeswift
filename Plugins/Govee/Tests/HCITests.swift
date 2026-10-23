import Foundation
import Testing

@testable import HomeswiftGovee

/// The bytes Linux's Bluetooth central sends and reads, against noble's hci-socket bindings and the Bluetooth
/// Core specification's layouts; on every platform.
@Suite struct HCITests {
    static func bytes(_ hex: String) -> [UInt8] { Govee.bytes(hex: hex.replacingOccurrences(of: " ", with: "")) }

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
        #expect(data.advertises(anyOf: Set(BLEClient.sensorServices.map { $0.lowercased() })))
        #expect(!data.advertises(anyOf: ["fe95"]))
        #expect(SensorDecoding.isValid(manufacturerData: data.manufacturerData))
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
        #expect(ATT.uuidString(Self.bytes("1019 0d0c 0b0a 0908 0706 0504 0302 0100")[...]) == BLEClient.controlCharacteristic)
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
        #expect(discovery.characteristics.map(\.uuid) == ["2a00", "2a01", BLEClient.controlCharacteristic])
        #expect(discovery.characteristics.last == ATT.Characteristic(declaration: 0x10, properties: 0x16, valueHandle: 0x11, uuid: BLEClient.controlCharacteristic))
    }

    @Test func discoveryFailsOnOtherErrors() {
        var discovery = CharacteristicDiscovery()
        #expect(throws: CharacteristicDiscovery.Failure.error(request: 0x08, code: 0x05)) { try discovery.receive(Self.bytes("01 08 0100 05")) }
        #expect(throws: CharacteristicDiscovery.Failure.self) { try discovery.receive(Self.bytes("0b 00")) }
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

    /// What Linux sees reaches a thermo-hygrometer by its MAC, as the Homebridge plugin matched it.
    @Test func aLinuxReadingIsMatchedByMAC() throws {
        guard case .advertisingReports(let reports)? = HCI.parse(Self.h5075Report), let report = reports.first else { Issue.record("not a report"); return }
        var cache = AdvertisementCache()
        let entry = cache.add(report)
        let reading = BLESensorReading(
            identifier: report.address, address: report.address, model: entry.data.localName ?? "", battery: 100, humidity: 50, tempInC: 20,
            tempInF: 68, rssi: entry.rssi)
        #expect(GoveePlugin.matches(BLETarget(address: "A4C138123456", name: nil), reading))
        #expect(GoveePlugin.matches(BLETarget(address: "a4:c1:38:12:34:56", name: "ihoment_H5075_FFFF"), reading))
        // The name is not enough where the address is known.
        #expect(!GoveePlugin.matches(BLETarget(address: "a4:c1:38:00:00:01", name: "GVH5075_3456"), reading))
    }
}
