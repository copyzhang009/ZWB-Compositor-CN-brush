import SwiftUI
import AppKit

/// Photoshop's parameter groups, in its order. The ones Compositor doesn't
/// render yet are still listed — greyed with a lock — so the panel reads like
/// Photoshop's and nothing looks missing.
enum BrushSettingsGroup: String, CaseIterable, Sendable {
    case tipShape, shapeDynamics, scatter, texture, dualBrush, colorDynamics
    case transfer, brushPose, noise, wetEdges, buildUp, smoothing, protectTexture

    var displayName: String {
        switch self {
        case .tipShape: "画笔笔尖形状"
        case .shapeDynamics: "形状动态"
        case .scatter: "散布"
        case .texture: "纹理"
        case .dualBrush: "双重画笔"
        case .colorDynamics: "颜色动态"
        case .transfer: "传递"
        case .brushPose: "画笔笔势"
        case .noise: "杂色"
        case .wetEdges: "湿边"
        case .buildUp: "建立"
        case .smoothing: "平滑"
        case .protectTexture: "保护纹理"
        }
    }

    /// The groups the renderer implements; the rest are listed but inert.
    var isImplemented: Bool {
        switch self {
        case .tipShape, .shapeDynamics, .transfer, .scatter: true
        default: false
        }
    }
}

/// Photoshop's brush settings dialog, rebuilt around what each control *does*
/// rather than how it looks: the loaded-brush picker on top, the parameter
/// groups down the left, and a pressure-aware stroke preview along the bottom.
struct BrushSettingsPanel: View {
    @Bindable var session: EditorSession
    @State private var group: BrushSettingsGroup = .tipShape
    @State private var presets: [BrushPreset] = []
    @State private var showsSave = false
    @State private var newName = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                groupList.frame(width: 158)
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    brushPicker
                    Divider()
                    ScrollView(.vertical, showsIndicators: true) {
                        Group {
                            switch group {
                            case .tipShape: tipShape
                            case .shapeDynamics: shapeDynamics
                            case .transfer: transfer
                            case .scatter: scatter
                            default:
                                Text("Photoshop 的这一项 Compositor 还没有实现。")
                                    .font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(.bottom, 10)
                    }
                }
                .padding(14)
                .frame(width: 500)
            }
            Divider()
            // The stroke the current settings would paint — with the brush's own
            // tip shape, so an imported tip previews as itself, and turning or
            // squashing the tip shows up right here.
            // Bound to locals first: nineteen chained property lookups in one
            // call overload the type checker, which then reports a bogus
            // "no exact matches in call to initializer".
            let brush = session.brushSettings
            let dynamics = brush.dynamics
            BrushStrokePreview(tip: brush.tip,
                               diameter: brush.diameter,
                               hardness: brush.hardness,
                               spacing: brush.spacing,
                               roundness: brush.roundness,
                               angle: brush.angle,
                               opacity: brush.opacity,
                               sizeJitter: dynamics.size.jitter,
                               roundnessJitter: dynamics.roundness.jitter,
                               angleJitter: dynamics.angle.jitter,
                               opacityJitter: dynamics.opacity.jitter,
                               fadeSteps: activeFadeSteps,
                               scatterAmount: dynamics.scatterAmount,
                               scatterCount: dynamics.scatterCount,
                               scatterBothAxes: dynamics.scatterBothAxes,
                               taper: true,
                               background: Color(white: 0.56),
                               insets: 26,
                               wave: 0.24)
                .frame(height: 150)
                .padding(14)
        }
        .frame(width: 680, height: 720)
        .onAppear { presets = session.brushPresets.presets }
    }

    // MARK: - Parameter groups

    private var groupList: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("画笔")
                .font(.system(size: 12, weight: .medium))
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                .padding(.horizontal, 10).padding(.vertical, 8)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(BrushSettingsGroup.allCases, id: \.self) { item in
                        Button { if item.isImplemented { group = item } } label: {
                            HStack(spacing: 7) {
                                Image(systemName: "square")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                                Text(item.displayName)
                                    .font(.system(size: 12))
                                    .foregroundStyle(item.isImplemented ? .primary : .tertiary)
                                Spacer(minLength: 0)
                                if !item.isImplemented {
                                    Image(systemName: "lock")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!item.isImplemented)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(group == item ? Color.accentColor.opacity(0.22) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .padding(.horizontal, 6)
                        .help(item.isImplemented ? "" : "Photoshop 的这一项 Compositor 还没有实现")
                    }
                }
            }
            Spacer(minLength: 0)
            Divider().padding(.vertical, 6)
            // Photoshop's New Brush: name it and it joins the library as it is set now.
            Button {
                newName = "自定义画笔 \(session.brushPresets.presets.count + 1)"
                showsSave = true
            } label: {
                Label("保存画笔…", systemImage: "plus.circle")
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .help("把当前的笔尖形状、形状动态与传递设置存为新画笔")
            .alert("保存画笔", isPresented: $showsSave) {
                TextField("名称", text: $newName)
                Button("保存") {
                    session.saveBrushPreset(named: newName)
                    presets = session.brushPresets.presets
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("将当前设置存入库中「自定义」组。")
            }
        }
        .padding(.top, 2)
    }

    // MARK: - Loaded brushes

    private var brushPicker: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 66), spacing: 6)], spacing: 6) {
                ForEach(presets) { preset in
                    brushCell(preset)
                }
            }
            .padding(.vertical, 2)
        }
        .frame(height: 186)
    }

    private func brushCell(_ preset: BrushPreset) -> some View {
        let selected = session.currentBrushPresetID == preset.id
        return Button {
            session.selectBrushPreset(preset)
        } label: {
            VStack(spacing: 3) {
                tipThumbnail(preset)
                    .frame(width: 52, height: 52)
                Text("\(Int(preset.diameter.rounded()))")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .padding(4)
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 2)
            }
        }
        .buttonStyle(.plain)
        .help("\(preset.name) · \(Int(preset.diameter.rounded())) 像素")
    }

    /// The tip's own shape: the sampled bitmap where there is one (cached and
    /// downsampled — never rebuilt per redraw), otherwise a round tip at the
    /// preset's roundness. Drawn on a dark chip so white tips read in any theme.
    @ViewBuilder
    private func tipThumbnail(_ preset: BrushPreset) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(Color(white: 0.22))
            if let tip = preset.tip,
               let image = BrushTipThumbnails.image(for: tip, identity: preset.id.uuidString, maxSize: 88) {
                Image(nsImage: image)
                    .resizable().interpolation(.medium).scaledToFit()
                    .padding(4)
            } else {
                Ellipse()
                    .fill(.white)
                    .frame(width: 30, height: max(3, 30 * preset.roundness))
                    .rotationEffect(.degrees(Double(preset.angle)))
            }
        }
    }

    // MARK: - Tip Shape

    private var tipShape: some View {
        VStack(alignment: .leading, spacing: 12) {
            psRow("大小", value: cg($session.brushSettings.diameter, 1...2000), unit: "像素")
            fullSlider(cg($session.brushSettings.diameter, 1...2000), in: 1...2000, step: 1)
            HStack(spacing: 16) {
                Toggle("翻转 X", isOn: $session.brushSettings.flipX)
                Toggle("翻转 Y", isOn: $session.brushSettings.flipY)
            }
            .toggleStyle(.checkbox)
            .font(.system(size: 12))
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 4) {
                        Text("角度：").font(.system(size: 12))
                        psField(cg($session.brushSettings.angle, -180...180), unit: "°", width: 76)
                    }
                    HStack(spacing: 4) {
                        Text("圆度：").font(.system(size: 12))
                        psField(percent($session.brushSettings.roundness), unit: "%", width: 76)
                    }
                }
                Spacer(minLength: 0)
                TipShapePreview(angle: $session.brushSettings.angle,
                                roundness: $session.brushSettings.roundness)
                    .frame(width: 132, height: 116)
            }
            VStack(alignment: .leading, spacing: 6) {
                psRow("硬度", value: percent($session.brushSettings.hardness), unit: "%")
                fullSlider(percent($session.brushSettings.hardness), in: 0...100, step: 1)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Toggle("", isOn: Binding(get: { session.brushSettings.spacing > 0 },
                                            set: { session.brushSettings.spacing = $0 ? 25 : 0 }))
                        .toggleStyle(.checkbox).labelsHidden()
                    psRow("间距", value: cg($session.brushSettings.spacing, 0...1000), unit: "%")
                }
                // The full Photoshop range: imported presets carry spacings well
                // past 100%, and clipping them would change how they paint.
                fullSlider(cg($session.brushSettings.spacing, 0...1000), in: 0...1000, step: 1)
                Text("取消勾选则由硬度自动决定间距")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Shape Dynamics

    private var shapeDynamics: some View {
        VStack(alignment: .leading, spacing: 14) {
            jitterBlock("大小抖动", jitter: $session.brushSettings.dynamics.size.jitter,
                        control: $session.brushSettings.dynamics.size.control,
                        fadeSteps: $session.brushSettings.dynamics.size.fadeSteps)
            numberBlock("最小直径", value: percent($session.brushSettings.dynamics.minimumDiameter))
            VStack(alignment: .leading, spacing: 6) {
                numberBlock("倾斜缩放", value: percent($session.brushSettings.dynamics.tiltScale, top: 999), max: 999)
                // The value is stored and saved, but the renderer doesn't read it yet.
                Text("倾斜输入尚未接入渲染，此项暂时不产生效果。")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            Divider()
            jitterBlock("角度抖动", jitter: $session.brushSettings.dynamics.angle.jitter,
                        control: $session.brushSettings.dynamics.angle.control,
                        fadeSteps: $session.brushSettings.dynamics.angle.fadeSteps)
            Divider()
            jitterBlock("圆度抖动", jitter: $session.brushSettings.dynamics.roundness.jitter,
                        control: $session.brushSettings.dynamics.roundness.control,
                        fadeSteps: $session.brushSettings.dynamics.roundness.fadeSteps)
            numberBlock("最小圆度", value: percent($session.brushSettings.dynamics.minimumRoundness))
        }
    }

    // MARK: - Transfer

    private var transfer: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Flow itself: without it reachable, a per-dab jitter can never show
            // through, because every dab already paints at full strength.
            VStack(alignment: .leading, spacing: 6) {
                psRow("流量", value: percent($session.brushSettings.flow), unit: "%")
                fullSlider(percent($session.brushSettings.flow), in: 1...100, step: 1)
            }
            Divider()
            jitterBlock("不透明度抖动", jitter: $session.brushSettings.dynamics.opacity.jitter,
                        control: $session.brushSettings.dynamics.opacity.control,
                        fadeSteps: $session.brushSettings.dynamics.opacity.fadeSteps)
            numberBlock("最小不透明度", value: percent($session.brushSettings.dynamics.opacity.minimum))
            Divider()
            jitterBlock("流量抖动", jitter: $session.brushSettings.dynamics.flow.jitter,
                        control: $session.brushSettings.dynamics.flow.control,
                        fadeSteps: $session.brushSettings.dynamics.flow.fadeSteps)
            numberBlock("最小流量", value: percent($session.brushSettings.dynamics.flow.minimum))
        }
    }

    // MARK: - Scatter

    private var scatter: some View {
        VStack(alignment: .leading, spacing: 14) {
            numberBlock("散布", value: percent($session.brushSettings.dynamics.scatterAmount, top: 1000), max: 1000)
            Toggle("两轴", isOn: $session.brushSettings.dynamics.scatterBothAxes)
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
                .help("勾选后笔迹向各个方向散开，不勾选只向笔画两侧散开")
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("数量").font(.system(size: 12))
                    Spacer(minLength: 8)
                    TextField("", value: scatterCountBinding,
                              format: .number.precision(.fractionLength(0)))
                        .frame(width: 96)
                        .multilineTextAlignment(.trailing)
                        .textFieldStyle(.roundedBorder)
                    Text("个").font(.system(size: 12))
                }
                Slider(value: scatterCountBinding, in: 1...32, step: 1)
            }
            numberBlock("数量抖动", value: percent($session.brushSettings.dynamics.scatterCountJitter))
        }
    }

    /// The dab count as a Double binding. `TextField(value:format:)` needs an
    /// exact format-style match, and there is none for a CGFloat binding — the
    /// compiler reports it as "no exact matches in call to initializer".
    private var scatterCountBinding: Binding<Double> {
        Binding(get: { Double(session.brushSettings.dynamics.scatterCount) },
                set: {
                    let value = $0.isFinite ? $0 : 1
                    session.brushSettings.dynamics.scatterCount = CGFloat(min(32, max(1, value)))
                })
    }

    // MARK: - Rows

    /// Photoshop's "label ……… [value] unit" line, the field right-aligned.
    private func psRow(_ title: String, value: Binding<Double>, unit: String) -> some View {
        HStack {
            Text(title).font(.system(size: 12))
            Spacer(minLength: 8)
            psField(value, unit: unit, width: 96)
        }
    }

    private func numberBlock(_ title: String, value: Binding<Double>, max top: Double = 100) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            psRow(title, value: value, unit: "%")
            fullSlider(value, in: 0...top, step: 1)
        }
    }

    /// One jitter channel: its amount, its control source, and — as Photoshop
    /// shows — the fade length once Fade is the source. Every row stays editable;
    /// nothing here is greyed out, so a brush can always be tuned and saved.
    private func jitterBlock(_ title: String, jitter: Binding<CGFloat>, control: Binding<BrushControl>,
                             fadeSteps: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            psRow(title, value: percent(jitter), unit: "%")
            fullSlider(percent(jitter), in: 0...100, step: 1)
            HStack(spacing: 8) {
                Text("控制").font(.system(size: 12)).foregroundStyle(.secondary)
                Picker("控制", selection: control) {
                    ForEach(BrushControl.allCases, id: \.self) { item in
                        Text(item.displayName).tag(item)
                    }
                }
                .labelsHidden().frame(width: 160)
                if control.wrappedValue == .fade {
                    Text("步数").font(.system(size: 12)).foregroundStyle(.secondary)
                    TextField("", value: fadeSteps, format: .number)
                        .frame(width: 52)
                        .multilineTextAlignment(.trailing)
                        .textFieldStyle(.roundedBorder)
                }
            }
        }
    }

    /// A right-aligned, filled value field with its unit outside, Photoshop style.
    private func psField(_ value: Binding<Double>, unit: String, width: CGFloat) -> some View {
        HStack(spacing: 4) {
            TextField("", value: value, format: .number.precision(.fractionLength(0)))
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .padding(.horizontal, 7).padding(.vertical, 4)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 3))
                .frame(width: width)
            Text(unit).font(.system(size: 12))
        }
    }

    private func fullSlider(_ value: Binding<Double>, in range: ClosedRange<Double>, step: Double) -> some View {
        Slider(value: value, in: range, step: step).frame(maxWidth: .infinity)
    }

    /// Fade steps of whichever channel is set to Fade, so the preview can show it.
    private var activeFadeSteps: Int {
        let d = session.brushSettings.dynamics
        if d.size.control == .fade { return d.size.fadeSteps }
        if d.opacity.control == .fade { return d.opacity.fadeSteps }
        if d.flow.control == .fade { return d.flow.fadeSteps }
        if d.roundness.control == .fade { return d.roundness.fadeSteps }
        return 0
    }

    // MARK: - Binding bridges

    /// A fractional setting on the panel's percent scale. `top` is the largest
    /// percent allowed — Tilt Scale is stored as a multiplier (2 = 200%).
    private func percent(_ base: Binding<CGFloat>, top: Double = 100) -> Binding<Double> {
        Binding(get: { Double(base.wrappedValue) * 100 },
                set: { base.wrappedValue = CGFloat(min(top, max(0, $0)) / 100) })
    }

    /// A raw CGFloat setting (pixels, degrees, percent) as the panel's Double field.
    private func cg(_ base: Binding<CGFloat>, _ range: ClosedRange<Double>) -> Binding<Double> {
        Binding(get: { Double(base.wrappedValue) },
                set: { base.wrappedValue = CGFloat(min(range.upperBound, max(range.lowerBound, $0))) })
    }
}

/// Photoshop's tip-shape box, as a control: the rotated ellipse shows the tip
/// angle and roundness, and its two handles drag them — the axis handle turns
/// the tip, the perpendicular handle squashes it.
private struct TipShapePreview: View {
    @Binding var angle: CGFloat
    @Binding var roundness: CGFloat

    private enum DragMode { case angle, roundness }

    /// Chosen on press, from whichever handle is nearer, and held for the drag —
    /// so a turn stays a turn even when the pointer drifts over the other handle.
    @State private var dragMode: DragMode?
    private let boxSize = CGSize(width: 132, height: 116)

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let rx = min(size.width, size.height) * 0.34
            let ry = max(3, rx * min(1, max(0.05, roundness)))
            let radians = angle * .pi / 180

            var frame = Path()
            frame.addRect(CGRect(origin: .zero, size: size))
            context.stroke(frame, with: .color(.secondary.opacity(0.5)), lineWidth: 1)

            // The tip itself: an ellipse squashed on the roundness axis and turned.
            let ellipse = Path(ellipseIn: CGRect(x: -rx, y: -ry, width: rx * 2, height: ry * 2))
            context.drawLayer { layer in
                layer.translateBy(x: center.x, y: center.y)
                layer.rotate(by: .radians(Double(radians)))
                layer.stroke(ellipse, with: .color(.primary), lineWidth: 1.3)
            }

            // Axis line through the tip, the way Photoshop draws it.
            let axisEnd = point(center, radians, rx: rx, ry: 0)
            var line = Path()
            line.move(to: point(center, radians, rx: -rx, ry: 0))
            line.addLine(to: axisEnd)
            context.stroke(line, with: .color(.primary.opacity(0.6)), lineWidth: 1)

            for handle in [axisEnd, point(center, radians, rx: 0, ry: -ry)] {
                let dot = Path(ellipseIn: CGRect(x: handle.x - 4, y: handle.y - 4, width: 8, height: 8))
                context.fill(dot, with: .color(.white))
                context.stroke(dot, with: .color(.black.opacity(0.6)), lineWidth: 1)
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let center = CGPoint(x: boxSize.width / 2, y: boxSize.height / 2)
                    let rx = min(boxSize.width, boxSize.height) * 0.34
                    let current = roundness
                    let radians = angle * .pi / 180
                    let ry = max(3, rx * min(1, max(0.05, current)))
                    if dragMode == nil {
                        // Whichever handle the press landed nearer decides the drag.
                        let axisHandle = point(center, radians, rx: rx, ry: 0)
                        let roundHandle = point(center, radians, rx: 0, ry: -ry)
                        let toAxis = hypot(value.startLocation.x - axisHandle.x, value.startLocation.y - axisHandle.y)
                        let toRound = hypot(value.startLocation.x - roundHandle.x, value.startLocation.y - roundHandle.y)
                        dragMode = toAxis <= toRound ? .angle : .roundness
                    }
                    if dragMode == .angle {
                        angle = wrapped(atan2(value.location.y - center.y, value.location.x - center.x) * 180 / .pi)
                    } else {
                        let distance = hypot(value.location.x - center.x, value.location.y - center.y)
                        roundness = min(1, max(0.05, distance / rx))
                    }
                }
                .onEnded { _ in dragMode = nil }
        )
        .help("拖长轴手柄旋转笔尖，拖短轴手柄调整圆度")
    }

    private func point(_ center: CGPoint, _ radians: CGFloat, rx: CGFloat, ry: CGFloat) -> CGPoint {
        let x = rx * cos(radians) - ry * sin(radians)
        let y = rx * sin(radians) + ry * cos(radians)
        return CGPoint(x: center.x + x, y: center.y + y)
    }

    /// Angles wrap into -180…180 to match Photoshop's read-out.
    private func wrapped(_ degrees: CGFloat) -> CGFloat {
        var value = degrees.truncatingRemainder(dividingBy: 360)
        if value > 180 { value -= 360 }
        if value < -180 { value += 360 }
        return value
    }
}
