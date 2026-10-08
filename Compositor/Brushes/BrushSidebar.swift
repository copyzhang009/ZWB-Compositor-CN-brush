import SwiftUI
import AppKit

/// The right-hand column, stacked the way Photoshop stacks its panels: the brush
/// library on top, the colour picker under it, and the layer stack along the
/// bottom. Each divider can be dragged, so the sections can be sized to taste;
/// the column's own width is dragged with the app's existing panel edge.
struct BrushSidebar: View {
    @Bindable var session: EditorSession
    var width: CGFloat

    @State private var brushHeight: CGFloat = 300
    @State private var colourHeight: CGFloat = 210
    @State private var lastDrag: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            BrushPresetPanel(session: session)
                .frame(height: brushHeight)
            // Both ranges stop short of squeezing a section out of usefulness:
            // the brush list keeps room for a few rows, and the picker keeps
            // room for its whole square and its swatches.
            dragHandle { brushHeight = clamp(brushHeight + $0, 250, 430) }
            colourSection
                .frame(height: colourHeight)
            dragHandle { colourHeight = clamp(colourHeight + $0, 215, 340) }
            LayersPanel(session: session, width: width)
        }
        .frame(width: width)
        .background(Color(nsColor: .windowBackgroundColor))
        // Reopens on the brushes last used for the brush and the eraser.
        .onAppear { session.restoreBrushStyles() }
    }

    /// A thin bar between two sections: dragging it trades height between them.
    private func dragHandle(_ adjust: @escaping (CGFloat) -> Void) -> some View {
        ZStack {
            Rectangle().fill(Color.primary.opacity(0.1))
            Rectangle().fill(Color.primary.opacity(0.22)).frame(height: 1)
        }
        .frame(height: 6)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let delta = value.translation.height - lastDrag
                    lastDrag = value.translation.height
                    adjust(delta)
                }
                .onEnded { _ in lastDrag = 0 }
        )
        .help("上下拖动调整这一栏的高度")
    }

    private func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
        min(high, max(low, value))
    }

    /// Photoshop's colour panel: the saturation/brightness square with its hue
    /// strip, setting the brush's foreground colour.
    private var colourSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("颜色")
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 12).padding(.vertical, 7)
            ColorPickerPanel(session: session)
            Spacer(minLength: 0)
        }
    }
}
