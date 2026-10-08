import SwiftUI
import AppKit

/// The two quick controls Photoshop puts at the head of the brush options bar:
/// the current brush's own thumbnail (opening the preset library) and the brush
/// settings panel. Living in one view keeps the upstream options bar's only
/// change to a single line.
struct BrushQuickAccess: View {
    @Bindable var session: EditorSession
    @State private var showsPresets = false
    @State private var settingsPanel = FloatingPanelController(name: "brushSettings")
    @State private var settingsWatch: NSObjectProtocol?

    var body: some View {
        HStack(spacing: 4) {
            Button { showsPresets = true } label: {
                HStack(spacing: 5) {
                    tipThumbnail
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                // A generous, visible target: an icon-sized hit area is hard to click.
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                .contentShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .help("画笔预设：选择或导入笔刷")
            .popover(isPresented: $showsPresets) {
                BrushPresetPanel(session: session)
                    .frame(width: 380, height: 520)
            }
            Button { openSettings() } label: {
                Image(systemName: "paintbrush.pointed")
                    .font(.system(size: 17))
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .help("画笔设置：笔尖形状 · 形状动态 · 传递")
        }
        .disabled(session.showsBusy)
    }

    /// The current brush's tip as a small dark chip, the way Photoshop shows it:
    /// the real bitmap for sampled tips, otherwise an ellipse at the tip's own
    /// roundness and angle.
    @ViewBuilder
    private var tipThumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(white: 0.22))
            if let tip = session.brushSettings.tip,
               let image = BrushTipThumbnails.image(for: tip,
                                                    identity: session.currentBrushPresetID?.uuidString
                                                        ?? BrushTipThumbnails.identity(for: tip),
                                                    maxSize: 56) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .scaledToFit()
                    .padding(3)
            } else {
                Ellipse()
                    .fill(.white)
                    .frame(width: 19, height: max(3, 19 * session.brushSettings.roundness))
                    .rotationEffect(.degrees(Double(session.brushSettings.angle)))
            }
        }
        .frame(width: 34, height: 26)
        .overlay {
            RoundedRectangle(cornerRadius: 3).strokeBorder(.secondary.opacity(0.5), lineWidth: 1)
        }
    }

    /// A panel is a window, so it can't be shown from the view's body. It also
    /// closes the moment focus leaves it — the way Photoshop's brush settings
    /// does — so it never sits over the canvas.
    private func openSettings() {
        settingsPanel.show(title: "画笔设置", content: BrushSettingsPanel(session: session))
        settingsWatch = settingsWatch ?? NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { note in
                guard let window = note.object as? NSWindow, window.title == "画笔设置" else { return }
                window.close()
                // The settings were being tuned, so capture them before they can
                // be lost to a relaunch.
                session.persistBrushStyles()
            }
    }
}
