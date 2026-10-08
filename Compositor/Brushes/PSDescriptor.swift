import Foundation

/// A parsed value from a Photoshop Action Descriptor, the tagged tree that
/// `.abr` `desc` sections (and many other Adobe files) are written in.
///
/// The wire format, reverse-engineered against Photoshop 2026's own brush
/// libraries and verified byte-exact on five production files:
///
/// - A descriptor = unicode name (u32 char count + UTF-16BE, no null) +
///   classID + u32 item count + items. The **root** of a `desc` section is
///   preceded by a u32 version (16); an embedded `Objc` value has **no**
///   version of its own.
/// - A key or classID = u32 length; when the length is 0 the key is exactly
///   the next 4 raw bytes (padded with spaces, e.g. `Nm␣␣`), otherwise it is
///   that many bytes with no terminator.
/// - An item = key + 4-character type tag + value.
nonisolated enum PSDValue: Sendable {
    case text(String)
    case boolean(Bool)
    case integer(Int)
    case number(Double)
    /// A double tagged with a unit, e.g. `#Pxl` pixels, `#Prc` percent, `#Ang` degrees.
    case unitFloat(unit: String, value: Double)
    case enumerated(type: String, value: String)
    /// `classID` is the descriptor's class; items keep their file order.
    case object(classID: String, items: [(key: String, value: PSDValue)])
    case list([PSDValue])
    /// `tdta` blobs and other raw payloads we do not interpret.
    case raw(Data)

    /// The double stored in a `unitFloat`, `doub`, or `long`; nil for other shapes.
    var doubleValue: Double? {
        switch self {
        case .unitFloat(_, let value): value
        case .number(let value): value
        case .integer(let value): Double(value)
        default: nil
        }
    }

    var boolValue: Bool? {
        if case .boolean(let value) = self { return value }
        return nil
    }

    var intValue: Int? {
        if case .integer(let value) = self { return value }
        return doubleValue.map(Int.init)
    }

    var textValue: String? {
        if case .text(let value) = self { return value }
        return nil
    }

    /// First item with `key` (trailing-space padding ignored), whatever its shape.
    func item(_ key: String) -> PSDValue? {
        guard case .object(_, let items) = self else { return nil }
        return items.first { $0.key.trimmingCharacters(in: [" "]) == key }?.value
    }
}

/// Reader for the Action Descriptor wire format. All multi-byte fields are
/// big-endian. Parsing is defensive: unknown type tags throw instead of
/// desynchronizing, so a parser bug surfaces immediately rather than
/// mis-associating brushes.
nonisolated enum PSDescriptor {
    enum PSDError: Error, Equatable {
        case truncated
        case unknownType(String)
        case outOfBounds
    }

    /// Parses a complete `desc` payload (version 16 header included).
    static func parseRoot(_ data: Data) throws -> PSDValue {
        var reader = Reader(data)
        reader.skip(4)  // version (16)
        return try reader.parseDescriptor(hasVersion: false)
    }

    nonisolated fileprivate struct Reader {
        let bytes: [UInt8]
        var offset: Int
        let end: Int

        init(_ data: Data) {
            bytes = [UInt8](data)
            offset = data.startIndex
            end = data.startIndex + data.count
        }

        mutating func skip(_ count: Int) {
            offset = min(end, offset + count)
        }

        mutating func u8() throws -> UInt8 {
            guard offset + 1 <= end else { throw PSDError.truncated }
            defer { offset += 1 }
            return bytes[offset]
        }

        mutating func u32() throws -> UInt32 {
            guard offset + 4 <= end else { throw PSDError.truncated }
            defer { offset += 4 }
            return UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16
                | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
        }

        mutating func i32() throws -> Int32 {
            Int32(bitPattern: try u32())
        }

        mutating func f64() throws -> Double {
            guard offset + 8 <= end else { throw PSDError.truncated }
            var value: UInt64 = 0
            for i in 0..<8 { value = value << 8 | UInt64(bytes[offset + i]) }
            offset += 8
            return Double(bitPattern: value)
        }

        mutating func ascii(_ count: Int) throws -> String {
            guard count >= 0, offset + count <= end else { throw PSDError.truncated }
            defer { offset += count }
            return String(decoding: bytes[offset..<offset + count], as: UTF8.self)
        }

        /// A key or classID: u32 length, then either 4 raw bytes (length 0) or
        /// that many bytes with no terminator.
        mutating func key() throws -> String {
            let length = Int(try u32())
            if length == 0 { return try ascii(4) }
            guard length <= 256 else { throw PSDError.outOfBounds }
            return try ascii(length)
        }

        /// A unicode string: u32 char count + UTF-16BE code units, with a
        /// trailing NUL when the value pads to an even boundary.
        mutating func text() throws -> String {
            let units = Int(try u32())
            guard units >= 0, units <= 65_536, offset + units * 2 <= end else { throw PSDError.outOfBounds }
            var codeUnits = [UInt16](repeating: 0, count: units)
            for i in 0..<units {
                codeUnits[i] = UInt16(bytes[offset + i * 2]) << 8 | UInt16(bytes[offset + i * 2 + 1])
            }
            offset += units * 2
            if codeUnits.last == 0 { codeUnits.removeLast() }
            return String(decoding: codeUnits, as: UTF16.self)
        }

        /// A descriptor: unicode name + classID + item count + items. Embedded
        /// `Objc` values carry no version; the section root's version is
        /// consumed by the caller.
        mutating func parseDescriptor(hasVersion: Bool) throws -> PSDValue {
            if hasVersion { skip(4) }
            _ = try text()   // unicode name (a single NUL in practice)
            let classID = try key()
            let count = Int(try u32())
            guard count >= 0, count <= 1_000_000 else { throw PSDError.outOfBounds }
            var items: [(key: String, value: PSDValue)] = []
            items.reserveCapacity(count)
            for _ in 0..<count {
                let key = try key()
                items.append((key, try parseTyped()))
            }
            return .object(classID: classID, items: items)
        }

        mutating func parseTyped() throws -> PSDValue {
            let type = try ascii(4)
            switch type {
            case "Objc", "GlbO":
                return try parseDescriptor(hasVersion: false)
            case "VlLs":
                let count = Int(try u32())
                guard count >= 0, count <= 1_000_000 else { throw PSDError.outOfBounds }
                var values: [PSDValue] = []
                values.reserveCapacity(count)
                for _ in 0..<count { values.append(try parseTyped()) }
                return .list(values)
            case "ObAr":
                // Object array: version + name + classID + count + typed items.
                skip(4)
                _ = try text()
                _ = try key()
                let count = Int(try u32())
                guard count >= 0, count <= 1_000_000 else { throw PSDError.outOfBounds }
                var values: [PSDValue] = []
                for _ in 0..<count { values.append(try parseTyped()) }
                return .list(values)
            case "UntF":
                let unit = try ascii(4)
                return .unitFloat(unit: unit, value: try f64())
            case "bool":
                return .boolean(try u8() != 0)
            case "long":
                return .integer(Int(try i32()))
            case "doub":
                return .number(try f64())
            case "TEXT":
                return .text(try text())
            case "enum", "TDuc":
                let typeID = try key()
                let valueID = try key()
                return .enumerated(type: typeID, value: valueID)
            case "tdta", "data":
                let count = Int(try u32())
                guard count >= 0, offset + count <= end else { throw PSDError.truncated }
                defer { offset += count }
                return .raw(Data(bytes[offset..<offset + count]))
            case "UnFl":
                // Unit float with two values (actual + constrained); keep the first.
                let unit = try ascii(4)
                let actual = try f64()
                _ = try f64()
                return .unitFloat(unit: unit, value: actual)
            case "tdum", "Pth ":
                // Not present in any brush file seen so far; refuse loudly if
                // one shows up so the format can be extended deliberately.
                throw PSDError.unknownType(type)
            default:
                throw PSDError.unknownType(type)
            }
        }
    }
}
