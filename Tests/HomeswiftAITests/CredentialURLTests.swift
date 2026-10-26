import Foundation
import HomeswiftAI
import Testing

@Suite struct CredentialURLTests {
    @Test func aCredentialURLIsRedactedUnderAnyKey() {
        let config = JSONValue.object(["rtspUrl": .string("rtsp://admin:hunter2@10.0.0.2/stream"), "homepage": .string("https://example.com/x")])
        let redacted = Redaction.redactSecrets(config)
        #expect(redacted["rtspUrl"]?.stringValue == Redaction.placeholder)
        #expect(redacted["homepage"]?.stringValue == "https://example.com/x")
    }

    @Test func aPasswordInAURLIsMaskedInText() {
        let text = Redaction.redactText("stream at rtsp://admin:hunter2@10.0.0.2/stream failed")
        #expect(!text.contains("hunter2"))
        #expect(text.contains("rtsp://admin:\(Redaction.placeholder)@"))
    }
}
