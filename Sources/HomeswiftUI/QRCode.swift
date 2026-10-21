import Foundation

/// A QR code (ISO/IEC 18004) for short text: byte mode, versions 1 to 6, error correction level M. Enough
/// for a HomeKit setup URI, which the Home app's camera reads; `svg()` draws it.
public struct QRCode: Sendable, Equatable {
    public enum Error: Swift.Error, Equatable { case tooLong(maximum: Int) }

    /// Modules per side.
    public let size: Int
    public let version: Int
    public let mask: Int
    /// `modules[row][column]`, true for dark.
    public let modules: [[Bool]]

    /// Level M, versions 1 to 6: data codewords, EC codewords per block, and the number of equal blocks.
    private static let table: [(data: Int, ec: Int, blocks: Int)] = [
        (16, 10, 1), (28, 16, 1), (44, 26, 1), (64, 18, 2), (86, 24, 2), (108, 16, 4),
    ]
    private static let alignment: [[Int]] = [[], [6, 18], [6, 22], [6, 26], [6, 30], [6, 34]]

    /// The most bytes a version can carry in byte mode.
    static func capacity(version: Int) -> Int {
        (table[version - 1].data * 8 - 12) / 8
    }

    public init(_ text: String) throws {
        let bytes = Array(text.utf8)
        guard let version = (1...Self.table.count).first(where: { Self.capacity(version: $0) >= bytes.count }) else {
            throw Error.tooLong(maximum: Self.capacity(version: Self.table.count))
        }
        self.version = version
        size = 17 + 4 * version
        let codewords = Self.interleave(Self.encode(bytes, version: version), version: version)

        var template = Matrix(size: size)
        template.drawFunctionPatterns(version: version)
        template.placeData(codewords)
        let best = (0..<8).map { mask -> (penalty: Int, matrix: Matrix, mask: Int) in
            var candidate = template
            candidate.applyMask(mask)
            candidate.drawFormat(mask: mask)
            return (candidate.penalty(), candidate, mask)
        }.min { $0.penalty < $1.penalty }!
        self.mask = best.mask
        modules = best.matrix.modules
    }

    /// The code as an SVG image: dark modules on white, with a quiet zone, crisp at any size.
    public func svg(quietZone: Int = 3) -> String {
        let total = size + 2 * quietZone
        var path = ""
        for row in 0..<size {
            for column in 0..<size where modules[row][column] {
                path += "M\(column + quietZone) \(row + quietZone)h1v1h-1z"
            }
        }
        return "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 \(total) \(total)\" shape-rendering=\"crispEdges\" role=\"img\" aria-label=\"QR code\">"
            + "<rect width=\"\(total)\" height=\"\(total)\" fill=\"#fff\"/><path fill=\"#111\" d=\"\(path)\"/></svg>"
    }

    // MARK: Encoding

    /// Byte mode: mode, count, the bytes, a terminator, then padding to the version's data capacity.
    static func encode(_ bytes: [UInt8], version: Int) -> [UInt8] {
        let dataCodewords = table[version - 1].data
        var bits = BitWriter()
        bits.append(0b0100, count: 4)
        bits.append(bytes.count, count: 8)
        for byte in bytes { bits.append(Int(byte), count: 8) }
        bits.append(0, count: min(4, dataCodewords * 8 - bits.count))
        while bits.count % 8 != 0 { bits.append(0, count: 1) }
        var pad = 0xEC
        while bits.count < dataCodewords * 8 {
            bits.append(pad, count: 8)
            pad ^= 0xEC ^ 0x11
        }
        return bits.bytes
    }

    /// Splits the data into equal blocks, appends each block's Reed-Solomon codewords, and interleaves them.
    static func interleave(_ data: [UInt8], version: Int) -> [UInt8] {
        let entry = table[version - 1]
        let length = entry.data / entry.blocks
        let blocks = (0..<entry.blocks).map { Array(data[$0 * length..<($0 + 1) * length]) }
        let divisor = ReedSolomon.divisor(degree: entry.ec)
        let ecs = blocks.map { ReedSolomon.remainder(of: $0, divisor: divisor) }
        var result: [UInt8] = []
        result.reserveCapacity(entry.data + entry.blocks * entry.ec)
        for index in 0..<length {
            for block in blocks { result.append(block[index]) }
        }
        for index in 0..<entry.ec {
            for ec in ecs { result.append(ec[index]) }
        }
        return result
    }

    struct BitWriter {
        var bytes: [UInt8] = []
        var count = 0
        mutating func append(_ value: Int, count: Int) {
            for index in stride(from: count - 1, through: 0, by: -1) {
                if self.count % 8 == 0 { bytes.append(0) }
                if (value >> index) & 1 == 1 { bytes[bytes.count - 1] |= UInt8(0x80 >> (self.count % 8)) }
                self.count += 1
            }
        }
    }

    enum ReedSolomon {
        /// The generator polynomial of this degree, highest power first, without its leading 1.
        static func divisor(degree: Int) -> [UInt8] {
            var result = [UInt8](repeating: 0, count: degree)
            result[degree - 1] = 1
            var root: UInt8 = 1
            for _ in 0..<degree {
                for index in 0..<degree {
                    result[index] = multiply(result[index], root)
                    if index + 1 < degree { result[index] ^= result[index + 1] }
                }
                root = multiply(root, 0x02)
            }
            return result
        }

        static func remainder(of data: [UInt8], divisor: [UInt8]) -> [UInt8] {
            var result = [UInt8](repeating: 0, count: divisor.count)
            for byte in data {
                let factor = byte ^ result.removeFirst()
                result.append(0)
                for index in result.indices { result[index] ^= multiply(divisor[index], factor) }
            }
            return result
        }

        /// GF(2^8) with the QR polynomial 0x11D.
        static func multiply(_ x: UInt8, _ y: UInt8) -> UInt8 {
            var z = 0
            for index in stride(from: 7, through: 0, by: -1) {
                z = (z << 1) ^ ((z >> 7) * 0x11D)
                z ^= ((Int(y) >> index) & 1) * Int(x)
            }
            return UInt8(z & 0xFF)
        }
    }

    // MARK: The matrix

    struct Matrix {
        let size: Int
        var modules: [[Bool]]
        /// Function modules (finders, timing, alignment, format) are never masked and hold no data.
        var isFunction: [[Bool]]

        init(size: Int) {
            self.size = size
            modules = Array(repeating: Array(repeating: false, count: size), count: size)
            isFunction = modules
        }

        mutating func setFunction(_ column: Int, _ row: Int, _ dark: Bool) {
            modules[row][column] = dark
            isFunction[row][column] = true
        }

        mutating func drawFunctionPatterns(version: Int) {
            for index in 0..<size {
                setFunction(6, index, index % 2 == 0)
                setFunction(index, 6, index % 2 == 0)
            }
            drawFinder(3, 3)
            drawFinder(size - 4, 3)
            drawFinder(3, size - 4)
            let positions = QRCode.alignment[version - 1]
            for (i, x) in positions.enumerated() {
                for (j, y) in positions.enumerated() {
                    // Not over the three finders.
                    if (i == 0 && j == 0) || (i == 0 && j == positions.count - 1) || (i == positions.count - 1 && j == 0) { continue }
                    for dy in -2...2 {
                        for dx in -2...2 { setFunction(x + dx, y + dy, max(abs(dx), abs(dy)) != 1) }
                    }
                }
            }
            drawFormat(mask: 0)   // reserves the modules; the final bits come with the chosen mask
        }

        private mutating func drawFinder(_ x: Int, _ y: Int) {
            for dy in -4...4 {
                for dx in -4...4 {
                    let distance = max(abs(dx), abs(dy))
                    let column = x + dx, row = y + dy
                    if (0..<size).contains(column), (0..<size).contains(row) {
                        setFunction(column, row, distance != 2 && distance != 4)
                    }
                }
            }
        }

        /// The 15 format bits: level M (00) and the mask, BCH-coded and XOR-masked, in both places.
        mutating func drawFormat(mask: Int) {
            let data = mask   // level M contributes 00 above the three mask bits
            var remainder = data
            for _ in 0..<10 { remainder = (remainder << 1) ^ ((remainder >> 9) * 0x537) }
            let bits = ((data << 10) | remainder) ^ 0x5412
            func bit(_ index: Int) -> Bool { (bits >> index) & 1 == 1 }
            for index in 0..<6 { setFunction(8, index, bit(index)) }
            setFunction(8, 7, bit(6))
            setFunction(8, 8, bit(7))
            setFunction(7, 8, bit(8))
            for index in 9..<15 { setFunction(14 - index, 8, bit(index)) }
            for index in 0..<8 { setFunction(size - 1 - index, 8, bit(index)) }
            for index in 8..<15 { setFunction(8, size - 15 + index, bit(index)) }
            setFunction(8, size - 8, true)
        }

        /// Codeword bits in the zigzag: two-module columns from the right, up then down, skipping column 6.
        mutating func placeData(_ data: [UInt8]) {
            var bitIndex = 0
            var right = size - 1
            while right >= 1 {
                if right == 6 { right = 5 }
                for vertical in 0..<size {
                    for offset in 0..<2 {
                        let column = right - offset
                        let upward = ((right + 1) & 2) == 0
                        let row = upward ? size - 1 - vertical : vertical
                        if !isFunction[row][column], bitIndex < data.count * 8 {
                            modules[row][column] = (data[bitIndex >> 3] >> (7 - (bitIndex & 7))) & 1 == 1
                            bitIndex += 1
                        }
                    }
                }
                right -= 2
            }
        }

        mutating func applyMask(_ mask: Int) {
            for row in 0..<size {
                for column in 0..<size where !isFunction[row][column] {
                    let x = column, y = row
                    let invert: Bool
                    switch mask {
                    case 0: invert = (x + y) % 2 == 0
                    case 1: invert = y % 2 == 0
                    case 2: invert = x % 3 == 0
                    case 3: invert = (x + y) % 3 == 0
                    case 4: invert = (x / 3 + y / 2) % 2 == 0
                    case 5: invert = x * y % 2 + x * y % 3 == 0
                    case 6: invert = (x * y % 2 + x * y % 3) % 2 == 0
                    default: invert = ((x + y) % 2 + x * y % 3) % 2 == 0
                    }
                    if invert { modules[row][column].toggle() }
                }
            }
        }

        /// The standard's four penalties, so the chosen mask leaves a symbol scanners read well.
        func penalty() -> Int {
            var result = 0
            let lines = modules + (0..<size).map { column in (0..<size).map { modules[$0][column] } }
            let finderA: [Bool] = [true, false, true, true, true, false, true, false, false, false, false]
            let finderB: [Bool] = Array(finderA.reversed())
            for line in lines {
                var run = 1
                for index in 1..<size {
                    if line[index] == line[index - 1] {
                        run += 1
                        if run == 5 { result += 3 } else if run > 5 { result += 1 }
                    } else {
                        run = 1
                    }
                }
                if size >= 11 {
                    for start in 0...(size - 11) {
                        let window = line[start..<start + 11]
                        if window.elementsEqual(finderA) || window.elementsEqual(finderB) { result += 40 }
                    }
                }
            }
            for row in 0..<size - 1 {
                for column in 0..<size - 1 {
                    let value = modules[row][column]
                    if modules[row][column + 1] == value, modules[row + 1][column] == value, modules[row + 1][column + 1] == value { result += 3 }
                }
            }
            let dark = modules.reduce(0) { $0 + $1.reduce(0) { $0 + ($1 ? 1 : 0) } }
            let total = size * size
            let k = (abs(dark * 20 - total * 10) + total - 1) / total - 1
            return result + k * 10
        }
    }
}
