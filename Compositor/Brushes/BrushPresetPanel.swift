import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The brush library, laid out like Photoshop's preset panel: groups of stroke
/// previews, each row previewing what that brush actually paints. Brushes can be
/// renamed, moved between groups and removed; groups can be created, renamed and
/// removed.
struct BrushPresetPanel: View {
    @Bindable var session: EditorSession
    @State private var groups: [(group: String?, presets: [BrushPreset])] = []
    @State private var collapsed: Set<String> = []
    @State private var hoveredID: UUID?
    @State private var message: String?
    @State private var renamingPreset: BrushPreset?
    @State private var renamingGroup: String?
    @State private var renameText = ""
    @State private var showsRename = false
    @State private var showsNewGroup = false
    @State private var newGroupName = ""
    /// The brush being dragged, the folder it is hovering over, and the gap
    /// between two brushes it is hovering over.
    @State private var dragging: UUID?
    @State private var dropTarget: String?
    @State private var dropBar: String?
    @State private var settingsPanel = FloatingPanelController(name: "brushSettings")
    @State private var settingsWatch: NSObjectProtocol?

    private static let builtInLabel = "内置画笔"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            brushToolbar
            Divider()
            if let message {
                Text(message)
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.top, 6)
            }
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(groups, id: \.group) { entry in
                            groupHeader(entry.group, count: entry.presets.count)
                            if !isCollapsed(entry.group) {
                                // A thin drop strip above every brush, plus one at the
                                // end, so a brush can land anywhere in the list.
                                ForEach(Array(entry.presets.enumerated()), id: \.element.id) { index, preset in
                                    insertionBar(entry.group, index: index, indented: entry.group != nil)
                                    brushRow(preset, indented: entry.group != nil).id(preset.id)
                                }
                                insertionBar(entry.group, index: entry.presets.count, indented: entry.group != nil)
                                if entry.presets.isEmpty {
                                    Text("把画笔拖到这里，或用右键菜单移动")
                                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                                        .padding(.leading, 30).padding(.vertical, 6)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
                .onAppear {
                    reload()
                    revealCurrent(proxy)
                }
            }
            Divider()
            footer
        }
        // Sized by whoever hosts it: the popover asks for 380×520, the sidebar
        // gives it the column's width and its own share of the height. The width
        // floor stays low so a narrow column compresses rather than clips.
        .frame(minWidth: 200, minHeight: 240)
        .alert("重命名", isPresented: $showsRename) {
            TextField("名称", text: $renameText)
            Button("确定") { commitRename() }
            Button("取消", role: .cancel) { renamingPreset = nil; renamingGroup = nil }
        }
        .alert("新建组", isPresented: $showsNewGroup) {
            TextField("组名", text: $newGroupName)
            Button("创建") {
                let name = newGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
                if session.addBrushGroup(newGroupName) {
                    reload()
                    message = "已创建组「\(name)」"
                } else {
                    message = "组名为空或已存在"
                }
            }
            Button("取消", role: .cancel) {}
        }
    }

    /// The strip Photoshop puts under the brush list's title: the current brush's
    /// own tip, its size, and the way into the full settings dialog.
    private var brushToolbar: some View {
        HStack(spacing: 10) {
            currentTipThumbnail
            Text("大小").font(.system(size: 12)).foregroundStyle(.secondary)
            TextField("", value: Binding(get: { Double(session.brushSettings.diameter) },
                                        set: {
                                            let value = $0.isFinite ? $0 : 30
                                            session.brushSettings.diameter = CGFloat(min(2000, max(1, value)))
                                        }),
                      format: .number.precision(.fractionLength(0)))
                .frame(width: 56)
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.roundedBorder)
            Text("px").font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button { openSettings() } label: {
                Image(systemName: "paintbrush.pointed")
                    .font(.system(size: 14))
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
                    .contentShape(RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            .help("画笔设置（也可以双击列表里的画笔）")
        }
        .padding(.horizontal, 12).padding(.bottom, 10)
    }

    /// The current brush's tip, on a dark chip like the options bar shows it.
    @ViewBuilder
    private var currentTipThumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3).fill(Color(white: 0.22))
            if let tip = session.brushSettings.tip,
               let image = BrushTipThumbnails.image(for: tip,
                                                    identity: session.currentBrushPresetID?.uuidString
                                                        ?? BrushTipThumbnails.identity(for: tip),
                                                    maxSize: 56) {
                Image(nsImage: image).resizable().interpolation(.medium).scaledToFit().padding(3)
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

    private var header: some View {
        HStack {
            Text("画笔预设").font(.headline)
            Spacer()
            Button("新建") { newGroupName = ""; showsNewGroup = true }
                .help("新建一个空的组，用右键菜单把画笔移进去")
            Button("导入") { importABR() }
                .help("导入 Photoshop 画笔文件（.abr）")
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    private var footer: some View {
        // Kept to the essentials: a narrow column has no room for hints, and the
        // build stamp is what tells you the running app isn't stale.
        HStack(spacing: 6) {
            Text("\(session.brushPresets.presets.count) 支")
                .font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
            Spacer(minLength: 2)
            Text(buildStamp)
                .font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
        }
        .help("右键画笔：重命名 / 移动 / 删除")
        .padding(.horizontal, 10).padding(.vertical, 7)
    }

    private var buildStamp: String {
        guard let url = Bundle.main.executableURL,
              let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
              let date = values.contentModificationDate else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return "构建 \(formatter.string(from: date))"
    }

    // MARK: - Data

    private func reload() {
        groups = session.brushPresets.grouped()
    }

    private func isCollapsed(_ group: String?) -> Bool {
        collapsed.contains(group ?? Self.builtInLabel)
    }

    private func toggle(_ group: String?) {
        let key = group ?? Self.builtInLabel
        if collapsed.contains(key) { collapsed.remove(key) } else { collapsed.insert(key) }
    }

    /// Opens the list on the brush in use, expanding its group if it was collapsed.
    private func revealCurrent(_ proxy: ScrollViewProxy) {
        guard let id = session.currentBrushPresetID else { return }
        if let group = session.brushPresets.presets.first(where: { $0.id == id })?.group {
            collapsed.remove(group)
        }
        DispatchQueue.main.async { proxy.scrollTo(id, anchor: .center) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { proxy.scrollTo(id, anchor: .center) }
    }

    // MARK: - Group header

    private func groupHeader(_ group: String?, count: Int) -> some View {
        let title = group ?? Self.builtInLabel
        let collapsedNow = isCollapsed(group)
        return HStack(spacing: 6) {
            Button { toggle(group) } label: {
                HStack(spacing: 6) {
                    Image(systemName: collapsedNow ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                    Image(systemName: collapsedNow ? "folder" : "folder.fill")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(title).font(.system(size: 12, weight: .medium))
                    Text("\(count)").font(.system(size: 10)).foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if group != nil {
                Button { removeGroup(title) } label: {
                    Image(systemName: "minus.circle")
                        .font(.system(size: 14)).padding(6).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("删除整组「\(title)」")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .contentShape(Rectangle())
        .background(dropTarget == title ? Color.accentColor.opacity(0.3) : Color.primary.opacity(0.06))
        .contextMenu {
            if group != nil {
                Button("重命名组…") { beginRenameGroup(group) }
                Button("删除整组", role: .destructive) { removeGroup(title) }
            }
        }
        // Dropping a brush on a folder moves it in there. The dragged brush is
        // tracked in state rather than through the item provider: same-window
        // drags don't need the round trip, and this way the folder can light up.
        .onDrop(of: [.text], isTargeted: targetedBinding(title)) { _ in
            defer { dragging = nil; dropTarget = nil }
            guard let id = dragging,
                  let preset = session.brushPresets.presets.first(where: { $0.id == id }) else { return false }
            session.moveBrushPreset(preset, to: group)
            reload()
            message = "已把「\(preset.name)」移入「\(title)」"
            return true
        }
    }

    private func targetedBinding(_ title: String) -> Binding<Bool> {
        Binding(get: { dropTarget == title },
                set: { dropTarget = $0 ? title : nil })
    }

    /// The gap between two brushes: dropping here inserts at `index`.
    private func insertionBar(_ group: String?, index: Int, indented: Bool) -> some View {
        let key = "\(group ?? "")|\(index)"
        return Rectangle()
            .fill(dropBar == key ? Color.accentColor : Color.clear)
            .frame(height: 5)
            .padding(.leading, indented ? 18 : 8)
            .padding(.trailing, 8)
            .contentShape(Rectangle())
            .onDrop(of: [.text], isTargeted: barBinding(key)) { _ in
                defer { dragging = nil; dropBar = nil }
                guard let id = dragging,
                      let preset = session.brushPresets.presets.first(where: { $0.id == id }) else { return false }
                session.moveBrushPreset(preset, to: group, at: index)
                reload()
                message = "已把「\(preset.name)」移到「\(group ?? Self.builtInLabel)」第 \(index + 1) 位"
                return true
            }
    }

    private func barBinding(_ key: String) -> Binding<Bool> {
        Binding(get: { dropBar == key },
                set: { dropBar = $0 ? key : nil })
    }

    // MARK: - Brush row

    private func brushRow(_ preset: BrushPreset, indented: Bool) -> some View {
        let selected = session.currentBrushPresetID == preset.id
        return Button {
            session.selectBrushPreset(preset)
        } label: {
            // Photoshop's row: the stroke on top, the brush's name beneath it,
            // both filling whatever width the column has.
            VStack(alignment: .leading, spacing: 0) {
                Group {
                    if let image = BrushStrokeThumbnails.image(for: preset, size: CGSize(width: 320, height: 34)) {
                        // Kept in proportion: stretching it to the column width
                        // was what made the previews go wrong as the panel resized.
                        Image(nsImage: image).resizable().scaledToFit()
                    } else {
                        BrushStrokePreview(tip: preset.tip, diameter: preset.diameter,
                                           hardness: preset.hardness, spacing: preset.spacing,
                                           roundness: preset.roundness, angle: preset.angle,
                                           opacity: preset.opacity,
                                           sizeJitter: preset.dynamics.size.jitter,
                                           background: nil, insets: 10)
                    }
                }
                .frame(height: 34)
                .frame(maxWidth: .infinity)
                .clipped()
                Text(preset.name)
                    .font(.system(size: 11)).foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 7).padding(.bottom, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(white: 0.28))
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay {
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 2)
            }
            .padding(.leading, indented ? 18 : 8)
            .padding(.trailing, 40)
            .padding(.vertical, 1)
        }
        .buttonStyle(.plain)
        // Double-clicking a brush opens its settings, as Photoshop's panel does.
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            session.selectBrushPreset(preset)
            openSettings()
        })
        .onHover { hovering in
            if hovering { hoveredID = preset.id }
            else if hoveredID == preset.id { hoveredID = nil }
        }
        .onDrag {
            dragging = preset.id
            return NSItemProvider(object: preset.id.uuidString as NSString)
        }
        .contextMenu {
            Button("重命名…") { beginRenamePreset(preset) }
            Menu("移动到组") {
                ForEach(groupChoices(), id: \.self) { choice in
                    Button(choice ?? Self.builtInLabel) {
                        session.moveBrushPreset(preset, to: choice)
                        reload()
                        message = "已把「\(preset.name)」移入「\(choice ?? Self.builtInLabel)」"
                    }
                }
            }
            Divider()
            Button("删除", role: .destructive) { remove(preset) }
        }
        .overlay(alignment: .topTrailing) {
            if hoveredID == preset.id {
                Button { remove(preset) } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.white, .black.opacity(0.6))
                        .padding(6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 2).padding(.trailing, 4)
                .help("删除「\(preset.name)」")
            }
        }
    }

    /// Every group a brush can be moved into, built-in first.
    private func groupChoices() -> [String?] {
        var choices: [String?] = [nil]
        for entry in groups where entry.group != nil {
            choices.append(entry.group)
        }
        for name in session.brushPresets.groups where !choices.contains(name) {
            choices.append(name)
        }
        return choices
    }

    // MARK: - Actions

    private func beginRenamePreset(_ preset: BrushPreset) {
        renamingPreset = preset
        renamingGroup = nil
        renameText = preset.name
        showsRename = true
    }

    private func beginRenameGroup(_ group: String?) {
        guard let group else { return }
        renamingPreset = nil
        renamingGroup = group
        renameText = group
        showsRename = true
    }

    private func commitRename() {
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let preset = renamingPreset {
            session.renameBrushPreset(preset, to: renameText)
            message = "已重命名为「\(name)」"
        } else if let group = renamingGroup {
            session.renameBrushGroup(group, to: renameText)
            message = "组已重命名为「\(name)」"
        }
        renamingPreset = nil
        renamingGroup = nil
        BrushStrokeThumbnails.invalidateAll()
        reload()
    }

    private func remove(_ preset: BrushPreset) {
        session.removeBrushPreset(preset)
        BrushStrokeThumbnails.invalidateAll()
        reload()
        message = "已删除「\(preset.name)」"
    }

    private func removeGroup(_ name: String) {
        session.removeBrushGroup(name)
        BrushStrokeThumbnails.invalidateAll()
        reload()
        message = "已删除整组「\(name)」"
    }

    private func importABR() {
        let panel = NSOpenPanel()
        panel.title = "导入 Photoshop 画笔（.abr）"
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        var added = 0
        for url in panel.urls where url.pathExtension.lowercased() == "abr" {
            // The file's own name becomes the group, as Photoshop does.
            let group = url.deletingPathExtension().lastPathComponent
            if let data = try? Data(contentsOf: url) {
                added += session.importBrushPresets(data, group: group)
            }
        }
        BrushStrokeThumbnails.invalidateAll()
        reload()
        message = added > 0 ? "已导入 \(added) 个笔刷" : "没有可导入的笔刷"
    }
}
