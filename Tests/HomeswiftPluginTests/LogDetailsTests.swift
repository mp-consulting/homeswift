import Foundation
import HomeswiftAI
import Testing

@testable import HomeswiftPlugin

@Suite struct LogDetailsTests {
    /// A payload long enough to leave the line.
    let state = #"{"state":{"onOff":0,"brightness":100,"colorTemInKelvin":3800,"mode":5},"sku":"H61B5","device":"EF:08:D2:39:32:35:41:33","softVersion":"1.03.10","wifiSoftVersion":"1.06.24","wifiHardVersion":"1.04.01"}"#

    @Test func takesJSONOutOfALine() throws {
        let split = try #require(LogDetails.split("Received snapshot: \(state)"))
        #expect(split.text == "Received snapshot: {…} \(state.utf8.count) B")
        #expect(try JSONValue(string: split.details) == JSONValue(string: state))
    }

    /// Labels in brackets come first (Govee's `[AWS] message event [{…}].`); what follows the JSON stays.
    @Test func skipsLabelsAndKeepsWhatFollows() throws {
        let split = try #require(LogDetails.split("[Govee Left] [AWS] message event [\(state)]."))
        #expect(split.text.hasPrefix("[Govee Left] [AWS] message event […] "))
        #expect(split.text.hasSuffix(" B."))
        #expect(try JSONValue(string: split.details).arrayValue?.count == 1)
        // A stray bracket before the JSON does not hide it.
        #expect(LogDetails.split("[Govee Left (unclosed: \(state)")?.text == "[Govee Left (unclosed: {…} \(state.utf8.count) B")
    }

    @Test func leavesShortOrCutJSONInTheText() {
        #expect(LogDetails.split(#"initialising with options {"aws":"enabled","ble":"disabled"}"#) == nil)
        // A plugin's preview cut at 200 characters does not parse.
        #expect(LogDetails.split("Shadow update received: " + String(state.dropLast(20)) + "…") == nil)
        // Brackets that are not JSON.
        #expect(LogDetails.split(String(repeating: "[not json] ", count: 30)) == nil)
    }

    @Test func readsBracketsInsideStrings() throws {
        let tricky = #"{"note":"a } and a ] and \" quote","items":[1,2,3],"#.appending(#""padding":"\#(String(repeating: "x", count: 160))"}"#)
        let split = try #require(LogDetails.split("payload \(tricky) done"))
        #expect(split.text.hasSuffix(" done"))
        #expect(try JSONValue(string: split.details)["note"]?.stringValue == #"a } and a ] and " quote"#)
    }

    @Test func masksSecrets() throws {
        let payload = #"{"accessToken":"abc123def456","password":"hunter22","nested":{"apiKey":"k-123456"},"auth":"Bearer abcdefghijklmnop","name":"Living room lamp","padding":"\#(String(repeating: "x", count: 80))"}"#
        let details = try JSONValue(string: try #require(LogDetails.split("login reply \(payload)")).details)
        #expect(details["accessToken"]?.stringValue == Redaction.placeholder)
        #expect(details["password"]?.stringValue == Redaction.placeholder)
        #expect(details["nested"]?["apiKey"]?.stringValue == Redaction.placeholder)
        #expect(details["auth"]?.stringValue == Redaction.placeholder)
        #expect(details["name"]?.stringValue == "Living room lamp")
    }

    /// HTTP credentials a plugin logs with a request or a reply: the whole value goes, whatever its shape.
    @Test func masksHeadersAndSessions() throws {
        let payload = #"{"headers":{"Authorization":"Basic dXNlcjpwYXNz","Cookie":"sid=0123456789abcdef; lang=en","X-Session-Id":"s-42"},"Set-Cookie":["a=1","b=2"],"session_id":"abcdef","status":200,"padding":"\#(String(repeating: "x", count: 60))"}"#
        let details = try JSONValue(string: try #require(LogDetails.split("reply \(payload)")).details)
        #expect(details["headers"]?["Authorization"]?.stringValue == Redaction.placeholder)
        #expect(details["headers"]?["Cookie"]?.stringValue == Redaction.placeholder)
        #expect(details["headers"]?["X-Session-Id"]?.stringValue == Redaction.placeholder)
        #expect(details["Set-Cookie"]?.stringValue == Redaction.placeholder)
        #expect(details["session_id"]?.stringValue == Redaction.placeholder)
        #expect(details["status"]?.doubleValue == 200)
    }

    @Test func writesSizes() {
        #expect(LogDetails.size(840) == "840 B")
        #expect(LogDetails.size(1434) == "1.4 KB")
        #expect(LogDetails.size(2_200_000) == "2.1 MB")
    }
}
