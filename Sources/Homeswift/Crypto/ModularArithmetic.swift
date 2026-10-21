import CHAPMath
import Foundation

/// Arithmetic modulo the SRP group prime, using Montgomery multiplication on 64-bit limbs.
///
/// General-purpose big-integer libraries are far too slow for 3072-bit exponentiation in debug
/// builds (minutes per pair setup). This covers exactly what SRP needs: modular multiply, add,
/// subtract and exponentiation of numbers below the modulus. Limbs are little-endian.
struct ModularField {
    typealias Number = [UInt64]

    let modulus: Number
    let count: Int
    let byteCount: Int
    private let n0inv: UInt64
    /// R^2 mod N, with R = 2^(64 * count).
    private let r2: Number

    init(modulusBytes: Data) {
        byteCount = modulusBytes.count
        count = (byteCount + 7) / 8
        modulus = Self.limbs(modulusBytes, count: count)

        // -N^-1 mod 2^64 by Newton iteration.
        var inverse: UInt64 = 1
        for _ in 0..<6 { inverse = inverse &* (2 &- modulus[0] &* inverse) }
        n0inv = 0 &- inverse

        // R mod N is R - N, the two's complement of N; doubled (64 * count) times it gives R^2 mod N.
        var r = Self.rawSubtract(Number(repeating: 0, count: count), modulus).result
        for _ in 0..<(64 * count) { r = Self.add(r, r, modulus: modulus) }
        r2 = r
    }

    // MARK: Conversions

    static func limbs(_ bytes: Data, count: Int) -> Number {
        var out = Number(repeating: 0, count: count)
        for (index, byte) in bytes.reversed().enumerated() where index < count * 8 {
            out[index / 8] |= UInt64(byte) << (8 * UInt64(index % 8))
        }
        return out
    }

    /// Big-endian bytes, which must encode a number below the modulus.
    func number(_ bytes: Data) -> Number? {
        let trimmed = bytes.drop { $0 == 0 }
        guard trimmed.count <= count * 8 else { return nil }
        let value = Self.limbs(Data(trimmed), count: count)
        return Self.compare(value, modulus) < 0 ? value : nil
    }

    func number(_ small: UInt64) -> Number {
        var out = Number(repeating: 0, count: count)
        out[0] = small
        return out
    }

    /// Big-endian bytes padded to the modulus length.
    func bytes(_ value: Number) -> Data {
        var out = Data(count: byteCount)
        for index in 0..<byteCount {
            let limb = value[index / 8]
            out[byteCount - 1 - index] = UInt8(truncatingIfNeeded: limb >> (8 * UInt64(index % 8)))
        }
        return out
    }

    func isZero(_ value: Number) -> Bool { value.allSatisfy { $0 == 0 } }

    // MARK: Operations

    func add(_ a: Number, _ b: Number) -> Number { Self.add(a, b, modulus: modulus) }

    func subtract(_ a: Number, _ b: Number) -> Number {
        let (out, borrow) = Self.rawSubtract(a, b)
        return borrow ? Self.rawAdd(out, modulus).result : out
    }

    func multiply(_ a: Number, _ b: Number) -> Number {
        montgomery(montgomery(a, b), r2)
    }

    /// `base ^ exponent mod N`, with the exponent as big-endian bytes of any length.
    func power(_ base: Number, _ exponent: Data) -> Number {
        let n = count
        let work = Workspace(field: self)
        defer { work.deallocate() }
        work.load(base, into: work.x)
        work.load(r2, into: work.y)
        work.multiply(work.x, work.y, into: work.base)  // base in Montgomery form
        work.load(number(1), into: work.x)
        work.multiply(work.x, work.y, into: work.result)  // 1 in Montgomery form
        for byte in exponent {
            for bit in (0..<8).reversed() {
                work.multiply(work.result, work.result, into: work.x)
                if byte >> bit & 1 == 1 {
                    work.multiply(work.x, work.base, into: work.result)
                } else {
                    work.result.update(from: work.x, count: n)
                }
            }
        }
        work.load(number(1), into: work.y)
        work.multiply(work.result, work.y, into: work.x)
        return Array(UnsafeBufferPointer(start: work.x, count: n))
    }

    private func montgomery(_ a: Number, _ b: Number) -> Number {
        let work = Workspace(field: self)
        defer { work.deallocate() }
        work.load(a, into: work.x)
        work.load(b, into: work.y)
        work.multiply(work.x, work.y, into: work.result)
        return Array(UnsafeBufferPointer(start: work.result, count: count))
    }

    /// Fixed buffers for Montgomery multiplication, so the hot loop has no closures or allocations.
    private struct Workspace {
        let n: Int
        let inv: UInt64
        let m: UnsafeMutablePointer<UInt64>
        let t: UnsafeMutablePointer<UInt64>
        let x: UnsafeMutablePointer<UInt64>
        let y: UnsafeMutablePointer<UInt64>
        let base: UnsafeMutablePointer<UInt64>
        let result: UnsafeMutablePointer<UInt64>

        init(field: ModularField) {
            n = field.count
            inv = field.n0inv
            m = .allocate(capacity: n)
            t = .allocate(capacity: n + 2)
            x = .allocate(capacity: n)
            y = .allocate(capacity: n)
            base = .allocate(capacity: n)
            result = .allocate(capacity: n)
            for i in 0..<n { m[i] = field.modulus[i] }
        }

        func deallocate() {
            for pointer in [m, t, x, y, base, result] { pointer.deallocate() }
        }

        func load(_ value: Number, into pointer: UnsafeMutablePointer<UInt64>) {
            for i in 0..<n { pointer[i] = value[i] }
        }

        /// out = a * b * R^-1 mod N. `out` must not alias `a` or `b`.
        func multiply(_ a: UnsafeMutablePointer<UInt64>, _ b: UnsafeMutablePointer<UInt64>, into out: UnsafeMutablePointer<UInt64>) {
            hap_montgomery_multiply(out, a, b, m, n, inv, t)
        }
    }

    // MARK: Helpers

    private static func add(_ a: Number, _ b: Number, modulus: Number) -> Number {
        let (out, carry) = rawAdd(a, b)
        return carry || compare(out, modulus) >= 0 ? rawSubtract(out, modulus).result : out
    }

    /// Limb-wise `a + b`, with the carry out of the top limb.
    private static func rawAdd(_ a: Number, _ b: Number) -> (result: Number, carry: Bool) {
        var out = Number(repeating: 0, count: a.count)
        var carry = false
        for i in 0..<a.count {
            let (s1, c1) = a[i].addingReportingOverflow(b[i])
            let (s2, c2) = s1.addingReportingOverflow(carry ? 1 : 0)
            out[i] = s2
            carry = c1 || c2
        }
        return (out, carry)
    }

    /// Limb-wise `a - b`, with the borrow out of the top limb.
    private static func rawSubtract(_ a: Number, _ b: Number) -> (result: Number, borrow: Bool) {
        var out = Number(repeating: 0, count: a.count)
        var borrow = false
        for i in 0..<a.count {
            let (d1, b1) = a[i].subtractingReportingOverflow(b[i])
            let (d2, b2) = d1.subtractingReportingOverflow(borrow ? 1 : 0)
            out[i] = d2
            borrow = b1 || b2
        }
        return (out, borrow)
    }

    static func compare(_ a: Number, _ b: Number) -> Int {
        for i in stride(from: a.count - 1, through: 0, by: -1) where a[i] != b[i] {
            return a[i] < b[i] ? -1 : 1
        }
        return 0
    }
}
