import AppKit

extension EditorSession {
    /// The shared brush-preset library, common to every open project. Presets are
    /// not per-document, so one store serves all tabs.
    var brushPresets: BrushPresetStore {
        Self.sharedBrushPresets
    }
    private static let sharedBrushPresets = BrushPresetStore.load(from: BrushPresetStore.defaultURL())

    /// Stashes the style of the mode being left and restores the one being
    /// entered, so the brush and the eraser each remember their own tip. The
    /// first time a mode is entered it simply keeps what is already set.
    func swapBrushStyle(from previous: BrushToolMode) {
        let leaving = (settings: brushSettings, presetID: currentBrushPresetID)
        if previous == .erase { eraseBrushStyle = leaving } else { paintBrushStyle = leaving }
        defer { persistBrushStyles() }
        guard let entering = brushMode == .erase ? eraseBrushStyle : paintBrushStyle else { return }
        brushSettings = entering.settings
        currentBrushPresetID = entering.presetID
    }

    /// Applies a preset to the brush tool's settings and remembers which preset it
    /// was, so the preset picker and the brush settings panel agree on the current
    /// brush. Hardness is applied for sampled tips too — it drives their automatic
    /// dab spacing even though it doesn't soften the bitmap.
    func selectBrushPreset(_ preset: BrushPreset) {
        brushSettings.tip = preset.tip
        brushSettings.diameter = preset.diameter
        brushSettings.hardness = preset.hardness
        brushSettings.opacity = preset.opacity
        brushSettings.spacing = preset.spacing
        brushSettings.angle = preset.angle
        brushSettings.roundness = preset.roundness
        brushSettings.flipX = preset.flipX
        brushSettings.flipY = preset.flipY
        brushSettings.flow = preset.flow
        brushSettings.dynamics = preset.dynamics
        currentBrushPresetID = preset.id
        persistBrushStyles()
    }

    /// Parses `.abr` data, appends the brushes to the library under `group`, and
    /// persists it. Returns the number of brushes added (0 on failure).
    @discardableResult
    func importBrushPresets(_ data: Data, group: String? = nil) -> Int {
        guard let added = try? brushPresets.importABR(data, group: group) else { return 0 }
        if !added.isEmpty {
            try? brushPresets.save(to: BrushPresetStore.defaultURL())
        }
        return added.count
    }

    /// Removes one preset from the library and persists it, dropping the selection
    /// when it pointed at the preset that just went away.
    func removeBrushPreset(_ preset: BrushPreset) {
        brushPresets.remove(preset)
        if currentBrushPresetID == preset.id { currentBrushPresetID = nil }
        try? brushPresets.save(to: BrushPresetStore.defaultURL())
    }

    /// Removes a whole imported library at once.
    func removeBrushGroup(_ group: String) {
        let ids = Set(brushPresets.presets.filter { $0.group == group }.map(\.id))
        brushPresets.removeGroup(group)
        if let current = currentBrushPresetID, ids.contains(current) { currentBrushPresetID = nil }
        persistBrushLibrary()
    }

    /// Saves the brush as it is set right now as a new preset, under `name`.
    /// Returns the stored preset (with its new id) so the panel can highlight it.
    @discardableResult
    func saveBrushPreset(named name: String, group: String? = "自定义") -> BrushPreset? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let settings = brushSettings
        brushPresets.append(BrushPreset(name: trimmed, tip: settings.tip, diameter: settings.diameter,
                                        hardness: settings.hardness, spacing: settings.spacing,
                                        opacity: settings.opacity, angle: settings.angle,
                                        roundness: settings.roundness, flipX: settings.flipX,
                                        flipY: settings.flipY, flow: settings.flow,
                                        dynamics: settings.dynamics),
                            group: group)
        persistBrushLibrary()
        let stored = brushPresets.presets.last
        if let stored { currentBrushPresetID = stored.id }
        return stored
    }

    /// Moves a brush into another group (nil = the built-in group), as dragging
    /// it onto a folder does.
    func moveBrushPreset(_ preset: BrushPreset, to group: String?) {
        brushPresets.move(preset, to: group)
        persistBrushLibrary()
    }

    /// Drops a brush between two others: into `group`, at `index` within it.
    func moveBrushPreset(_ preset: BrushPreset, to group: String?, at index: Int) {
        brushPresets.move(preset, to: group, at: index)
        persistBrushLibrary()
    }

    /// Renames one brush.
    func renameBrushPreset(_ preset: BrushPreset, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        brushPresets.rename(preset, to: trimmed)
        persistBrushLibrary()
    }

    /// Creates an empty group to drag brushes into. False when the name is taken.
    @discardableResult
    func addBrushGroup(_ name: String) -> Bool {
        guard brushPresets.addGroup(name) else { return false }
        persistBrushLibrary()
        return true
    }

    /// Renames a group, carrying its brushes along.
    func renameBrushGroup(_ group: String, to name: String) {
        brushPresets.renameGroup(group, to: name)
        persistBrushLibrary()
    }

    private func persistBrushLibrary() {
        try? brushPresets.save(to: BrushPresetStore.defaultURL())
    }
}
