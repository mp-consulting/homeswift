import Foundation
import Testing

@testable import HomeswiftFFmpeg

// A trun fullbox with the given flags, sample count and trailing fields.
private func trun(_ flags: UInt32, _ sampleCount: UInt32, _ fields: [UInt32]) -> Data {
    var body = Data()
    for value in [flags & 0x00FF_FFFF, sampleCount] + fields {
        body.append(contentsOf: [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
    }
    return box("trun", body)
}

// An hdlr fullbox: version/flags, pre_defined, handler_type, reserved, name.
private func hdlr(_ handlerType: String) -> Data {
    var body = Data(count: 24)
    body.replaceSubrange(8..<12, with: Array(handlerType.utf8))
    return box("hdlr", body)
}

private let TRUN_DATA_OFFSET: UInt32 = 0x000001
private let TRUN_FIRST_SAMPLE_FLAGS: UInt32 = 0x000004
private let TRUN_SAMPLE_DURATION: UInt32 = 0x000100
private let TRUN_SAMPLE_SIZE: UInt32 = 0x000200
private let TRUN_SAMPLE_FLAGS: UInt32 = 0x000400
private let SAMPLE_NON_SYNC: UInt32 = 0x0001_0000

@Suite struct FindBoxTests {
    let layout = box("ftyp", bytes(4)) + box("moov", box("trak", bytes(2))) + box("moof", bytes(1))

    @Test func locatesTopLevelBoxes() {
        let moov = findBox(layout, "moov")
        #expect(moov?.size == BOX_HEADER_SIZE + BOX_HEADER_SIZE + 2)
        #expect(findBox(layout, "moof")?.offset == layout.count - BOX_HEADER_SIZE - 1)
    }

    @Test func respectsSearchRanges() throws {
        let moov = try #require(findBox(layout, "moov"))
        #expect(findBox(layout, "trak", start: moov.offset + BOX_HEADER_SIZE, end: moov.offset + moov.size) != nil)
        // Outside the range, nothing.
        #expect(findBox(layout, "trak") == nil)
    }

    @Test func returnsNilForAbsentTypesAndMalformedSizes() {
        #expect(findBox(layout, "mdat") == nil)
        var malformed = Data(count: BOX_HEADER_SIZE)
        malformed[3] = 3
        malformed.replaceSubrange(4..<8, with: Array("free".utf8))
        #expect(findBox(malformed, "free") == nil)
        #expect(findBox(layout, "toolong") == nil)
    }

    @Test func worksOnSlices() {
        // Offsets are relative to the start of the data, whatever its indices.
        let padded = bytes(5, 0xFF) + layout
        let slice = padded[5...]
        #expect(findBox(slice, "moof")?.offset == layout.count - BOX_HEADER_SIZE - 1)
        #expect(splitMoofMdat(Data(slice)) == nil)
    }
}

@Suite struct IsKeyframeTests {
    private func segment(_ trunBox: Data) -> Data { box("moof", box("traf", trunBox)) + box("mdat", bytes(4)) }

    @Test func detectsASyncSampleViaFirstSampleFlags() {
        #expect(isKeyframe(segment(trun(TRUN_DATA_OFFSET | TRUN_FIRST_SAMPLE_FLAGS, 1, [0, 0x0200_0000]))))
        #expect(!isKeyframe(segment(trun(TRUN_DATA_OFFSET | TRUN_FIRST_SAMPLE_FLAGS, 1, [0, SAMPLE_NON_SYNC]))))
    }

    @Test func fallsBackToPerSampleFlags() {
        let flags = TRUN_SAMPLE_DURATION | TRUN_SAMPLE_SIZE | TRUN_SAMPLE_FLAGS
        #expect(isKeyframe(segment(trun(flags, 1, [1000, 512, 0]))))
        #expect(!isKeyframe(segment(trun(flags, 1, [1000, 512, SAMPLE_NON_SYNC]))))
    }

    @Test func returnsFalseWhenTheHierarchyOrFlagsAreMissing() {
        #expect(!isKeyframe(bytes(16)))
        #expect(!isKeyframe(segment(trun(0, 1, []))))
        #expect(!isKeyframe(box("moof", bytes(4))))
        // first_sample_flags announced but missing.
        #expect(!isKeyframe(segment(trun(TRUN_FIRST_SAMPLE_FLAGS, 1, []))))
    }
}

@Suite struct HasAudioTrackTests {
    @Test func detectsAudioHandlersAcrossTracks() {
        let videoTrak = box("trak", box("mdia", hdlr("vide")))
        let audioTrak = box("trak", box("mdia", hdlr("soun")))
        #expect(hasAudioTrack(box("moov", videoTrak + audioTrak)))
        #expect(!hasAudioTrack(box("moov", videoTrak)))
        #expect(!hasAudioTrack(bytes(8)))
    }
}

@Suite struct SplitMoofMdatTests {
    @Test func splitsAFragment() throws {
        let moofBox = box("moof", box("traf", trun(TRUN_FIRST_SAMPLE_FLAGS, 1, [0x0200_0000])))
        let mdatBox = box("mdat", Data("framedata".utf8))
        let result = try #require(splitMoofMdat(moofBox + mdatBox))
        #expect(result.moof == moofBox)
        #expect(result.mdat == mdatBox)
    }

    @Test func returnsNilWithoutMdat() {
        #expect(splitMoofMdat(box("moof", bytes(4))) == nil)
        #expect(splitMoofMdat(Data()) == nil)
    }
}

@Suite struct FMp4BoxReaderTests {
    let stream = box("ftyp", Data("iso5".utf8)) + box("moov", bytes(37, 1)) + box("moof", bytes(19, 2)) + box("mdat", bytes(301, 3)) + box("free", Data())

    // Feeds the stream in chunks of the given sizes (cycling), returning every box produced.
    private func feed(_ input: Data, _ sizes: [Int]) -> (boxes: [FMp4ParsedBox], ok: Bool) {
        var reader = FMp4BoxReader()
        var boxes: [FMp4ParsedBox] = []
        var ok = true
        var offset = 0
        var index = 0
        while offset < input.count {
            let size = sizes[index % sizes.count]
            let chunk = input.rebased(offset, min(offset + size, input.count))
            ok = reader.push(chunk) { boxes.append($0) } && ok
            offset += size
            index += 1
        }
        return (boxes, ok)
    }

    private func reassemble(_ boxes: [FMp4ParsedBox]) -> Data {
        boxes.reduce(into: Data()) { $0 += $1.header + $1.data }
    }

    @Test func parsesASingleChunk() {
        let (boxes, ok) = feed(stream, [stream.count])
        #expect(ok)
        #expect(Array(boxes.map(\.type)[1...3]) == [BOX_TYPE_MOOV, BOX_TYPE_MOOF, BOX_TYPE_MDAT])
        #expect(boxes.map(\.length) == [4, 37, 19, 301, 0])
        #expect(reassemble(boxes) == stream)
    }

    @Test func reassemblesBoxesSplitAtEveryChunkSize() {
        for size in 1...64 {
            let (boxes, ok) = feed(stream, [size])
            #expect(ok)
            #expect(boxes.count == 5, "chunk size \(size)")
            #expect(reassemble(boxes) == stream, "chunk size \(size)")
        }
    }

    @Test func reassemblesBoxesSplitAtIrregularOffsets() {
        let (boxes, _) = feed(stream, [3, 1, 7, 2, 50, 5, 200, 1, 13])
        #expect(boxes.count == 5)
        #expect(reassemble(boxes) == stream)
    }

    @Test func flagsABoxSizeBelowTheHeaderSizeAsCorruption() {
        var corrupt = Data(count: BOX_HEADER_SIZE)
        corrupt.replaceSubrange(4..<8, with: Array("free".utf8))
        var reader = FMp4BoxReader()
        var boxes: [FMp4ParsedBox] = []
        // A valid box ahead of the corruption is still delivered.
        #expect(reader.push(box("ftyp", bytes(4)) + corrupt.prefix(3)) { boxes.append($0) })
        #expect(!reader.push(corrupt.rebased(3, corrupt.count)) { boxes.append($0) })
        #expect(reader.invalidBoxSize == 0)
        #expect(boxes.count == 1)
        reader.reset()
        #expect(reader.invalidBoxSize == nil)
    }
}
