import AppKit
import Carbon.HIToolbox

// All global hotkey registration of issue #8 lives here.

/// Registers ⌃⌥⌘0-9 style layout hotkeys and the open-editor hotkey; re-registers when the prefs change.
final class LayoutHotkeyRegistrar {
    private let hotKeys: HotKeys
    private let overlay: Overlay
    private var ids: [UInt32] = []
    private var signature = ""
    private var observer: NSObjectProtocol?

    init(hotKeys: HotKeys = .shared, overlay: Overlay) {
        self.hotKeys = hotKeys
        self.overlay = overlay
    }

    func start() {
        reload()
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) {
            [weak self] _ in self?.reload()
        }
    }

    /// Registration signature; changes only when a relevant pref changes.
    static func signature(layoutMods: HotkeyModifiers, editor: Shortcut?) -> String {
        "\(layoutMods.carbon)|\(editor.map { "\($0.modifiers.carbon)-\($0.keyCode)" } ?? "off")"
    }

    private func reload() {
        let layoutMods = Prefs.layoutHotkeyModifiers
        let editor = ShortcutStore.read(.openEditor)
        let sig = Self.signature(layoutMods: layoutMods, editor: editor)
        guard sig != signature else { return }
        signature = sig
        ids.forEach(hotKeys.unregister)
        ids = []
        if layoutMods.isValid {
            for number in LayoutHotkeys.validNumbers {
                let overlay = overlay
                if let id = hotKeys.register(keyCode: LayoutHotkeyKeys.digitKeyCodes[number], modifiers: layoutMods.carbon,
                                             action: { applyLayout(number: number, overlay: overlay) }) { ids.append(id) }
            }
        }
        if let editor, let id = hotKeys.register(keyCode: editor.keyCode, modifiers: editor.modifiers.carbon, action: openEditorForCursorScreen) {
            ids.append(id)
        }
    }
}

/// Applies the layout numbered `number` to the screen under the cursor, then flashes its zones.
/// Mid-drag, the drag overlay refreshes itself via `ScreenLayoutStore.didChange` (see DragSnapController).
func applyLayout(number: Int, overlay: Overlay) {
    guard let layout = LayoutHotkeys.shared.layout(forNumber: number),
          let screen = ZoneLayout.screenUnderCursor() else { return }
    ZoneLayout.setLayout(id: layout.id, for: screen)
    if Prefs.flashZonesOnSwitch && !DragSnapController.isDragging { overlay.show(on: screen, autoHideAfter: 1.0) }
}

/// Pure decision: edit the current layout when an editor can open it, otherwise start a new layout (nil).
func editorTarget(for layout: Layout, canEdit: (Layout) -> Bool) -> Layout? {
    canEdit(layout) ? layout : nil
}

/// Opens the layout editor for the screen under the cursor, routed by `LayoutEditors` (grid or canvas editor for the
/// screen's current layout); a layout no editor can open falls back to a new grid layout.
func openEditorForCursorScreen() {
    guard let screen = ZoneLayout.screenUnderCursor() else { return }
    if let target = editorTarget(for: ZoneLayout.layout(for: screen), canEdit: LayoutEditors.canEdit),
       LayoutEditors.open(on: screen, editing: target) { return }
    GridEditor.open(on: screen)
}
