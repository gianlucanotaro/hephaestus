import CoreGraphics

/// Pure planning logic for "rotate windows across monitors". No AppKit/AX state is touched here so it is unit-testable.
///
/// Screens are addressed by their position in the left-to-right order (`orderedScreenIndices`).
enum RotationDirection: Int {
    case left = -1, right = 1
}

struct RotationWindow: Equatable {
    var id: Int
    /// Index into the ordered screens the window currently sits on.
    var screen: Int
    /// Zone the window currently occupies on that screen; nil when it is in no zone.
    var zone: ZoneIndex?
}

struct RotationMove: Equatable {
    var id: Int
    var fromScreen: Int
    var toScreen: Int
    /// Destination zone index (already clamped). nil: the window was in no zone, so it is moved
    /// proportionally with `RotationPlan.proportionalRect`.
    var zone: ZoneIndex?
}

enum RotationPlan {
    /// Indices of `frames` sorted left-to-right by `minX` (ties: lower `minY` first, then original order).
    static func orderedScreenIndices(frames: [CGRect]) -> [Int] {
        frames.indices.sorted {
            let (a, b) = (frames[$0], frames[$1])
            if a.minX != b.minX { return a.minX < b.minX }
            if a.minY != b.minY { return a.minY < b.minY }
            return $0 < $1
        }
    }

    /// The screen one step over in `direction`, wrapping around. nil when there is nothing to rotate to.
    static func destination(of screen: Int, count: Int, direction: RotationDirection) -> Int? {
        guard count > 1, (0..<count).contains(screen) else { return nil }
        return ((screen + direction.rawValue) % count + count) % count
    }

    /// Moves every window one screen over, keeping its zone index (clamped to the destination layout's zone count).
    /// `zoneCounts[i]` is the number of zones of ordered screen `i`. Single screen: empty plan.
    static func plan(windows: [RotationWindow], zoneCounts: [Int], direction: RotationDirection) -> [RotationMove] {
        windows.compactMap { w in
            guard let to = destination(of: w.screen, count: zoneCounts.count, direction: direction) else { return nil }
            var zone: ZoneIndex?
            if let z = w.zone, zoneCounts[to] > 0 { zone = min(max(z, 0), zoneCounts[to] - 1) }
            return RotationMove(id: w.id, fromScreen: w.screen, toScreen: to, zone: zone)
        }
    }

    /// The zone a window frame belongs to: the zone with the largest overlap, provided it covers at least
    /// `minCoverage` of the window's area; otherwise nil (e.g. a free-floating or multi-zone window).
    static func bestZone(for frame: CGRect, in zones: [CGRect], minCoverage: CGFloat = 0.5) -> ZoneIndex? {
        let windowArea = frame.width * frame.height
        guard windowArea > 0 else { return nil }
        var best: (ZoneIndex, CGFloat)?
        for (i, zone) in zones.enumerated() {
            let r = frame.intersection(zone)
            let a = r.isNull ? 0 : r.width * r.height
            if a > 0, a > (best?.1 ?? 0) { best = (i, a) }
        }
        guard let (index, area) = best, area / windowArea >= minCoverage else { return nil }
        return index
    }

    /// Maps `frame` from one screen's usable frame to another's, keeping relative position and size.
    static func proportionalRect(_ frame: CGRect, from source: CGRect, to target: CGRect) -> CGRect {
        guard source.width > 0, source.height > 0 else { return target }
        let sx = target.width / source.width, sy = target.height / source.height
        let r = CGRect(x: target.minX + (frame.minX - source.minX) * sx,
                       y: target.minY + (frame.minY - source.minY) * sy,
                       width: frame.width * sx, height: frame.height * sy)
        return r.intersection(target).isNull ? target : r.intersection(target)
    }
}

/// Key-event state machine for the rotation shortcut. Pure so the hold/swallow rules are testable.
/// "Held" means the modifier and the trigger key are both down.
struct RotationHoldState {
    enum Kind { case keyDown, keyUp, flagsChanged }
    enum Action: Equatable { case none, showPreview, hidePreview, rotate(RotationDirection) }

    var enabled = true
    var triggerKeyCode: Int
    var modifier: CGEventFlags
    private(set) var held = false
    private var swallowedKeyUps: Set<Int> = []

    static let leftArrow = 123, rightArrow = 124

    init(triggerKeyCode: Int, modifier: CGEventFlags) {
        self.triggerKeyCode = triggerKeyCode
        self.modifier = modifier
    }

    /// Returns what to do and whether the event should be swallowed (only possible with an event tap).
    mutating func handle(_ kind: Kind, keyCode: Int, flags: CGEventFlags, isRepeat: Bool = false) -> (action: Action, swallow: Bool) {
        guard enabled else {
            let was = held
            held = false
            swallowedKeyUps.removeAll()
            return (was ? .hidePreview : .none, false)
        }
        switch kind {
        case .flagsChanged:
            if held, !flags.contains(modifier) {
                held = false
                return (.hidePreview, false)
            }
            return (.none, false)
        case .keyDown:
            if keyCode == triggerKeyCode, flags.contains(modifier) {
                swallowedKeyUps.insert(keyCode)
                if held { return (.none, true) }
                held = true
                return (.showPreview, true)
            }
            if held, keyCode == Self.leftArrow || keyCode == Self.rightArrow {
                swallowedKeyUps.insert(keyCode)
                if isRepeat { return (.none, true) }
                return (.rotate(keyCode == Self.leftArrow ? .left : .right), true)
            }
            return (.none, false)
        case .keyUp:
            let swallow = swallowedKeyUps.remove(keyCode) != nil
            if held, keyCode == triggerKeyCode {
                held = false
                return (.hidePreview, swallow)
            }
            return (.none, swallow)
        }
    }
}
