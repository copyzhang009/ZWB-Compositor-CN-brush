import Foundation

/// A Photoshop brush tip parsed from an `.abr` file. `coverage` is stored in
/// Compositor's convention — 0 = transparent, 255 = opaque — which is the inverse
/// of the on-disk grayscale, where black paints and white is clear.
nonisolated struct ABRBrush: Sendable, Equatable {
    var name: String
    /// Natural tip size in pixels; the tip is scaled to whatever diameter the user picks.
    var width: Int
    var height: Int
    /// Spacing as a percentage of the brush diameter (Photoshop's default is 25%).
    var spacing: CGFloat
    /// Row-major coverage, `width * height` bytes, 0 = transparent … 255 = opaque.
    var coverage: [UInt8]
}

/// A complete brush preset: the tip's shape parameters from the descriptor,
/// its dynamics, and — when the preset uses a sampled rather than computed
/// tip — the bitmap matched by UUID from the `samp` section.
nonisolated struct ABRPreset: Sendable {
    var name: String
    var diameter: CGFloat
    /// 0…1, meaningful for computed round tips, absent for sampled ones.
    var hardness: CGFloat
    /// Tip rotation in degrees.
    var angle: CGFloat
    /// 0…1 (PS "Roundness" — 1 = circle).
    var roundness: CGFloat
    /// Spacing as a percentage of the diameter.
    var spacing: CGFloat
    /// Mirrored along the horizontal/vertical axis (PS "Flip X" / "Flip Y").
    var flipX: Bool
    var flipY: Bool
    /// Tool flow 0…1.
    var flow: CGFloat
    var smoothing: Bool
    /// `nil` = computed (round/elliptical) tip; otherwise the sampled bitmap.
    var tip: ABRBrush?
    var dynamics: BrushDynamics
}

/// A reader for the Photoshop brush format. Two families exist:
///
/// **Legacy (v1/v2)** — version + brush count, then computed/sampled records
/// (`type u16 + length u32 + payload`). Tips come out as presets with default
/// dynamics; the format carries none.
///
/// **Modern (v6/7/9/10)** — major + subversion, then `8BIM`-tagged sections
/// (`samp` tips, `patt` patterns, `desc` settings, `phry`). A `samp` section is a
/// sequence of brush records, each: a 4-byte preamble, a Pascal UUID identifier,
/// the tip rectangle (4 × i32), the bit depth, a compression flag, and
/// **one continuous PackBits stream** that fills the tip row by row.
///
/// The `desc` section holds the actual preset list — names, tip parameters and
/// every Shape Dynamics / Transfer setting — as a Photoshop Action Descriptor
/// (see `PSDescriptor`). Sampled tips are attached to their preset through the
/// `sampledData` UUID inside each preset's `Brsh` object, **not** by section
/// order: a library mixes computed and sampled presets freely.
///
/// Photoshop's encoder lets the stream overshoot `width × height` slightly; the
/// decoder takes the first `width × height` samples and ignores the excess, the
/// same way Photoshop does. `patt` and `phry` sections are skipped.
enum ABRReader {
    enum ABRError: Error, Equatable {
        case truncated
        case invalidSignature
        case unsupported(String)
    }

    /// Parses the full preset list: tips, names, and dynamics.
    static func parsePresets(_ data: Data) throws -> [ABRPreset] {
        guard data.count >= 8 else { throw ABRError.truncated }
        let major = Int(readUInt16(data, 0))
        guard (1...10).contains(major) else { throw ABRError.invalidSignature }
        if major >= 6 {
            return try parseModern(data)
        }
        return try parseLegacy(data, major: major).map { brush in
            ABRPreset(name: brush.name, diameter: CGFloat(max(brush.width, brush.height)),
                      hardness: 1, angle: 0, roundness: 1,
                      spacing: brush.spacing > 0 ? brush.spacing : 25,
                      flipX: false, flipY: false,
                      flow: 1, smoothing: false, tip: brush, dynamics: BrushDynamics())
        }
    }

    // MARK: - Modern (v6/7/9/10)

    private static func parseModern(_ data: Data) throws -> [ABRPreset] {
        var offset = 4
        var sampled: [(id: String, brush: ABRBrush)] = []
        var descData: Data?
        while offset + 12 <= data.count {
            guard hasSignature(data, offset) else { break }
            let key = String(decoding: data[data.startIndex + offset + 4..<data.startIndex + offset + 8], as: UTF8.self)
            let size = Int(readUInt32(data, offset + 8))
            let payload = offset + 12
            guard payload + size <= data.count else { throw ABRError.truncated }
            if key == "samp" {
                sampled.append(contentsOf: parseSampSection(data, start: payload, end: payload + size))
            } else if key == "desc" {
                descData = data.subdata(in: payload..<payload + size)
            }
            offset = align4(payload + size)
        }
        // The descriptor section is authoritative when present: it defines the
        // presets in Photoshop's display order, with every dynamic setting.
        if let desc = descData, let presets = try? parseDescPresets(desc, sampled: sampled), !presets.isEmpty {
            return presets
        }
        // No (or unreadable) descriptor: fall back to the sampled tips alone,
        // numbered — nothing else in the file knows their names.
        return sampled.enumerated().map { index, entry in
            ABRPreset(name: "笔刷 \(index + 1)", diameter: CGFloat(max(entry.brush.width, entry.brush.height)),
                      hardness: 1, angle: 0, roundness: 1, spacing: 25,
                      flipX: false, flipY: false,
                      flow: 1, smoothing: false, tip: entry.brush, dynamics: BrushDynamics())
        }
    }

    /// Reads the preset list out of a `desc` payload and attaches each sampled
    /// tip whose UUID the preset references.
    private static func parseDescPresets(_ data: Data, sampled: [(id: String, brush: ABRBrush)]) throws -> [ABRPreset] {
        let root = try PSDescriptor.parseRoot(data)
        guard case .list(let entries) = root.item("Brsh") else { return [] }
        var byID: [String: ABRBrush] = [:]
        for entry in sampled { byID[entry.id.lowercased()] = entry.brush }
        var presets: [ABRPreset] = []
        presets.reserveCapacity(entries.count)
        for entry in entries {
            guard case .object = entry else { continue }
            let name = displayName(entry.item("Nm")?.textValue)
            let brsh = entry.item("Brsh")
            let tipID = brsh?.item("sampledData")?.textValue?.lowercased()
            let options = entry.item("toolOptions")
            presets.append(ABRPreset(
                name: name,
                diameter: CGFloat(brsh?.item("Dmtr")?.doubleValue ?? 40),
                hardness: CGFloat((brsh?.item("Hrdn")?.doubleValue ?? 100) / 100),
                angle: CGFloat(brsh?.item("Angl")?.doubleValue ?? 0),
                roundness: CGFloat((brsh?.item("Rndn")?.doubleValue ?? 100) / 100),
                spacing: CGFloat(brsh?.item("Spcn")?.doubleValue ?? 25),
                flipX: brsh?.item("flipX")?.boolValue ?? false,
                flipY: brsh?.item("flipY")?.boolValue ?? false,
                flow: CGFloat((options?.item("flow")?.doubleValue ?? 100) / 100),
                smoothing: options?.item("smoothing")?.boolValue ?? false,
                tip: tipID.flatMap { byID[$0] },
                dynamics: BrushDynamics(preset: entry)))
        }
        return presets
    }

    /// Preset names are stored as Photoshop localization strings,
    /// `$$$/path/key=Display Name`; the display part follows the `=`.
    private static func displayName(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "笔刷" }
        if let eq = raw.lastIndex(of: "=") { return String(raw[raw.index(after: eq)...]) }
        return raw
    }

    /// Walks the `samp` section locating brush records (a Pascal UUID identifier
    /// marks each one) and decodes their tips. The entries are not reliably
    /// length-prefixed in real files, so records are found by their identifier.
    private static func parseSampSection(_ data: Data, start: Int, end: Int) -> [(id: String, brush: ABRBrush)] {
        var marks: [Int] = []
        var offset = start
        while offset < end - 40 {
            if isUUIDRecord(data, offset) { marks.append(offset) }
            offset += 1
        }
        var brushes: [(id: String, brush: ABRBrush)] = []
        for (index, mark) in marks.enumerated() {
            let recordEnd = index + 1 < marks.count ? marks[index + 1] : end
            guard let brush = parseSampRecord(data, mark: mark, end: recordEnd) else { continue }
            brushes.append((brush.name, brush))
        }
        return brushes
    }

    /// A record marks its identifier with a 1-byte length followed by a UUID string.
    private static func isUUIDRecord(_ data: Data, _ offset: Int) -> Bool {
        guard offset + 38 <= data.count else { return false }
        guard data[data.startIndex + offset] == 36 else { return false }
        var chars: [Character] = []
        for i in 1...36 { chars.append(Character(UnicodeScalar(data[data.startIndex + offset + i]))) }
        let s = String(chars)
        let dashes = s.enumerated().filter { $0.element == "-" }.map { $0.offset }
        guard dashes == [8, 13, 18, 23] else { return false }
        for ch in s where ch != "-" {
            if !("0"..."9" ~= ch) && !("a"..."f" ~= ch) && !("A"..."F" ~= ch) { return false }
        }
        return true
    }

    private static func parseSampRecord(_ data: Data, mark: Int, end: Int) -> ABRBrush? {
        // Layout (offsets relative to the record mark):
        //   +4    identifier length byte, then the UUID
        //   +49   tip rectangle: top, left, bottom, right (4 × i32)
        //   +316  pixel data: one continuous PackBits stream
        let name = String(decoding: data[data.startIndex + mark + 1..<data.startIndex + mark + 37], as: UTF8.self)
        let rect = mark + 49
        guard rect + 16 <= end else { return nil }
        let top = Int(readInt32(data, rect)), left = Int(readInt32(data, rect + 4))
        let bottom = Int(readInt32(data, rect + 8)), right = Int(readInt32(data, rect + 12))
        let width = right - left, height = bottom - top
        guard width > 0, height > 0, width <= 8192, height <= 8192 else { return nil }
        let pixelStart = mark + 316
        guard pixelStart < end else { return nil }
        let packed = [UInt8](data[data.startIndex + pixelStart..<data.startIndex + end])
        let decoded = unpackPackBits(packed)
        guard decoded.count >= width * height else { return nil }
        let gray = Array(decoded.prefix(width * height))
        return ABRBrush(name: name, width: width, height: height,
                        spacing: 25, coverage: invertToCoverage(gray))
    }

    private static func hasSignature(_ data: Data, _ offset: Int) -> Bool {
        data[data.startIndex + offset] == 0x38 && data[data.startIndex + offset + 1] == 0x42
            && data[data.startIndex + offset + 2] == 0x49 && data[data.startIndex + offset + 3] == 0x4D
    }

    // MARK: - Legacy (v1/v2)

    private static func parseLegacy(_ data: Data, major: Int) throws -> [ABRBrush] {
        let count = Int(readUInt16(data, 2))
        var cursor = 4
        var brushes: [ABRBrush] = []
        for _ in 0..<count {
            guard cursor + 6 <= data.count else { break }
            let type = Int(readUInt16(data, cursor))
            let size = Int(readUInt32(data, cursor + 2))
            cursor += 6
            defer { cursor += size }
            guard type == 2, major == 2, size >= 21 else { continue }
            // Sampled payload: misc(4) + spacing(2) + name + antiAlias(1) + short
            // bounds (4 × i16) + bounds (5 × i32) + depth(2) + compression(1) + data.
            let payload = cursor
            let spacing = CGFloat(readUInt16(data, payload + 4))
            var nameCursor = payload + 6
            let name = readLegacyName(data, cursor: &nameCursor)
            var c = nameCursor
            guard c + 1 + 8 + 20 + 2 + 1 <= payload + size else { continue }
            c += 1   // anti-alias
            c += 8   // short bounds (4 × i16)
            let top = Int(readInt32(data, c)), left = Int(readInt32(data, c + 4))
            let bottom = Int(readInt32(data, c + 8)), right = Int(readInt32(data, c + 12))
            c += 20  // long bounds (5 × i32; the fifth is ignored)
            let depth = Int(readUInt16(data, c)); c += 2
            let compression = data[data.startIndex + c]; c += 1
            let width = right - left, height = bottom - top
            guard width > 0, height > 0, width <= 8192, height <= 8192,
                  [0, 1].contains(Int(compression)) else { continue }
            guard let gray = decodeLegacyPixels(data, width: width, height: height, depth: depth,
                                                compression: Int(compression), cursor: &c, limit: payload + size) else { continue }
            brushes.append(ABRBrush(name: name, width: width, height: height,
                                    spacing: spacing > 0 ? spacing : 25, coverage: invertToCoverage(gray)))
        }
        return brushes
    }

    /// Legacy pixels: raw planes, or PackBits with a u16 byte count per row. Rows
    /// overflow their width here too, so each decoded row is clipped and the rest
    /// of the row zero-padded.
    private static func decodeLegacyPixels(_ data: Data, width: Int, height: Int, depth: Int,
                                           compression: Int, cursor: inout Int, limit: Int) -> [UInt8]? {
        let pixelBytes = max(1, depth / 8)
        var gray = [UInt8](repeating: 0, count: width * height)
        if compression == 0 {
            let rowBytes = width * pixelBytes
            for row in 0..<height {
                guard cursor + rowBytes <= limit else { return nil }
                copyRow([UInt8](data[data.startIndex + cursor..<data.startIndex + cursor + rowBytes]),
                        into: &gray, row: row, width: width, pixelBytes: pixelBytes)
                cursor += rowBytes
            }
            return gray
        }
        for row in 0..<height {
            guard cursor + 2 <= limit else { return nil }
            let packedLength = Int(readUInt16(data, cursor))
            cursor += 2
            guard packedLength > 0, cursor + packedLength <= limit else { return nil }
            let unpacked = unpackPackBits([UInt8](data[data.startIndex + cursor..<data.startIndex + cursor + packedLength]))
            cursor += packedLength
            copyRow(unpacked, into: &gray, row: row, width: width, pixelBytes: pixelBytes)
        }
        return gray
    }

    /// v2 stores the name as a length-prefixed UTF-16 string (including the null).
    private static func readLegacyName(_ data: Data, cursor: inout Int) -> String {
        guard cursor + 4 <= data.count else { return "" }
        let units = Int(readUInt32(data, cursor))
        cursor += 4
        guard units > 0, cursor + units * 2 <= data.count else { return "" }
        var codeUnits: [UInt16] = []
        for i in 0..<units { codeUnits.append(readUInt16(data, cursor + i * 2)) }
        cursor += units * 2
        var result = String(decoding: codeUnits, as: UTF16.self)
        if result.hasSuffix("\u{0}") { result.removeLast() }
        return result
    }

    // MARK: - Shared helpers

    /// Decodes one contiguous PackBits stream: 0…127 copy the next n+1 bytes,
    /// -1…-127 repeat the next byte (-n+1) times, -128 is a no-op.
    private static func unpackPackBits(_ packed: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var i = 0
        while i < packed.count {
            let n = Int(Int8(bitPattern: packed[i]))
            i += 1
            if n >= 0 {
                let count = min(n + 1, packed.count - i)
                out.append(contentsOf: packed[i..<i + count])
                i += count
            } else if n > -128 {
                let count = -n + 1
                if i < packed.count { out.append(contentsOf: repeatElement(packed[i], count: count)) }
                i += 1
            }
        }
        return out
    }

    /// On disk black (0) paints and white (255) is clear; Compositor's coverage is the
    /// opposite, so flip it. The high byte of a 16-bit sample was already taken.
    private static func invertToCoverage(_ gray: [UInt8]) -> [UInt8] {
        gray.map { 255 &- $0 }
    }

    private static func align4(_ offset: Int) -> Int { (offset + 3) / 4 * 4 }

    /// Copies one decoded row into `gray`, clipping to the row width and taking the
    /// high byte of each sample (16-bit tips drop to 8-bit). Missing bytes stay 0.
    private static func copyRow(_ bytes: [UInt8], into gray: inout [UInt8], row: Int, width: Int, pixelBytes: Int) {
        let base = row * width
        for x in 0..<width {
            let i = x * pixelBytes
            gray[base + x] = i < bytes.count ? bytes[i] : 0
        }
    }

    private static func readUInt16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[data.startIndex + offset]) << 8 | UInt16(data[data.startIndex + offset + 1])
    }

    private static func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(readUInt16(data, offset)) << 16 | UInt32(readUInt16(data, offset + 2))
    }

    private static func readInt32(_ data: Data, _ offset: Int) -> Int32 {
        Int32(bitPattern: readUInt32(data, offset))
    }
}
