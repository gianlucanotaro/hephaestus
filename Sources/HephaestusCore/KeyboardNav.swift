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
            directModifiers: HotkeyModifiers.sanitized(d.integer(forKey: navDirectModifiersKey), fallback: KeyboardNavConfig.defaultDirect),
            moveModifiers: HotkeyModifiers.sanitized(d.integer(forKey: navMoveModifiersKey), fallback: KeyboardNavConfig.defaultMove),
            expandModifiers: HotkeyModifiers.sanitized(d.integer(forKey: navExpandModifiersKey), fallback: KeyboardNavConfig.defaultExpand),
            direct: [ShortcutID.directFirst, .directMiddle, .directLast].map { ShortcutStore.read($0) })
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

    /// Zones the window currently occupies: the tracker's record when it is still valid (same screen and layout, the
    /// window still sits where the tracker put it), else the best frame overlap against the zones.
    static func currentZones(of window: AXUIElement, frame: CGRect, in zones: [CGRect], on screen: NSScreen) -> Set<ZoneIndex> {
        let record = WindowTracker.shared.record(for: window)
        let valid = record.flatMap { $0.screenUUID == screen.displayUUID && $0.layoutID == ZoneLayout.layout(for: screen).id ? $0 : nil }
        return ZoneNavigation.currentZones(tracked: valid.map { ($0.zones, $0.snappedFrame) }, frame: frame, in: zones)
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
        guard WindowEligibility.canSnap(window: win as! AXUIElement) else { NSSound.beep(); return nil }
        return (win as! AXUIElement, ZoneLayout.fromAX(ax))
    }

    private static func move(_ direction: NavDirection) {
        guard let (window, frame) = frontWindow(),
              let screen = ZoneLayout.screen(containing: frame) else { return }
        let owner = ZoneLayout.surfaceOwner(of: screen)
        let surfaces = ZoneLayout.allZones()
        guard let current = surfaces.firstIndex(where: { $0.screen === owner }) else { return }
        let screens = surfaces.map { NavScreen(frame: $0.screen.frame, zones: $0.zones) }
        let config = Prefs.keyboardNavConfig
        guard let target = ZoneNavigation.moveTarget(window: frame, screens: screens, currentScreen: current,
                                                     mode: config.mode, direction: direction,
                                                     crossScreens: Prefs.navCrossScreens,
                                                     locate: { currentZones(of: window, frame: $0, in: $1, on: owner) }),
              case .zone(let s, let z) = target, screens[s].zones.indices.contains(z) else { return }
        WindowMover.snap(window, toAppKitRect: screens[s].zones[z], zones: [z], on: surfaces[s].screen, from: frame)
    }

    private static func expand(_ direction: NavDirection) {
        guard let (window, frame) = frontWindow(),
              let screen = ZoneLayout.screen(containing: frame) else { return }
        let owner = ZoneLayout.surfaceOwner(of: screen)
        let zones = ZoneLayout.zones(for: owner)
        let span = currentZones(of: window, frame: frame, in: zones, on: owner)
        guard let expanded = ZoneNavigation.expand(span: span, direction: direction, in: zones),
              let box = ZoneLayout.boundingRect(of: expanded, in: zones) else { return }
        WindowMover.snap(window, toAppKitRect: box, zones: expanded, on: owner, from: frame)
    }
}
