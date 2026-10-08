import CoreGraphics
import Foundation

/// Where a dynamic value (size, angle, roundness, opacity, flow) takes its
/// input, matching Photoshop's Control pop-ups. The raw numbers are the
/// `bVTy` codes stored in `.abr` descriptors.
nonisolated enum BrushControl: String, CaseIterable, Sendable, Hashable, Codable {
    case off, fade, penPressure, penTilt, stylusWheel, rotation, initialDirection, direction

    /// Whether the renderer actually reads this source. Tilt, wheel, rotation and
    /// direction need inputs Compositor doesn't gather yet, so choosing them
    /// changes nothing — the panel says so instead of pretending they work.
    var isImplemented: Bool {
        switch self {
        case .off, .fade, .penPressure: true
        default: false
        }
    }

    /// The `bVTy` code Photoshop writes into brush descriptors.
    var abrCode: Int {
        switch self {
        case .off: 0
        case .fade: 1
        case .penPressure: 2
        case .penTilt: 3
        case .stylusWheel: 4
        case .rotation: 5
        case .initialDirection: 6
        case .direction: 7
        }
    }

    static func from(abrCode: Int) -> BrushControl {
        BrushControl.allCases.first { $0.abrCode == abrCode } ?? .off
    }

    nonisolated var displayName: String {
        switch self {
        case .off: "关闭"
        case .fade: "渐隐"
        case .penPressure: "钢笔压力"
        case .penTilt: "钢笔斜度"
        case .stylusWheel: "光笔轮"
        case .rotation: "旋转"
        case .initialDirection: "初始方向"
        case .direction: "方向"
        }
    }
}

/// One row of Photoshop's Shape Dynamics / Transfer panels: the control
/// source, its parameters, and how far the value may randomly jitter per dab.
nonisolated struct PSDynamic: Sendable, Equatable, Codable {
    /// What drives the value between `minimum` and full.
    var control: BrushControl = .off
    /// Steps for the Fade control (1 stroke = `fadeSteps` dabs from full to minimum).
    var fadeSteps: Int = 25
    /// 0…1 random per-dab variation (PS "Jitter").
    var jitter: CGFloat = 0
    /// 0…1 fraction kept at the control's low end (PS "Minimum …").
    var minimum: CGFloat = 0

    init(control: BrushControl = .off, fadeSteps: Int = 25, jitter: CGFloat = 0, minimum: CGFloat = 0) {
        self.control = control
        self.fadeSteps = max(1, fadeSteps)
        self.jitter = min(1, max(0, jitter))
        self.minimum = min(1, max(0, minimum))
    }
}

/// The Shape Dynamics / Transfer settings, matching Photoshop's panels. Each
/// channel is one PSDynamic; pen pressure is the only control source wired
/// into rendering so far — the others parse, persist, and display, but act
/// like `.off` until their input lands.
nonisolated struct BrushDynamics: Sendable, Equatable, Codable {
    // Shape Dynamics
    var size = PSDynamic(control: .penPressure)
    /// PS "Minimum Diameter", a preset-level floor shared by the size channel.
    var minimumDiameter: CGFloat = 0.1
    var angle = PSDynamic()
    var roundness = PSDynamic()
    /// PS "Minimum Roundness", preset-level, 0…1.
    var minimumRoundness: CGFloat = 1
    /// PS "Tilt Scale" in percent (100 = natural), used by the tilt control.
    var tiltScale: CGFloat = 2
    // Transfer
    var opacity = PSDynamic()
    var flow = PSDynamic()
    /// Scatter: how far dabs stray from the stroke (a fraction of the diameter),
    /// how many land at each spacing step, how much that count varies, and
    /// whether the straying is sideways only or in both axes.
    var scatterAmount: CGFloat = 0
    var scatterCount: CGFloat = 1
    var scatterCountJitter: CGFloat = 0
    var scatterBothAxes = false

    // Hand-written so a library saved before these fields existed still loads —
    // a synthesised decoder would fail on the missing keys and the whole library
    // would silently fall back to defaults.
    private enum CodingKeys: String, CodingKey {
        case size, angle, roundness, opacity, flow
        case minimumDiameter, minimumRoundness, tiltScale
        case scatterAmount, scatterCount, scatterCountJitter, scatterBothAxes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        size = try c.decodeIfPresent(PSDynamic.self, forKey: .size) ?? PSDynamic(control: .penPressure)
        angle = try c.decodeIfPresent(PSDynamic.self, forKey: .angle) ?? PSDynamic()
        roundness = try c.decodeIfPresent(PSDynamic.self, forKey: .roundness) ?? PSDynamic()
        opacity = try c.decodeIfPresent(PSDynamic.self, forKey: .opacity) ?? PSDynamic()
        flow = try c.decodeIfPresent(PSDynamic.self, forKey: .flow) ?? PSDynamic()
        minimumDiameter = try c.decodeIfPresent(CGFloat.self, forKey: .minimumDiameter) ?? 0.1
        minimumRoundness = try c.decodeIfPresent(CGFloat.self, forKey: .minimumRoundness) ?? 1
        tiltScale = try c.decodeIfPresent(CGFloat.self, forKey: .tiltScale) ?? 2
        scatterAmount = try c.decodeIfPresent(CGFloat.self, forKey: .scatterAmount) ?? 0
        scatterCount = try c.decodeIfPresent(CGFloat.self, forKey: .scatterCount) ?? 1
        scatterCountJitter = try c.decodeIfPresent(CGFloat.self, forKey: .scatterCountJitter) ?? 0
        scatterBothAxes = try c.decodeIfPresent(Bool.self, forKey: .scatterBothAxes) ?? false
    }

    init() {}

    /// Builds dynamics from a parsed brush descriptor, taking Photoshop's
    /// preset-level minimums where present (they win over the per-channel
    /// `Mnm` values inside `szVr`/`opVr`/`prVr`).
    init(preset: PSDValue) {
        self.init()
        func dynamic(_ key: String) -> PSDynamic {
            guard let object = preset.item(key) else { return PSDynamic() }
            return PSDynamic(
                control: BrushControl.from(abrCode: object.item("bVTy")?.intValue ?? 0),
                fadeSteps: object.item("fStp")?.intValue ?? 25,
                jitter: CGFloat((object.item("jitter")?.doubleValue ?? 0) / 100),
                minimum: CGFloat((object.item("Mnm")?.doubleValue ?? 0) / 100))
        }
        let useTip = preset.item("useTipDynamics")?.boolValue ?? false
        let usePaint = preset.item("usePaintDynamics")?.boolValue ?? false
        size = useTip ? dynamic("szVr") : PSDynamic(control: .off)
        angle = useTip ? dynamic("angleDynamics") : PSDynamic()
        roundness = useTip ? dynamic("roundnessDynamics") : PSDynamic()
        opacity = usePaint ? dynamic("opVr") : PSDynamic()
        flow = usePaint ? dynamic("prVr") : PSDynamic()
        if let value = preset.item("minimumDiameter")?.doubleValue { minimumDiameter = CGFloat(value / 100) }
        if let value = preset.item("minimumRoundness")?.doubleValue { minimumRoundness = CGFloat(value / 100) }
        if let value = preset.item("tiltScale")?.doubleValue { tiltScale = CGFloat(value / 100) }
        // Scatter, when the brush carries it: Photoshop writes `scatterDynamics`
        // only for brushes that scatter. `brVr` is the amount, `Cnt` the dab count.
        if let scatter = preset.item("scatterDynamics") {
            scatterAmount = CGFloat((scatter.item("brVr")?.doubleValue ?? 0) / 100)
            scatterCountJitter = CGFloat((preset.item("countDynamics")?.item("jitter")?.doubleValue ?? 0) / 100)
        }
        if let count = preset.item("Cnt")?.doubleValue { scatterCount = max(1, CGFloat(count)) }
        scatterBothAxes = preset.item("bothAxes")?.boolValue ?? false
        // `useTipDynamics` off means Photoshop renders the tip at a constant
        // size; keep the channel's parsed control but floor the minimum at 1.
        if !useTip { minimumDiameter = 1 }
    }

    /// 0…1 value of a control source. Pen pressure and Fade are wired; the rest
    /// (tilt, wheel, rotation, direction) need inputs Compositor doesn't gather
    /// yet, so they read as full and behave like a constant.
    func controlValue(_ channel: PSDynamic, pressure: CGFloat, fadeStep: Int = 0) -> CGFloat {
        switch channel.control {
        case .penPressure:
            return min(1, max(0, pressure))
        case .fade:
            // Fade runs from full to the channel's minimum over `fadeSteps` dabs.
            let steps = max(1, channel.fadeSteps)
            return max(0, 1 - CGFloat(fadeStep) / CGFloat(steps))
        default:
            return 1
        }
    }

    /// The diameter multiplier at a given pen pressure: the control maps the
    /// value between the minimum diameter and full. With the control off the
    /// brush stays at the base diameter (jitter applies per dab at render).
    func sizeFactor(pressure: CGFloat, fadeStep: Int = 0) -> CGFloat {
        size.control == .off ? 1
            : minimumDiameter + (1 - minimumDiameter) * controlValue(size, pressure: pressure, fadeStep: fadeStep)
    }

    /// The per-dab opacity multiplier at a given pen pressure.
    func opacityFactor(pressure: CGFloat, fadeStep: Int = 0) -> CGFloat {
        opacity.control == .off ? 1
            : opacity.minimum + (1 - opacity.minimum) * controlValue(opacity, pressure: pressure, fadeStep: fadeStep)
    }

    /// The per-dab flow multiplier at a given pen pressure.
    func flowFactor(pressure: CGFloat, fadeStep: Int = 0) -> CGFloat {
        flow.control == .off ? 1
            : flow.minimum + (1 - flow.minimum) * controlValue(flow, pressure: pressure, fadeStep: fadeStep)
    }

    /// The roundness multiplier (0…1) at a given pen pressure. With the control
    /// off the tip keeps its base roundness.
    func roundnessFactor(pressure: CGFloat, fadeStep: Int = 0) -> CGFloat {
        roundness.control == .off ? 1
            : minimumRoundness + (1 - minimumRoundness) * controlValue(roundness, pressure: pressure, fadeStep: fadeStep)
    }

    /// Symmetric ± jitter for a channel: 1 + jitter × U(-1, 1). A channel with no
    /// jitter returns exactly 1, so the default brush is untouched.
    func jitterFactor(_ channel: PSDynamic) -> CGFloat {
        channel.jitter <= 0 ? 1 : 1 + channel.jitter * CGFloat.random(in: -1...1)
    }

    /// The per-dab angle contribution (degrees) from the angle channel. The base
    /// angle lives on the tip (`BrushSettings.angle`); the channel either adds a
    /// random jitter or follows the stroke direction when its control source is
    /// initial/ongoing direction.
    /// `initialDirectionDegrees` is the direction the stroke began with. Photoshop
    /// distinguishes the two sources: Direction turns the tip with the hand as it
    /// goes, Initial Direction freezes it at the angle the stroke started from.
    func angleContribution(directionDegrees: CGFloat, initialDirectionDegrees: CGFloat? = nil) -> CGFloat {
        var result: CGFloat = 0
        switch angle.control {
        case .direction:
            result += directionDegrees
        case .initialDirection:
            result += initialDirectionDegrees ?? directionDegrees
        default:
            break
        }
        if angle.jitter > 0 { result += angle.jitter * 180 * CGFloat.random(in: -1...1) }
        return result
    }
}
