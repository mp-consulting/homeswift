/// A HAP service or characteristic type.
///
/// Apple-defined types share the base UUID `0000XXXX-0000-1000-8000-0026BB765291` and go on the wire in
/// short form (`"25"` for On). Custom types use a full UUID string.
public struct HAPUUID: Hashable, Sendable, CustomStringConvertible {
    static let appleSuffix = "-0000-1000-8000-0026BB765291"

    /// The full, uppercase UUID string.
    public let uuidString: String

    /// An Apple-defined type from its short identifier, e.g. `HAPUUID(0x25)`.
    public init(_ short: UInt32) {
        self.init(full: Self.fullString(short))
    }

    private init(full: String) { uuidString = full }

    private static func fullString(_ short: UInt32) -> String {
        let hex = String(short, radix: 16, uppercase: true)
        return String(repeating: "0", count: 8 - hex.count) + hex + appleSuffix
    }

    /// A full UUID string, or a short Apple form such as `"25"`.
    public init(_ string: String) {
        let upper = string.uppercased()
        if upper.count <= 8, let short = UInt32(upper, radix: 16) {
            self.init(full: Self.fullString(short))
        } else {
            self.init(full: upper)
        }
    }

    /// The form used in the accessory database: short for Apple types, full otherwise.
    public var shortForm: String {
        guard uuidString.hasSuffix(Self.appleSuffix) else { return uuidString }
        let head = uuidString.prefix(8).drop { $0 == "0" }
        return head.isEmpty ? "0" : String(head)
    }

    public var description: String { shortForm }
}
