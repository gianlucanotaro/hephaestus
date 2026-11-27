import AppKit
import ApplicationServices
import SwiftUI

/// Stack hover (#46). Keys live here to keep shared files untouched.
extension Prefs {
    static let stackHoverKey = "stackHoverEnabled"

    static func registerStackHoverDefaults() {
        UserDefaults.standard.register(defaults: [stackHoverKey: false])
    }
    static var stackHoverEnabled: Bool { UserDefaults.standard.bool(forKey: stackHoverKey) }
}

/// Badge + hover tray for zones holding 2+ tracked windows. MAIN THREAD ONLY.
///
/// Zone membership comes from `WindowTracker`; z-order from the window server's on-screen list (owner pid, bounds,
/// layer, ordering only: no window names, so no Screen Recording). Titles come from AX, icons from NSRunningApplication.
final class StackHoverController {
    static let shared = StackHoverController()

    /// A window in a stack, front-to-back.
    private struct Member {
        var element: AXUIElement
        var pid: pid_t
        var appName: String
        var title: String
        var icon: NSImage?
    }
    private struct Stack {
        var key: StackMath.StackKey
        var members: [Member]
        var frontFrame: CGRect     // AppKit space
        var visible: CGRect        // visibleFrame of the screen the front window is on
    }

    private var enabled = false
    private var stacks: [Stack] = []
    private var badges: [StackMath.StackKey: (panel: StackPanel, view: StackBadgeView)] = [:]
    private var tray: StackPanel?
    private var trayView: StackTrayView?
    private var hover = StackMath.Hover()
    private var activeKey: StackMath.StackKey?
    private var monitors: [Any] = []
    private var keyMonitors: [Any] = []
    private var refreshTimer: Timer?
    private var tickTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var started = false
    private var badgesHidden = false

    private init() {}

    /// Call once at launch. Follows the setting live.
    func start() {
        guard !started else { return }
        started = true
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.applySetting()
        }
        applySetting()
    }

    private func applySetting() {
        let want = Prefs.stackHoverEnabled
        guard want != enabled else { return }
        enabled = want
        want ? install() : uninstall()
    }

    // MARK: - Install / uninstall

    private func install() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] e in self?.pointer(e) }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in self?.pointer(e); return e }) { monitors.append(l) }
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: WindowTracker.didChange, object: nil, queue: .main) { [weak self] _ in self?.refresh() })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
                // Let the window server update z-order first.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self?.refresh() }
            })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.refresh() })
        observers.append(nc.addObserver(forName: ScreenLayoutStore.didChange, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self?.refresh() }
        })
        refresh()
    }

    private func uninstall() {
        monitors.forEach(NSEvent.removeMonitor); monitors = []
        let nc = NotificationCenter.default
        observers.forEach { nc.removeObserver($0); NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers = []
        refreshTimer?.invalidate(); refreshTimer = nil
        tickTimer?.invalidate(); tickTimer = nil
        hideTray()
        hover = StackMath.Hover()
        activeKey = nil
        stacks = []
        badges.values.forEach { $0.panel.orderOut(nil) }
        badges = [:]
    }

    private var suppressed: Bool {
        !enabled || DragSnapController.isDragging || LayoutEditorController.current != nil
    }

    // MARK: - Data

    /// Front-to-back on-screen windows (pid, bounds, layer only; never the window name).
    private static func onScreenEntries() -> [StackMath.CGEntry] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { d in
            guard let pid = d[kCGWindowOwnerPID as String] as? Int32,
                  let layer = d[kCGWindowLayer as String] as? Int,
                  let b = d[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: b) else { return nil }
            return StackMath.CGEntry(pid: pid, bounds: rect, layer: layer)
        }
    }

    private func computeStacks() -> [Stack] {
        guard AXIsProcessTrusted() else { return [] }
        let tracked = WindowTracker.shared.windows
        var items: [StackMath.Item] = []
        var axFrames: [CGRect] = []
        for (i, rec) in tracked.enumerated() {
            guard let ax = WindowMover.frame(of: rec.element) else { continue }   // gone or unreadable
            items.append(.init(id: i, pid: rec.pid, screenUUID: rec.screenUUID, zones: rec.zones,
                               frame: ZoneLayout.fromAX(ax), minimized: AX.bool(rec.element, kAXMinimizedAttribute)))
            axFrames.append(ax)
        }
        let groups = StackMath.stacks(items)
        guard !groups.isEmpty else { return [] }
        let ranks = StackMath.zRanks(items: items, frames: axFrames, entries: Self.onScreenEntries())
        var out: [Stack] = []
        for g in groups {
            let ordered = StackMath.sortedFrontToBack(g.ids, ranks: ranks)
            // Only show a stack whose front window is really on screen now (not on another Space).
            guard let front = ordered.first, ranks[front] != nil,
                  let frontItem = items.first(where: { $0.id == front }) else { continue }
            let members: [Member] = ordered.map { id in
                let rec = tracked[id]
                let app = NSRunningApplication(processIdentifier: rec.pid)
                let live = AX.title(of: rec.element)
                return Member(element: rec.element, pid: rec.pid, appName: app?.localizedName ?? rec.bundleID,
                              title: live.isEmpty ? rec.titleHint : live, icon: app?.icon)
            }
            let c = CGPoint(x: frontItem.frame.midX, y: frontItem.frame.midY)
            let screen = NSScreen.screens.first { $0.frame.contains(c) } ?? NSScreen.main
            out.append(Stack(key: g.key, members: members, frontFrame: frontItem.frame,
                             visible: screen?.visibleFrame ?? frontItem.frame))
        }
        return out
    }

    // MARK: - Refresh

    private func refresh() {
        guard enabled else { return }
        stacks = computeStacks()
        if let key = activeKey, hover.isShown, !stacks.contains(where: { $0.key == key }) {
            apply(hover.dismiss())
        }
        syncBadges()
        if hover.isShown, let key = activeKey, let s = stacks.first(where: { $0.key == key }) { fillTray(s) }
        updateTimers()
    }

    private func syncBadges() {
        let hide = suppressed
        badgesHidden = hide
        let live = Set(stacks.map(\.key))
        for key in badges.keys where !live.contains(key) {
            badges[key]?.panel.orderOut(nil)
            badges[key] = nil
        }
        for s in stacks {
            let rect = StackMath.badgeRect(of: s.frontFrame)
            let entry: (panel: StackPanel, view: StackBadgeView)
            if let e = badges[s.key] {
                entry = e
            } else {
                let p = StackPanel(frame: rect)
                let v = StackBadgeView(frame: CGRect(origin: .zero, size: rect.size))
                p.contentView = v
                p.ignoresMouseEvents = true   // clicks reach the window below; hover is tracked by the global monitor
                entry = (p, v)
                badges[s.key] = entry
            }
            entry.view.count = s.members.count
            entry.panel.setFrame(rect, display: true)
            if hide { entry.panel.orderOut(nil) } else { entry.panel.orderFrontRegardless() }
        }
    }

    private func updateTimers() {
        if stacks.isEmpty {
            refreshTimer?.invalidate(); refreshTimer = nil
        } else if refreshTimer == nil {
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in self?.refresh() }
        }
        if hover.needsTick, tickTimer == nil {
            tickTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in self?.evaluate() }
        } else if !hover.needsTick {
            tickTimer?.invalidate(); tickTimer = nil
        }
    }

    // MARK: - Pointer / state machine

    private func pointer(_ event: NSEvent) {
        if event.type == .leftMouseDown, hover.isShown, !(tray.map { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? false) {
            apply(hover.dismiss())   // a click anywhere else (e.g. on the title bar) dismisses
        }
        evaluate()
    }

    private func evaluate() {
        guard enabled else { return }
        let p = NSEvent.mouseLocation
        if hover.state == .idle || hover.state == .dismissed || isPending {
            activeKey = stacks.first { StackMath.inTrigger(p, frame: $0.frontFrame) }?.key
        }
        let active = stacks.first { $0.key == activeKey }
        let inTrigger = active.map { StackMath.inTrigger(p, frame: $0.frontFrame) } ?? false
        let inTray = tray.map { NSMouseInRect(p, $0.frame, false) } ?? false
        let action = hover.update(now: ProcessInfo.processInfo.systemUptime, inTrigger: inTrigger, inTray: inTray,
                                  suppressed: suppressed)
        apply(action)
        if suppressed != badgesHidden { syncBadges() }
        updateTimers()
    }

    private var isPending: Bool {
        if case .pending = hover.state { return true }
        return false
    }

    private func apply(_ action: StackMath.Hover.Action?) {
        switch action {
        case .open:
            if let s = stacks.first(where: { $0.key == activeKey }) { showTray(s) } else { _ = hover.dismiss() }
        case .close: hideTray()
        case nil: break
        }
    }

    // MARK: - Tray

    private func showTray(_ s: Stack) {
        let view = StackTrayView(frame: .zero)
        let panel = StackPanel(frame: .zero)
        panel.contentView = view
        panel.ignoresMouseEvents = false
        tray = panel
        trayView = view
        view.onPick = { [weak self] i in self?.pick(i) }
        fillTray(s)
        panel.orderFrontRegardless()
        installKeyMonitors()
    }

    private func fillTray(_ s: Stack) {
        guard let panel = tray, let view = trayView else { return }
        let layout = StackMath.trayLayout(count: s.members.count, maxWidth: s.visible.width)
        let rect = StackMath.trayRect(size: layout.size, window: s.frontFrame, visible: s.visible)
        view.header = StackMath.headerTitle(zoneTitle: Layout.zoneTitle(s.key.zone), count: s.members.count)
        view.columns = layout.columns
        view.cards = s.members.enumerated().map { i, m in
            StackCardInfo(appName: m.appName, title: m.title, icon: m.icon, tint: StackPalette.tint(of: m.icon), isFront: i == 0)
        }
        panel.setFrame(rect, display: false)
        view.frame = CGRect(origin: .zero, size: rect.size)
        view.needsDisplay = true
    }

    private func hideTray() {
        tray?.orderOut(nil)
        tray = nil
        trayView = nil
        keyMonitors.forEach(NSEvent.removeMonitor)
        keyMonitors = []
    }

    private func installKeyMonitors() {
        guard keyMonitors.isEmpty else { return }
        // The panels never become key, so Esc arrives via the global monitor (it cannot be swallowed).
        if let g = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            if e.keyCode == 53 { self?.apply(self?.hover.dismiss()) }
        }) { keyMonitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            if e.keyCode == 53 { self?.apply(self?.hover.dismiss()); return nil }
            return e
        }) { keyMonitors.append(l) }
    }

    // MARK: - Raise

    private func pick(_ index: Int) {
        guard let s = stacks.first(where: { $0.key == activeKey }), index < s.members.count else { return }
        let m = s.members[index]
        AXUIElementPerformAction(m.element, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(m.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(m.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        NSRunningApplication(processIdentifier: m.pid)?.activate(options: [.activateIgnoringOtherApps])
        apply(hover.dismiss())
        // Z-order changes asynchronously; refresh so the badge and FRONT tag follow.
        for delay in [0.15, 0.5] { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.refresh() } }
    }
}

// MARK: - Settings UI

struct StackHoverSettings: View {
    @AppStorage(Prefs.stackHoverKey) private var enabled = false

    var body: some View {
        Group {
            Text("Stack hover").font(.headline)
            Toggle("Show stack badge and hover tray", isOn: $enabled)
            Text("When several windows share a zone, the front one gets a count badge. Hover it (or the title bar) to list the stack and click a window to bring it forward. Shows app icons and window titles only, no thumbnails, so no extra permission is needed.")
                .settingsHint()
        }
    }
}
