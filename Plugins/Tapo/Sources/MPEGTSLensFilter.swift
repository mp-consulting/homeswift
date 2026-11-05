import Foundation

/// One lens out of the camera's MPEG-TS, as FFmpeg should get it (docs/clean-room/TapoCamera.md, 7): in HD each lens is a
/// program of its own (with the audio in a third), so the filter keeps the `videoIndex`th video stream, its program's
/// PMT and a PAT rewritten to list that program alone, and drops the rest, the misdeclared audio included. Video starts
/// with the first PES that opens on a keyframe, so FFmpeg decodes from its first packet and needs almost no probing:
/// a long probe of the whole TS made it send seconds of backlog at once, which the Home app does not play.
struct MPEGTSLensFilter {
    static let packetSize = 188
    static let videoTypes: Set<UInt8> = [0x1B, 0x24]

    let videoIndex: Int
    private var carry = Data()
    /// The programs in the PAT's order: program number and PMT PID.
    private var programs: [(number: UInt16, pmt: UInt16)] = []
    /// The video streams found, in program order: PMT PID, ES PID, stream type.
    private var videos: [UInt16: (pid: UInt16, type: UInt8)] = [:]
    private var selected: (program: UInt16, pmt: UInt16, pid: UInt16, type: UInt8)?
    private var pat: Data?
    private var started = false

    init(videoIndex: Int) { self.videoIndex = videoIndex }

    /// Whether the video has begun (a keyframe went out).
    var hasStarted: Bool { started }

    /// The packets to pass on from `data`, which may split packets anywhere.
    mutating func filter(_ data: Data) -> Data {
        carry.append(data)
        var out = Data()
        var index = carry.startIndex
        while carry.endIndex - index >= Self.packetSize {
            guard carry[index] == 0x47 else {
                // Lost sync: find the next sync byte.
                index = carry[(index + 1)...].firstIndex(of: 0x47) ?? carry.endIndex
                continue
            }
            let packet = carry[index..<(index + Self.packetSize)]
            index += Self.packetSize
            if let kept = handle(Data(packet)) { out.append(kept) }
        }
        carry = Data(carry[index...])
        return out
    }

    private mutating func handle(_ packet: Data) -> Data? {
        let bytes = [UInt8](packet)
        let pid = UInt16(bytes[1] & 0x1F) << 8 | UInt16(bytes[2])
        let unitStart = bytes[1] & 0x40 != 0
        let adaptation = (bytes[3] >> 4) & 0x3
        var payload = 4
        if adaptation == 2 || adaptation == 3 { payload += 1 + Int(bytes[4]) }
        guard adaptation != 2, payload < Self.packetSize else {
            return pid == selected?.pid && started ? packet : nil
        }
        if pid == 0 {
            if unitStart, let section = Self.section(bytes, from: payload) { readPAT(section) }
            return started ? pat : nil
        }
        if let index = programs.firstIndex(where: { $0.pmt == pid }) {
            if unitStart, let section = Self.section(bytes, from: payload) { readPMT(section, pmt: pid, programIndex: index) }
            return pid == selected?.pmt && started ? packet : nil
        }
        guard let selected, pid == selected.pid else { return nil }
        if !started {
            guard unitStart, Self.opensOnKeyframe(bytes, from: payload, type: selected.type), let pat else { return nil }
            started = true
            // The tables first, so FFmpeg knows the stream before its first frame.
            return pat + (pmtPacket ?? Data()) + packet
        }
        return packet
    }

    private var pmtPacket: Data?

    /// A PSI section's bytes (table id onwards) when it fits in this packet.
    static func section(_ bytes: [UInt8], from payload: Int) -> [UInt8]? {
        let pointer = Int(bytes[payload])
        let start = payload + 1 + pointer
        guard start + 3 <= bytes.count else { return nil }
        let length = Int(bytes[start + 1] & 0x0F) << 8 | Int(bytes[start + 2])
        guard start + 3 + length <= bytes.count, length >= 9 else { return nil }
        return Array(bytes[start..<(start + 3 + length)])
    }

    private mutating func readPAT(_ section: [UInt8]) {
        guard section[0] == 0x00 else { return }
        var found: [(UInt16, UInt16)] = []
        var offset = 8
        while offset + 4 <= section.count - 4 {
            let number = UInt16(section[offset]) << 8 | UInt16(section[offset + 1])
            let pmt = UInt16(section[offset + 2] & 0x1F) << 8 | UInt16(section[offset + 3])
            if number != 0 { found.append((number, pmt)) }
            offset += 4
        }
        patVersion = section[5] & 0x3E
        if found.map(\.0) != programs.map(\.number) || found.map(\.1) != programs.map(\.pmt) {
            programs = found.map { (number: $0.0, pmt: $0.1) }
        }
        choose()
    }

    private mutating func readPMT(_ section: [UInt8], pmt: UInt16, programIndex: Int) {
        guard section[0] == 0x02, section.count >= 16 else { return }
        let infoLength = Int(section[10] & 0x0F) << 8 | Int(section[11])
        var offset = 12 + infoLength
        var video: (pid: UInt16, type: UInt8)?
        while offset + 5 <= section.count - 4 {
            let type = section[offset]
            let pid = UInt16(section[offset + 1] & 0x1F) << 8 | UInt16(section[offset + 2])
            let esInfo = Int(section[offset + 3] & 0x0F) << 8 | Int(section[offset + 4])
            if Self.videoTypes.contains(type), video == nil { video = (pid, type) }
            offset += 5 + esInfo
        }
        if let video { videos[pmt] = video }
        pmtSections[pmt] = section
        choose()
    }

    /// The `videoIndex`th video stream, counting programs in the PAT's order, once every program's PMT has been read.
    private mutating func choose() {
        guard selected == nil, !programs.isEmpty, programs.allSatisfy({ pmtSections[$0.pmt] != nil }) else { return }
        let withVideo = programs.compactMap { program in videos[program.pmt].map { (program, $0) } }
        guard withVideo.indices.contains(videoIndex) else { return }
        let (program, video) = withVideo[videoIndex]
        selected = (program.number, program.pmt, video.pid, video.type)
        pat = Self.patPacket(program: program.number, pmt: program.pmt, version: patVersion)
        pmtPacket = pmtSections[program.pmt].map { Self.packet(pid: program.pmt, section: $0) }
    }

    private var pmtSections: [UInt16: [UInt8]] = [:]
    private var patVersion: UInt8 = 0

    /// Whether a PES opens on a keyframe: an HEVC VPS, SPS or IRAP picture, or an H.264 SPS or IDR, in its first bytes.
    static func opensOnKeyframe(_ bytes: [UInt8], from payload: Int, type: UInt8) -> Bool {
        guard payload + 9 <= bytes.count, bytes[payload] == 0, bytes[payload + 1] == 0, bytes[payload + 2] == 1 else { return false }
        var index = payload + 9 + Int(bytes[payload + 8])
        while index + 3 < bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                let header = bytes[index + 3]
                if type == 0x24 {
                    let nal = (header >> 1) & 0x3F
                    if nal == 32 || nal == 33 || (16...21).contains(nal) { return true }
                    if nal < 32 { return false }
                } else {
                    let nal = header & 0x1F
                    if nal == 7 || nal == 5 { return true }
                    if nal == 1 { return false }
                }
                index += 3
            } else {
                index += 1
            }
        }
        return false
    }

    /// A PAT listing one program, in a packet of its own.
    static func patPacket(program: UInt16, pmt: UInt16, version: UInt8) -> Data {
        var section: [UInt8] = [0x00, 0xB0, 0x0D, 0x00, 0x01, version | 0xC1, 0x00, 0x00,
                                UInt8(program >> 8), UInt8(program & 0xFF), 0xE0 | UInt8(pmt >> 8), UInt8(pmt & 0xFF)]
        section += crc32(section).bigEndianBytes
        return packet(pid: 0, section: section)
    }

    /// A PSI section in one packet, with a pointer field and stuffing.
    static func packet(pid: UInt16, section: [UInt8]) -> Data {
        var bytes: [UInt8] = [0x47, 0x40 | UInt8(pid >> 8), UInt8(pid & 0xFF), 0x10, 0x00] + section
        bytes += [UInt8](repeating: 0xFF, count: max(0, packetSize - bytes.count))
        return Data(bytes.prefix(packetSize))
    }

    /// CRC-32/MPEG-2 of a PSI section.
    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte) << 24
            for _ in 0..<8 { crc = crc & 0x8000_0000 != 0 ? (crc << 1) ^ 0x04C1_1DB7 : crc << 1 }
        }
        return crc
    }
}

extension UInt32 {
    var bigEndianBytes: [UInt8] { [UInt8(self >> 24), UInt8(self >> 16 & 0xFF), UInt8(self >> 8 & 0xFF), UInt8(self & 0xFF)] }
}
