import AppKit

// Per-monitor layouts (issue #5).
//
// Limitation: macOS has no public Spaces API (only private CGS calls), so FancyZones' per-virtual-desktop
// layouts are intentionally NOT supported. Layouts are per display only.

enum ScreenOrientation: String {
    case landscape, portrait

    /// Square counts as landscape.
    init(size: CGSize) { self = size.height > size.width ? .portrait : .landscape }
}

extension Prefs {
    /// Layout ids applied to newly connected displays of each orientation. Deliberately NOT registered with a
    /// default: when unset, the landscape/portrait default is the globally active layout (`activeLayoutKey`),
    /// so existing users keep the layout they already chose.
    static let defaultLayoutLandscapeKey = "defaultLayoutLandscape"
    static let defaultLayoutPortraitKey = "defaultLayoutPortrait"
    /// UserDefaults key holding the JSON-encoded `[displayUUID: layoutID]` dictionary.
    static let screenLayoutsKey = "screenLayoutAssignments"

    static func defaultLayoutKey(for orientation: ScreenOrientation) -> String {
        orientation == .portrait ? defaultLayoutPortraitKey : defaultLayoutLandscapeKey
    }
}

extension NSScreen {
    /// Stable identifier of the physical display (survives reconnects and reboots, unlike `displayID`).
    var displayUUID: String {
        if let cf = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
           let s = CFUUIDCreateString(nil, cf) as String? { return s }
        return "display-\(displayID)"
    }
    var orientation: ScreenOrientation { ScreenOrientation(size: frame.size) }
}

/// Screen -> layout assignments (persisted by display UUID) and per-orientation defaults.
/// All lookups are pure given the injected stores, so they are testable without real displays.
final class ScreenLayoutStore {
    static let didChange = Notification.Name("HephaestusScreenLayoutsDidChange")
    static let shared = ScreenLayoutStore()

    private let layouts: LayoutStore
    private let defaults: UserDefaults
    private var observer: NSObjectProtocol?

    init(layouts: LayoutStore = .shared, defaults: UserDefaults = .standard) {
        self.layouts = layouts
        self.defaults = defaults
    }

    /// Raw assignments (display UUID -> layout id); ids may refer to layouts that no longer exist.
    var assignments: [String: String] {
        get {
            guard let data = defaults.data(forKey: Prefs.screenLayoutsKey),
                  let map = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
            return map
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: Prefs.screenLayoutsKey) }
    }

    /// The default layout for new displays of `orientation`; unset or deleted ids fall back to the active layout.
    func defaultLayout(for orientation: ScreenOrientation) -> Layout {
        if let id = defaults.string(forKey: Prefs.defaultLayoutKey(for: orientation)), let l = layouts.layout(id: id) { return l }
        return layouts.active
    }

    func setDefaultLayout(id: String, for orientation: ScreenOrientation) {
        guard layouts.layout(id: id) != nil else { return }
        defaults.set(id, forKey: Prefs.defaultLayoutKey(for: orientation))
        notify()
    }

    /// Assigned layout if it still exists, else the orientation default. Does not persist anything.
    func layout(uuid: String, orientation: ScreenOrientation) -> Layout {
        if let id = assignments[uuid], let l = layouts.layout(id: id) { return l }
        return defaultLayout(for: orientation)
    }

    func layout(for screen: NSScreen) -> Layout { layout(uuid: screen.displayUUID, orientation: screen.orientation) }

    func setLayout(id: String, uuid: String) {
        guard layouts.layout(id: id) != nil else { return }
        var map = assignments
        map[uuid] = id
        assignments = map
        notify()
    }

    func setLayout(id: String, for screen: NSScreen) { setLayout(id: id, uuid: screen.displayUUID) }

    func clearAssignment(uuid: String) {
        var map = assignments
        guard map.removeValue(forKey: uuid) != nil else { return }
        assignments = map
        notify()
    }

    /// Pins the current orientation default to every display that has no valid assignment, so a display keeps the
    /// layout it was given when it appeared even if the defaults change later. Returns true if anything changed.
    @discardableResult
    func materialize(_ displays: [(uuid: String, orientation: ScreenOrientation)]) -> Bool {
        var map = assignments
        var changed = false
        for d in displays where map[d.uuid].flatMap({ layouts.layout(id: $0) }) == nil {
            map[d.uuid] = defaultLayout(for: d.orientation).id
            changed = true
        }
        if changed { assignments = map; notify() }
        return changed
    }

    /// Applies defaults to the currently connected displays now and whenever the display configuration changes.
    func start() {
        materializeConnectedScreens()
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.materializeConnectedScreens() }
    }

    private func materializeConnectedScreens() {
        materialize(NSScreen.screens.map { ($0.displayUUID, $0.orientation) })
    }

    private func notify() { NotificationCenter.default.post(name: Self.didChange, object: self) }
}

extension ZoneLayout {
    /// The screen currently under the mouse cursor, else the main screen.
    static func screenUnderCursor() -> NSScreen? {
        let p = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(p) } ?? NSScreen.main
    }

    /// Assigns a layout to the screen's surface (the representative screen when spanning, so the change is visible).
    static func setLayout(id: String, for screen: NSScreen) {
        ScreenLayoutStore.shared.setLayout(id: id, for: surfaceOwner(of: screen))
    }
}

/// Menu builders and actions for per-screen layout selection.
final class ScreenLayoutMenu: NSObject {
    /// Called after the user picks a layout (e.g. to flash the overlay).
    var onPick: (() -> Void)?
    /// The screen the "Layout" menu was last built for.
    private(set) var screen: NSScreen?

    /// Adds one checkable item per layout for the screen under the cursor; returns that screen.
    @discardableResult
    func addLayoutItems(to menu: NSMenu) -> NSScreen? {
        screen = ZoneLayout.screenUnderCursor()
        guard let screen else { return nil }
        let current = ZoneLayout.layout(for: screen).id
        for layout in LayoutStore.shared.all {
            let item = NSMenuItem(title: layout.name, action: #selector(pickForScreen(_:)), keyEquivalent: "")
            item.representedObject = layout.id
            item.target = self
            item.state = layout.id == current ? .on : .off
            menu.addItem(item)
        }
        return screen
    }

    /// "Default Layouts" submenu with Landscape / Portrait pickers for newly connected displays.
    func defaultsItem() -> NSMenuItem {
        let root = NSMenu()
        for orientation in [ScreenOrientation.landscape, .portrait] {
            let sub = NSMenu()
            let current = ScreenLayoutStore.shared.defaultLayout(for: orientation).id
            for layout in LayoutStore.shared.all {
                let item = NSMenuItem(title: layout.name, action: #selector(pickDefault(_:)), keyEquivalent: "")
                item.representedObject = [orientation.rawValue, layout.id]
                item.target = self
                item.state = layout.id == current ? .on : .off
                sub.addItem(item)
            }
            let entry = NSMenuItem(title: orientation == .portrait ? "Portrait Displays" : "Landscape Displays",
                                   action: nil, keyEquivalent: "")
            entry.submenu = sub
            root.addItem(entry)
        }
        let item = NSMenuItem(title: "Default Layouts for New Displays", action: nil, keyEquivalent: "")
        item.submenu = root
        return item
    }

    @objc private func pickForScreen(_ sender: NSMenuItem) {
        // The cursor is in the menu bar by now; use the screen the menu was built for.
        guard let id = sender.representedObject as? String, let screen else { return }
        ZoneLayout.setLayout(id: id, for: screen)
        onPick?()
    }

    @objc private func pickDefault(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String], pair.count == 2,
              let orientation = ScreenOrientation(rawValue: pair[0]) else { return }
        ScreenLayoutStore.shared.setDefaultLayout(id: pair[1], for: orientation)
    }
}
