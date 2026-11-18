import AppKit
import ApplicationServices
import Carbon.HIToolbox

extension Prefs {
    static let navModeKey = "keyboardNavMode"
    static let navCrossScreensKey = "keyboardNavCrossScreens"
    static let navDirectModifiersKey = "keyboardNavDirectModifiers"
    static let navMoveModifiersKey = "keyboardNavMoveModifiers"
    static let navExpandModifiersKey = "keyboardNavExpandModifiers"

    static func registerKeyboardNavDefaults() {
        UserDefaults.standard.register(defaults: [
            navModeKey: KeyboardNavMode.direct.rawValue,
            navCrossScreensKey: false,
            navDirectModifiersKey: KeyboardNavConfig.defaultDirect,
            navMoveModifiersKey: KeyboardNavConfig.defaultMove,
            navExpandModifiersKey: KeyboardNavConfig.defaultExpand,
        ])
    }

    static var keyboardNavConfig: KeyboardNavConfig {
        let d = UserDefaults.standard
        return KeyboardNavConfig(
            mode: KeyboardNavMode(rawValue: d.string(forKey: navModeKey) ?? "") ?? .direct,
            directModifiers: HotKeyModifiers.sanitized(d.integer(forKey: navDirectModifiersKey), fallback: KeyboardNavConfig.defaultDirect),
            moveModifiers: HotKeyModifiers.sanitized(d.integer(forKey: navMoveModifiersKey), fallback: KeyboardNavConfig.defaultMove),
            expandModifiers: HotKeyModifiers.sanitized(d.integer(forKey: navExpandModifiersKey), fallback: KeyboardNavConfig.defaultExpand))
    }
    static var navCrossScreens: Bool { UserDefaults.standard.bool(forKey: navCrossScreensKey) }
}

/// Registers the snap / navigate / expand hotkeys for the current `Prefs.keyboardNavConfig` and
/// re-registers whenever the relevant preferences change.
final class KeyboardNavController {
    private let hotKeys: HotKeys
    private var ids: [UInt32] = []
    private var applied: KeyboardNavConfig?

    /// Shares the app's single `HotKeys` instance (Carbon handler + id space are per instance).
    init(hotKeys: HotKeys = .shared) { self.hotKeys = hotKeys }

    func start() {
        apply()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil,
                                               queue: .main) { [weak self] _ in self?.apply() }
    }

    private func apply() {
        let config = Prefs.keyboardNavConfig
        guard config != applied else { return }
        applied = config
        ids.forEach(hotKeys.unregister)
        ids = config.bindings.compactMap { binding in
            hotKeys.register(keyCode: binding.keyCode, modifiers: binding.modifiers) {
                KeyboardNav.perform(binding.action)
            }
        }
    }
}

enum KeyboardNav {
    static func perform(_ action: KeyboardNavAction) {
        switch action {
        case .snap(let slot): WindowMover.snapFrontWindow(slot: slot)
        case .move(let d): move(d)
        case .expand(let d): expand(d)
        }
    }

    /// Zones the window currently occupies. Single swap point for a real window tracker (#14).
    static func currentZones(of windowFrame: CGRect, in zones: [CGRect]) -> Set<ZoneIndex> {
        ZoneNavigation.zoneSpan(of: windowFrame, in: zones)
    }

    private static func frontWindow() -> (AXUIElement, CGRect)? {
        guard WindowMover.ensureAccessibility(prompt: true),
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return nil }
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(app.processIdentifier),
                                            kAXFocusedWindowAttribute as CFString, &ref) == .success,
              let win = ref, let ax = WindowMover.frame(of: win as! AXUIElement)
        else { return nil }
        return (win as! AXUIElement, ZoneLayout.fromAX(ax))
    }

    private static func move(_ direction: NavDirection) {
        guard let (window, frame) = frontWindow(),
              let screen = ZoneLayout.screen(containing: frame),
              let current = NSScreen.screens.firstIndex(of: screen) else { return }
        let screens = ZoneLayout.allZones().map { NavScreen(frame: $0.screen.frame, zones: $0.zones) }
        let config = Prefs.keyboardNavConfig
        guard let target = ZoneNavigation.moveTarget(window: frame, screens: screens, currentScreen: current,
                                                     mode: config.mode, direction: direction,
                                                     crossScreens: Prefs.navCrossScreens,
                                                     locate: currentZones),
              case .zone(let s, let z) = target, screens[s].zones.indices.contains(z) else { return }
        WindowMover.move(window, toAppKitRect: screens[s].zones[z])
    }

    private static func expand(_ direction: NavDirection) {
        guard let (window, frame) = frontWindow(),
              let screen = ZoneLayout.screen(containing: frame) else { return }
        let zones = ZoneLayout.zones(for: screen)
        let span = currentZones(of: frame, in: zones)
        guard let expanded = ZoneNavigation.expand(span: span, direction: direction, in: zones),
              let box = ZoneLayout.boundingRect(of: expanded, in: zones) else { return }
        WindowMover.move(window, toAppKitRect: box)
    }
}
