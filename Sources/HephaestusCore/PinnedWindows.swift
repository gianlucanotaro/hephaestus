import AppKit
import ApplicationServices

// Pin window on top (#45).
//
// macOS has NO public API to set another app's window level (tools that do need SIP off or private CGS/SkyLight
// calls, which this app deliberately avoids). So "pinned" means: Hephaestus re-raises the window with `AXRaise`
// whenever something may have covered it. KNOWN LIMITS:
//   - it can flicker briefly (the window is covered, then raised on the next event or poll tick, at most ~1 s later);
//   - it cannot sit above fullscreen apps, the menu bar, system UI or other apps' floating-level panels;
//   - `AXRaise` without activating the app may be ignored by some apps; then nothing happens (we never activate
//     the app or move focus, so typing keeps going to the app the user chose);
//   - pins are NOT persisted: AX elements cannot be saved reliably, so pins are dropped on quit/relaunch.

extension Prefs {
    static let pinnedWindowsEnabledKey = "pinnedWindowsEnabled"
    static let pinHotkeyKeyCodeKey = "pinHotkeyKeyCode"
    static let pinHotkeyModifiersKey = "pinHotkeyModifiers"

    static func registerPinnedWindowsDefaults() {
        UserDefaults.standard.register(defaults: [pinnedWindowsEnabledKey: true])
    }
    static var pinnedWindowsEnabled: Bool { UserDefaults.standard.bool(forKey: pinnedWindowsEnabledKey) }
}

struct PinnedWindow {
    /// Stable id of this pin (used by the raise decision and the rate limiter).
    let token: Int
    let element: AXUIElement
    let pid: pid_t
    let appName: String
    let bundleID: String?
    var title: String
}

/// Owns the pinned windows, the AX observers, the safety poll and the raise plumbing. MAIN THREAD ONLY.
final class PinnedWindows {
    static let shared = PinnedWindows()
    /// Posted after the set of pinned windows changed.
    static let didChange = Notification.Name("HephaestusPinnedWindowsDidChange")
    static let pollInterval: TimeInterval = 1.0

    private var list = PinList<PinnedWindow>()
    private var nextToken = 0
    private var gate = RaiseGate()
    private var observers: [pid_t: AXObserver] = [:]
    private var poll: Timer?
    private var checkScheduled = false
    private var started = false

    private init() {}

    var windows: [PinnedWindow] { list.items }

    // MARK: Lifecycle

    /// Idempotent. Cheap while nothing is pinned (handlers return early, no timer, no observers).
    func start() {
        guard !started else { return }
        started = true
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.scheduleCheck()
        }
        ws.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.removeAll(where: { $0.pid == app.processIdentifier })
        }
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, !Prefs.pinnedWindowsEnabled, !self.list.items.isEmpty else { return }
            self.removeAll(where: { _ in true })   // feature switched off: drop every pin, stop observers and timer
        }
    }

    // MARK: Pin / unpin

    /// Whether `window` may be pinned: a standard, non-minimized, non-fullscreen window (default eligibility policy,
    /// independent of zones and of the excluded-apps list) that does not belong to Hephaestus.
    static func isPinnable(_ window: AXUIElement) -> Bool {
        var pid: pid_t = 0
        AXUIElementGetPid(window, &pid)
        guard pid != ProcessInfo.processInfo.processIdentifier else { return false }
        return WindowEligibility.isSnappable(WindowEligibility.readTraits(window), policy: EligibilityPolicy())
    }

    func isPinned(_ window: AXUIElement) -> Bool { list.contains { CFEqual($0.element, window) } }

    /// The focused window of the frontmost app, nil for Hephaestus itself or when AX is unavailable.
    static func frontmostFocusedWindow() -> AXUIElement? {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(app.processIdentifier),
                                            kAXFocusedWindowAttribute as CFString, &ref) == .success,
              let w = ref, CFGetTypeID(w) == AXUIElementGetTypeID() else { return nil }
        return (w as! AXUIElement)
    }

    /// Hotkey / menu entry point.
    func toggleFrontmostWindow() {
        guard Prefs.pinnedWindowsEnabled, let window = Self.frontmostFocusedWindow(), Self.isPinnable(window) || isPinned(window)
        else { NSSound.beep(); return }
        toggle(window)
    }

    func toggle(_ window: AXUIElement) {
        var pid: pid_t = 0
        AXUIElementGetPid(window, &pid)
        let app = NSRunningApplication(processIdentifier: pid)
        let pin = PinnedWindow(token: nextToken, element: window, pid: pid, appName: app?.localizedName ?? "App",
                               bundleID: app?.bundleIdentifier, title: Self.title(of: window))
        if list.toggle(pin, matches: { CFEqual($0.element, window) }) {
            nextToken += 1
            attach(pid: pid, window: window)
            scheduleCheck()
        } else {
            detach(window: window, pid: pid)
        }
        changed()
    }

    func unpin(token: Int) {
        removeAll(where: { $0.token == token })
    }

    private func removeAll(where predicate: (PinnedWindow) -> Bool) {
        let removed = list.items.filter(predicate)
        guard !removed.isEmpty else { return }
        list.remove(where: predicate)
        for pin in removed { detach(window: pin.element, pid: pin.pid) }
        changed()
    }

    private func changed() {
        updatePoll()
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    private static func title(of w: AXUIElement) -> String {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &ref) == .success else { return "" }
        return (ref as? String) ?? ""
    }

    // MARK: Observers (one per app that owns pinned windows)

    private func attach(pid: pid_t, window: AXUIElement) {
        guard AXIsProcessTrusted() else { return }
        if observers[pid] == nil {
            let callback: AXObserverCallback = { _, element, notification, refcon in
                guard let refcon else { return }
                Unmanaged<PinnedWindows>.fromOpaque(refcon).takeUnretainedValue().axEvent(element, notification as String)
            }
            var obs: AXObserver?
            guard AXObserverCreate(pid, callback, &obs) == .success, let observer = obs else { return }
            let me = Unmanaged.passUnretained(self).toOpaque()
            let app = AXUIElementCreateApplication(pid)
            for n in [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification, kAXApplicationActivatedNotification] {
                AXObserverAddNotification(observer, app, n as CFString, me)
            }
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            observers[pid] = observer
        }
        if let observer = observers[pid] {
            AXObserverAddNotification(observer, window, kAXUIElementDestroyedNotification as CFString,
                                      Unmanaged.passUnretained(self).toOpaque())
        }
    }

    private func detach(window: AXUIElement, pid: pid_t) {
        guard let observer = observers[pid] else { return }
        AXObserverRemoveNotification(observer, window, kAXUIElementDestroyedNotification as CFString)
        if !list.contains(where: { $0.pid == pid }) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            observers[pid] = nil
        }
    }

    private func axEvent(_ element: AXUIElement, _ notification: String) {
        if notification == kAXUIElementDestroyedNotification as String {
            removeAll(where: { CFEqual($0.element, element) })   // window closed: auto-unpin
            return
        }
        // Focus / main-window changes also fire as an echo of our own raise; the poll covers any real change we skip.
        guard !gate.isEcho(now: Self.now) else { return }
        scheduleCheck()
    }

    // MARK: Safety poll + check

    private func updatePoll() {
        if list.items.isEmpty {
            poll?.invalidate()
            poll = nil
        } else if poll == nil {
            let t = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in self?.check() }
            t.tolerance = 0.3
            RunLoop.main.add(t, forMode: .common)
            poll = t
        }
    }

    /// Coalesces bursts of notifications into one z-order check shortly after (so the new z-order has settled).
    private func scheduleCheck() {
        guard !list.items.isEmpty, !checkScheduled else { return }
        checkScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.checkScheduled = false
            self?.check()
        }
    }

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func check() {
        guard Prefs.pinnedWindowsEnabled, !list.items.isEmpty, AXIsProcessTrusted() else { return }
        var targets: [PinTarget] = []
        var dead: [Int] = []
        for pin in list.items {
            switch Self.axFrame(of: pin.element) {
            case .frame(let f): targets.append(PinTarget(key: pin.token, pid: pin.pid, bounds: f))
            case .gone: dead.append(pin.token)
            case .unavailable: break   // other Space / app busy: skip this round
            }
        }
        if !dead.isEmpty { removeAll(where: { dead.contains($0.token) }) }
        guard !targets.isEmpty else { return }
        let keys = PinRaise.windowsToRaise(pinned: targets, windows: Self.onScreenWindows(),
                                           ignoringPid: ProcessInfo.processInfo.processIdentifier)
        for key in keys {
            guard let pin = list.items.first(where: { $0.token == key }), gate.allowRaise(key: key, now: Self.now) else { continue }
            // Deliberately NO NSRunningApplication.activate and no kAXFocused change: never steal focus.
            let result = AXUIElementPerformAction(pin.element, kAXRaiseAction as CFString)
            if result == .invalidUIElement { removeAll(where: { $0.token == key }) }
        }
    }

    private enum FrameRead { case frame(CGRect), gone, unavailable }

    private static func axFrame(of w: AXUIElement) -> FrameRead {
        var minimized: CFTypeRef?
        if AXUIElementCopyAttributeValue(w, kAXMinimizedAttribute as CFString, &minimized) == .success, (minimized as? Bool) == true {
            return .unavailable
        }
        var posRef: CFTypeRef?, sizeRef: CFTypeRef?
        let pe = AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &posRef)
        if pe == .invalidUIElement { return .gone }
        let se = AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &sizeRef)
        guard pe == .success, se == .success, let posRef, let sizeRef else { return .unavailable }
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &p)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &s)
        return .frame(CGRect(origin: p, size: s))
    }

    /// On-screen windows, front to back. Only owner pid, bounds, layer and alpha are read (no Screen Recording).
    private static func onScreenWindows() -> [WindowSnapshot] {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return info.compactMap { d in
            guard let pid = d[kCGWindowOwnerPID as String] as? Int32,
                  let boundsDict = d[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else { return nil }
            return WindowSnapshot(number: d[kCGWindowNumber as String] as? Int ?? 0, pid: pid, bounds: bounds,
                                  layer: d[kCGWindowLayer as String] as? Int ?? 0,
                                  alpha: d[kCGWindowAlpha as String] as? Double ?? 1)
        }
    }
}

// MARK: - Hotkey

/// Registers the pin toggle shortcut (default ⌃⌥P) while the feature is enabled; re-registers on prefs change.
final class PinHotkeyController {
    private let hotKeys: HotKeys
    private var id: UInt32?
    private var registered: Shortcut?

    init(hotKeys: HotKeys = .shared) { self.hotKeys = hotKeys }

    func start() {
        reconcile()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.reconcile()
        }
    }

    private func reconcile() {
        let want = Prefs.pinnedWindowsEnabled ? ShortcutStore.read(.pinWindow) : nil
        guard want != registered else { return }
        if let id { hotKeys.unregister(id) }
        id = nil
        registered = want
        if let want {
            id = hotKeys.register(keyCode: want.keyCode, modifiers: want.modifiers.carbon) { PinnedWindows.shared.toggleFrontmostWindow() }
        }
    }
}

// MARK: - Menu

/// The "Pin Window on Top" item and the "Pinned Windows" submenu in the menu bar menu.
final class PinMenu: NSObject {
    func addItems(to menu: NSMenu) {
        let pins = PinnedWindows.shared
        let enabled = Prefs.pinnedWindowsEnabled
        let focused = enabled ? PinnedWindows.frontmostFocusedWindow() : nil
        let state: Bool? = focused.flatMap { w in pins.isPinned(w) ? true : (PinnedWindows.isPinnable(w) ? false : nil) }
        let toggle = PinMenuLogic.toggleItem(isPinned: state, featureEnabled: enabled)
        let item = NSMenuItem(title: toggle.title, action: #selector(togglePin), keyEquivalent: "")
        item.target = self
        item.isEnabled = toggle.enabled
        menu.addItem(item)

        let sub = NSMenu()
        for pin in pins.windows {
            let row = NSMenuItem(title: PinMenuLogic.listTitle(appName: pin.appName, windowTitle: pin.title),
                                 action: #selector(unpin(_:)), keyEquivalent: "")
            row.target = self
            row.representedObject = pin.token
            row.toolTip = "Click to unpin"
            sub.addItem(row)
        }
        let listItem = NSMenuItem(title: PinMenuLogic.submenuTitle(count: pins.windows.count), action: nil, keyEquivalent: "")
        listItem.submenu = sub
        listItem.isEnabled = !pins.windows.isEmpty
        menu.addItem(listItem)
        menu.addItem(.separator())
    }

    @objc private func togglePin() {
        // The menu steals focus briefly; wait for the previous app to become frontmost again (same as snap).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { PinnedWindows.shared.toggleFrontmostWindow() }
    }

    @objc private func unpin(_ sender: NSMenuItem) {
        guard let token = sender.representedObject as? Int else { return }
        PinnedWindows.shared.unpin(token: token)
    }
}
