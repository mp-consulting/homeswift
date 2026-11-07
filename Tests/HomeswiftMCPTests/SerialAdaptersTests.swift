import Foundation
import Testing
@testable import HomeswiftMCP

@Suite struct SerialAdaptersTests {
    @Test func sticksAreKnownByTheirNames() {
        #expect(SerialAdapters.radio(of: "usb-ITead_Sonoff_Zigbee_3.0_USB_Dongle_Plus_V2_20230601-if00-port0") == .zigbee)
        #expect(SerialAdapters.radio(of: "usb-dresden_elektronik_ingenieurtechnik_GmbH_ConBee_II_DE2412345-if00") == .zigbee)
        #expect(SerialAdapters.radio(of: "usb-Nabu_Casa_SkyConnect_v1.0_3c1a2b-if00-port0") == .zigbee)
        #expect(SerialAdapters.radio(of: "usb-Zooz_800_Z-Wave_Stick_533D004242-if00") == .zwave)
        #expect(SerialAdapters.radio(of: "usb-0658_0200-if00") == .zwave)
        #expect(SerialAdapters.radio(of: "usb-Silicon_Labs_HubZ_Smart_Home_Controller_C0F003D3-if01-port0") == .both)
        #expect(SerialAdapters.radio(of: "usb-FTDI_FT232R_USB_UART_A50285BI-if00-port0") == nil)
    }

    @Test func theFolderIsListedByName() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-serial-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["usb-Zooz_800_Z-Wave_Stick-if00", "usb-FTDI_UART-if00", "usb-ITead_Sonoff_Zigbee_3.0-if00-port0"] {
            // Dangling links, as a container given the host's folder sees them.
            try FileManager.default.createSymbolicLink(atPath: directory.appendingPathComponent(name).path, withDestinationPath: "../../ttyUSB9")
        }
        let found = SerialAdapters.list(in: directory.path)
        #expect(found.map(\.radio) == [.zigbee, .zwave])
        #expect(found.first?.path == directory.appendingPathComponent("usb-ITead_Sonoff_Zigbee_3.0-if00-port0").path)
        #expect(SerialAdapters.list(in: directory.appendingPathComponent("missing").path).isEmpty)
    }
}
