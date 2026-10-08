import Foundation

/// A snapshot of just the fields that define a brush's look — remembered so the
/// app reopens on the brush and the eraser that were last in use.
///
/// This is a separate type rather than `BrushSettings: Codable` on purpose:
/// Swift refuses to synthesise `Codable` in an extension that lives in a
/// different file from the type, and hand-writing the conformance would add a
/// standing maintenance cost to an upstream file every time it gains a field.
private struct StoredSettings: Codable {
    var diameter: CGFloat
    var hardness: CGFloat
    var spacing: CGFloat
    var opacity: CGFloat
    var angle: CGFloat
    var roundness: CGFloat
    var flipX: Bool
    var flipY: Bool
    var flow: CGFloat
    var dynamics: BrushDynamics
    var tip: ABRBrush?

    init(_ settings: BrushSettings) {
        diameter = settings.diameter
        hardness = settings.hardness
        spacing = settings.spacing
        opacity = settings.opacity
        angle = settings.angle
        roundness = settings.roundness
        flipX = settings.flipX
        flipY = settings.flipY
        flow = settings.flow
        dynamics = settings.dynamics
        tip = settings.tip
    }

    /// Copies the snapshot back over a live settings value, leaving everything
    /// else (colour, smoothing, tool state) as it is.
    func applied(to settings: BrushSettings) -> BrushSettings {
        var out = settings
        out.diameter = diameter
        out.hardness = hardness
        out.spacing = spacing
        out.opacity = opacity
        out.angle = angle
        out.roundness = roundness
        out.flipX = flipX
        out.flipY = flipY
        out.flow = flow
        out.dynamics = dynamics
        out.tip = tip
        return out
    }
}

/// Stored at file scope: extensions can't hold stored properties.
private enum BrushStyleStore {
    static let key = "brushStyles.v1"
    static var restored = false
}

private struct StoredStyle: Codable {
    var settings: StoredSettings
    var presetID: UUID?
}

private struct StoredStyles: Codable {
    var paint: StoredStyle?
    var erase: StoredStyle?
}

extension EditorSession {
    /// Writes both styles — the one in use and the stashed other — so whatever
    /// the app was last doing is what reopens.
    func persistBrushStyles() {
        let current = StoredStyle(settings: StoredSettings(brushSettings), presetID: currentBrushPresetID)
        var stored = StoredStyles()
        if brushMode == .erase {
            stored.erase = current
            stored.paint = paintBrushStyle.map { StoredStyle(settings: StoredSettings($0.settings), presetID: $0.presetID) }
        } else {
            stored.paint = current
            stored.erase = eraseBrushStyle.map { StoredStyle(settings: StoredSettings($0.settings), presetID: $0.presetID) }
        }
        guard let data = try? JSONEncoder().encode(stored) else { return }
        UserDefaults.standard.set(data, forKey: BrushStyleStore.key)
    }

    /// Restores them once per launch.
    func restoreBrushStyles() {
        guard !BrushStyleStore.restored else { return }
        BrushStyleStore.restored = true
        guard let data = UserDefaults.standard.data(forKey: BrushStyleStore.key),
              let stored = try? JSONDecoder().decode(StoredStyles.self, from: data) else { return }

        paintBrushStyle = stored.paint.map { ($0.settings.applied(to: brushSettings), $0.presetID) }
        eraseBrushStyle = stored.erase.map { ($0.settings.applied(to: brushSettings), $0.presetID) }
        guard let own = brushMode == .erase ? stored.erase : stored.paint else { return }
        brushSettings = own.settings.applied(to: brushSettings)
        currentBrushPresetID = own.presetID
    }
}
