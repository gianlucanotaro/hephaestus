import AppKit
import ApplicationServices

/// Places newly created windows (#15): into the app's last known zone, or onto the active screen.
/// Owns the `AXObserver` plumbing (one observer per running regular app, `kAXWindowCreatedNotification`);
/// the decisions live in `NewWindowPlacementMath`. MAIN THREAD ONLY.
final class NewWindowPlacement {
    static let shared = NewWindowPlacement()
    /// Wait for the app to finish its own initial layout/restore before touching the window.
    static let settleDelay: TimeInterval = 0.25

    private var observers: [pid_t: AXObserver] = [:]
    private var started = false
    private var trustPoll: Timer?

    private init() {}

    // MARK: - Lifecycle

    /// Attach to all running apps and watch launches/terminations. Idempotent.
    func start() {
        guard !started else { return }
        started = true
        Prefs.registerNewWindowDefaults()
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] n in
            if let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication { self?.attach(app) }
        }
        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            if let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                self?.detach(pid: app.processIdentifier)
            }
        }
        attachAllWhenTrusted()
    }

    /// Accessibility may be granted after launch: poll (cheaply) until it is, then attach everywhere.
    private func attachAllWhenTrusted() {
        if AXIsProcessTrusted() {
            trustPoll?.invalidate()
            trustPoll = nil
            NSWorkspace.shared.runningApplications.forEach { attach($0) }
        } else if trustPoll == nil {
            trustPoll = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                self?.attachAllWhenTrusted()
            }
        }
    }

    private func attach(_ app: NSRunningApplication, attempt: Int = 0) {
        let pid = app.processIdentifier
        guard app.activationPolicy == .regular, pid != ProcessInfo.processInfo.processIdentifier,
              observers[pid] == nil, !app.isTerminated, AXIsProcessTrusted() else { return }
        let callback: AXObserverCallback = { _, element, _, refcon in
            guard let refcon else { return }
            Unmanaged<NewWindowPlacement>.fromOpaque(refcon).takeUnretainedValue().windowCreated(element)
        }
        var obs: AXObserver?
        let axApp = AXUIElementCreateApplication(pid)
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard AXObserverCreate(pid, callback, &obs) == .success, let observer = obs,
              AXObserverAddNotification(observer, axApp, kAXWindowCreatedNotification as CFString, me) == .success else {
            // A freshly launched app often is not AX-ready yet; retry a few times, then give up quietly.
            if attempt < 3 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5 * Double(attempt + 1)) { [weak self] in
                    self?.attach(app, attempt: attempt + 1)
                }
            }
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        observers[pid] = observer
    }

    private func detach(pid: pid_t) {
        guard let observer = observers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    // MARK: - Placement

    /// Minimal local gate: standard, non-modal, non-minimized, non-fullscreen AXWindow (no sheets/popups/dialogs).
    /// TODO: once the `WindowEligibility.canSnap(window:)` PR (#27) and this PR are both merged, delegate to it.
    static func isPlaceable(_ window: AXUIElement) -> Bool {
        func string(_ a: String) -> String? {
            var r: CFTypeRef?
            return AXUIElementCopyAttributeValue(window, a as CFString, &r) == .success ? r as? String : nil
        }
        func flag(_ a: String) -> Bool {
            var r: CFTypeRef?
            return AXUIElementCopyAttributeValue(window, a as CFString, &r) == .success && (r as? Bool) == true
        }
        return NewWindowPlacementMath.isPlaceable(.init(
            role: string(kAXRoleAttribute), subrole: string(kAXSubroleAttribute),
            minimized: flag(kAXMinimizedAttribute), fullscreen: flag("AXFullScreen"), modal: flag(kAXModalAttribute)))
    }

    private func windowCreated(_ window: AXUIElement) {
        guard Prefs.newWindowToLastZone || Prefs.newWindowToActiveScreen,
              let created = WindowTracker.currentFrame(of: window) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay) { [weak self] in
            self?.place(window, createdFrame: created)
        }
    }

    private func place(_ window: AXUIElement, createdFrame: CGRect) {
        var pid: pid_t = 0
        AXUIElementGetPid(window, &pid)
        // Window or app gone by now: nothing to do.
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
              let now = WindowTracker.currentFrame(of: window) else { return }
        let screens = Self.screenGeometries()
        let bundle = app.bundleIdentifier ?? ""
        let last = bundle.isEmpty ? nil : WindowTracker.shared.lastAssignment(forBundleID: bundle)
        let decision = NewWindowPlacementMath.decide(.init(
            lastZoneSetting: Prefs.newWindowToLastZone, activeScreenSetting: Prefs.newWindowToActiveScreen,
            placeable: Self.isPlaceable(window), appHidden: app.isHidden,
            alreadyTracked: WindowTracker.shared.record(for: window) != nil,
            createdInZone: screens.contains { NewWindowPlacementMath.isInsideZone(createdFrame, zones: $0.zones) },
            stillAtCreationFrame: WindowStateMath.frameMatches(createdFrame, now),
            hasLastZone: last != nil))
        let active = Self.activeScreen()
        switch decision {
        case .skip:
            return
        case .lastZone:
            if let last,
               let t = NewWindowPlacementMath.resolveZoneTarget(last: last, screens: screens, activeUUID: active?.windowTrackerUUID),
               let screen = NSScreen.screens.first(where: { $0.windowTrackerUUID == t.screenUUID }) {
                WindowMover.move(window, toAppKitRect: t.rect)
                WindowTracker.shared.register(window: window, zones: Set(t.zones), screen: screen,
                                              currentFrame: now, snappedFrame: t.rect)
            } else if Prefs.newWindowToActiveScreen {
                moveToActiveScreen(window, frame: now, active: active)
            }
        case .activeScreen:
            moveToActiveScreen(window, frame: now, active: active)
        }
    }

    private func moveToActiveScreen(_ window: AXUIElement, frame: CGRect, active: NSScreen?) {
        guard let active else { return }
        let source = ZoneLayout.screen(containing: frame)?.visibleFrame
        if let f = NewWindowPlacementMath.activeScreenFrame(window: frame, from: source, to: active.visibleFrame) {
            WindowMover.move(window, toAppKitRect: f)
        }
    }

    // MARK: - Screens

    static func screenGeometries() -> [NewWindowPlacementMath.ScreenGeometry] {
        NSScreen.screens.map { .init(uuid: $0.windowTrackerUUID, visibleFrame: $0.visibleFrame, zones: ZoneLayout.zones(for: $0)) }
    }

    /// The screen under the cursor, else the main screen.
    static func activeScreen() -> NSScreen? {
        let frames = NSScreen.screens.map { (uuid: $0.windowTrackerUUID, frame: $0.frame) }
        let uuid = NewWindowPlacementMath.activeScreenUUID(cursor: NSEvent.mouseLocation, frames: frames,
                                                           fallback: NSScreen.main?.windowTrackerUUID)
        return NSScreen.screens.first { $0.windowTrackerUUID == uuid } ?? NSScreen.main
    }
}
