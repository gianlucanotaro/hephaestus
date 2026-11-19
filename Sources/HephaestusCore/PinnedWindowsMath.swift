import CoreGraphics
import Foundation

// Pure logic for "pin window on top" (#45): pin list, which pinned windows need a re-raise, raise rate limiting and
// menu titles. No AX / AppKit here so everything is unit-tested. The plumbing lives in `PinnedWindows.swift`.

/// Ordered list of pinned items. Order = stacking priority: later items sit above earlier ones. Pure value type;
/// the item identity test is supplied by the caller (the real list uses `CFEqual` on AX elements).
struct PinList<Item> {
    private(set) var items: [Item] = []

    func contains(where matches: (Item) -> Bool) -> Bool { items.contains(where: matches) }

    /// Pins `item` unless an existing item matches, in which case that one is removed. Returns true when pinned.
    @discardableResult
    mutating func toggle(_ item: Item, matches: (Item) -> Bool) -> Bool {
        if let i = items.firstIndex(where: matches) {
            items.remove(at: i)
            return false
        }
        items.append(item)
        return true
    }

    /// Removes every matching item (stable order for the rest). Returns how many were removed.
    @discardableResult
    mutating func remove(where predicate: (Item) -> Bool) -> Int {
        let before = items.count
        items.removeAll(where: predicate)
        return before - items.count
    }

    mutating func removeAll() { items.removeAll() }
}

/// One on-screen window from `CGWindowListCopyWindowInfo` (public fields only; no Screen Recording needed).
struct WindowSnapshot: Equatable {
    var number: Int
    var pid: Int32
    /// Global coordinates, top-left origin: the same space as Accessibility positions.
    var bounds: CGRect
    var layer: Int
    var alpha: Double
}

/// A pinned window as seen by the raise decision. `key` is stable per pin.
struct PinTarget: Equatable {
    var key: Int
    var pid: Int32
    var bounds: CGRect
}

enum PinRaise {
    /// How far an AX frame may differ from the CG bounds and still be "the same window".
    static let boundsTolerance: CGFloat = 2

    static func sameWindow(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= boundsTolerance && abs(a.minY - b.minY) <= boundsTolerance
            && abs(a.width - b.width) <= boundsTolerance && abs(a.height - b.height) <= boundsTolerance
    }

    /// Keys of the pinned windows that must be raised, in the order to raise them (lowest priority first, so the
    /// highest ends on top and the pins keep their relative order).
    /// - `pinned`: in priority order (later = above).
    /// - `windows`: ALL on-screen windows, front to back (the order CGWindowList returns).
    /// A pinned window is obscured when a window above it overlaps it and is either not pinned or a lower-priority
    /// pin. Only normal-layer windows count (menus, panels, the Dock and other floating windows are not ours to
    /// beat). Pins with no on-screen match (minimized, other Space, hidden app, moved since) are skipped.
    static func windowsToRaise(pinned: [PinTarget], windows: [WindowSnapshot], ignoringPid: Int32? = nil) -> [Int] {
        let normal = windows.filter { $0.layer == 0 && $0.alpha > 0.01 && $0.pid != ignoringPid }
        var matched: [Int: Int] = [:]      // window index (in `normal`) -> priority of the pin that owns it
        var matchIndex: [Int: Int] = [:]   // priority -> window index
        for (priority, pin) in pinned.enumerated() {
            guard let idx = normal.indices.first(where: {
                matched[$0] == nil && normal[$0].pid == pin.pid && sameWindow(normal[$0].bounds, pin.bounds)
            }) else { continue }
            matched[idx] = priority
            matchIndex[priority] = idx
        }
        var out: [Int] = []
        for (priority, pin) in pinned.enumerated() {
            guard let idx = matchIndex[priority] else { continue }
            let obscured = (0..<idx).contains { above in
                let r = normal[above].bounds.intersection(pin.bounds)
                guard !r.isNull, r.width > 1, r.height > 1 else { return false }
                if let p = matched[above] { return p < priority }
                return true
            }
            if obscured { out.append(pin.key) }
        }
        return out
    }
}

/// Rate limiting for raises: at most one raise per pin per `minInterval`, and a short window after any raise in which
/// AX notifications are assumed to be echoes of our own raise. Times are passed in (seconds) so it is testable.
struct RaiseGate {
    var minInterval: TimeInterval = 0.15
    var echoWindow: TimeInterval = 0.3
    private var lastRaise: [Int: TimeInterval] = [:]
    private var lastAny: TimeInterval?

    /// Returns true (and records the raise) when `key` may be raised now.
    mutating func allowRaise(key: Int, now: TimeInterval) -> Bool {
        if let t = lastRaise[key], now - t < minInterval { return false }
        lastRaise[key] = now
        lastAny = now
        return true
    }

    /// True when a notification arriving `now` is probably caused by our own raise and should be ignored.
    func isEcho(now: TimeInterval) -> Bool {
        guard let t = lastAny else { return false }
        return now - t < echoWindow
    }

    mutating func forget(key: Int) { lastRaise[key] = nil; lastForce[key] = nil; forceFailures[key] = nil }

    // MARK: Force raise (focus-switching fallback)

    var forceInterval: TimeInterval = 1.5
    var maxForceInterval: TimeInterval = 30
    private var lastForce: [Int: TimeInterval] = [:]
    private var forceFailures: [Int: Int] = [:]

    /// Minimum wait before the next force for `key`: doubles with every force that did not help (capped), so a pin
    /// that cannot be kept on top (an app that ignores it, a fight with another pin) backs off instead of flickering.
    func forceDelay(key: Int) -> TimeInterval {
        min(forceInterval * pow(2, Double(forceFailures[key] ?? 0)), maxForceInterval)
    }

    /// Returns true (and records it, also counting as our own activity for `isEcho`) when `key` may be forced now.
    mutating func allowForce(key: Int, now: TimeInterval) -> Bool {
        if let t = lastForce[key], now - t < forceDelay(key: key) { return false }
        lastForce[key] = now
        lastAny = now
        return true
    }

    mutating func recordForce(key: Int, succeeded: Bool) {
        forceFailures[key] = succeeded ? nil : (forceFailures[key] ?? 0) + 1
    }
}

enum PinForce {
    /// Whether to fall back to the focus-switching raise. Pure; the caller supplies the facts.
    static func shouldForce(enabled: Bool, stillObscured: Bool, pinnedAppIsFrontmost: Bool,
                            frontmostIsSelf: Bool, mouseButtonDown: Bool) -> Bool {
        enabled && stillObscured && !pinnedAppIsFrontmost && !frontmostIsSelf && !mouseButtonDown
    }
}

enum PinMenuLogic {
    /// Title and enabled state of the toggle item. `isPinned` is nil when the focused window cannot be pinned.
    static func toggleItem(isPinned: Bool?, featureEnabled: Bool) -> (title: String, enabled: Bool) {
        guard featureEnabled else { return ("Pin Window on Top", false) }
        switch isPinned {
        case .some(true): return ("Unpin Window", true)
        case .some(false): return ("Pin Window on Top", true)
        case .none: return ("Pin Window on Top", false)
        }
    }

    static func submenuTitle(count: Int) -> String { count == 0 ? "Pinned Windows" : "Pinned Windows (\(count))" }

    /// "App — Title", shortened; just the app when the window has no title.
    static func listTitle(appName: String, windowTitle: String, limit: Int = 50) -> String {
        let t = windowTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let full = t.isEmpty ? appName : "\(appName) — \(t)"
        return full.count <= limit ? full : String(full.prefix(limit - 1)) + "…"
    }
}
