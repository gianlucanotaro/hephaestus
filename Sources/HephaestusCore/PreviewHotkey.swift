import Foundation

/// Registers the "show/hide zones" hotkey (default ⌃⌥Z) from its Prefs-backed shortcut and re-registers on change.
final class PreviewHotkeyController {
    private let hotKeys: HotKeys
    private let action: () -> Void
    private var id: UInt32?
    private var applied: Shortcut??

    init(hotKeys: HotKeys = .shared, action: @escaping () -> Void) {
        self.hotKeys = hotKeys
        self.action = action
    }

    func start() {
        apply()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.apply()
        }
    }

    private func apply() {
        let shortcut = ShortcutStore.read(.preview)
        if let applied, applied == shortcut { return }
        applied = .some(shortcut)
        if let id { hotKeys.unregister(id) }
        id = shortcut.flatMap { hotKeys.register(keyCode: $0.keyCode, modifiers: $0.modifiers.carbon, action: action) }
    }
}
