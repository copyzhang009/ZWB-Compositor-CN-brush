import Foundation
import CoreGraphics

/// A brush preset: a tip shape (round, or a bitmap imported from `.abr`) plus the
/// settings that travel with it. This is the on-disk model that the preset panel
/// browses and the brush tool applies.
nonisolated struct BrushPreset: Codable, Identifiable, Sendable, Equatable {
    var id: UUID
    var name: String
    /// `nil` = the round tip; otherwise the sampled bitmap imported from an ABR file.
    var tip: ABRBrush?
    /// The brush diameter in pixels, applied to whatever tip shape is selected.
    var diameter: CGFloat
    /// Edge hardness 0…1; meaningful for the round tip, ignored by sampled tips.
    var hardness: CGFloat
    /// Spacing as a percentage of the diameter (Photoshop's default is 25%).
    var spacing: CGFloat
    /// Stroke-wide opacity cap 0.01…1.
    var opacity: CGFloat
    /// Tip rotation in degrees and roundness 0…1 (PS "Angle" / "Roundness").
    var angle: CGFloat
    var roundness: CGFloat
    /// Mirrored along the horizontal/vertical axis (PS "Flip X" / "Flip Y").
    var flipX: Bool
    var flipY: Bool
    /// Tool flow 0…1 (stored now; the renderer consumes it when flow lands).
    var flow: CGFloat
    /// Shape Dynamics / Transfer settings from the preset.
    var dynamics: BrushDynamics
    /// The library this preset came from — the `.abr` file's name when imported.
    /// `nil` for the built-in round brush. Drives the preset panel's grouping.
    var group: String?

    init(id: UUID = UUID(), name: String, tip: ABRBrush? = nil,
         diameter: CGFloat = 40, hardness: CGFloat = 1, spacing: CGFloat = 25, opacity: CGFloat = 1,
         angle: CGFloat = 0, roundness: CGFloat = 1, flipX: Bool = false, flipY: Bool = false,
         flow: CGFloat = 1, dynamics: BrushDynamics = BrushDynamics(), group: String? = nil) {
        self.id = id
        self.name = name
        self.tip = tip
        self.diameter = diameter
        self.hardness = hardness
        self.spacing = spacing
        self.opacity = opacity
        self.angle = angle
        self.roundness = roundness
        self.flipX = flipX
        self.flipY = flipY
        self.flow = flow
        self.dynamics = dynamics
        self.group = group
    }

    /// The default round brush, as used before any preset is chosen. Spacing 0
    /// keeps Compositor's own tight auto-spacing (a preset from Photoshop would
    /// carry the 25% spacing its file specifies).
    static let round = BrushPreset(name: "圆形笔刷", tip: nil, diameter: 40, hardness: 1, spacing: 0, opacity: 1)

    /// The starter library — the everyday brushes Photoshop ships, described with
    /// Compositor's own model. Built in code rather than by bundling Adobe's brush
    /// files, so there is nothing to redistribute and nothing to add to the Xcode
    /// project. These live under the built-in (nil) group.
    static let builtInDefaults: [BrushPreset] = {
        func dynamics(size: Bool = false, opacity: Bool = false, flow: Bool = false,
                      sizeJitter: CGFloat = 0, flowMinimum: CGFloat = 0) -> BrushDynamics {
            var d = BrushDynamics()
            if size { d.size = PSDynamic(control: .penPressure) }
            if sizeJitter > 0 { d.size.jitter = sizeJitter }
            if opacity { d.opacity = PSDynamic(control: .penPressure) }
            if flow { d.flow = PSDynamic(control: .penPressure, minimum: flowMinimum) }
            return d
        }
        return [
            BrushPreset(name: "柔边圆", diameter: 30, hardness: 0, spacing: 25),
            BrushPreset(name: "硬边圆", diameter: 12, hardness: 1, spacing: 25),
            BrushPreset(name: "柔边圆 · 压感大小", diameter: 30, hardness: 0, spacing: 25,
                        dynamics: dynamics(size: true)),
            BrushPreset(name: "硬边圆 · 压感大小", diameter: 12, hardness: 1, spacing: 25,
                        dynamics: dynamics(size: true)),
            BrushPreset(name: "柔边圆 · 压感不透明度", diameter: 30, hardness: 0, spacing: 25,
                        dynamics: dynamics(opacity: true)),
            BrushPreset(name: "硬边圆 · 压感不透明度", diameter: 12, hardness: 1, spacing: 25,
                        dynamics: dynamics(opacity: true)),
            BrushPreset(name: "硬边圆 · 压感大小与不透明度", diameter: 12, hardness: 1, spacing: 25,
                        dynamics: dynamics(size: true, opacity: true)),
            BrushPreset(name: "柔边圆 · 压感大小与流量", diameter: 30, hardness: 0, spacing: 25,
                        dynamics: dynamics(size: true, flow: true)),
            BrushPreset(name: "喷枪", diameter: 60, hardness: 0, spacing: 10,
                        flow: 0.12, dynamics: dynamics(flow: true, flowMinimum: 0.1)),
            BrushPreset(name: "椭圆软笔", diameter: 40, hardness: 0.3, spacing: 25,
                        angle: 45, roundness: 0.4),
            BrushPreset(name: "粉笔", diameter: 20, hardness: 0.85, spacing: 15,
                        dynamics: dynamics(size: true, sizeJitter: 0.25)),
            BrushPreset(name: "散点笔", diameter: 24, hardness: 0.9, spacing: 120,
                        dynamics: dynamics(size: true, sizeJitter: 0.6)),
        ]
    }()

    /// What a fresh library starts with: the round brush, then the starter set.
    static var defaultLibrary: [BrushPreset] { [.round] + builtInDefaults }

    /// Builds a preset from a fully parsed `.abr` descriptor entry.
    init(abr: ABRPreset, group: String? = nil) {
        self.init(name: abr.name, tip: abr.tip, diameter: abr.diameter,
                  hardness: abr.hardness, spacing: abr.spacing, opacity: 1,
                  angle: abr.angle, roundness: abr.roundness,
                  flipX: abr.flipX, flipY: abr.flipY,
                  flow: abr.flow, dynamics: abr.dynamics, group: group)
    }

    // Newer fields decode with their defaults so a library saved by an earlier
    // build still loads after an upgrade.
    private enum CodingKeys: String, CodingKey {
        case id, name, tip, diameter, hardness, spacing, opacity
        case angle, roundness, flipX, flipY, flow, dynamics, group
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        tip = try c.decodeIfPresent(ABRBrush.self, forKey: .tip)
        diameter = try c.decode(CGFloat.self, forKey: .diameter)
        hardness = try c.decode(CGFloat.self, forKey: .hardness)
        spacing = try c.decode(CGFloat.self, forKey: .spacing)
        opacity = try c.decode(CGFloat.self, forKey: .opacity)
        angle = try c.decodeIfPresent(CGFloat.self, forKey: .angle) ?? 0
        roundness = try c.decodeIfPresent(CGFloat.self, forKey: .roundness) ?? 1
        flipX = try c.decodeIfPresent(Bool.self, forKey: .flipX) ?? false
        flipY = try c.decodeIfPresent(Bool.self, forKey: .flipY) ?? false
        flow = try c.decodeIfPresent(CGFloat.self, forKey: .flow) ?? 1
        dynamics = try c.decodeIfPresent(BrushDynamics.self, forKey: .dynamics) ?? BrushDynamics()
        group = try c.decodeIfPresent(String.self, forKey: .group)
    }
}

extension ABRBrush: Codable {
    private enum CodingKeys: String, CodingKey {
        case name, width, height, spacing, coverage
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        width = try c.decode(Int.self, forKey: .width)
        height = try c.decode(Int.self, forKey: .height)
        spacing = try c.decode(CGFloat.self, forKey: .spacing)
        let b64 = try c.decode(String.self, forKey: .coverage)
        coverage = Array(Data(base64Encoded: b64) ?? Data())
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(width, forKey: .width)
        try c.encode(height, forKey: .height)
        try c.encode(spacing, forKey: .spacing)
        try c.encode(Data(coverage).base64EncodedString(), forKey: .coverage)
    }
}

extension ABRBrush {
    /// The tip as white pixels whose alpha follows the coverage — what a preview
    /// draws to show the real tip shape instead of a plain circle. Non-premultiplied
    /// so the white stays white at every alpha.
    ///
    /// `maxSize` caps the long edge: pickers and previews only ever draw a tip a
    /// few dozen pixels wide, and building a megapixel bitmap per redraw is what
    /// made the options bar stutter. Sampled with nearest-neighbour, which is all
    /// a shape thumbnail needs.
    func makeAlphaImage(maxSize: Int? = nil) -> CGImage? {
        guard width > 0, height > 0, coverage.count >= width * height else { return nil }
        let scale = maxSize.map { min(1, CGFloat($0) / CGFloat(max(width, height))) } ?? 1
        let w = max(1, Int((CGFloat(width) * scale).rounded()))
        let h = max(1, Int((CGFloat(height) * scale).rounded()))
        var pixels = [UInt8](repeating: 255, count: w * h * 4)
        if w == width, h == height {
            for i in 0..<(w * h) { pixels[i * 4 + 3] = coverage[i] }
        } else {
            for y in 0..<h {
                let sourceRow = min(height - 1, Int((CGFloat(y) + 0.5) / scale)) * width
                let row = y * w
                for x in 0..<w {
                    let source = sourceRow + min(width - 1, Int((CGFloat(x) + 0.5) / scale))
                    pixels[(row + x) * 4 + 3] = coverage[source]
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// The coverage bitmap as a grayscale image (255 = opaque), ready to stamp into a
    /// coverage context. One byte per pixel, tightly packed.
    func makeImage() -> CGImage? {
        guard width > 0, height > 0, coverage.count >= width * height else { return nil }
        guard let provider = CGDataProvider(data: Data(coverage) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
                       bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
