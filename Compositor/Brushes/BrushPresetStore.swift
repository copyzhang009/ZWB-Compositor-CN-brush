import Foundation

/// Owns the user's brush presets: loads and saves them, and imports `.abr` files.
/// The list always keeps a round brush available at the front, so painting never
/// depends on an import. (Plain class for now; the preset panel can wrap it in
/// `@Observable` or `@State` when it needs reactive updates.)
final class BrushPresetStore {
    var presets: [BrushPreset]
    /// Groups the user made that may not hold a brush yet.
    var groups: [String]

    init(presets: [BrushPreset] = [.round], groups: [String] = []) {
        self.presets = presets
        self.groups = groups
    }

    /// Parses an `.abr` file and appends every preset it contains — computed
    /// tips (round/elliptical, parameterized) and sampled bitmap tips alike,
    /// with their names and dynamics from the descriptor section. `group` is the
    /// library the presets belong to, normally the file's own name.
    @discardableResult
    func importABR(_ data: Data, group: String? = nil) throws -> [BrushPreset] {
        let parsed = try ABRReader.parsePresets(data)
        let added = parsed.map { BrushPreset(abr: $0, group: group) }
        presets.append(contentsOf: added)
        return added
    }

    /// Takes one preset out of the library.
    func remove(_ preset: BrushPreset) {
        presets.removeAll { $0.id == preset.id }
    }

    /// Takes a whole imported library out, by group name.
    func removeGroup(_ group: String) {
        presets.removeAll { $0.group == group }
        groups.removeAll { $0 == group }
    }

    /// Adds a hand-made preset, under the given group.
    func append(_ preset: BrushPreset, group: String? = nil) {
        var preset = preset
        preset.group = group
        presets.append(preset)
        if let group, !groups.contains(group) { groups.append(group) }
    }

    /// Renames one brush.
    func rename(_ preset: BrushPreset, to name: String) {
        guard let index = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        presets[index].name = name
    }

    /// Moves a brush into another group (nil = the built-in group), landing at
    /// the end of it.
    func move(_ preset: BrushPreset, to group: String?) {
        move(preset, to: group, at: presets.filter { $0.group == group }.count)
    }

    /// Moves a brush into a group at a given position within it (0 = first), so
    /// dropping between two brushes puts it right there.
    func move(_ preset: BrushPreset, to group: String?, at index: Int) {
        guard let from = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        var item = presets.remove(at: from)
        item.group = group
        // Where the target group now sits in the array, after the removal.
        let members = presets.indices.filter { presets[$0].group == group }
        let landing: Int
        if index <= 0 {
            landing = members.first ?? presets.count
        } else if index >= members.count {
            landing = (members.last.map { $0 + 1 }) ?? presets.count
        } else {
            landing = members[index]
        }
        presets.insert(item, at: min(max(0, landing), presets.count))
        if let group, !groups.contains(group) { groups.append(group) }
    }


    /// Creates an empty group for the user to drag brushes into.
    @discardableResult
    func addGroup(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "内置", !groups.contains(trimmed) else { return false }
        groups.append(trimmed)
        return true
    }

    /// Renames a group, taking its brushes with it.
    func renameGroup(_ group: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != group, !groups.contains(trimmed) else { return }
        for index in presets.indices where presets[index].group == group {
            presets[index].group = trimmed
        }
        if let index = groups.firstIndex(of: group) { groups[index] = trimmed }
    }

    /// The groups on offer, in the order they first appear, with each group's
    /// presets. The built-in brushes come first under a nil group.
    func grouped() -> [(group: String?, presets: [BrushPreset])] {
        var order: [String?] = []
        var buckets: [String?: [BrushPreset]] = [:]
        for preset in presets {
            if buckets[preset.group] == nil { order.append(preset.group) }
            buckets[preset.group, default: []].append(preset)
        }
        // A group the user made but hasn't filled yet still shows.
        for group in groups where buckets[group] == nil { order.append(group) }
        // A nil group always leads, so the built-in brushes sit on top.
        if let index = order.firstIndex(where: { $0 == nil }), index != 0 {
            order.remove(at: index)
            order.insert(nil, at: 0)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    /// The on-disk shape. An earlier build wrote a bare array of presets, which
    /// `load` still reads so nobody's library is lost.
    private struct Library: Codable {
        var presets: [BrushPreset]
        var groups: [String]
    }

    func save(to url: URL) throws {
        let data = try JSONEncoder().encode(Library(presets: presets, groups: groups))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    static func load(from url: URL) -> BrushPresetStore {
        var presets: [BrushPreset] = []
        var groups: [String] = []
        if let data = try? Data(contentsOf: url) {
            if let library = try? JSONDecoder().decode(Library.self, from: data) {
                presets = library.presets
                groups = library.groups
            } else if let decoded = try? JSONDecoder().decode([BrushPreset].self, from: data) {
                presets = decoded
            }
        }
        // The starter brushes are always on offer — a library saved before they
        // existed gets them too, matched by name so they never duplicate.
        let known = Set(presets.map(\.name))
        let missing = BrushPreset.defaultLibrary.filter { !known.contains($0.name) }
        presets.insert(contentsOf: missing, at: 0)
        return BrushPresetStore(presets: presets, groups: groups)
    }

    /// The on-disk location inside the app container (or a test-provided base directory).
    static func defaultURL(base: URL? = nil) -> URL {
        let dir = (base ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!)
            .appendingPathComponent("Brushes", isDirectory: true)
        return dir.appendingPathComponent("presets.json")
    }
}
