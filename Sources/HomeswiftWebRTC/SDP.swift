import Foundation

/// The SDP a receiving WebRTC client offers, and what it reads from the answer. Bundle is off, as Ring's client has
/// it (docs/clean-room/RingWebRTC.md section 3): audio and video each have their own ICE credentials and DTLS
/// transport. Audio is `sendrecv` (return audio), video `recvonly`.
public struct SDPOffer: Sendable, Equatable {
    public struct Media: Sendable, Equatable {
        public var credentials: ICECredentials
        public var ssrc: UInt32

        public init(credentials: ICECredentials = .random(), ssrc: UInt32 = UInt32.random(in: 1...UInt32.max)) {
            self.credentials = credentials
            self.ssrc = ssrc
        }
    }

    public var sessionID: UInt64
    /// The SHA-256 fingerprint of this side's DTLS certificate, as colon-separated upper-case hex.
    public var fingerprint: String
    public var audio: Media
    public var video: Media
    public var videoRTXSSRC: UInt32
    public var cname: String

    public static let opus: Int = 96
    public static let pcmu: Int = 0
    public static let h264: Int = 98
    public static let rtx: Int = 99
    /// High profile, level 4.1.
    public static let profileLevelID = "640029"

    public init(fingerprint: String, audio: Media = Media(), video: Media = Media(), sessionID: UInt64 = UInt64.random(in: 1...UInt64(Int64.max)),
                videoRTXSSRC: UInt32 = UInt32.random(in: 1...UInt32.max), cname: String = UUID().uuidString.lowercased()) {
        self.fingerprint = fingerprint
        self.audio = audio
        self.video = video
        self.sessionID = sessionID
        self.videoRTXSSRC = videoRTXSSRC
        self.cname = cname
    }

    public var text: String {
        func transport(_ media: Media, mid: Int, direction: String) -> [String] {
            [
                "c=IN IP4 0.0.0.0",
                "a=ice-ufrag:\(media.credentials.ufrag)", "a=ice-pwd:\(media.credentials.password)", "a=ice-options:trickle",
                "a=fingerprint:sha-256 \(fingerprint)", "a=setup:actpass", "a=\(direction)", "a=mid:\(mid)",
                "a=rtcp:9 IN IP4 0.0.0.0", "a=rtcp-mux", "a=ssrc:\(media.ssrc) cname:\(cname)",
            ]
        }
        var lines = ["v=0", "o=- \(sessionID) 0 IN IP4 0.0.0.0", "s=-", "t=0 0", "a=msid-semantic:WMS *"]
        lines.append("m=audio 9 UDP/TLS/RTP/SAVPF \(Self.opus) \(Self.pcmu)")
        lines += transport(audio, mid: 0, direction: "sendrecv")
        lines += ["a=rtpmap:\(Self.opus) opus/48000/2", "a=rtpmap:\(Self.pcmu) PCMU/8000"]
        lines.append("m=video 9 UDP/TLS/RTP/SAVPF \(Self.h264) \(Self.rtx)")
        lines += transport(video, mid: 1, direction: "recvonly")
        lines += ["a=ssrc:\(videoRTXSSRC) cname:\(cname)", "a=ssrc-group:FID \(video.ssrc) \(videoRTXSSRC)"]
        lines.append("a=rtpmap:\(Self.h264) H264/90000")
        for feedback in ["transport-cc", "ccm fir", "nack", "nack pli", "goog-remb"] { lines.append("a=rtcp-fb:\(Self.h264) \(feedback)") }
        lines.append("a=fmtp:\(Self.h264) packetization-mode=1;profile-level-id=\(Self.profileLevelID);level-asymmetry-allowed=1")
        lines += ["a=rtpmap:\(Self.rtx) rtx/90000", "a=fmtp:\(Self.rtx) apt=\(Self.h264)"]
        return lines.joined(separator: "\r\n") + "\r\n"
    }
}

/// What a client needs from the peer's answer, per m-line.
public struct SDPAnswer: Sendable, Equatable {
    public struct Media: Sendable, Equatable {
        public var kind: String
        public var credentials: ICECredentials?
        public var fingerprint: String?
        /// `active`, `passive` or `actpass`; the DTLS role this side takes is the other one.
        public var setup: String?
        public var candidates: [ICECandidate] = []
        /// Payload type → encoding name (`opus`, `PCMU`, `H264`).
        public var codecs: [Int: String] = [:]
        public var payloadTypes: [Int] = []
    }

    public var media: [Media] = []

    public var audio: Media? { media.first { $0.kind == "audio" } }
    public var video: Media? { media.first { $0.kind == "video" } }
    /// Ring's client takes the answer's audio for Opus when it says ` opus/`, else PCMU.
    public var audioIsOpus: Bool { audio?.codecs.values.contains { $0.lowercased() == "opus" } ?? false }

    public init(_ text: String) {
        var session = Media(kind: "session")
        var current: Media?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("m=") {
                if let current { media.append(current) }
                let parts = line.dropFirst(2).split(separator: " ")
                var next = Media(kind: parts.first.map(String.init) ?? "")
                next.payloadTypes = parts.dropFirst(3).compactMap { Int($0) }
                next.credentials = session.credentials
                next.fingerprint = session.fingerprint
                next.setup = session.setup
                current = next
                continue
            }
            guard line.hasPrefix("a=") else { continue }
            let attribute = String(line.dropFirst(2))
            func apply(_ body: (inout Media) -> Void) {
                if current != nil { body(&current!) } else { body(&session) }
            }
            if let value = attribute.value(after: "ice-ufrag:") {
                apply { $0.credentials = ICECredentials(ufrag: value, password: $0.credentials?.password ?? "") }
            } else if let value = attribute.value(after: "ice-pwd:") {
                apply { $0.credentials = ICECredentials(ufrag: $0.credentials?.ufrag ?? "", password: value) }
            } else if let value = attribute.value(after: "fingerprint:") {
                apply { $0.fingerprint = value }
            } else if let value = attribute.value(after: "setup:") {
                apply { $0.setup = value }
            } else if attribute.hasPrefix("candidate:"), let candidate = ICECandidate(sdp: attribute) {
                apply { $0.candidates.append(candidate) }
            } else if let value = attribute.value(after: "rtpmap:") {
                let parts = value.split(separator: " ", maxSplits: 1)
                if parts.count == 2, let type = Int(parts[0]), let name = parts[1].split(separator: "/").first {
                    apply { $0.codecs[type] = String(name) }
                }
            }
        }
        if let current { media.append(current) }
    }
}

extension String {
    fileprivate func value(after prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces) : nil
    }
}
