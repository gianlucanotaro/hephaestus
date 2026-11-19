import AppKit
import ApplicationServices

// Pin window on top (#45).
//
// macOS has NO public API to set another app's window level (tools that do need SIP off or private CGS/SkyLight
// calls, which this app deliberately avoids). So "pinned" means: Hephaestus re-raises the window with `AXRaise`
// whenever something may have covered it. KNOWN LIMITS:
//   - it can flicker briefly (the window is covered, then raised on the next event or poll tick, at most ~1 s later);
//   - it cannot sit above fullscreen apps, the menu bar, system UI or other apps' floating-level panels;
//   - a plain `AXRaise` of a window of a NON-frontmost app is ignored by macOS (it only reorders within the app).
//     So after the gentle raise we verify the z-order and, if the pin is still covered and "force" is on, briefly
//     make the pinned app frontmost (kAXFrontmostAttribute), raise the window, then give focus back to the app
//     and window the user was in. This flickers and may cost a keystroke typed in that instant;
//   - pins are NOT persisted: AX elements cannot be saved reliably, so pins are dropped on quit/relaunch.

extension Prefs {
    static let pinnedWindowsEnabledKey = "pinnedWindowsEnabled"
    static let pinForceKey = "pinnedWindowsForce"
    /// Read-only debug switch (not registered, no UI): `defaults write dev.rsdf.hephaestus pinDebug -bool true`.
    static let pinDebugKey = "pinDebug"
    static let pinHotkeyKeyCodeKey = "pinHotkeyKeyCode"
    static let pinHotkeyModifiersKey = "pinHotkeyModifiers"

    static func registerPinnedWindowsDefaults() {
        UserDefaults.standard.register(defaults: [pinnedWindowsEnabledKey: true, pinForceKey: true])
    }
    static var pinnedWindowsEnabled: Bool { UserDefaults.standard.bool(forKey: pinnedWindowsEnabledKey) }
    static var pinForce: Bool { UserDefaults.standard.bool(forKey: pinForceKey) }
    static var pinDebug: Bool { UserDefaults.standard.bool(forKey: pinDebugKey) }
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
            guard let self, !self.gate.isEcho(now: Self.now) else { return }   // our own force-raise activations
            self.scheduleCheck()
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
        return focusedWindow(pid: app.processIdentifier)
    }

    /// Focused window of an app, falling back to its main window (some apps report only one of the two).
    static func focusedWindow(pid: pid_t) -> AXUIElement? {
        let axApp = AXUIElementCreateApplication(pid)
        for attr in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var ref: CFTypeRef?
            if AXUIElementCopyAttributeValue(axApp, attr as CFString, &ref) == .success,
               let w = ref, CFGetTypeID(w) == AXUIElementGetTypeID() { return (w as! AXUIElement) }
        }
        return nil
    }

    /// Hotkey / menu entry point.
    func toggleFrontmostWindow(window preCaptured: AXUIElement? = nil) {
        guard Prefs.pinnedWindowsEnabled, let window = preCaptured ?? Self.frontmostFocusedWindow(),
              Self.isPinnable(window) || isPinned(window)
        else { Self.log("toggle refused: no focused pinnable window (captured: \(preCaptured != nil))"); NSSound.beep(); return }
        toggle(window)
    }

    static func log(_ message: @autoclosure () -> String) {
        if Prefs.pinDebug { NSLog("Pin: %@", message()) }
    }

    func toggle(_ window: AXUIElement) {
        var pid: pid_t = 0
        AXUIElementGetPid(window, &pid)
        let app = NSRunningApplication(processIdentifier: pid)
        let pin = PinnedWindow(token: nextToken, element: window, pid: pid, appName: app?.localizedName ?? "App",
                               bundleID: app?.bundleIdentifier, title: Self.title(of: window))
        let pinnedNow = list.toggle(pin, matches: { CFEqual($0.element, window) })
        Self.log("toggled \(pinnedNow ? "PIN" : "UNPIN"): \(pin.appName) (pid \(pid)) \"\(pin.title)\"")
        if pinnedNow {
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
        let keys = obscuredKeys()
        var raised = false
        for key in keys {
            guard let pin = list.items.first(where: { $0.token == key }), gate.allowRaise(key: key, now: Self.now) else { continue }
            // Gentle raise: no activation, no focus change.
            let result = AXUIElementPerformAction(pin.element, kAXRaiseAction as CFString)
            Self.log("obscured: \(pin.appName) \"\(pin.title)\"; AXRaise -> \(result.rawValue)")
            if result == .invalidUIElement { removeAll(where: { $0.token == key }) } else { raised = true }
        }
        if raised, Prefs.pinForce || Prefs.pinDebug, !verifyScheduled {
            verifyScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                self?.verifyScheduled = false
                self?.verifyAndForce()
            }
        }
    }

    private var verifyScheduled = false

    /// Re-reads the z-order after the gentle raise; pins still covered get the force raise (when enabled).
    private func verifyAndForce() {
        for key in obscuredKeys() {
            guard let pin = list.items.first(where: { $0.token == key }) else { continue }
            let front = NSWorkspace.shared.frontmostApplication
            let force = PinForce.shouldForce(
                enabled: Prefs.pinForce, stillObscured: true,
                pinnedAppIsFrontmost: front?.processIdentifier == pin.pid,
                frontmostIsSelf: front?.processIdentifier == ProcessInfo.processInfo.processIdentifier,
                mouseButtonDown: NSEvent.pressedMouseButtons != 0)
            Self.log("still obscured after AXRaise: \(pin.appName); force=\(force) (enabled \(Prefs.pinForce), frontmost \(front?.localizedName ?? "?"), mouse \(NSEvent.pressedMouseButtons))")
            guard force, gate.allowForce(key: key, now: Self.now) else { continue }
            forceRaise(pin, previous: front)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self else { return }
                let ok = !self.obscuredKeys().contains(key)
                self.gate.recordForce(key: key, succeeded: ok)
                Self.log("after force: \(pin.appName) \(ok ? "on top" : "STILL obscured (backing off)")")
            }
        }
    }

    /// Brings the pinned app/window forward, then hands focus back to the app and window the user was in.
    private func forceRaise(_ pin: PinnedWindow, previous: NSRunningApplication?) {
        let prevWindow = previous.flatMap { Self.focusedWindow(pid: $0.processIdentifier) }
        let axPinned = AXUIElementCreateApplication(pin.pid)
        let r1 = AXUIElementSetAttributeValue(axPinned, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        if r1 != .success { NSRunningApplication(processIdentifier: pin.pid)?.activate(options: []) }
        let r2 = AXUIElementPerformAction(pin.element, kAXRaiseAction as CFString)
        let r3 = AXUIElementSetAttributeValue(pin.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        Self.log("force: frontmost(pinned) -> \(r1.rawValue), AXRaise -> \(r2.rawValue), main -> \(r3.rawValue)")
        guard let previous, previous.processIdentifier != pin.pid, !previous.isTerminated else { return }
        // Give the window server a moment to order the pinned window, then restore the user's app and window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            let axPrev = AXUIElementCreateApplication(previous.processIdentifier)
            let b1 = AXUIElementSetAttributeValue(axPrev, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            if b1 != .success { previous.activate(options: []) }
            var b2 = AXError.success, b3 = AXError.success
            if let w = prevWindow {
                b2 = AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
                b3 = AXUIElementSetAttributeValue(w, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            }
            // Re-assert the pinned window's place once more now that focus is back.
            let again = AXUIElementPerformAction(pin.element, kAXRaiseAction as CFString)
            Self.log("restore \(previous.localizedName ?? "?"): frontmost -> \(b1.rawValue), main -> \(b2.rawValue), focused -> \(b3.rawValue); re-raise -> \(again.rawValue)")
        }
    }

    /// Tokens of pinned windows currently covered by another window (also unpins dead ones).
    private func obscuredKeys() -> [Int] {
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
        guard !targets.isEmpty else { return [] }
        return PinRaise.windowsToRaise(pinned: targets, windows: Self.onScreenWindows(),
                                       ignoringPid: ProcessInfo.processInfo.processIdentifier)
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
    /// The window that was focused when the menu was built. The menu opens without activating Hephaestus, so this is
    /// the user's window; the click handler uses it instead of re-querying after the menu closed.
    private var captured: AXUIElement?

    func addItems(to menu: NSMenu) {
        let pins = PinnedWindows.shared
        let enabled = Prefs.pinnedWindowsEnabled
        let focused = enabled ? PinnedWindows.frontmostFocusedWindow() : nil
        captured = focused
        PinnedWindows.log("menu built; focused window: \(focused != nil ? "found" : "none"), frontmost: \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
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
        let window = captured
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { PinnedWindows.shared.toggleFrontmostWindow(window: window) }
    }

    @objc private func unpin(_ sender: NSMenuItem) {
        guard let token = sender.representedObject as? Int else { return }
        PinnedWindows.shared.unpin(token: token)
    }
}
