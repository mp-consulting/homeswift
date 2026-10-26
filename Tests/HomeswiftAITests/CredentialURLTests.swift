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

    @Test func aPasswordWithSlashOrAtOrAUserNameWithAtIsMaskedInText() {
        let slash = Redaction.redactText("rtsp://admin:pa/ss@10.0.0.2/stream")
        #expect(!slash.contains("pa/ss"))
        let at = Redaction.redactText("rtsp://admin:pa@ss@10.0.0.2/stream")
        #expect(!at.contains("ss@"))
        let user = Redaction.redactText("rtsp://me@example.com:secret@192.168.1.10/stream")
        #expect(!user.contains("secret"))
    }

    @Test func aStructuredURLWithAPasswordIsACredentialURL() {
        #expect(Redaction.isCredentialURL("rtsp://u:pa/ss@h/s"))
        #expect(Redaction.isCredentialURL("rtsp://me@example.com:secret@192.168.1.10/stream"))
        #expect(!Redaction.isCredentialURL("https://example.com/x"))
    }

    @Test func aPasswordInAURLIsMaskedInText() {
        let text = Redaction.redactText("stream at rtsp://admin:hunter2@10.0.0.2/stream failed")
        #expect(!text.contains("hunter2"))
        #expect(text.contains("rtsp://admin:\(Redaction.placeholder)@"))
    }
}
