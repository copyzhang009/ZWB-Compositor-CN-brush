import SwiftUI
import AppKit

/// Photoshop's colour panel: a saturation/brightness square with a vertical hue
/// strip beside it. Dragging in either one sets the brush's foreground colour,
/// and the panel opens showing the colour already in use.
struct ColorPickerPanel: View {
    @Bindable var session: EditorSession
    @State private var hue: CGFloat = 0
    @State private var saturation: CGFloat = 1
    @State private var brightness: CGFloat = 1

    /// Which of the two swatches the square and strip are editing.
    @State private var editingBackground = false

    var body: some View {
        GeometryReader { geo in
            let strip: CGFloat = 20
            let swatches: CGFloat = 48
            let side = max(60, min(geo.size.width - strip - swatches - 26, geo.size.height - 20))
            HStack(alignment: .top, spacing: 10) {
                colourSwatches
                square(side: side)
                hueStrip(height: side)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 12)
        .onAppear(perform: syncFromBrush)
    }

    /// Photoshop's overlapping foreground/background chips. Clicking one points
    /// the square and strip at it.
    private var colourSwatches: some View {
        ZStack(alignment: .topLeading) {
            chip(session.paletteColor(background: true), background: true)
                .offset(x: 15, y: 15)
            chip(session.paletteColor(background: false), background: false)
        }
        .frame(width: 46, height: 46, alignment: .topLeading)
    }

    private func chip(_ color: PaletteColor, background: Bool) -> some View {
        let active = editingBackground == background
        return Rectangle()
            .fill(Color(nsColor: color.nsColor))
            .frame(width: 31, height: 31)
            .overlay {
                Rectangle().strokeBorder(active ? Color.accentColor : Color.white, lineWidth: active ? 2 : 1)
            }
            .shadow(color: .black.opacity(0.4), radius: 1, y: 0.5)
            .contentShape(Rectangle())
            .onTapGesture {
                editingBackground = background
                syncFromBrush()
            }
            .help(background ? "背景色（点击后调整这里）" : "前景色（点击后调整这里）")
    }

    // MARK: - Saturation / brightness square

    private func square(side: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [.white, Color(hue: hue, saturation: 1, brightness: 1)],
                           startPoint: .leading, endPoint: .trailing)
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
            marker(diameter: 11, fill: .clear, stroke: .white)
                .position(x: saturation * side, y: (1 - brightness) * side)
            marker(diameter: 13, fill: .clear, stroke: .black.opacity(0.55))
                .position(x: saturation * side, y: (1 - brightness) * side)
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 2))
        .overlay { RoundedRectangle(cornerRadius: 2).strokeBorder(.black.opacity(0.35), lineWidth: 1) }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    saturation = min(1, max(0, value.location.x / side))
                    brightness = min(1, max(0, 1 - value.location.y / side))
                    apply()
                }
        )
        .help("拖动选择饱和度与明度")
    }

    // MARK: - Hue strip

    private func hueStrip(height: CGFloat) -> some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: stride(from: 0.0, through: 1.0, by: 1.0 / 6)
                .map { Color(hue: min(0.999, $0), saturation: 1, brightness: 1) },
                           startPoint: .top, endPoint: .bottom)
            // Photoshop's little arrow pair riding the hue.
            Image(systemName: "arrowtriangle.right.fill")
                .font(.system(size: 9))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.7), radius: 1)
                .position(x: 4, y: hue * height)
            Image(systemName: "arrowtriangle.left.fill")
                .font(.system(size: 9))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.7), radius: 1)
                .position(x: 16, y: hue * height)
        }
        .frame(width: 20, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 2))
        .overlay { RoundedRectangle(cornerRadius: 2).strokeBorder(.black.opacity(0.35), lineWidth: 1) }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    hue = min(1, max(0, value.location.y / height))
                    apply()
                }
        )
        .help("拖动选择色相")
    }

    private func marker(diameter: CGFloat, fill: Color, stroke: Color) -> some View {
        Circle()
            .fill(fill)
            .overlay { Circle().strokeBorder(stroke, lineWidth: 1.5) }
            .frame(width: diameter, height: diameter)
            .allowsHitTesting(false)
    }

    // MARK: - Colour plumbing

    private func apply() {
        guard let rgb = NSColor(hue: hue, saturation: saturation, brightness: brightness, alpha: 1)
            .usingColorSpace(.sRGB) else { return }
        session.setPaletteColor(PaletteColor(red: rgb.redComponent,
                                             green: rgb.greenComponent,
                                             blue: rgb.blueComponent),
                                background: editingBackground)
    }

    /// Opens on the colour the active swatch is already using.
    private func syncFromBrush() {
        let color = session.paletteColor(background: editingBackground)
        guard let rgb = NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1)
            .usingColorSpace(.sRGB) else { return }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        rgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        hue = h
        saturation = s
        brightness = b
    }
}
