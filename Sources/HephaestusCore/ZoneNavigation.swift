import Carbon.HIToolbox
import CoreGraphics

/// Pure logic for keyboard zone navigation (issue #10). Everything works on AppKit-space `CGRect`s
/// (origin bottom-left, so "up" means larger y) and `ZoneIndex`es; no AppKit/AX calls in this file.

enum NavDirection: CaseIterable {
    case left, right, up, down
    var isHorizontal: Bool { self == .left || self == .right }
}

/// How the navigation hotkeys behave.
enum KeyboardNavMode: String, CaseIterable {
    /// Direct per-zone hotkeys (first / middle / last zone). The historical behaviour and the default.
    case direct
    /// Left / right arrows step to the previous / next zone index.
    case zoneIndex
    /// All four arrows pick the nearest zone in that direction; a second hotkey set expands the span.
    case relative

    var title: String {
        switch self {
        case .direct: return "Direct zones (first / middle / last)"
        case .zoneIndex: return "Zone index (left / right)"
        case .relative: return "Relative position (all arrows)"
        }
    }
}

/// One screen as seen by the navigation logic.
struct NavScreen: Equatable {
    var frame: CGRect
    var zones: [CGRect]
}

enum NavTarget: Equatable {
    case zone(screen: Int, zone: ZoneIndex)
}

enum ZoneNavigation {
    static let epsilon: CGFloat = 1

    // MARK: Locating the window

    /// Intersection-over-union of two rects (0 when disjoint).
    static func overlapRatio(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let i = a.intersection(b)
        guard !i.isNull, i.width > 0, i.height > 0 else { return 0 }
        let inter = i.width * i.height
        let union = a.width * a.height + b.width * b.height - inter
        return union > 0 ? inter / union : 0
    }

    /// The zone that best matches `frame` (highest overlap ratio). With no overlap at all, the zone whose
    /// center is closest. `nil` only when `zones` is empty. Ties go to the lowest index.
    static func bestZone(for frame: CGRect, in zones: [CGRect]) -> ZoneIndex? {
        guard !zones.isEmpty else { return nil }
        var best = 0, bestScore: CGFloat = -1
        for (i, z) in zones.enumerated() {
            let s = overlapRatio(frame, z)
            if s > bestScore + 1e-9 { best = i; bestScore = s }
        }
        if bestScore > 0 { return best }
        let c = CGPoint(x: frame.midX, y: frame.midY)
        return zones.indices.min { hypot(c.x - zones[$0].midX, c.y - zones[$0].midY)
            < hypot(c.x - zones[$1].midX, c.y - zones[$1].midY) }
    }

    /// Current zones of a window: the tracker's zones when it has a record and the window still sits at the frame the
    /// tracker applied (and the zones still exist), else the frame-overlap guess (`zoneSpan`).
    static func currentZones(tracked: (zones: [ZoneIndex], snappedFrame: CGRect)?, frame: CGRect, in zones: [CGRect],
                             tolerance: CGFloat = 16) -> Set<ZoneIndex> {
        if let tracked, !tracked.zones.isEmpty, tracked.zones.allSatisfy(zones.indices.contains),
           WindowStateMath.frameMatches(frame, tracked.snappedFrame) {
            return Set(tracked.zones)
        }
        return zoneSpan(of: frame, in: zones, tolerance: tolerance)
    }

    /// The set of zones the window occupies judging by its frame alone. A near-exact match of one zone wins;
    /// otherwise, if the zones the window mostly covers have a bounding rect matching the window (a multi-zone
    /// span), that set; otherwise just the best-overlap zone. Fallback for windows the tracker does not know.
    static func zoneSpan(of frame: CGRect, in zones: [CGRect], tolerance: CGFloat = 16) -> Set<ZoneIndex> {
        guard let best = bestZone(for: frame, in: zones) else { return [] }
        if overlapRatio(frame, zones[best]) >= 0.9 { return [best] }
        let covered = zones.indices.filter { i in
            let z = zones[i], inter = frame.intersection(z)
            guard !inter.isNull, z.width * z.height > 0 else { return false }
            return inter.width * inter.height / (z.width * z.height) >= 0.5
        }
        if covered.count > 1,
           let box = ZoneLayout.boundingRect(of: Set(covered), in: zones),
           abs(box.minX - frame.minX) <= tolerance, abs(box.maxX - frame.maxX) <= tolerance,
           abs(box.minY - frame.minY) <= tolerance, abs(box.maxY - frame.maxY) <= tolerance {
            return Set(covered)
        }
        return [best]
    }

    // MARK: Relative position

    enum SearchKind { case move, expand }

    /// The rect in `rects` nearest to `ref` in `direction`, or nil if there is none.
    /// - `.move`: candidates whose center lies strictly in that direction from `ref`'s center (works for
    ///   overlapping layouts); candidates sharing a perpendicular range with `ref` win over those that
    ///   don't, then the lowest `along + 2 * perpendicular` center distance.
    /// - `.expand`: candidates that extend past `ref`'s edge in that direction and overlap it
    ///   perpendicularly (no diagonal grabs); the one whose near edge is closest wins.
    /// Indices in `excluding` are skipped. Ties go to the lowest index.
    static func nearest(from ref: CGRect, direction: NavDirection, in rects: [CGRect],
                        excluding: Set<Int> = [], kind: SearchKind = .move) -> Int? {
        var best: (key: [CGFloat], index: Int)?
        for (i, c) in rects.enumerated() where !excluding.contains(i) {
            let along: CGFloat, perp: CGFloat, perpOverlap: Bool
            switch direction {
            case .left: along = ref.midX - c.midX
            case .right: along = c.midX - ref.midX
            case .up: along = c.midY - ref.midY
            case .down: along = ref.midY - c.midY
            }
            if direction.isHorizontal {
                perp = abs(c.midY - ref.midY)
                perpOverlap = min(c.maxY, ref.maxY) - max(c.minY, ref.minY) > epsilon
            } else {
                perp = abs(c.midX - ref.midX)
                perpOverlap = min(c.maxX, ref.maxX) - max(c.minX, ref.minX) > epsilon
            }
            let key: [CGFloat]
            switch kind {
            case .move:
                guard along > epsilon else { continue }
                key = [perpOverlap ? 0 : 1, along + 2 * perp]
            case .expand:
                let past: CGFloat
                switch direction {
                case .left: past = ref.minX - c.minX
                case .right: past = c.maxX - ref.maxX
                case .up: past = c.maxY - ref.maxY
                case .down: past = ref.minY - c.minY
                }
                guard perpOverlap, past > epsilon else { continue }
                key = [nearEdgeDistance(ref, c, direction), perp]
            }
            if best == nil || key.lexicographicallyPrecedes(best!.key) { best = (key, i) }
        }
        return best?.index
    }

    /// Distance from `ref`'s edge facing `direction` to the candidate's near edge (overlap clamped to 0).
    private static func nearEdgeDistance(_ ref: CGRect, _ c: CGRect, _ d: NavDirection) -> CGFloat {
        switch d {
        case .left: return max(0, ref.minX - c.maxX)
        case .right: return max(0, c.minX - ref.maxX)
        case .up: return max(0, c.minY - ref.maxY)
        case .down: return max(0, ref.minY - c.maxY)
        }
    }

    /// The zone to enter when arriving on a new screen while moving `direction`: the zone nearest the edge
    /// being entered (opposite side of travel), and among those the one closest to `ref` perpendicularly.
    static func entryZone(direction: NavDirection, ref: CGRect, in zones: [CGRect]) -> ZoneIndex? {
        guard !zones.isEmpty else { return nil }
        func edge(_ z: CGRect) -> CGFloat {
            switch direction {
            case .right: return z.minX
            case .left: return -z.maxX
            case .up: return z.minY
            case .down: return -z.maxY
            }
        }
        func perp(_ z: CGRect) -> CGFloat {
            direction.isHorizontal ? abs(z.midY - ref.midY) : abs(z.midX - ref.midX)
        }
        let bestEdge = zones.map(edge).min()!
        return zones.indices.filter { edge(zones[$0]) <= bestEdge + epsilon }
            .min { perp(zones[$0]) < perp(zones[$1]) }
    }

    /// Relative-position expand: `span` plus the adjacent zone in `direction`, or nil when there is none.
    /// The resulting rect is `ZoneLayout.boundingRect(of:in:)` of the returned set.
    static func expand(span: Set<ZoneIndex>, direction: NavDirection, in zones: [CGRect]) -> Set<ZoneIndex>? {
        guard let box = ZoneLayout.boundingRect(of: span, in: zones),
              let t = nearest(from: box, direction: direction, in: zones, excluding: span, kind: .expand)
        else { return nil }
        return span.union([t])
    }

    // MARK: Moving

    /// The first zone to use on the nearest screen (in `direction`, other than `currentScreen`) that has zones.
    static func crossScreenTarget(window: CGRect, screens: [NavScreen], currentScreen: Int,
                                  mode: KeyboardNavMode, direction: NavDirection) -> NavTarget? {
        let frames = screens.map(\.frame)
        var excluded: Set<Int> = [currentScreen]
        while let n = nearest(from: window, direction: direction, in: frames, excluding: excluded) {
            excluded.insert(n)
            let z = screens[n].zones
            guard !z.isEmpty else { continue }
            if mode == .zoneIndex { return .zone(screen: n, zone: direction == .left ? z.count - 1 : 0) }
            if let entry = entryZone(direction: direction, ref: window, in: z) { return .zone(screen: n, zone: entry) }
        }
        return nil
    }

    /// Where a move hotkey sends a window currently at `window` (AppKit space) on `screens[currentScreen]`.
    /// Zone-index mode only handles left/right (nil otherwise). Without `crossScreens`, zone-index mode wraps
    /// around the current screen's zones and relative mode stops at the edge. With it, both continue onto the
    /// adjacent screen in that direction (nil if there is none). `locate` finds the window's current zones.
    static func moveTarget(window: CGRect, screens: [NavScreen], currentScreen: Int, mode: KeyboardNavMode,
                           direction: NavDirection, crossScreens: Bool,
                           locate: (CGRect, [CGRect]) -> Set<ZoneIndex> = { zoneSpan(of: $0, in: $1) }) -> NavTarget? {
        guard screens.indices.contains(currentScreen), mode != .direct else { return nil }
        let zones = screens[currentScreen].zones
        let span = locate(window, zones)
        let cross = {
            crossScreens ? crossScreenTarget(window: window, screens: screens, currentScreen: currentScreen,
                                             mode: mode, direction: direction) : nil
        }
        guard !span.isEmpty, let box = ZoneLayout.boundingRect(of: span, in: zones) else { return cross() }

        switch mode {
        case .direct:
            return nil
        case .zoneIndex:
            guard direction.isHorizontal else { return nil }
            let step = direction == .left ? -1 : 1
            let next = (direction == .left ? span.min()! : span.max()!) + step
            if zones.indices.contains(next) { return .zone(screen: currentScreen, zone: next) }
            if crossScreens { return cross() }
            let wrapped = direction == .left ? zones.count - 1 : 0
            return span == [wrapped] ? nil : .zone(screen: currentScreen, zone: wrapped)
        case .relative:
            if let t = nearest(from: box, direction: direction, in: zones, excluding: span) {
                return .zone(screen: currentScreen, zone: t)
            }
            return cross()
        }
    }
}

// MARK: - Hotkey bindings

enum KeyboardNavAction: Equatable {
    case snap(SnapSlot)
    case move(NavDirection)
    case expand(NavDirection)
}

struct KeyBinding: Equatable {
    var action: KeyboardNavAction
    var keyCode: Int
    var modifiers: Int
}

/// Carbon modifier flags, as stored in Prefs.
enum HotKeyModifiers {
    static let all = controlKey | optionKey | shiftKey | cmdKey
    /// Masks to the four supported flags; falls back when none is left (a bare arrow key must never be global).
    static func sanitized(_ raw: Int, fallback: Int) -> Int {
        let m = raw & all
        return m == 0 ? fallback : m
    }
    static func symbols(_ m: Int) -> String {
        (m & controlKey != 0 ? "⌃" : "") + (m & optionKey != 0 ? "⌥" : "")
            + (m & shiftKey != 0 ? "⇧" : "") + (m & cmdKey != 0 ? "⌘" : "")
    }
}

struct KeyboardNavConfig: Equatable {
    var mode: KeyboardNavMode
    var directModifiers: Int
    var moveModifiers: Int
    var expandModifiers: Int

    static let defaultDirect = controlKey | optionKey
    static let defaultMove = controlKey | optionKey
    static let defaultExpand = controlKey | optionKey | shiftKey

    static let arrows: [(NavDirection, Int)] = [(.left, kVK_LeftArrow), (.right, kVK_RightArrow),
                                                (.up, kVK_UpArrow), (.down, kVK_DownArrow)]

    /// Hotkeys to register for this config. A (key, modifiers) pair already taken by an earlier binding is dropped.
    var bindings: [KeyBinding] {
        var out: [KeyBinding] = []
        switch mode {
        case .direct:
            out = [KeyBinding(action: .snap(.first), keyCode: kVK_LeftArrow, modifiers: directModifiers),
                   KeyBinding(action: .snap(.middle), keyCode: kVK_UpArrow, modifiers: directModifiers),
                   KeyBinding(action: .snap(.last), keyCode: kVK_RightArrow, modifiers: directModifiers)]
        case .zoneIndex:
            out = Self.arrows.filter { $0.0.isHorizontal }
                .map { KeyBinding(action: .move($0.0), keyCode: $0.1, modifiers: moveModifiers) }
        case .relative:
            out = Self.arrows.map { KeyBinding(action: .move($0.0), keyCode: $0.1, modifiers: moveModifiers) }
                + Self.arrows.map { KeyBinding(action: .expand($0.0), keyCode: $0.1, modifiers: expandModifiers) }
        }
        var seen = Set<[Int]>()
        return out.filter { seen.insert([$0.keyCode, $0.modifiers]).inserted }
    }

    /// True when move and expand share modifiers in relative mode (the expand hotkeys would not register).
    var hasConflict: Bool { mode == .relative && moveModifiers == expandModifiers }
}
