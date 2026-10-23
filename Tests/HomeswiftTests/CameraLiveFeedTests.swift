import Foundation
import NIOConcurrencyHelpers
import Testing

@testable import Homeswift

/// Initialization segments FFmpeg 9 wrote (`-movflags frag_keyframe+empty_moov+default_base_moof`): H.264 High at
/// level 4.0 with AAC-LC at 16 kHz, and HEVC Main (x265, `-tag:v hvc1`) without audio. The codec strings are the
/// ones ffprobe and the hvcC bytes give.
enum InitSegmentFixtures {
    static let h264AAC = decode("""
        AAAAHGZ0eXBpc281AAACAGlzbzVpc282bXA0MQAABM5tb292AAAAbG12aGQAAAAAAAAAAAAAAAAAALuAAAAAAAABAAABAAAAAAAAAAAAAAAAAQAAAAAAAAAA
        AAAAAAAAAAEAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACAAAB8nRyYWsAAABcdGtoZAAAAAMAAAAAAAAAAAAAAAEAAAAA
        AAAAAAAAAAAAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAEAAAAABQAAAALQAAAAAAY5tZGlhAAAAIG1kaGQAAAAAAAAAAAAA
        AAAAADwAAAAAAFXEAAAAAAAtaGRscgAAAAAAAAAAdmlkZQAAAAAAAAAAAAAAAFZpZGVvSGFuZGxlcgAAAAE5bWluZgAAABR2bWhkAAAAAQAAAAAAAAAAAAAA
        JGRpbmYAAAAcZHJlZgAAAAAAAAABAAAADHVybCAAAAABAAAA+XN0YmwAAACtc3RzZAAAAAAAAAABAAAAnWF2YzEAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAAB
        QAC0AEgAAABIAAAAAAAAAAEUTGF2YzYzLjEuMTAyIGxpYngyNjQAAAAAAAAAAAAAAAAY//8AAAA3YXZjQwFkACj/4QAaZ2QAKKzZQUGfnwEQAAADABAAAAMB
        4PGDGWABAAZo6+PLIsD9+PgAAAAAEHBhc3AAAAABAAAAAQAAABBzdHRzAAAAAAAAAAAAAAAQc3RzYwAAAAAAAAAAAAAAFHN0c3oAAAAAAAAAAAAAAAAAAAAQ
        c3RjbwAAAAAAAAAAAAABv3RyYWsAAABcdGtoZAAAAAMAAAAAAAAAAAAAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAQEAAAAAAQAAAAAAAAAAAAAAAAAAAAEAAAAA
        AAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAVttZGlhAAAAIG1kaGQAAAAAAAAAAAAAAAAAAD6AAAAAAFXEAAAAAAAtaGRscgAAAAAAAAAAc291bgAAAAAAAAAA
        AAAAAFNvdW5kSGFuZGxlcgAAAAEGbWluZgAAABBzbWhkAAAAAAAAAAAAAAAkZGluZgAAABxkcmVmAAAAAAAAAAEAAAAMdXJsIAAAAAEAAADKc3RibAAAAH5z
        dHNkAAAAAAAAAAEAAABubXA0YQAAAAAAAAABAAAAAAAAAAAAAQAQAAAAAD6AAAAAAAA2ZXNkcwAAAAADgICAJQACAASAgIAXQBUAAAAAAH0AAAB9AAWAgIAF
        FAhW5QAGgICAAQIAAAAUYnRydAAAAAAAAH0AAAB9AAAAABBzdHRzAAAAAAAAAAAAAAAQc3RzYwAAAAAAAAAAAAAAFHN0c3oAAAAAAAAAAAAAAAAAAAAQc3Rj
        bwAAAAAAAAAAAAAASG12ZXgAAAAgdHJleAAAAAAAAAABAAAAAQAAAAAAAAAAAAAAAAAAACB0cmV4AAAAAAAAAAIAAAABAAAAAAAAAAAAAAAAAAAAYXVkdGEA
        AABZbWV0YQAAAAAAAAAhaGRscgAAAAAAAAAAbWRpcmFwcGwAAAAAAAAAAAAAAAAsaWxzdAAAACSpdG9vAAAAHGRhdGEAAAABAAAAAExhdmY2My4xLjEwMg==
        """)

    static let hevc = decode("""
        AAAAHGZ0eXBpc281AAACAGlzbzVpc282bXA0MQAADEptb292AAAAbG12aGQAAAAAAAAAAAAAAAAAAAPoAAAAAAABAAABAAAAAAAAAAAAAAAAAQAAAAAAAAAA
        AAAAAAAAAAEAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACAAALTXRyYWsAAABcdGtoZAAAAAMAAAAAAAAAAAAAAAEAAAAA
        AAAAAAAAAAAAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAEAAAAABQAAAALQAAAAACultZGlhAAAAIG1kaGQAAAAAAAAAAAAA
        AAAAADwAAAAAAFXEAAAAAAAtaGRscgAAAAAAAAAAdmlkZQAAAAAAAAAAAAAAAFZpZGVvSGFuZGxlcgAAAAqUbWluZgAAABR2bWhkAAAAAQAAAAAAAAAAAAAA
        JGRpbmYAAAAcZHJlZgAAAAAAAAABAAAADHVybCAAAAABAAAKVHN0YmwAAAoIc3RzZAAAAAAAAAABAAAJ+Gh2YzEAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAAB
        QAC0AEgAAABIAAAAAAAAAAEUTGF2YzYzLjEuMTAyIGxpYngyNjUAAAAAAAAAAAAAAAAY//8AAAmIaHZjQwEBYAAAAJAAAAAAADzwAPz9+PgAAA8EoAABABhA
        AQwB//8BYAAAAwCQAAADAAADADyVmAmhAAEAK0IBAQFgAAADAJAAAAMAAAMAPKAKCAufeWVmkkyvAWgIAAADAAgAAAMAeECiAAEAB0QBwXK0YkAnAAEJC04B
        Bf///////////wYsot4JtRdH27tVpP5/wvxOeDI2NSAoYnVpbGQgMjE3KSAtIDQuMysxLWU5Yjg4MTI6W01hYyBPUyBYXVtjbGFuZyAyMS4wLjBdWzY0IGJp
        dF0gOGJpdCsxMGJpdCsxMmJpdCAtIEguMjY1L0hFVkMgY29kZWMgLSBDb3B5cmlnaHQgMjAxMy0yMDE4IChjKSBNdWx0aWNvcmV3YXJlLCBJbmMgLSBodHRw
        Oi8veDI2NS5vcmcgLSBvcHRpb25zOiBjcHVpZD0zNCBmcmFtZS10aHJlYWRzPTMgd3BwIG5vLXBtb2RlIG5vLXBtZSBuby1wc25yIG5vLXNzaW0gbG9nLWxl
        dmVsPTAgYml0ZGVwdGg9OCBpbnB1dC1jc3A9MSBmcHM9MTUvMSBpbnB1dC1yZXM9MzIweDE4MCBpbnRlcmxhY2U9MCB0b3RhbC1mcmFtZXM9MCBsZXZlbC1p
        ZGM9MCBoaWdoLXRpZXI9MSB1aGQtYmQ9MCByZWY9MyBuby1hbGxvdy1ub24tY29uZm9ybWFuY2Ugbm8tcmVwZWF0LWhlYWRlcnMgYW5uZXhiIG5vLWF1ZCBu
        by1lb2Igbm8tZW9zIG5vLWhyZCBpbmZvIGhhc2g9MCB0ZW1wb3JhbC1sYXllcnM9MCBvcGVuLWdvcCBtaW4ta2V5aW50PTE1IGtleWludD0yNTAgZ29wLWxv
        b2thaGVhZD0wIGJmcmFtZXM9NCBiLWFkYXB0PTIgYi1weXJhbWlkIGJmcmFtZS1iaWFzPTAgcmMtbG9va2FoZWFkPTIwIGxvb2thaGVhZC1zbGljZXM9MCBz
        Y2VuZWN1dD00MCBuby1oaXN0LXNjZW5lY3V0IHJhZGw9MCBuby1zcGxpY2Ugbm8taW50cmEtcmVmcmVzaCBjdHU9NjQgbWluLWN1LXNpemU9OCBuby1yZWN0
        IG5vLWFtcCBtYXgtdHUtc2l6ZT0zMiB0dS1pbnRlci1kZXB0aD0xIHR1LWludHJhLWRlcHRoPTEgbGltaXQtdHU9MCByZG9xLWxldmVsPTAgZHluYW1pYy1y
        ZD0wLjAwIG5vLXNzaW0tcmQgc2lnbmhpZGUgbm8tdHNraXAgbnItaW50cmE9MCBuci1pbnRlcj0wIG5vLWNvbnN0cmFpbmVkLWludHJhIHN0cm9uZy1pbnRy
        YS1zbW9vdGhpbmcgbWF4LW1lcmdlPTMgbGltaXQtcmVmcz0xIG5vLWxpbWl0LW1vZGVzIG1lPTEgc3VibWU9MiBtZXJhbmdlPTU3IHRlbXBvcmFsLW12cCBu
        by1mcmFtZS1kdXAgbm8taG1lIHdlaWdodHAgbm8td2VpZ2h0YiBuby1hbmFseXplLXNyYy1waWNzIGRlYmxvY2s9MDowIHNhbyBuby1zYW8tbm9uLWRlYmxv
        Y2sgcmQ9MyBzZWxlY3RpdmUtc2FvPTQgZWFybHktc2tpcCByc2tpcCBuby1mYXN0LWludHJhIG5vLXRza2lwLWZhc3Qgbm8tY3UtbG9zc2xlc3MgYi1pbnRy
        YSBuby1zcGxpdHJkLXNraXAgcmRwZW5hbHR5PTAgcHN5LXJkPTIuMDAgcHN5LXJkb3E9MC4wMCBuby1yZC1yZWZpbmUgbm8tbG9zc2xlc3MgY2JxcG9mZnM9
        MCBjcnFwb2Zmcz0wIHJjPWNyZiBjcmY9MjguMCBxY29tcD0wLjYwIHFwc3RlcD00IHN0YXRzLXdyaXRlPTAgc3RhdHMtcmVhZD0wIGlwcmF0aW89MS40MCBw
        YnJhdGlvPTEuMzAgYXEtbW9kZT0yIGFxLXN0cmVuZ3RoPTEuMDAgY3V0cmVlIHpvbmUtY291bnQ9MCBuby1zdHJpY3QtY2JyIHFnLXNpemU9MzIgbm8tcmMt
        Z3JhaW4gcXBtYXg9NjkgcXBtaW49MCBuby1jb25zdC12YnYgc2FyPTEgb3ZlcnNjYW49MCB2aWRlb2Zvcm1hdD01IHJhbmdlPTAgY29sb3JwcmltPTIgdHJh
        bnNmZXI9MiBjb2xvcm1hdHJpeD0yIGNocm9tYWxvYz0wIGRpc3BsYXktd2luZG93PTAgY2xsPTAsMCBtaW4tbHVtYT0wIG1heC1sdW1hPTI1NSBsb2cyLW1h
        eC1wb2MtbHNiPTggdnVpLXRpbWluZy1pbmZvIHZ1aS1ocmQtaW5mbyBzbGljZXM9MSBuby1vcHQtcXAtcHBzIG5vLW9wdC1yZWYtbGlzdC1sZW5ndGgtcHBz
        IG5vLW11bHRpLXBhc3Mtb3B0LXJwcyBzY2VuZWN1dC1iaWFzPTAuMDUgbm8tb3B0LWN1LWRlbHRhLXFwIG5vLWFxLW1vdGlvbiBuby1oZHIxMCBuby1oZHIx
        MC1vcHQgbm8tZGhkcjEwLW9wdCBuby1pZHItcmVjb3Zlcnktc2VpIGFuYWx5c2lzLXJldXNlLWxldmVsPTAgYW5hbHlzaXMtc2F2ZS1yZXVzZS1sZXZlbD0w
        IGFuYWx5c2lzLWxvYWQtcmV1c2UtbGV2ZWw9MCBzY2FsZS1mYWN0b3I9MCByZWZpbmUtaW50cmE9MCByZWZpbmUtaW50ZXI9MCByZWZpbmUtbXY9MSByZWZp
        bmUtY3R1LWRpc3RvcnRpb249MCBuby1saW1pdC1zYW8gY3R1LWluZm89MCBuby1sb3dwYXNzLWRjdCByZWZpbmUtYW5hbHlzaXMtdHlwZT0wIGNvcHktcGlj
        PTEgbWF4LWF1c2l6ZS1mYWN0b3I9MS4wIG5vLWR5bmFtaWMtcmVmaW5lIG5vLXNpbmdsZS1zZWkgbm8taGV2Yy1hcSBuby1zdnQgbm8tZmllbGQgcXAtYWRh
        cHRhdGlvbi1yYW5nZT0xLjAwIHNjZW5lY3V0LWF3YXJlLXFwPTBjb25mb3JtYW5jZS13aW5kb3ctb2Zmc2V0cyByaWdodD0wIGJvdHRvbT0wIGRlY29kZXIt
        bWF4LXJhdGU9MCBuby12YnYtbGl2ZS1tdWx0aS1wYXNzIG5vLW1jc3RmIG5vLXNicmMgbm8tZnJhbWUtcmOAAAAACmZpZWwBAAAAABBwYXNwAAAAAQAAAAEA
        AAAQc3R0cwAAAAAAAAAAAAAAEHN0c2MAAAAAAAAAAAAAABRzdHN6AAAAAAAAAAAAAAAAAAAAEHN0Y28AAAAAAAAAAAAAAChtdmV4AAAAIHRyZXgAAAAAAAAA
        AQAAAAEAAAAAAAAAAAAAAAAAAABhdWR0YQAAAFltZXRhAAAAAAAAACFoZGxyAAAAAAAAAABtZGlyYXBwbAAAAAAAAAAAAAAAACxpbHN0AAAAJKl0b28AAAAc
        ZGF0YQAAAAEAAAAATGF2ZjYzLjEuMTAy
        """)

    static func decode(_ text: String) -> Data { Data(base64Encoded: text.filter { !$0.isWhitespace })! }
}

@Suite struct CameraLiveFeedTests {
    @Test func namesTheCodecsOfAnH264AndAACSegment() {
        #expect(CameraLiveFeed.codecs(initSegment: InitSegmentFixtures.h264AAC) == ["avc1.640028", "mp4a.40.2"])
        #expect(CameraLiveFeed.mimeType(initSegment: InitSegmentFixtures.h264AAC) == #"video/mp4; codecs="avc1.640028, mp4a.40.2""#)
    }

    @Test func namesHEVCAsAnnexEWritesIt() {
        #expect(CameraLiveFeed.codecs(initSegment: InitSegmentFixtures.hevc) == ["hvc1.1.6.L60.90"])
        // Profile space, tier, reversed compatibility flags and trailing zero constraint bytes.
        var hvcC: [UInt8] = [1, 0b0110_0010, 0x60, 0, 0, 0, 0xB0, 0, 0, 0, 0, 0, 153]
        #expect(CameraLiveFeed.hevcParameters(hvcC) == "A2.6.H153.B0")
        hvcC[1] = 0b0000_0001
        hvcC[6] = 0
        #expect(CameraLiveFeed.hevcParameters(hvcC) == "1.6.L153")
    }

    @Test func givesNothingForWhatIsNotAnInitSegment() {
        #expect(CameraLiveFeed.mimeType(initSegment: Data()) == nil)
        #expect(CameraLiveFeed.mimeType(initSegment: Data("ftypmoov".utf8)) == nil)
        // Every truncation of a real segment parses without trapping.
        let segment = InitSegmentFixtures.h264AAC
        for length in stride(from: 0, to: segment.count, by: 7) {
            _ = CameraLiveFeed.codecs(initSegment: segment.prefix(length))
        }
        // A media fragment alone has no moov.
        #expect(CameraLiveFeed.codecs(initSegment: Data([0, 0, 0, 8]) + Data("moof".utf8)).isEmpty)
    }

    @Test func cancelsOnce() {
        let count = NIOLockedValueBox(0)
        let (fragments, _) = AsyncThrowingStream.makeStream(of: Data.self)
        let feed = CameraLiveFeed(initSegment: InitSegmentFixtures.h264AAC, fragments: fragments) { count.withLockedValue { $0 += 1 } }
        #expect(feed.mimeType.contains("avc1.640028"))
        feed.cancel()
        feed.cancel()
        #expect(count.withLockedValue { $0 } == 1)
        // A given type wins over the segment's.
        #expect(CameraLiveFeed(mimeType: "video/mp4; codecs=\"avc1.4d401f\"", initSegment: Data(), fragments: fragments) {}.mimeType == "video/mp4; codecs=\"avc1.4d401f\"")
    }
}
