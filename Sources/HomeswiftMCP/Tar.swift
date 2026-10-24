import Foundation

/// POSIX tar (ustar, with pax headers for long paths): the instance backup's format. Plain tar, uncompressed: the
/// package links no zlib, and `tar -xf` opens it everywhere. Only regular files and directories are written or
/// read; the reader refuses links, devices, absolute paths and `..`, so an archive can never write outside where
/// it is unpacked (`InstanceBackups.stageRestore`).
public enum Tar {
    public struct Entry: Sendable, Equatable {
        public enum Kind: Sendable, Equatable { case file, directory }
        public var path: String
        public var kind: Kind
        public var data: Data
        public var modified: Date

        public init(path: String, kind: Kind = .file, data: Data = Data(), modified: Date = Date()) {
            self.path = path
            self.kind = kind
            self.data = data
            self.modified = modified
        }
    }

    public struct FormatError: Error, CustomStringConvertible, Equatable {
        public let description: String
        public init(_ description: String) { self.description = description }
    }

    static let block = 512

    // MARK: Writing

    /// Builds an archive in memory, entry by entry; `data` ends it with the two empty blocks tar expects.
    public struct Writer {
        private var output = Data()

        public init() {}

        public mutating func append(_ entry: Entry) throws {
            var path = entry.path
            if entry.kind == .directory, !path.hasSuffix("/") { path += "/" }
            guard !path.isEmpty, path.utf8.count <= 4096 else { throw FormatError("bad path \(entry.path)") }
            let size = entry.kind == .file ? entry.data.count : 0
            let (name, prefix) = Self.split(path)
            if name == nil {
                // Longer than ustar's 100 + 155: a pax header carries the path.
                let record = Self.paxRecord(key: "path", value: path)
                try appendHeader(name: "PaxHeaders/\(String(path.suffix(80)).replacingOccurrences(of: "/", with: "_"))", prefix: "", size: record.count, type: "x", modified: entry.modified, mode: 0o600)
                appendPadded(record)
            }
            try appendHeader(name: name ?? String(path.suffix(99)), prefix: prefix ?? "", size: size, type: entry.kind == .file ? "0" : "5",
                             modified: entry.modified, mode: entry.kind == .file ? 0o600 : 0o700)
            if size > 0 { appendPadded(entry.data) }
        }

        public var data: Data {
            var finished = output
            finished.append(Data(count: Tar.block * 2))
            return finished
        }

        /// ustar's name (100 bytes) and prefix (155): split at a slash so that both fit, or nil when they cannot.
        static func split(_ path: String) -> (name: String?, prefix: String?) {
            let bytes = Array(path.utf8)
            if bytes.count <= 100 { return (path, "") }
            guard bytes.count <= 256 else { return (nil, nil) }
            for index in stride(from: min(bytes.count - 1, 155), through: 1, by: -1) where bytes[index] == UInt8(ascii: "/") {
                let rest = bytes.count - index - 1
                if rest > 0, rest <= 100 {
                    return (String(decoding: bytes[(index + 1)...], as: UTF8.self), String(decoding: bytes[..<index], as: UTF8.self))
                }
            }
            return (nil, nil)
        }

        /// `"<length> key=value\n"`, where the length counts itself.
        static func paxRecord(key: String, value: String) -> Data {
            let body = " \(key)=\(value)\n"
            var length = body.utf8.count + 1
            while "\(length)".utf8.count + body.utf8.count != length { length += 1 }
            return Data("\(length)\(body)".utf8)
        }

        private mutating func appendHeader(name: String, prefix: String, size: Int, type: Character, modified: Date, mode: Int) throws {
            var header = [UInt8](repeating: 0, count: Tar.block)
            func put(_ text: String, at offset: Int, length: Int) {
                for (index, byte) in text.utf8.prefix(length).enumerated() { header[offset + index] = byte }
            }
            func octal(_ value: Int, at offset: Int, length: Int) {
                put(String(String(value, radix: 8).suffix(length - 1)).leftPadded(to: length - 1), at: offset, length: length - 1)
            }
            guard size <= 0o77777777777 else { throw FormatError("\(name) is too large for tar") }
            put(name, at: 0, length: 100)
            octal(mode, at: 100, length: 8)
            octal(0, at: 108, length: 8)
            octal(0, at: 116, length: 8)
            octal(size, at: 124, length: 12)
            octal(max(0, Int(modified.timeIntervalSince1970)), at: 136, length: 12)
            for index in 148..<156 { header[index] = UInt8(ascii: " ") }
            header[156] = UInt8(ascii: String(type).unicodeScalars.first!)
            put("ustar", at: 257, length: 6)
            put("00", at: 263, length: 2)
            put(prefix, at: 345, length: 155)
            let sum = header.reduce(0) { $0 + Int($1) }
            put(String(String(sum, radix: 8)).leftPadded(to: 6) + "\0 ", at: 148, length: 8)
            output.append(contentsOf: header)
        }

        private mutating func appendPadded(_ data: Data) {
            output.append(data)
            let remainder = data.count % Tar.block
            if remainder > 0 { output.append(Data(count: Tar.block - remainder)) }
        }
    }

    // MARK: Reading

    /// The entries of an archive, checked: header checksums, sizes within the data, only files and directories,
    /// relative paths without `.`, `..` or empty parts. pax and GNU long names are followed; anything else (links,
    /// devices, FIFOs) is refused, as the whole archive then is. `maxEntries` caps how many it may hold.
    public static func read(_ archive: Data, maxEntries: Int = 100_000) throws -> [Entry] {
        let bytes = [UInt8](archive)
        var entries: [Entry] = []
        var offset = 0
        var longPath: String?
        while offset + block <= bytes.count {
            let header = bytes[offset..<(offset + block)]
            if header.allSatisfy({ $0 == 0 }) { break }
            guard checksumMatches(header) else { throw FormatError("a header's checksum is wrong at byte \(offset): not a tar archive, or a damaged one") }
            let size = try number(header, at: 124, length: 12)
            let type = header[header.startIndex + 156]
            let start = offset + block
            // Compared without adding: a base-256 size near Int.max would overflow `start + size` and trap.
            guard size >= 0, size <= bytes.count - start else { throw FormatError("an entry runs past the end of the archive") }
            let body = Data(bytes[start..<(start + size)])
            offset = start + (size + block - 1) / block * block
            switch type {
            case UInt8(ascii: "x"):
                longPath = paxPath(body) ?? longPath
                continue
            case UInt8(ascii: "g"):
                continue
            case UInt8(ascii: "L"):
                longPath = String(decoding: body.prefix { $0 != 0 }, as: UTF8.self)
                continue
            case 0, UInt8(ascii: "0"), UInt8(ascii: "7"), UInt8(ascii: "5"):
                break
            default:
                throw FormatError("the archive holds a link or a special file (\(String(describing: UnicodeScalar(type)))): refused")
            }
            var path = longPath ?? {
                let name = string(header, at: 0, length: 100)
                let prefix = string(header, at: 345, length: 155)
                return prefix.isEmpty ? name : "\(prefix)/\(name)"
            }()
            longPath = nil
            let isDirectory = type == UInt8(ascii: "5") || path.hasSuffix("/")
            while path.hasSuffix("/") { path.removeLast() }
            if path.hasPrefix("./") { path.removeFirst(2) }
            if path.isEmpty || path == "." { continue }
            try checkPath(path)
            let modified = Date(timeIntervalSince1970: TimeInterval((try? number(header, at: 136, length: 12)) ?? 0))
            entries.append(Entry(path: path, kind: isDirectory ? .directory : .file, data: isDirectory ? Data() : body, modified: modified))
            guard entries.count <= maxEntries else { throw FormatError("the archive holds more than \(maxEntries) entries") }
        }
        return entries
    }

    /// A relative path whose parts are names: nothing that climbs out of the directory it is unpacked into.
    public static func checkPath(_ path: String) throws {
        guard !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0") else { throw FormatError("unsafe path in the archive: \(path)") }
        for part in path.split(separator: "/", omittingEmptySubsequences: false) {
            guard !part.isEmpty, part != ".", part != ".." else { throw FormatError("unsafe path in the archive: \(path)") }
        }
    }

    private static func checksumMatches(_ header: ArraySlice<UInt8>) -> Bool {
        guard let stored = try? number(header, at: 148, length: 8) else { return false }
        var sum = 0
        for (index, byte) in header.enumerated() { sum += (148..<156).contains(index) ? 32 : Int(byte) }
        return sum == stored
    }

    private static func string(_ header: ArraySlice<UInt8>, at offset: Int, length: Int) -> String {
        let field = header[(header.startIndex + offset)..<(header.startIndex + offset + length)]
        return String(decoding: field.prefix { $0 != 0 }, as: UTF8.self)
    }

    private static func number(_ header: ArraySlice<UInt8>, at offset: Int, length: Int) throws -> Int {
        let field = header[(header.startIndex + offset)..<(header.startIndex + offset + length)]
        if let first = field.first, first & 0x80 != 0 {
            // GNU's base-256 for large values.
            return field.dropFirst().reduce(Int(first & 0x7f)) { $0 << 8 | Int($1) }
        }
        let text = String(decoding: field.prefix { $0 != 0 }, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return 0 }
        guard let value = Int(text, radix: 8) else { throw FormatError("a header's number is not octal") }
        return value
    }

    private static func paxPath(_ body: Data) -> String? {
        var rest = [UInt8](body)[...]
        var path: String?
        while let space = rest.firstIndex(of: UInt8(ascii: " ")),
              let length = Int(String(decoding: rest[rest.startIndex..<space], as: UTF8.self)), length > space - rest.startIndex, rest.count >= length {
            let record = rest.prefix(length)
            rest = rest.dropFirst(length)
            var content = record[(space + 1)...]
            if content.last == UInt8(ascii: "\n") { content = content.dropLast() }
            let text = String(decoding: content, as: UTF8.self)
            if text.hasPrefix("path=") { path = String(text.dropFirst(5)) }
        }
        return path
    }
}

private extension String {
    func leftPadded(to length: Int) -> String {
        count >= length ? self : String(repeating: "0", count: length - count) + self
    }
}
