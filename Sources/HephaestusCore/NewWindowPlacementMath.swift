import CoreGraphics
import Foundation

/// Pure decision/geometry logic for new-window placement (#15). All rects are AppKit space.
/// No AppKit or AX calls here so everything is unit-testable.
enum NewWindowPlacementMath {
    /// What the placer knows about one connected screen.
    struct ScreenGeometry: Equatable {
        var uuid: String
        var visibleFrame: CGRect
        /// Zones of the layout currently in effect on this screen, by `ZoneIndex`.
        var zones: [CGRect]
    }

    struct Context {
        var lastZoneSetting: Bool
        var activeScreenSetting: Bool
        /// `NewWindowPlacement.isPlaceable` (standard window, not sheet/dialog/minimized/fullscreen).
        var placeable: Bool
        var appHidden: Bool
        /// Already snapped by the user or the tracker.
        var alreadyTracked: Bool
        /// The window was created already sitting in a zone (the app or the user put it there).
        var createdInZone: Bool
        /// After the settle delay the window is still at/near its creation frame (nobody moved it).
        var stillAtCreationFrame: Bool
        var hasLastZone: Bool
    }

    enum Decision: Equatable { case skip, lastZone, activeScreen }

    static func decide(_ c: Context) -> Decision {
        guard c.placeable, !c.appHidden, !c.alreadyTracked, !c.createdInZone, c.stillAtCreationFrame else { return .skip }
        if c.lastZoneSetting, c.hasLastZone { return .lastZone }
        return c.activeScreenSetting ? .activeScreen : .skip
    }

    /// AX attributes of a candidate window (nil = attribute missing).
    struct WindowTraits {
        var role: String?
        var subrole: String?
        var minimized = false
        var fullscreen = false
        var modal = false
    }

    /// Only ordinary document-style windows: no sheets, dialogs, popups, floating panels, minimized or fullscreen windows.
    static func isPlaceable(_ t: WindowTraits) -> Bool {
        t.role == "AXWindow" && t.subrole == "AXStandardWindow" && !t.minimized && !t.fullscreen && !t.modal
    }

    /// True when `frame` matches one of `zones` (i.e. the window is "already snapped").
    static func isInsideZone(_ frame: CGRect, zones: [CGRect]) -> Bool {
        zones.contains { WindowStateMath.frameMatches(frame, $0) }
    }

    struct ZoneTarget: Equatable {
        var screenUUID: String
        var zones: [ZoneIndex]
        var rect: CGRect
    }

    /// Resolve a remembered assignment to current geometry: the remembered screen if still connected, else
    /// `activeUUID`, else the first screen. Zone indices are clamped to that screen's current layout.
    static func resolveZoneTarget(last: LastAssignment, screens: [ScreenGeometry], activeUUID: String?) -> ZoneTarget? {
        guard let uuid = WindowStateMath.resolveScreen(home: last.screenUUID, available: screens.map(\.uuid), fallback: activeUUID),
              let screen = screens.first(where: { $0.uuid == uuid }),
              let rect = WindowStateMath.reapplyTarget(zones: last.zones, in: screen.zones) else { return nil }
        return ZoneTarget(screenUUID: uuid, zones: WindowStateMath.clampZones(last.zones, count: screen.zones.count), rect: rect)
    }

    /// Move `frame` inside `bounds`, shrinking it only if it is larger than `bounds`.
    static func clamp(_ frame: CGRect, into bounds: CGRect) -> CGRect {
        let w = min(frame.width, bounds.width), h = min(frame.height, bounds.height)
        let x = min(max(frame.minX, bounds.minX), bounds.maxX - w)
        let y = min(max(frame.minY, bounds.minY), bounds.maxY - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// New frame for a window moved to the active screen, keeping its size. If its old screen's visible frame
    /// is known the offset inside that screen is kept (then clamped); else it is centered.
    /// Returns nil when no move is needed (already inside `target`).
    static func activeScreenFrame(window: CGRect, from source: CGRect?, to target: CGRect) -> CGRect? {
        if target.contains(window) { return nil }
        var f = window
        if let source, source != target {
            f.origin = CGPoint(x: target.minX + (window.minX - source.minX), y: target.minY + (window.minY - source.minY))
        } else {
            f.origin = CGPoint(x: target.midX - window.width / 2, y: target.midY - window.height / 2)
        }
        let out = clamp(f, into: target)
        return out == window ? nil : out
    }

    /// Screen containing the cursor, else `fallback`, else the first screen.
    static func activeScreenUUID(cursor: CGPoint, frames: [(uuid: String, frame: CGRect)], fallback: String?) -> String? {
        frames.first { $0.frame.contains(cursor) }?.uuid ?? fallback ?? frames.first?.uuid
    }
}
