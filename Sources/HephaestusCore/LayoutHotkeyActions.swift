import AppKit
import Carbon.HIToolbox

// All global hotkey registration of issue #8 lives here, so reconciling with the HotKeys API changes of other
// PRs (#30, #33) only touches this file.

/// Registers ⌃⌥⌘0-9 style layout hotkeys and the open-editor hotkey; re-registers when the prefs change.
final class LayoutHotkeyRegistrar {
    private let hotKeys: HotKeys
    private let overlay: Overlay
    private var ids: [UInt32] = []
    private var signature = ""
    private var observer: NSObjectProtocol?

    init(hotKeys: HotKeys, overlay: Overlay) {
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
    static func signature(layoutMods: HotkeyModifiers, editorMods: HotkeyModifiers, editorLetter: String) -> String {
        "\(layoutMods.carbon)|\(editorMods.carbon)|\(editorLetter)"
    }

    private func reload() {
        let layoutMods = Prefs.layoutHotkeyModifiers
        let editorMods = Prefs.editorHotkeyModifiers
        let letter = Prefs.editorHotkeyLetter
        let sig = Self.signature(layoutMods: layoutMods, editorMods: editorMods, editorLetter: letter)
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
        if editorMods.isValid, let code = LayoutHotkeyKeys.keyCode(forLetter: letter),
           let id = hotKeys.register(keyCode: code, modifiers: editorMods.carbon, action: openEditorForCursorScreen) {
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

/// Pure decision: edit the current layout when it is grid-editable, otherwise start a new grid layout (nil).
func editorTarget(for layout: Layout, canEdit: (Layout) -> Bool) -> Layout? {
    canEdit(layout) ? layout : nil
}

/// Opens the layout editor for the screen under the cursor. #7 will add `LayoutEditors.open(on:editing:)`;
/// re-point this single function there.
func openEditorForCursorScreen() {
    guard let screen = ZoneLayout.screenUnderCursor() else { return }
    let target = editorTarget(for: ZoneLayout.layout(for: screen), canEdit: GridEditor.canEdit)
    GridEditor.open(on: screen, editing: target)
}
