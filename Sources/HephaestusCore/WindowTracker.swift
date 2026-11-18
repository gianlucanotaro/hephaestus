import AppKit
import ApplicationServices

/// Settings for window-state features (all default on). Keys live here to keep shared files untouched.
extension Prefs {
    static let restoreSizeOnUnsnapKey = "windowRestoreSizeOnUnsnap"
    static let reapplyOnDisplayChangeKey = "windowReapplyOnDisplayChange"
    static let reapplyOnLayoutChangeKey = "windowReapplyOnLayoutChange"

    static func registerWindowStateDefaults() {
        UserDefaults.standard.register(defaults: [
            restoreSizeOnUnsnapKey: true, reapplyOnDisplayChangeKey: true, reapplyOnLayoutChangeKey: true,
        ])
    }
    static var restoreSizeOnUnsnap: Bool { UserDefaults.standard.bool(forKey: restoreSizeOnUnsnapKey) }
    static var reapplyOnDisplayChange: Bool { UserDefaults.standard.bool(forKey: reapplyOnDisplayChangeKey) }
    static var reapplyOnLayoutChange: Bool { UserDefaults.standard.bool(forKey: reapplyOnLayoutChangeKey) }
}

extension NSScreen {
    /// Stable display UUID (survives reconnects, unlike `displayID`). Empty string if unavailable.
    var windowTrackerUUID: String {
        guard let u = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
              let s = CFUUIDCreateString(nil, u) else { return "" }
        return s as String
    }
}

/// A window the app has snapped. Rects are in AppKit space.
struct TrackedWindow {
    let element: AXUIElement
    let pid: pid_t
    let bundleID: String
    var titleHint: String
    /// Zones the window occupies (sorted; several when it spans zones), indexes into the layout.
    var zones: [ZoneIndex]
    var layoutID: String
    /// Home screen UUID: where the user put the window. Never overwritten by a fallback to another screen,
    /// so the window returns when the display comes back.
    var screenUUID: String
    var preSnapFrame: CGRect
    /// The frame the tracker last applied (used to detect that the window was moved by someone else).
    var snappedFrame: CGRect
}

/// Central window <-> zone tracker. MAIN THREAD ONLY.
///
/// Identity: `AXUIElement` equality (`CFEqual`) while the app runs; across relaunches a best-effort match by
/// bundle id + snapped frame + title hint. Dead windows are dropped lazily (any query/mutation prunes).
final class WindowTracker {
    static let shared = WindowTracker()
    /// Posted (object: the tracker) after the set of tracked windows or their zones changed.
    static let didChange = Notification.Name("HephaestusWindowTrackerDidChange")

    private(set) var windows: [TrackedWindow] = []
    private var lastByBundle: [String: LastAssignment] = [:]
    private var pendingRestore: [PersistedAssignment] = []
    private var started = false
    private var debounce: DispatchWorkItem?
    private var pendingDisplay = false
    private var pendingLayout = false
    private static let defaultsKey = "windowTrackerState"

    private init() {}

    // MARK: - Public queries

    /// Tracked windows occupying `zone` (spanning windows included), optionally only on one screen UUID.
    func windows(inZone zone: ZoneIndex, screenUUID: String? = nil) -> [TrackedWindow] {
        prune()
        return windows.filter { $0.zones.contains(zone) && (screenUUID == nil || $0.screenUUID == screenUUID) }
    }

    /// The tracked record for a window, if it is snapped.
    func record(for window: AXUIElement) -> TrackedWindow? {
        prune()
        return windows.first { CFEqual($0.element, window) }
    }

    /// The last zones an app (bundle id) was snapped to, even if that window has since closed or been unsnapped.
    func lastAssignment(forBundleID id: String) -> LastAssignment? { lastByBundle[id] }

    // MARK: - Mutation

    /// The window's current frame in AppKit space. Read it BEFORE moving the window and pass it to `register`.
    static func currentFrame(of window: AXUIElement) -> CGRect? {
        WindowMover.frame(of: window).map(ZoneLayout.fromAX)
    }

    /// Record a successful snap. `currentFrame` is the window's frame (AppKit space) BEFORE the snap;
    /// `snappedFrame` the frame it was moved to. Call after `WindowMover.move`.
    func register(window: AXUIElement, zones: Set<ZoneIndex>, screen: NSScreen, currentFrame: CGRect, snappedFrame: CGRect) {
        var pid: pid_t = 0
        AXUIElementGetPid(window, &pid)
        let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
        let sorted = zones.sorted()
        let layoutID = ZoneLayout.layout(for: screen).id
        let uuid = screen.windowTrackerUUID
        let existingIndex = windows.firstIndex { CFEqual($0.element, window) }
        let existing = existingIndex.map { (preSnap: windows[$0].preSnapFrame, snapped: windows[$0].snappedFrame) }
        let rec = TrackedWindow(element: window, pid: pid, bundleID: bundle, titleHint: Self.title(of: window),
                                zones: sorted, layoutID: layoutID, screenUUID: uuid,
                                preSnapFrame: WindowStateMath.preSnapFrame(existing: existing, current: currentFrame),
                                snappedFrame: snappedFrame)
        if let i = existingIndex { windows[i] = rec } else { windows.append(rec) }
        if !bundle.isEmpty { lastByBundle[bundle] = LastAssignment(zones: sorted, layoutID: layoutID, screenUUID: uuid) }
        changed()
    }

    func unregister(_ window: AXUIElement) {
        guard let i = windows.firstIndex(where: { CFEqual($0.element, window) }) else { return }
        windows.remove(at: i)
        changed()
    }

    /// Window was dragged out of its zone. Clears the assignment; if `restoreSize` and the window was still at
    /// its snapped frame (`startFrame`, AppKit space) it gets its pre-snap size back, keeping `cursor`
    /// (AppKit space) at the same relative spot. Returns the pre-snap frame of the cleared record.
    @discardableResult
    func unsnap(_ window: AXUIElement, startFrame: CGRect, cursor: CGPoint, restoreSize: Bool) -> CGRect? {
        guard let i = windows.firstIndex(where: { CFEqual($0.element, window) }) else { return nil }
        let rec = windows.remove(at: i)
        changed()
        if restoreSize, WindowStateMath.frameMatches(startFrame, rec.snappedFrame) {
            let current = WindowMover.frame(of: window).map(ZoneLayout.fromAX) ?? startFrame
            let f = ZoneLayout.toAX(WindowStateMath.unsnapFrame(current: current, cursor: cursor, restoreSize: rec.preSnapFrame.size))
            var size = f.size, origin = f.origin
            if let v = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, v) }
            if let v = AXValueCreate(.cgPoint, &origin) { AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, v) }
        }
        return rec.preSnapFrame
    }

    // MARK: - Observation & restore

    /// Start observing display and layout changes and restore persisted assignments. Idempotent.
    func start() {
        guard !started else { return }
        started = true
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.schedule(display: true)
        }
        nc.addObserver(forName: LayoutStore.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.schedule(display: false)
        }
        load()
        // Give apps a moment after login/launch before looking at their windows.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.restorePersisted() }
    }

    private func schedule(display: Bool) {
        if display { pendingDisplay = true } else { pendingLayout = true }
        debounce?.cancel()
        // Screen parameters settle asynchronously; layout notifications often come in bursts.
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let d = self.pendingDisplay, l = self.pendingLayout
            self.pendingDisplay = false
            self.pendingLayout = false
            self.reapplyAll(display: d, layout: l)
        }
        debounce = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: item)
    }

    /// Re-apply tracked windows to the current geometry by zone index (clamped to the layout's zone count).
    /// Screens are matched by UUID; a window whose home screen is gone goes to the main screen.
    func reapplyAll(display: Bool, layout: Bool) {
        guard AXIsProcessTrusted() else { return }
        prune()
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }
        let uuids = screens.map(\.windowTrackerUUID)
        let fallback = NSScreen.main?.windowTrackerUUID
        var out: [TrackedWindow] = []
        for var rec in windows {
            guard let uuid = WindowStateMath.resolveScreen(home: rec.screenUUID, available: uuids, fallback: fallback),
                  let screen = screens.first(where: { $0.windowTrackerUUID == uuid }) else { out.append(rec); continue }
            let layoutNow = ZoneLayout.layout(for: screen)
            let zones = ZoneLayout.zones(for: screen)
            let current = WindowMover.frame(of: rec.element).map(ZoneLayout.fromAX)
            let action = WindowStateMath.reapplyAction(
                displayTrigger: display, displaySetting: Prefs.reapplyOnDisplayChange,
                layoutTrigger: layout, layoutSetting: Prefs.reapplyOnLayoutChange,
                layoutIDChanged: layoutNow.id != rec.layoutID,
                movedExternally: current.map { !WindowStateMath.frameMatches($0, rec.snappedFrame) } ?? false)
            switch action {
            case .keep: out.append(rec)
            case .drop: continue
            case .apply:
                guard let target = WindowStateMath.reapplyTarget(zones: rec.zones, in: zones) else { out.append(rec); continue }
                if current.map({ !WindowStateMath.frameMatches($0, target, tolerance: 1) }) ?? true {
                    WindowMover.move(rec.element, toAppKitRect: target)
                }
                rec.zones = WindowStateMath.clampZones(rec.zones, count: zones.count)
                rec.snappedFrame = target
                rec.layoutID = layoutNow.id
                out.append(rec)
            }
        }
        windows = out
        changed()
    }

    /// Adopt persisted assignments whose window is found sitting at its recorded frame (best effort).
    private func restorePersisted() {
        let pending = pendingRestore
        pendingRestore = []
        guard AXIsProcessTrusted(), !pending.isEmpty else { return }
        var claimed: [pid_t: Set<Int>] = [:]
        for p in pending {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: p.bundleID) {
                let axApp = AXUIElementCreateApplication(app.processIdentifier)
                var ref: CFTypeRef?
                guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &ref) == .success,
                      let wins = ref as? [AXUIElement] else { continue }
                let cands = wins.map { w in
                    WindowStateMath.Candidate(title: Self.title(of: w),
                                              frame: WindowMover.frame(of: w).map(ZoneLayout.fromAX) ?? .zero)
                }
                guard let i = WindowStateMath.bestMatch(title: p.titleHint, snapped: p.snappedFrame, candidates: cands,
                                                        excluding: claimed[app.processIdentifier] ?? []),
                      !windows.contains(where: { CFEqual($0.element, wins[i]) }) else { continue }
                claimed[app.processIdentifier, default: []].insert(i)
                windows.append(TrackedWindow(element: wins[i], pid: app.processIdentifier, bundleID: p.bundleID,
                                             titleHint: cands[i].title, zones: p.zones, layoutID: p.layoutID,
                                             screenUUID: p.screenUUID, preSnapFrame: p.preSnapFrame,
                                             snappedFrame: p.snappedFrame))
                break
            }
        }
        changed()
    }

    // MARK: - Internals

    /// Drop windows whose AX element is gone. `cannotComplete` (busy app) keeps the window.
    private func prune() {
        let before = windows.count
        windows.removeAll { rec in
            var role: CFTypeRef?
            let err = AXUIElementCopyAttributeValue(rec.element, kAXRoleAttribute as CFString, &role)
            return err != .success && err != .cannotComplete
        }
        if windows.count != before { changed() }
    }

    private func changed() {
        save()
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    private static func title(of w: AXUIElement) -> String {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &ref) == .success else { return "" }
        return (ref as? String) ?? ""
    }

    private func save() {
        let file = WindowStateFile(assignments: windows.filter { !$0.bundleID.isEmpty }.map {
            PersistedAssignment(bundleID: $0.bundleID, titleHint: $0.titleHint, zones: $0.zones, layoutID: $0.layoutID,
                                screenUUID: $0.screenUUID, preSnapFrame: $0.preSnapFrame, snappedFrame: $0.snappedFrame)
        }, lastByBundle: lastByBundle)
        if let data = WindowStateCodec.encode(file) { UserDefaults.standard.set(data, forKey: Self.defaultsKey) }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey), let f = WindowStateCodec.decode(data) else { return }
        pendingRestore = f.assignments
        lastByBundle = f.lastByBundle
    }
}
