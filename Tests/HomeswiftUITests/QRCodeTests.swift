import Foundation
import Testing
#if canImport(CoreImage)
import CoreImage
#endif

@testable import HomeswiftUI

@Suite struct QRCodeTests {
    @Test func encodesASetupURI() throws {
        let code = try QRCode("X-HM://0023ISYWYGYD8")
        #expect(code.version == 2)
        #expect(code.size == 25)
        // The top-left finder: a dark 7x7 ring around a dark 3x3 centre, then a light separator.
        #expect(code.modules[0][0..<7].allSatisfy { $0 })
        #expect(Array(code.modules[1][1..<6]) == [false, false, false, false, false])
        #expect(Array(code.modules[2][2..<5]) == [true, true, true])
        #expect(!code.modules[7][0..<8].contains(true))
        #expect(code.modules[code.size - 8][8])
        let svg = code.svg()
        #expect(svg.hasPrefix("<svg "))
        #expect(svg.contains("viewBox=\"0 0 31 31\""))
        #expect(QRCode.capacity(version: 1) == 14)
        #expect(QRCode.capacity(version: 6) == 106)
        #expect(try QRCode(String(repeating: "x", count: 106)).version == 6)
        #expect(throws: QRCode.Error.tooLong(maximum: 106)) { try QRCode(String(repeating: "x", count: 107)) }
    }

    #if canImport(CoreImage)
    @Test func decodesWithCoreImage() throws {
        let payloads = [
            "X-HM://0023ISYWYGYD8",
            "https://example.com/a-longer-payload-that-needs-version-four?with=a-query&and=more-text",
            String(repeating: "Homeswift ", count: 10),
        ]
        for text in payloads {
            let code = try QRCode(text)
            #expect(Self.decode(code) == text, "version \(code.version), mask \(code.mask)")
        }
    }

    /// Draws the modules as a grey bitmap and reads it back with Core Image's detector.
    static func decode(_ code: QRCode) -> String? {
        let scale = 8, quiet = 4
        let size = (code.size + 2 * quiet) * scale
        var pixels = [UInt8](repeating: 255, count: size * size)
        for row in 0..<code.size {
            for column in 0..<code.size where code.modules[row][column] {
                for dy in 0..<scale {
                    for dx in 0..<scale { pixels[((row + quiet) * scale + dy) * size + (column + quiet) * scale + dx] = 0 }
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(
                width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: size, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        return detector?.features(in: CIImage(cgImage: image)).compactMap { ($0 as? CIQRCodeFeature)?.messageString }.first
    }
    #endif
}
