#!/usr/bin/env python3
"""Apply Compositor brush-feature patches to a fresh upstream checkout.

Run AFTER apply_l10n.py. Like the l10n script, every rewrite here must be
deterministic and idempotent, anchored on a unique string. Any REQUIRED rewrite
that fails to apply aborts the sync — a silent miss would ship a build without
pressure / brush support and nobody would notice until too late.

New brush code lives in Compositor/Brushes/ (preserved by sync-upstream.sh), so
this script only touches upstream files that MUST change (for now: Info.plist).

Usage:
  python3 apply_brush.py --root /path/to/Compositor-CN
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


def fail(msg: str) -> int:
    print(f"[apply_brush] 错误：{msg}", file=sys.stderr)
    return 1


def patch_info_plist(root: Path) -> int:
    """Neutralize upstream Sparkle auto-update so the CN build never replaces
    itself with the English upstream app. (Self-hosted appcast comes later;
    for now we just turn the automatic checks off.)"""
    path = root / "Config" / "Info.plist"
    if not path.exists():
        print(f"[apply_brush] 跳过 Info.plist（不存在：{path}）")
        return 0
    text = path.read_text(encoding="utf-8")
    original = text

    # Disable automatic checks: <key>SUEnableAutomaticChecks</key>\s*<true/>
    pattern = re.compile(r"(<key>SUEnableAutomaticChecks</key>\s*)<true/>")
    text, n = pattern.subn(r"\1<false/>", text, count=1)
    if n != 1:
        # Already false: the patch is in place from an earlier run. Anything else
        # is a real upstream change and has to be looked at.
        if re.search(r"<key>SUEnableAutomaticChecks</key>\s*<false/>", text):
            print("[apply_brush] Info.plist 已是 false，跳过")
            return 0
        return fail("Info.plist 中未找到 SUEnableAutomaticChecks（上游变动？）")

    if text != original:
        path.write_text(text, encoding="utf-8")
        print("[apply_brush] 已改 Info.plist：SUEnableAutomaticChecks → false")
    return 0


def patch_editor_session(root: Path) -> int:
    """Add the shared current-preset id to EditorSession.

    EditorSession.swift is upstream, so the property vanishes on every sync; the
    preset picker and the brush settings panel both need it to agree on which
    brush is selected. Idempotent: a second run finds the marker and skips.
    """
    path = root / "Compositor" / "Document" / "EditorSession.swift"
    if not path.exists():
        print(f"[apply_brush] 跳过 EditorSession.swift（不存在：{path}）")
        return 0
    text = path.read_text(encoding="utf-8")
    if "currentBrushPresetID" in text:
        print("[apply_brush] EditorSession.swift currentBrushPresetID 已存在，跳过")
        return 0

    anchor = "    var brushSettings = BrushSettings() { didSet { refreshGradient() } }\n"
    if anchor not in text:
        return fail("EditorSession.swift 中未找到 brushSettings 声明（上游变动？）")
    text = text.replace(anchor, anchor + """    /// The preset the brush settings came from, shared by the preset picker and the
    /// brush settings panel so both show the same selected brush.
    var currentBrushPresetID: UUID?
""", 1)
    path.write_text(text, encoding="utf-8")
    print("[apply_brush] 已改 EditorSession.swift：加 currentBrushPresetID")
    return 0


def patch_new_document(root: Path) -> int:
    """Open new documents on a white background plus a transparent layer.

    The helper itself lives in EditorSession+CanvasDefaults.swift (whitelisted
    for sync); this only rewires createDocument. Idempotent by marker.
    """
    path = root / "Compositor" / "Document" / "EditorSession.swift"
    if not path.exists():
        print(f"[apply_brush] 跳过 EditorSession.swift（不存在：{path}）")
        return 0
    text = path.read_text(encoding="utf-8")
    if "newDocumentLayers" in text:
        print("[apply_brush] EditorSession.swift 新建文档默认层已存在，跳过")
        return 0

    old = """        var document = CanvasDocument(width: width, height: height)
        let layer = emptyLayer ? ImageLayer(name: "图层 1", blankSize: document.size) : nil
        if let layer { document.layers = [layer] }
"""
    if old not in text:
        return fail("EditorSession.swift 中未找到 createDocument 的图层建立代码（上游变动？）")
    text = text.replace(old, """        var document = CanvasDocument(width: width, height: height)
        // A new document opens on an opaque white background plus a transparent
        // layer to paint on, as Photoshop does.
        let layers = emptyLayer ? newDocumentLayers(size: document.size) : []
        if !layers.isEmpty { document.layers = layers }
        let layer = layers.last
""", 1)
    path.write_text(text, encoding="utf-8")
    print("[apply_brush] 已改 EditorSession.swift：新建文档白底 + 透明层")
    return 0


def patch_sidebar(root: Path) -> int:
    """Stack brushes, colour and layers in the right column, as Photoshop does.

    The stack itself lives in Compositor/Brushes/BrushSidebar.swift (whitelisted);
    this only swaps the layer panel in the main layout for it. Idempotent.
    """
    path = root / "Compositor" / "ContentView.swift"
    if not path.exists():
        print(f"[apply_brush] 跳过 ContentView.swift（不存在：{path}）")
        return 0
    text = path.read_text(encoding="utf-8")
    if "BrushSidebar" in text:
        print("[apply_brush] ContentView.swift 侧边栏已存在，跳过")
        return 0

    old = """                PanelResizeEdge(width: $layersPanelWidth, range: LayersPanel.widths)
                LayersPanel(session: session, width: layersPanelWidth)
"""
    if old not in text:
        return fail("ContentView.swift 中未找到右侧栏 LayersPanel（上游变动？）")
    text = text.replace(old, """                PanelResizeEdge(width: $layersPanelWidth, range: LayersPanel.widths)
                // Photoshop's right column: brushes, colour and layers stacked.
                BrushSidebar(session: session, width: layersPanelWidth)
""", 1)
    path.write_text(text, encoding="utf-8")
    print("[apply_brush] 已改 ContentView.swift：右侧栏改为笔刷/颜色/图层堆叠")
    return 0


def patch_brush_mode_styles(root: Path) -> int:
    """Give the brush and the eraser separate tips, as Photoshop does.

    Adds two stash slots plus a didSet on `brushMode` that swaps them; the swap
    itself lives in EditorSession+BrushPresets.swift (whitelisted).
    Idempotent by marker.
    """
    path = root / "Compositor" / "Document" / "EditorSession.swift"
    if not path.exists():
        print(f"[apply_brush] 跳过 EditorSession.swift（不存在：{path}）")
        return 0
    text = path.read_text(encoding="utf-8")
    if "paintBrushStyle" in text:
        print("[apply_brush] EditorSession.swift 画笔/橡皮分设已存在，跳过")
        return 0

    old = "    var brushMode: BrushToolMode = .paint\n"
    if old not in text:
        return fail("EditorSession.swift 中未找到 brushMode 声明（上游变动？）")
    text = text.replace(old, """    /// The brush and the eraser keep separate tips, as Photoshop's do: leaving a
    /// mode stashes its style, returning brings it back.
    @ObservationIgnored var paintBrushStyle: (settings: BrushSettings, presetID: UUID?)?
    @ObservationIgnored var eraseBrushStyle: (settings: BrushSettings, presetID: UUID?)?
    var brushMode: BrushToolMode = .paint { didSet { swapBrushStyle(from: oldValue) } }
""", 1)
    path.write_text(text, encoding="utf-8")
    print("[apply_brush] 已改 EditorSession.swift：画笔/橡皮分设笔刷")
    return 0


def patch_import_images(root: Path) -> int:
    """Route a dropped/importer-visible `.abr` to the brush library.

    Upstream's image importer reads a `.abr` as an image and fails with "can't
    read that image". This hooks the file list first: `.abr` files go to the
    brush library (grouped by file name), the rest fall through to images.
    Idempotent by marker.
    """
    path = root / "Compositor" / "Document" / "EditorSession.swift"
    if not path.exists():
        print(f"[apply_brush] 跳过 EditorSession.swift（不存在：{path}）")
        return 0
    text = path.read_text(encoding="utf-8")
    if "brushFiles" in text:
        print("[apply_brush] EditorSession.swift .abr 路由已存在，跳过")
        return 0

    anchor = "        guard !urls.isEmpty else { return }\n"
    if anchor not in text:
        return fail("EditorSession.swift 中未找到 importImages 的 urls 守卫（上游变动？）")
    text = text.replace(anchor, anchor + """        // A dropped `.abr` file is a brush pack, not an image: import its brushes.
        let brushFiles = urls.filter { $0.pathExtension.lowercased() == "abr" }
        if !brushFiles.isEmpty {
            var imported = 0
            for url in brushFiles {
                if let data = try? Data(contentsOf: url) {
                    imported += importBrushPresets(data, group: url.deletingPathExtension().lastPathComponent)
                }
            }
            importError = imported > 0 ? "已导入 \\(imported) 个笔刷，在画笔工具的预设面板里选择" : "这个 .abr 文件里没有可导入的笔刷"
        }
        let imageFiles = urls.filter { $0.pathExtension.lowercased() != "abr" }
        guard !imageFiles.isEmpty else { return }
""", 1)
    path.write_text(text, encoding="utf-8")
    print("[apply_brush] 已改 EditorSession.swift：加 .abr 拖拽路由")
    return 0


def patch_brush_controls(root: Path) -> int:
    """Put the brush quick-access controls in the options bar.

    BrushControls.swift is upstream, so `rsync --delete` restores its upstream
    form on every sync. Everything added lives in BrushQuickAccess, so this is a
    single-line insertion after the bar's Spacer (the right-hand side, where the
    hand reaches for it). Idempotent.
    """
    path = root / "Compositor" / "UI" / "BrushControls.swift"
    if not path.exists():
        print(f"[apply_brush] 跳过 BrushControls.swift（不存在：{path}）")
        return 0
    text = path.read_text(encoding="utf-8")
    if "BrushQuickAccess" in text:
        print("[apply_brush] BrushControls.swift 已含 BrushQuickAccess，跳过")
        return 0

    anchor = "            Spacer(minLength: 0)\n"
    if anchor not in text:
        return fail("BrushControls.swift 中未找到 Spacer 锚点（上游变动？）")
    text = text.replace(anchor, anchor + """            if session.tool.isBrushTool {
                BrushQuickAccess(session: session)
            }
""", 1)
    path.write_text(text, encoding="utf-8")
    print("[apply_brush] 已改 BrushControls.swift：插入 BrushQuickAccess")
    return 0


def self_check(root: Path) -> int:
    """Verify the patch took effect. Fail the sync if a critical change is missing."""
    plist = root / "Config" / "Info.plist"
    if plist.exists():
        text = plist.read_text(encoding="utf-8")
        if re.search(r"<key>SUEnableAutomaticChecks</key>\s*<true/>", text):
            return fail("自检失败：SUEnableAutomaticChecks 仍为 true")
    controls = root / "Compositor" / "UI" / "BrushControls.swift"
    if controls.exists() and "BrushQuickAccess" not in controls.read_text(encoding="utf-8"):
        return fail("自检失败：BrushControls.swift 缺少 BrushQuickAccess")
    quick = root / "Compositor" / "Brushes" / "BrushQuickAccess.swift"
    if not quick.exists():
        return fail("自检失败：BrushQuickAccess.swift 缺失（检查同步白名单）")
    session = root / "Compositor" / "Document" / "EditorSession.swift"
    if session.exists():
        sessionText = session.read_text(encoding="utf-8")
        if "currentBrushPresetID" not in sessionText:
            return fail("自检失败：EditorSession.swift 缺少 currentBrushPresetID")
        if "brushFiles" not in sessionText:
            return fail("自检失败：EditorSession.swift 缺少 .abr 拖拽路由")
        if "newDocumentLayers" not in sessionText:
            return fail("自检失败：EditorSession.swift 缺少新文档默认层")
        if "paintBrushStyle" not in sessionText:
            return fail("自检失败：EditorSession.swift 缺少画笔/橡皮分设")
        if "func createDocument" not in sessionText:
            return fail("自检失败：EditorSession.swift 缺少 createDocument")
    preset_panel = root / "Compositor" / "Brushes" / "BrushPresetPanel.swift"
    if preset_panel.exists() and "removeBrushGroup" not in preset_panel.read_text(encoding="utf-8"):
        return fail("自检失败：BrushPresetPanel.swift 缺少分组/删除实现")
    for name in ("BrushPresetPreview.swift", "BrushSettingsPanel.swift"):
        if not (root / "Compositor" / "Brushes" / name).exists() \
                and not (root / "Compositor" / "UI" / name).exists():
            return fail(f"自检失败：{name} 缺失（检查同步白名单）")
    canvas_defaults = root / "Compositor" / "Document" / "EditorSession+CanvasDefaults.swift"
    if not canvas_defaults.exists():
        return fail("自检失败：EditorSession+CanvasDefaults.swift 缺失（检查同步白名单）")
    sidebar = root / "Compositor" / "Brushes" / "BrushSidebar.swift"
    if not sidebar.exists():
        return fail("自检失败：BrushSidebar.swift 缺失（检查同步白名单）")
    content_view = root / "Compositor" / "ContentView.swift"
    if content_view.exists() and "BrushSidebar" not in content_view.read_text(encoding="utf-8"):
        return fail("自检失败：ContentView.swift 右侧栏未改为 BrushSidebar")
    print("[apply_brush] 自检通过")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True, help="Path to Compositor working copy root")
    args = parser.parse_args()
    root = Path(args.root).resolve()
    if not (root / "Compositor.xcodeproj").exists():
        return fail(f"未找到 Compositor.xcodeproj：{root}")

    for step in (patch_info_plist, patch_editor_session, patch_import_images,
                 patch_new_document, patch_brush_mode_styles, patch_sidebar,
                 patch_brush_controls):
        code = step(root)
        if code:
            return code
    return self_check(root)


if __name__ == "__main__":
    raise SystemExit(main())
