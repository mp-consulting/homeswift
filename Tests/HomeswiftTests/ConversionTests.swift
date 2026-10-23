import Foundation
import Testing

@testable import Homeswift

@Suite struct ConversionTests {
    @Test func saturatingConversionsNeverTrap() {
        #expect(Int(saturating: 12.9) == 12)
        #expect(Int(saturating: -12.9) == -12)
        #expect(Int(saturating: Double.nan) == nil)
        #expect(Int(saturating: Double.infinity) == .max)
        #expect(Int(saturating: -Double.infinity) == .min)
        #expect(Int(saturating: 1e19) == .max)
        #expect(Int(saturating: -1e300) == .min)
        #expect(Int(saturating: 9.223372036854775807e18) == .max)   // 2^63 itself does not fit
        #expect(Int64(saturating: Float(3.5)) == 3)
        #expect(UInt8(saturating: 300.0) == 255)
        #expect(UInt8(saturating: -1.0) == 0)
        #expect(UInt16(saturating: 65_535.9) == 65_535)
        #expect(UInt32(saturating: -0.5) == 0)
        #expect(Int(saturating: 150.0, in: 0...100) == 100)
        #expect(Int(saturating: -1e300, in: 0...100) == 0)
        #expect(Int(saturating: 42.7, in: 0...100) == 42)
        #expect(Int(saturating: Double.nan, in: 0...100) == nil)
        #expect(Double.nan.finite == nil)
        #expect(Double.infinity.finite == nil)
        #expect(2.5.finite == 2.5)
    }

    @Test func hapValuesOutOfRangeAreNotIntegers() {
        #expect(HAPValue.double(1e300).intValue == nil)
        #expect(HAPValue.double(.nan).intValue == nil)
        #expect(HAPValue.double(41.6).intValue == 42)
        // A controller's write of 1e300 to an integer characteristic is refused, not a crash.
        #expect(CharacteristicType.brightness.coerce(.double(1e300)) == nil)
        #expect(CharacteristicType.brightness.coerce(.double(55)) == .int(55))
    }

    @Test func theTraceShowsNoKeys() {
        let body = Data(#"{"characteristics":[{"aid":2,"iid":12,"value":"AQEBAgIDBDJzcnRwLW1hc3Rlci1rZXk="},{"aid":2,"iid":13,"value":1}]}"#.utf8)
        let request = HTTPRequest(method: "PUT", target: "/characteristics", headers: [:], body: body)
        let traced = HAPConnection.traceBody(request) { aid, iid in aid == 2 && iid == 12 }
        #expect(!traced.contains("AQEBAgIDBDJzcnRwLW1hc3Rlci1rZXk="))
        #expect(traced.contains("<32 bytes>"))
        #expect(traced.contains(#""value":1"#))
        // Writes of other characteristics read as they came.
        #expect(HAPConnection.traceBody(request) { _, _ in false } == String(decoding: body, as: UTF8.self))
        let pairing = HTTPRequest(method: "POST", target: "/pair-verify", headers: [:], body: Data(repeating: 1, count: 37))
        #expect(HAPConnection.traceBody(pairing) { _, _ in true } == "<37 bytes>")
        let garbage = HTTPRequest(method: "PUT", target: "/characteristics", headers: [:], body: Data("not json".utf8))
        #expect(HAPConnection.traceBody(garbage) { _, _ in true } == "<8 bytes>")
    }

    @Test func keyCarryingCharacteristicsAreConfidentialAndLocksAreSecurityControls() {
        #expect(Characteristic(.setupEndpoints).isConfidential)
        #expect(Characteristic(.setupDataStreamTransport).isConfidential)
        #expect(!Characteristic(.selectedRTPStreamConfiguration).isConfidential)
        #expect(Characteristic(.lockTargetState).isSecurityControl)
        #expect(Characteristic(.targetDoorState).isSecurityControl)
        #expect(Characteristic(.securitySystemTargetState).isSecurityControl)
        let on = Characteristic(.on)
        #expect(!on.isSecurityControl)
        #expect(on.securityControl() === on)
        #expect(on.isSecurityControl)
    }
}
