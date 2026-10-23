import Foundation

/// TLV types used by pairing.
enum TLVType: UInt8 {
    case method = 0x00
    case identifier = 0x01
    case salt = 0x02
    case publicKey = 0x03
    case proof = 0x04
    case encryptedData = 0x05
    case state = 0x06
    case error = 0x07
    case retryDelay = 0x08
    case certificate = 0x09
    case signature = 0x0A
    case permissions = 0x0B
    case fragmentData = 0x0C
    case fragmentLast = 0x0D
    case sessionID = 0x0E
    case flags = 0x13
    case separator = 0xFF
}

/// Pairing error codes (`kTLVError_*`).
enum TLVError: UInt8, Error {
    case unknown = 0x01
    case authentication = 0x02
    case backoff = 0x03
    case maxPeers = 0x04
    case maxTries = 0x05
    case unavailable = 0x06
    case busy = 0x07
}

/// An ordered list of type-length-value items, as used by pair setup, pair verify and pairings.
///
/// Values over 255 bytes are split into consecutive fragments of the same type and joined again on decode.
struct TLV8: Equatable {
    struct Item: Equatable {
        var type: UInt8
        var value: Data
    }

    var items: [Item] = []

    init(_ items: [Item] = []) { self.items = items }

    init(_ pairs: [(TLVType, Data)]) {
        items = pairs.map { Item(type: $0.0.rawValue, value: $0.1) }
    }

    init(decoding data: Data) throws {
        var items: [Item] = []
        var lastFragmentWasFull = false
        do {
            try HAPTLV.forEachItem(data) { type, value in
                if lastFragmentWasFull, let last = items.last, last.type == type {
                    items[items.count - 1].value.append(value)
                } else {
                    items.append(Item(type: type, value: Data(value)))
                }
                lastFragmentWasFull = value.count == 255
            }
        } catch {
            throw TLVError.unknown
        }
        self.items = items
    }

    subscript(type: TLVType) -> Data? {
        items.first { $0.type == type.rawValue }?.value
    }

    func byte(_ type: TLVType) -> UInt8? {
        self[type]?.first
    }

    mutating func append(_ type: TLVType, _ value: Data) {
        items.append(Item(type: type.rawValue, value: value))
    }

    mutating func append(_ type: TLVType, _ byte: UInt8) {
        append(type, Data([byte]))
    }

    /// Items between separators, for pairing lists.
    var groups: [TLV8] {
        var groups: [TLV8] = [TLV8()]
        for item in items {
            if item.type == TLVType.separator.rawValue {
                groups.append(TLV8())
            } else {
                groups[groups.count - 1].items.append(item)
            }
        }
        return groups.filter { !$0.items.isEmpty }
    }

    func encoded() -> Data {
        var out = Data()
        for item in items { HAPTLV.appendFragments(item.type, item.value, to: &out) }
        return out
    }
}
