import CoreGraphics
import Foundation

/// Pure helpers for window/zone bookkeeping. All rects are in ONE coordinate space chosen by the caller
/// (the tracker stores AppKit space). No AppKit or AX calls here so everything is unit-testable.
enum WindowStateMath {
    /// Two frames count as "the same" within `tolerance` points on every edge (apps round/clamp sizes).
    static func frameMatches(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 8) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    /// Frame for a window being pulled out of its zone: it gets `restoreSize`, and the cursor keeps the same
    /// relative position on the window as it had on the zone-sized window (position follows the drag).
    static func unsnapFrame(current: CGRect, cursor: CGPoint, restoreSize: CGSize) -> CGRect {
        let rx = current.width > 0 ? min(max((cursor.x - current.minX) / current.width, 0), 1) : 0.5
        let ry = current.height > 0 ? min(max((cursor.y - current.minY) / current.height, 0), 1) : 0.5
        return CGRect(x: cursor.x - rx * restoreSize.width, y: cursor.y - ry * restoreSize.height,
                      width: restoreSize.width, height: restoreSize.height)
    }

    /// Zone indices valid for a layout with `count` zones: out-of-range indices are clamped to the last zone,
    /// duplicates removed, result sorted. Empty when the layout has no zones.
    static func clampZones(_ zones: [ZoneIndex], count: Int) -> [ZoneIndex] {
        guard count > 0 else { return [] }
        return Set(zones.map { min(max($0, 0), count - 1) }).sorted()
    }

    /// Target rect (bounding rect of the clamped zones) for re-applying an assignment to new geometry.
    static func reapplyTarget(zones: [ZoneIndex], in zoneRects: [CGRect]) -> CGRect? {
        ZoneLayout.boundingRect(of: Set(clampZones(zones, count: zoneRects.count)), in: zoneRects)
    }

    /// Screen to use for a window whose home screen is `home`: the home screen if connected, else the fallback.
    static func resolveScreen(home: String, available: [String], fallback: String?) -> String? {
        if available.contains(home) { return home }
        if let fallback, available.contains(fallback) { return fallback }
        return available.first
    }

    /// Pre-snap frame to remember when (re)snapping a window: if it is still sitting in its previous snapped
    /// frame the original pre-snap frame is kept (zone-to-zone moves must not overwrite it); else `current`.
    static func preSnapFrame(existing: (preSnap: CGRect, snapped: CGRect)?, current: CGRect) -> CGRect {
        if let existing, frameMatches(existing.snapped, current) { return existing.preSnap }
        return current
    }

    struct Candidate: Equatable {
        var title: String
        var frame: CGRect
    }

    /// Best-effort match of a persisted assignment to a live window of the same app: the window must be
    /// sitting at the recorded snapped frame; an equal title wins over a different one. Returns the index.
    static func bestMatch(title: String, snapped: CGRect, candidates: [Candidate], excluding: Set<Int> = []) -> Int? {
        var best: (index: Int, score: Int)?
        for (i, c) in candidates.enumerated() where !excluding.contains(i) && frameMatches(c.frame, snapped) {
            let score = (!title.isEmpty && c.title == title) ? 2 : 1
            if best == nil || score > best!.score { best = (i, score) }
        }
        return best?.index
    }

    enum ReapplyAction: Equatable { case keep, apply, drop }

    /// What to do with a tracked window when geometry may have changed.
    /// - `displayTrigger`: screens changed (windows may have been shuffled by the system, so always apply).
    /// - `layoutTrigger`: layout changed or was edited; the window is left alone (dropped) if someone else
    ///   moved it since we placed it. With the setting off, windows whose layout changed are dropped
    ///   because their zone numbers no longer mean anything.
    static func reapplyAction(displayTrigger: Bool, displaySetting: Bool, layoutTrigger: Bool, layoutSetting: Bool,
                              layoutIDChanged: Bool, movedExternally: Bool) -> ReapplyAction {
        if displayTrigger { return displaySetting ? .apply : .keep }
        guard layoutTrigger else { return .keep }
        guard layoutSetting else { return layoutIDChanged ? .drop : .keep }
        return movedExternally ? .drop : .apply
    }
}

/// One persisted assignment (best-effort restore after relaunch; no AX identity survives a relaunch).
struct PersistedAssignment: Codable, Equatable {
    var bundleID: String
    var titleHint: String
    var zones: [ZoneIndex]
    var layoutID: String
    var screenUUID: String
    var preSnapFrame: CGRect
    var snappedFrame: CGRect
}

/// Last zone an app was snapped to; survives the window closing (used to place new windows).
struct LastAssignment: Codable, Equatable {
    var zones: [ZoneIndex]
    var layoutID: String
    var screenUUID: String
}

struct WindowStateFile: Codable, Equatable {
    var version = 1
    var assignments: [PersistedAssignment] = []
    var lastByBundle: [String: LastAssignment] = [:]
}

enum WindowStateCodec {
    static func encode(_ file: WindowStateFile) -> Data? {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return try? e.encode(file)
    }

    /// Nil for corrupt data or an unknown (newer) version.
    static func decode(_ data: Data) -> WindowStateFile? {
        guard let f = try? JSONDecoder().decode(WindowStateFile.self, from: data), f.version == 1 else { return nil }
        return f
    }
}
