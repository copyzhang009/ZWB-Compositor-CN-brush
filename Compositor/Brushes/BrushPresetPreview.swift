import SwiftUI
import AppKit

/// Caches the small white tip images the pickers and previews draw.
///
/// A brush tip can be a megapixel bitmap. Rebuilding it inside a SwiftUI body
/// means rebuilding it on *every* redraw — which is what made the options bar
/// stutter once it carried a thumbnail. Keyed by identity and target size, and
/// held in an NSCache so a big library can't grow without bound.
enum BrushTipThumbnails {
    private static let cache = NSCache<NSString, NSImage>()

    /// `identity` should be stable for the brush (its preset id); the size is part
    /// of the key so pickers and previews don't fight over one entry.
    static func image(for tip: ABRBrush, identity: String, maxSize: Int) -> NSImage? {
        let key = "\(identity)|\(maxSize)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let cgImage = tip.makeAlphaImage(maxSize: maxSize) else { return nil }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        cache.setObject(image, forKey: key)
        return image
    }

    /// A stable identity for a tip with no preset behind it (a hand-tuned brush).
    /// Size alone can repeat across a library, so a few leading coverage bytes join
    /// the key to keep two tips of the same size apart.
    static func identity(for tip: ABRBrush) -> String {
        let head = tip.coverage.prefix(8).map(String.init).joined(separator: ",")
        return "tip-\(tip.width)x\(tip.height)-\(head)"
    }
}

/// Caches a preset's whole stroke preview as an image.
///
/// The library panel shows one preview per brush. Drawing each of them live means
/// dozens of canvases re-rendering on every scroll and redraw; rendering each
/// once and keeping the bitmap is what makes the list cheap. Keyed by preset and
/// size.
enum BrushStrokeThumbnails {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(for preset: BrushPreset, size: CGSize) -> NSImage? {
        let key = "\(preset.id.uuidString)|\(Int(size.width))x\(Int(size.height))" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let renderer = ImageRenderer(content: BrushStrokePreview(
            tip: preset.tip, diameter: preset.diameter, hardness: preset.hardness,
            spacing: preset.spacing, roundness: preset.roundness, angle: preset.angle,
            opacity: preset.opacity, sizeJitter: preset.dynamics.size.jitter,
            roundnessJitter: preset.dynamics.roundness.jitter,
            angleJitter: preset.dynamics.angle.jitter,
            opacityJitter: preset.dynamics.opacity.jitter,
            fadeSteps: 0,
            scatterAmount: preset.dynamics.scatterAmount,
            scatterCount: preset.dynamics.scatterCount,
            scatterBothAxes: preset.dynamics.scatterBothAxes,
            taper: true, background: nil, insets: 14, wave: 0.22)
            .frame(width: size.width, height: size.height))
        renderer.scale = 1
        guard let cgImage = renderer.cgImage else { return nil }
        let image = NSImage(cgImage: cgImage, size: size)
        cache.setObject(image, forKey: key)
        return image
    }

    /// Drops every cached preview — call after a preset is edited or removed.
    static func invalidateAll() {
        cache.removeAllObjects()
    }
}

/// Paints a short stroke with a brush's own settings, the way Photoshop's preview
/// does: dabs laid along a wave at the brush's spacing, tapered as if drawn by
/// hand, using the **real tip bitmap** when the brush has one — so an imported
/// branch-shaped tip previews as that shape, not as a plain circle.
struct BrushStrokePreview: View {
    var tip: ABRBrush?
    var diameter: CGFloat = 25
    var hardness: CGFloat = 0
    /// Percent of the diameter; 0 means the automatic spacing the renderer uses.
    var spacing: CGFloat = 0
    var roundness: CGFloat = 1
    var angle: CGFloat = 0
    var opacity: CGFloat = 1
    var sizeJitter: CGFloat = 0
    /// The Shape Dynamics / Transfer jitter channels, so the preview actually
    /// shows what changing them does — otherwise they look inert.
    var roundnessJitter: CGFloat = 0
    var angleJitter: CGFloat = 0
    var opacityJitter: CGFloat = 0
    /// Fade over this many dabs (0 = off), matching the Fade control.
    var fadeSteps = 0
    /// Scatter: how many dabs land per step and how far they stray.
    var scatterAmount: CGFloat = 0
    var scatterCount: CGFloat = 1
    var scatterBothAxes = false
    /// Whether both ends taper, as a hand-drawn stroke does.
    var taper = true
    /// Solid backing, or nil to draw only the stroke (a list row supplies its own).
    var background: Color? = Color(white: 0.56)
    var insets: CGFloat = 26
    /// Wave depth as a fraction of the height; 0 draws a straight stroke.
    var wave: CGFloat = 0.24

    var body: some View {
        Canvas { context, size in
            let inset = min(insets, size.width * 0.18)
            let width = max(1, size.width - inset * 2)
            let height = max(1, size.height)
            func curve(_ t: CGFloat) -> CGPoint {
                CGPoint(x: inset + width * t, y: height * (0.54 - wave * sin(t * .pi)))
            }
            let scale = min(1, height * 0.6 / max(4, diameter))
            let radius = max(1.1, diameter * scale / 2)
            // Match the renderer: 0 spacing means the automatic fraction, not "none".
            let fraction = spacing > 0 ? spacing / 100 : BrushStroke.spacingFraction(hardness)
            let step = max(1, radius * 2 * fraction * 0.9)
            // Capped: past a couple of hundred dabs the preview looks the same but
            // costs proportionally more, and this redraws while a slider is dragged.
            let count = max(10, min(180, Int(width / step)))
            let radians = angle * .pi / 180
            let aspect = tip.map { CGFloat($0.height) / CGFloat(max(1, $0.width)) } ?? 1
            // Cached and downsampled: a preview row must never rebuild a megapixel tip.
            let resolvedTip = tip
                .flatMap { BrushTipThumbnails.image(for: $0, identity: BrushTipThumbnails.identity(for: $0), maxSize: 96) }
                .map { context.resolve(Image(nsImage: $0)) }

            context.drawLayer { layer in
                if tip == nil, hardness < 0.99 {
                    layer.addFilter(.blur(radius: radius * (1 - hardness) * 0.8))
                }
                for i in 0...count {
                    let t = CGFloat(i) / CGFloat(count)
                    let point = curve(t)
                    var pressure = taper ? 0.3 + 0.7 * sin(t * .pi) : 1
                    if fadeSteps > 0 { pressure *= max(0, 1 - CGFloat(i) / CGFloat(max(1, fadeSteps))) }
                    let sizeJ = sizeJitter > 0 ? 1 + sizeJitter * noise(i) : 1
                    let roundJ = roundnessJitter > 0 ? 1 + roundnessJitter * noise(i &+ 977) : 1
                    let angleJ = angleJitter > 0 ? angleJitter * 180 * noise(i &+ 131) : 0
                    let alphaJ = opacityJitter > 0 ? 1 + opacityJitter * noise(i &+ 613) : 1
                    let r = max(0.9, radius * pressure * sizeJ)
                    let alpha = Double(opacity) * Double(0.4 + 0.6 * pressure) * Double(max(0, alphaJ))
                    // Scatter draws several dabs at this step, each nudged off the
                    // path — so the preview shows it the way the canvas will.
                    let copies = max(1, min(12, Int(scatterCount.rounded())))
                    for copy in 0..<copies {
                        var origin = point
                        if scatterAmount > 0 {
                            let spread = r * 2 * scatterAmount
                            let across = noise(i &* 31 &+ copy) * spread
                            origin = scatterBothAxes
                                ? CGPoint(x: point.x + noise(i &* 17 &+ copy) * spread, y: point.y + across)
                                : CGPoint(x: point.x, y: point.y + across)
                        }
                        if let resolvedTip {
                            // The tip's own shape, kept at its aspect ratio.
                            let w = r * 2, h = r * 2 * aspect
                            layer.draw(resolvedTip, in: CGRect(x: origin.x - w / 2, y: origin.y - h / 2,
                                                               width: w, height: h))
                        } else {
                            let shape = Path(ellipseIn: CGRect(x: -r, y: -r, width: r * 2, height: r * 2))
                                .applying(CGAffineTransform(translationX: origin.x, y: origin.y)
                                    .rotated(by: radians + angleJ * .pi / 180)
                                    .scaledBy(x: 1, y: min(1, max(0.05, roundness * roundJ))))
                            layer.fill(shape, with: .color(.white.opacity(alpha)))
                        }
                    }
                }
            }
        }
        .background {
            if let background {
                RoundedRectangle(cornerRadius: 4).fill(background)
            }
        }
        .overlay {
            if background != nil {
                RoundedRectangle(cornerRadius: 4).strokeBorder(.black.opacity(0.25), lineWidth: 1)
            }
        }
    }

    /// Deterministic ±1 noise so a preview doesn't flicker while a slider is dragged.
    private func noise(_ index: Int) -> CGFloat {
        var value = UInt64(bitPattern: Int64(index &* 2654435761))
        value ^= value >> 13; value = value &* 0x9E3779B97F4A7C15; value ^= value >> 7
        return CGFloat(value % 2000) / 1000 - 1
    }
}
