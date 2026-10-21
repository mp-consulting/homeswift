/// A value that writes itself as HAP JSON.
protocol JSONWritable {
    func write(to json: inout JSONWriter)
}

/// Writes JSON bytes directly, for the few shapes HAP responses have.
///
/// JSONEncoder took about 9 ms for a 100-accessory database; this takes a fraction of that.
/// Callers write keys and values in order; commas are added as needed.
struct JSONWriter {
    private(set) var bytes: [UInt8] = []
    /// One entry per open object or array: true until its first member is written.
    private var empty: [Bool] = []
    private var afterKey = false

    init(capacity: Int = 256) {
        bytes.reserveCapacity(capacity)
    }

    // MARK: Structure

    mutating func object(_ body: (inout JSONWriter) -> Void) {
        open(UInt8(ascii: "{"))
        body(&self)
        close(UInt8(ascii: "}"))
    }

    mutating func array(_ body: (inout JSONWriter) -> Void) {
        open(UInt8(ascii: "["))
        body(&self)
        close(UInt8(ascii: "]"))
    }

    mutating func key(_ name: String) {
        separate()
        quoted(name)
        bytes.append(UInt8(ascii: ":"))
        afterKey = true
    }

    // MARK: Values

    mutating func value(_ value: Int) {
        separate()
        integer(value)
    }

    mutating func value(_ value: Double) {
        separate()
        if !value.isFinite {
            bytes.append(contentsOf: "null".utf8)
        } else if value == value.rounded(), abs(value) < 1e15 {
            integer(Int(value))
        } else {
            bytes.append(contentsOf: value.description.utf8)
        }
    }

    mutating func value(_ value: Bool) {
        separate()
        bytes.append(contentsOf: (value ? "true" : "false").utf8)
    }

    mutating func value(_ value: String) {
        separate()
        quoted(value)
    }

    mutating func value(_ value: HAPValue) {
        switch value {
        case .bool(let bool): self.value(bool)
        case .int(let int): self.value(int)
        case .double(let double): self.value(double)
        case .string(let string): self.value(string)
        case .null:
            separate()
            bytes.append(contentsOf: "null".utf8)
        }
    }

    mutating func value(_ value: some JSONWritable) {
        value.write(to: &self)
    }

    mutating func value(_ values: [Int]) {
        array { json in
            for value in values { json.value(value) }
        }
    }

    mutating func value(_ values: [String]) {
        array { json in
            for value in values { json.value(value) }
        }
    }

    /// Writes `"key": value`, or nothing when the value is nil.
    mutating func field(_ name: String, _ value: Int?) {
        guard let value else { return }
        key(name)
        self.value(value)
    }

    mutating func field(_ name: String, _ value: Double?) {
        guard let value else { return }
        key(name)
        self.value(value)
    }

    mutating func field(_ name: String, _ value: Bool?) {
        guard let value else { return }
        key(name)
        self.value(value)
    }

    mutating func field(_ name: String, _ value: String?) {
        guard let value else { return }
        key(name)
        self.value(value)
    }

    mutating func field(_ name: String, _ value: HAPValue?) {
        guard let value else { return }
        key(name)
        self.value(value)
    }

    mutating func field(_ name: String, _ values: [Int]?) {
        guard let values else { return }
        key(name)
        value(values)
    }

    mutating func field(_ name: String, _ values: [String]?) {
        guard let values else { return }
        key(name)
        value(values)
    }

    // MARK: Bytes

    private mutating func open(_ byte: UInt8) {
        separate()
        bytes.append(byte)
        empty.append(true)
    }

    private mutating func close(_ byte: UInt8) {
        empty.removeLast()
        bytes.append(byte)
    }

    /// A comma before every member but the first, and none right after a key.
    private mutating func separate() {
        if afterKey {
            afterKey = false
        } else if let last = empty.last {
            if last {
                empty[empty.count - 1] = false
            } else {
                bytes.append(UInt8(ascii: ","))
            }
        }
    }

    private mutating func integer(_ value: Int) {
        if value == 0 {
            bytes.append(UInt8(ascii: "0"))
            return
        }
        var magnitude = value.magnitude
        if value < 0 { bytes.append(UInt8(ascii: "-")) }
        let start = bytes.count
        while magnitude > 0 {
            bytes.append(UInt8(ascii: "0") + UInt8(magnitude % 10))
            magnitude /= 10
        }
        bytes[start...].reverse()
    }

    private mutating func quoted(_ string: String) {
        bytes.append(UInt8(ascii: "\""))
        // Nearly every string has nothing to escape: one copy instead of a switch per byte.
        if string.utf8.allSatisfy({ $0 >= 0x20 && $0 != UInt8(ascii: "\"") && $0 != UInt8(ascii: "\\") }) {
            bytes.append(contentsOf: string.utf8)
            bytes.append(UInt8(ascii: "\""))
            return
        }
        for byte in string.utf8 {
            switch byte {
            case UInt8(ascii: "\""): bytes.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "\"")])
            case UInt8(ascii: "\\"): bytes.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "\\")])
            case UInt8(ascii: "\n"): bytes.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "n")])
            case UInt8(ascii: "\r"): bytes.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "r")])
            case UInt8(ascii: "\t"): bytes.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "t")])
            case 0..<0x20:
                let hex = Array("0123456789abcdef".utf8)
                bytes.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "u"), UInt8(ascii: "0"), UInt8(ascii: "0")])
                bytes.append(hex[Int(byte >> 4)])
                bytes.append(hex[Int(byte & 0xF)])
            default: bytes.append(byte)
            }
        }
        bytes.append(UInt8(ascii: "\""))
    }
}
