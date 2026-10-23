import Foundation

/// Light scenes, DIY effects and music mode as the frames both the AWS `ptReal` command and the BLE control
/// characteristic take: a port of the Homebridge plugin's `utils/scene-codes.ts`, itself a port of the Govee
/// app's `MultipleControllerCommV1.makeSendBytesV2()`, so the bytes are the ones the app writes.
///
/// Applying a scene is two steps: the effect payload as an `0xA3` multi-packet sequence, then a single
/// `0x33 0x05 0x04 <scene code, little-endian>` frame that activates it.
enum SceneCodes {
    static let protocolMulti: UInt8 = 0xA3
    static let protocolWrite: UInt8 = 0x33
    static let commandMode: UInt8 = 0x05

    static let subModeScene: UInt8 = 0x04
    static let subModeDIY: UInt8 = 0x0A
    static let subModeMusicLegacy: UInt8 = 0x0C
    static let subModeMusicModern: UInt8 = 0x13

    static let frameLength = 20
    static let continuationPayload = 17

    /// `CategoryV1.LightEffect.sceneType` in the Govee app.
    enum SceneType: Int, Sendable {
        case `static` = 0, rgb, rgbic, graffiti, cube, diy, compose
    }

    /// The command-type byte the app uses for each payload kind (`MultiNewScenesControllerV*`).
    static func commandType(_ type: Int) -> UInt8? {
        switch SceneType(rawValue: type) {
        case .rgb: 0x01
        case .rgbic: 0x02
        case .cube: 0x04
        case .graffiti: 0x07
        case .diy, .compose: 0x0A
        default: nil
        }
    }

    /// The XOR checksum of the app (`BleUtils.getBCC()`) over the first `length` bytes.
    static func bcc(_ frame: [UInt8], length: Int = 19) -> UInt8 {
        var checksum = frame[0]
        for index in 1..<length { checksum ^= frame[index] }
        return checksum
    }

    /// A 20-byte write frame: protocol, command type, data, checksum.
    static func singleFrame(_ protocolByte: UInt8, _ commandType: UInt8, _ data: [Int] = []) -> [UInt8] {
        var frame = [UInt8](repeating: 0, count: frameLength)
        frame[0] = protocolByte
        frame[1] = commandType
        for (index, byte) in data.enumerated() where 2 + index < frameLength - 1 { frame[2 + index] = UInt8(truncatingIfNeeded: byte) }
        frame[frameLength - 1] = bcc(frame)
        return frame
    }

    /// Splits a payload into the app's multi-packet sequence: an opening frame (`0x01`, the frame count, the
    /// header, as much payload as fits), continuation frames of 17 bytes numbered from 1, and a final
    /// frame numbered `0xFF` that carries the tail.
    static func multiPacketFrames(_ protocolByte: UInt8, header: [UInt8], payload: [UInt8]) -> [[UInt8]] {
        var frames: [[UInt8]] = []
        var first = [UInt8](repeating: 0, count: frameLength)
        first[0] = protocolByte
        first[1] = 0x00
        first[2] = 0x01
        for (index, byte) in header.enumerated() { first[4 + index] = byte }
        var last = [UInt8](repeating: 0, count: frameLength)
        last[0] = protocolByte
        last[1] = 0xFF

        let firstDataOffset = header.count + 4
        let firstCapacity = 15 - header.count
        var frameCount = 2

        if payload.count <= firstCapacity {
            for (index, byte) in payload.enumerated() { first[firstDataOffset + index] = byte }
        } else {
            let remaining = payload.count - firstCapacity
            var finalChunkLength = remaining % continuationPayload
            let chunkCount = remaining / continuationPayload + (finalChunkLength > 0 ? 1 : 0)
            if finalChunkLength == 0 { finalChunkLength = continuationPayload }
            frameCount = chunkCount + 1
            for index in 0..<firstCapacity { first[firstDataOffset + index] = payload[index] }

            var offset = firstCapacity
            for index in 1...chunkCount {
                let isFinal = index == chunkCount
                let size = isFinal ? finalChunkLength : continuationPayload
                var chunk = [UInt8](repeating: 0, count: continuationPayload)
                for position in 0..<size { chunk[position] = payload[offset + position] }
                offset += size
                if isFinal {
                    for (position, byte) in chunk.enumerated() { last[2 + position] = byte }
                } else {
                    var middle = [UInt8](repeating: 0, count: frameLength)
                    middle[0] = protocolByte
                    middle[1] = UInt8(truncatingIfNeeded: index)
                    for (position, byte) in chunk.enumerated() { middle[2 + position] = byte }
                    middle[frameLength - 1] = bcc(middle)
                    frames.append(middle)
                }
            }
        }

        first[3] = UInt8(truncatingIfNeeded: frameCount)
        first[frameLength - 1] = bcc(first)
        frames.insert(first, at: 0)
        last[frameLength - 1] = bcc(last)
        frames.append(last)
        return frames
    }

    /// The RGBIC layout (a count of sub-effects, each prefixed with its length): `ScenesRgbIC.isValidProtocolBytes()`.
    static func looksLikeRGBIC(_ payload: [UInt8]) -> Bool {
        guard payload.count >= 2 else { return false }
        let effectCount = Int(payload[0])
        guard effectCount > 0 else { return false }
        var offset = 1
        var consumed = 1
        for _ in 0..<effectCount {
            guard offset < payload.count else { return false }
            let effectLength = Int(payload[offset])
            consumed += effectLength + 1
            guard consumed <= payload.count else { return false }
            offset += 1 + effectLength
        }
        return consumed == payload.count
    }

    static func detectSceneType(_ payload: [UInt8]) -> Int {
        looksLikeRGBIC(payload) ? SceneType.rgbic.rawValue : SceneType.rgb.rawValue
    }

    /// The base64 frames that apply a scene of the library. A static scene, or one without a payload, is the
    /// activation frame alone.
    static func encodeScene(scenceParam: String, sceneCode: Int, sceneType: Int? = nil) -> [String] {
        let activation = singleFrame(protocolWrite, commandMode, [Int(subModeScene), sceneCode & 0xFF, (sceneCode >> 8) & 0xFF])
        let payload = scenceParam.isEmpty ? [] : Govee.bytes(base64: scenceParam)
        guard !payload.isEmpty, sceneType != SceneType.static.rawValue else { return [base64(activation)] }
        let type = sceneType ?? detectSceneType(payload)
        // An unknown kind: activating by code alone still works on devices that hold the effect.
        guard let commandType = commandType(type) else { return [base64(activation)] }
        // Graffiti payloads carry a two-byte prefix the app strips before framing.
        let body = type == SceneType.graffiti.rawValue && payload.count > 2 ? Array(payload.dropFirst(2)) : payload
        return multiPacketFrames(protocolMulti, header: [commandType], payload: body).map(base64) + [base64(activation)]
    }

    /// A DIY effect: the same transfer, activated through the DIY sub-mode.
    static func encodeDIY(effect: String, code: Int) -> [String] {
        let activation = singleFrame(protocolWrite, commandMode, [Int(subModeDIY), code & 0xFF, (code >> 8) & 0xFF])
        let payload = effect.isEmpty ? [] : Govee.bytes(base64: effect)
        guard !payload.isEmpty else { return [base64(activation)] }
        return multiPacketFrames(protocolMulti, header: [commandType(SceneType.diy.rawValue)!], payload: payload).map(base64) + [base64(activation)]
    }

    // MARK: Music

    enum MusicProtocol: String, Sendable { case modern, legacy }
    enum MusicEffect: String, Sendable, CaseIterable { case energic, rolling, spectrum, rhythm }

    struct MusicMode: Sendable, Equatable {
        var effect: MusicEffect
        /// 0 to 100.
        var sensitivity: Int
        /// The device picks the colours; otherwise `colour` is applied.
        var autoColour: Bool
        var colour: RGB?
        /// Rhythm only: the soft rather than the power variant.
        var soft = false
        var musicProtocol: MusicProtocol = .modern
    }

    static func effectCode(_ effect: MusicEffect, _ musicProtocol: MusicProtocol) -> Int {
        switch (musicProtocol, effect) {
        case (.modern, .rhythm): 3
        case (.modern, .spectrum): 4
        case (.modern, .energic): 5
        case (.modern, .rolling): 6
        case (.legacy, .energic): 0
        case (.legacy, .rolling): 2
        case (.legacy, .spectrum): 3
        case (.legacy, .rhythm): 5
        }
    }

    /// The music-mode frame. Both generations send the sub-mode, the effect, the sensitivity, then a colour
    /// flag (1 and the colour, or 0 to let the device choose); rhythm adds a soft/power byte whose sense is
    /// inverted between them, and legacy energic stops after the sensitivity.
    static func encodeMusicMode(_ mode: MusicMode) -> [String] {
        let subMode = Int(mode.musicProtocol == .legacy ? subModeMusicLegacy : subModeMusicModern)
        let effect = effectCode(mode.effect, mode.musicProtocol)
        let sensitivity = min(max(mode.sensitivity, 0), 100)
        let manual = mode.autoColour ? 0 : 1
        let colour = mode.colour ?? RGB(0, 0, 0)
        let colourBytes = manual == 1 ? [manual, colour.r, colour.g, colour.b] : [manual]
        let data: [Int]
        switch (mode.musicProtocol, mode.effect) {
        case (.legacy, .energic): data = [subMode, effect, sensitivity]
        case (.legacy, .rhythm): data = [subMode, effect, sensitivity, mode.soft ? 0 : 1] + colourBytes
        case (.modern, .rhythm): data = [subMode, effect, sensitivity, mode.soft ? 1 : 0] + colourBytes
        default: data = [subMode, effect, sensitivity] + colourBytes
        }
        return [base64(singleFrame(protocolWrite, commandMode, data))]
    }

    // MARK: Codes in config.json

    /// Frames joined with commas, as config.json and the AWS `ptReal` payload hold them.
    static func framesToCode(_ frames: [String]) -> String { frames.joined(separator: ",") }

    static func codeToFrames(_ code: String) -> [String] {
        code.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func base64(_ frame: [UInt8]) -> String { Data(frame).base64EncodedString() }
}
