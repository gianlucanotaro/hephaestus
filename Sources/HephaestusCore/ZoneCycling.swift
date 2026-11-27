import AppKit
import ApplicationServices
import Carbon.HIToolbox
import SwiftUI

// MARK: - Pure planning

/// A window that can be cycled to. `id` is an opaque caller-chosen handle (e.g. index into the real window list).
struct CycleCandidate: Equatable {
    var id: Int
    /// Position in the tracker's window list: tracker order is snap order (a window keeps its place when re-snapped).
    var order: Int
    var pid: Int32
    var title: String
}

enum ZoneCycleDirection { case next, previous }

enum ZoneCycling {
    /// Stable cycle order: snap order, then pid, then title, then id (so ties never reshuffle).
    static func ordered(_ candidates: [CycleCandidate]) -> [CycleCandidate] {
        candidates.sorted {
            ($0.order, $0.pid, $0.title, $0.id) < ($1.order, $1.pid, $1.title, $1.id)
        }
    }

    /// The candidate to activate after/before `current`, wrapping around. If `current` is not among the candidates
    /// it is treated as sitting before the first (next -> first) / after the last (previous -> last).
    /// Returns nil if there is nothing else to switch to.
    static func nextWindow(in candidates: [CycleCandidate], current: Int, direction: ZoneCycleDirection) -> Int? {
        let list = ordered(candidates)
        guard list.contains(where: { $0.id != current }) else { return nil }
        guard let i = list.firstIndex(where: { $0.id == current }) else {
            return (direction == .next ? list.first : list.last)?.id
        }
        let n = list.count
        return list[(i + (direction == .next ? 1 : n - 1)) % n].id
    }
}

// MARK: - Prefs

extension Prefs {
    static let zoneCycleEnabledKey = "zoneCycleEnabled"
    static let zoneCycleModifiersKey = "zoneCycleModifiers"

    static func registerZoneCycleDefaults() {
        UserDefaults.standard.register(defaults: [
            zoneCycleEnabledKey: true, zoneCycleModifiersKey: controlKey | optionKey,
        ])
    }
    static var zoneCycleEnabled: Bool { UserDefaults.standard.bool(forKey: zoneCycleEnabledKey) }
}

// MARK: - Controller

/// Registers the next/previous hotkeys (PageDown / PageUp) and switches between windows tracked in the focused
/// window's zone. MAIN THREAD ONLY.
final class ZoneCycleController {
    private let hotKeys: HotKeys
    private var ids: [UInt32] = []
    private var registered: [Shortcut?] = []

    init(hotKeys: HotKeys = .shared) { self.hotKeys = hotKeys }

    func start() {
        reconcile()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.reconcile()
        }
    }

    private func reconcile() {
        let want = Prefs.zoneCycleEnabled
        let next = ShortcutStore.read(.cycleNext), previous = ShortcutStore.read(.cyclePrevious)
        if !registered.isEmpty, !want || [next, previous] != registered {
            ids.forEach { hotKeys.unregister($0) }
            ids = []
            registered = []
        }
        guard want, registered.isEmpty else { return }
        registered = [next, previous]
        if let next, let id = hotKeys.register(keyCode: next.keyCode, modifiers: next.modifiers.carbon, action: { [weak self] in self?.cycle(.next) }) {
            ids.append(id)
        }
        if let previous, let id = hotKeys.register(keyCode: previous.keyCode, modifiers: previous.modifiers.carbon, action: { [weak self] in self?.cycle(.previous) }) {
            ids.append(id)
        }
    }

    private func cycle(_ direction: ZoneCycleDirection) {
        guard let current = WindowMover.focusedWindow(prompt: false) else { return }
        let tracker = WindowTracker.shared
        // A window spanning several zones cycles within its first zone.
        guard let rec = tracker.record(for: current), let zone = rec.zones.first else { NSSound.beep(); return }

        // Tracker list order is snap order; use it as the cycle order, and drop minimized windows.
        let all = tracker.windows
        let inZone = tracker.windows(inZone: zone, screenUUID: rec.screenUUID).filter { !Self.isMinimized($0.element) }
        var cands: [CycleCandidate] = []
        var currentID = -1
        for (i, w) in inZone.enumerated() {
            cands.append(CycleCandidate(id: i, order: all.firstIndex { CFEqual($0.element, w.element) } ?? i,
                                        pid: w.pid, title: w.titleHint))
            if CFEqual(w.element, current) { currentID = i }
        }
        guard let target = ZoneCycling.nextWindow(in: cands, current: currentID, direction: direction) else { return }
        Self.activate(inZone[target])
    }

    private static func isMinimized(_ w: AXUIElement) -> Bool {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w, kAXMinimizedAttribute as CFString, &ref) == .success else { return false }
        return (ref as? Bool) ?? false
    }

    private static func activate(_ rec: TrackedWindow) {
        AXUIElementPerformAction(rec.element, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(rec.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(rec.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        NSRunningApplication(processIdentifier: rec.pid)?.activate(options: [.activateIgnoringOtherApps])
    }
}

// MARK: - Settings UI

/// The enable toggle (Windows tab). The two shortcuts are recorded in the Shortcuts tab.
struct ZoneCycleSettings: View {
    @AppStorage(Prefs.zoneCycleEnabledKey) private var enabled = true

    var body: some View {
        Group {
            Text("Zone cycling").font(.headline)
            Toggle("Cycle windows within a zone", isOn: $enabled)
            Text("Next / previous window snapped to the focused window's zone (shortcuts: Shortcuts tab).")
                .settingsHint()
        }
    }
}
