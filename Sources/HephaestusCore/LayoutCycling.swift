import AppKit

// Mouse-wheel layout cycling during a snap-drag (issue #9). Pure logic first, AppKit glue below.

extension Prefs {
    static let wheelCycleKey = "cycleLayoutsWithWheel"
    static func registerWheelCycleDefaults() {
        UserDefaults.standard.register(defaults: [wheelCycleKey: false])
    }
    static var cycleLayoutsWithWheel: Bool { UserDefaults.standard.bool(forKey: wheelCycleKey) }
}

enum CycleDirection { case forward, backward }

enum LayoutCycleOrder {
    /// Ids to cycle through: hotkey-numbered layouts if 2+ have numbers, else custom layouts if 2+, else all layouts.
    static func order(hotkeyOrdered: [Layout], all: [Layout]) -> [String] {
        if hotkeyOrdered.count >= 2 { return hotkeyOrdered.map(\.id) }
        let custom = all.filter { !$0.isBuiltIn }
        if custom.count >= 2 { return custom.map(\.id) }
        return all.map(\.id)
    }

    /// Next id in `order`, wrapping. If `current` is not part of the order, forward picks the first and backward the last.
    static func next(from current: String, in order: [String], direction: CycleDirection) -> String? {
        guard !order.isEmpty else { return nil }
        guard let i = order.firstIndex(of: current) else { return direction == .forward ? order.first : order.last }
        let n = order.count
        return order[direction == .forward ? (i + 1) % n : (i + n - 1) % n]
    }
}

/// Turns a stream of scroll deltas into discrete cycle steps: accumulates until `threshold`, then fires once and
/// resets, and ignores further steps within `minInterval` so one trackpad flick moves a single layout.
struct ScrollAccumulator {
    static let preciseThreshold: CGFloat = 40   // trackpad points
    static let wheelThreshold: CGFloat = 1      // mouse wheel notches
    var minInterval: TimeInterval = 0.25
    private(set) var accumulated: CGFloat = 0
    private var lastFire: TimeInterval = -.infinity

    /// Scrolling down (negative delta) = next layout.
    mutating func add(delta: CGFloat, threshold: CGFloat, at time: TimeInterval) -> CycleDirection? {
        guard delta != 0 else { return nil }
        // A direction reversal discards what was accumulated the other way.
        if accumulated != 0, (accumulated < 0) != (delta < 0) { accumulated = 0 }
        accumulated += delta
        guard abs(accumulated) >= threshold else { return nil }
        let direction: CycleDirection = accumulated < 0 ? .forward : .backward
        accumulated = 0
        guard time - lastFire >= minInterval else { return nil }
        lastFire = time
        return direction
    }

    mutating func reset() { accumulated = 0; lastFire = -.infinity }
}

/// Applies wheel steps to the layout of the screen under the cursor.
final class WheelLayoutCycler {
    private var accumulator = ScrollAccumulator()

    func reset() { accumulator.reset() }

    /// Returns true when the event was consumed (a layout cycle happened or momentum of one was ignored).
    @discardableResult
    func handle(_ event: NSEvent) -> Bool {
        if !event.momentumPhase.isEmpty { return true }   // inertia after a flick must not cycle again
        let precise = event.hasPreciseScrollingDeltas
        guard let direction = accumulator.add(
            delta: event.scrollingDeltaY,
            threshold: precise ? ScrollAccumulator.preciseThreshold : ScrollAccumulator.wheelThreshold,
            at: event.timestamp) else { return true }
        guard let screen = ZoneLayout.screenUnderCursor() else { return true }
        let order = LayoutCycleOrder.order(hotkeyOrdered: LayoutHotkeys.shared.orderedLayouts, all: LayoutStore.shared.all)
        let current = ZoneLayout.layout(for: screen).id
        if let id = LayoutCycleOrder.next(from: current, in: order, direction: direction), id != current {
            // ScreenLayoutStore.didChange makes DragSnapController rebuild the overlay.
            ZoneLayout.setLayout(id: id, for: screen)
        }
        return true
    }
}

/// Swallows scroll-wheel events system-wide, ONLY while enabled (i.e. during a snap-drag), so the window under the
/// cursor does not scroll. Uses a public CGEventTap (needs the Accessibility permission the app already has).
/// If the tap cannot be created, `enable()` returns false and events simply pass through (the NSEvent monitor
/// still drives the cycling, but the underlying view scrolls too).
final class ScrollSwallower {
    /// Return true to swallow the event.
    var handler: ((NSEvent) -> Bool)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    var isEnabled: Bool { tap != nil }

    @discardableResult
    func enable() -> Bool {
        if tap != nil { return true }
        let callback: CGEventTapCallBack = { _, type, cgEvent, info in
            guard let info else { return Unmanaged.passUnretained(cgEvent) }
            let me = Unmanaged<ScrollSwallower>.fromOpaque(info).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = me.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(cgEvent)
            }
            guard type == .scrollWheel, let event = NSEvent(cgEvent: cgEvent) else { return Unmanaged.passUnretained(cgEvent) }
            return (me.handler?(event) ?? false) ? nil : Unmanaged.passUnretained(cgEvent)
        }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: CGEventMask(1 << CGEventType.scrollWheel.rawValue),
                                           callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }
        let src = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        tap = port
        source = src
        return true
    }

    /// Removes the tap entirely, so nothing observes scroll events outside a drag.
    func disable() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        CFMachPortInvalidate(tap)
        self.tap = nil
        source = nil
    }

    deinit { disable() }
}
