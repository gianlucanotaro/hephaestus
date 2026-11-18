import AppKit

/// User-configurable layout, persisted in UserDefaults.
enum Prefs {
    static let aspectWKey = "aspectW"
    static let aspectHKey = "aspectH"
    static let gapKey = "gap"
    static let dragActivationKey = "dragActivation"
    static let multiZoneModifierKey = "multiZoneModifier"
    static let showAllScreensKey = "dragShowAllScreens"
    static let useSystemColorsKey = "overlayUseSystemColors"
    static let highlightColorKey = "overlayHighlightColor"
    static let inactiveColorKey = "overlayInactiveColor"
    static let borderColorKey = "overlayBorderColor"
    static let numberColorKey = "overlayNumberColor"
    static let opacityKey = "overlayOpacity"
    static let showNumbersKey = "overlayShowNumbers"

    static func register() {
        registerLayoutDefaults()
        registerEligibilityDefaults()
        UserDefaults.standard.register(defaults: [
            aspectWKey: 16.0, aspectHKey: 9.0, gapKey: 8.0, dragActivationKey: DragActivation.shift.rawValue,
            multiZoneModifierKey: MultiZoneModifier.control.rawValue, showAllScreensKey: false, useSystemColorsKey: true,
            highlightColorKey: "#0A84FF", inactiveColorKey: "#8E8E93", borderColorKey: "#0A84FF", numberColorKey: "#FFFFFF",
            opacityKey: 0.5, showNumbersKey: true,
        ])
    }

    static var multiZoneModifier: MultiZoneModifier {
        MultiZoneModifier(rawValue: UserDefaults.standard.string(forKey: multiZoneModifierKey) ?? "") ?? .control
    }
    static var showZonesOnAllScreens: Bool { UserDefaults.standard.bool(forKey: showAllScreensKey) }

    static var aspect: CGFloat {
        let w = UserDefaults.standard.double(forKey: aspectWKey)
        let h = UserDefaults.standard.double(forKey: aspectHKey)
        return h > 0 && w > 0 ? CGFloat(w / h) : 16.0 / 9.0
    }
    static var dragActivation: DragActivation {
        DragActivation(rawValue: UserDefaults.standard.string(forKey: dragActivationKey) ?? "") ?? .shift
    }
    static var gap: CGFloat { CGFloat(UserDefaults.standard.double(forKey: gapKey)) }
}

extension NSScreen {
    var displayID: UInt32 {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

enum ZoneLayout {
    /// Pure geometry for the "Ultrawide 3-way" rule: a centered rect with the given aspect ratio at full
    /// height, and the leftover width split evenly into left/right. Same coordinate space as `frame`.
    /// Screens too narrow for that (sides under 10% of the width, e.g. a 16:10 laptop panel)
    /// fall back to a proportional 25/50/25 split so every screen still gets three zones.
    static func ultrawideZones(in frame: CGRect, centerAspect: CGFloat, gap: CGFloat) -> [CGRect] {
        var centerW = frame.height * centerAspect
        if (frame.width - centerW) / 2 < frame.width * 0.10 { centerW = frame.width * 0.5 }
        let sideW = (frame.width - centerW) / 2
        let inset = gap / 2
        func r(_ x: CGFloat, _ w: CGFloat) -> CGRect {
            CGRect(x: x, y: frame.minY, width: w, height: frame.height).insetBy(dx: inset, dy: inset)
        }
        return [r(frame.minX, sideW), r(frame.minX + sideW, centerW), r(frame.minX + sideW + centerW, sideW)]
    }

    /// Pure geometry: the zones of `layout` inside `frame` (AppKit space), indexed by `ZoneIndex`.
    /// Each zone is inset by `gap / 2` on every side. `centerAspect` only matters for rule-based layouts.
    static func zones(layout: Layout, in frame: CGRect, centerAspect: CGFloat = 16.0 / 9.0, gap: CGFloat) -> [CGRect] {
        switch layout.rule {
        case .ultrawideThreeWay?:
            return ultrawideZones(in: frame, centerAspect: centerAspect, gap: gap)
        case nil:
            return layout.zones.map { $0.resolve(in: frame).insetBy(dx: gap / 2, dy: gap / 2) }
        }
    }

    /// How close (in points) the cursor must be to the shared edge of two adjacent zones to select both.
    static let edgeThreshold: CGFloat = 24

    /// Pure hit-test: the zone under `point` (the gap counts as part of the nearest zone), plus every
    /// zone adjacent to it whose facing edge is within `edgeThreshold` of the point. Empty if outside all zones.
    static func selection(at point: CGPoint, in zones: [CGRect], gap: CGFloat,
                          edgeThreshold: CGFloat = ZoneLayout.edgeThreshold,
                          overlap: OverlapResolution = .smallest) -> Set<ZoneIndex> {
        guard let primary = ZoneResolution.primaryZone(at: point, in: zones, gap: gap, policy: overlap) else { return [] }
        let pr = zones[primary]
        var result: Set<ZoneIndex> = [primary]
        let tolerance = gap + 1
        for (zone, r) in zones.enumerated() where zone != primary {
            let xOverlap = min(pr.maxX, r.maxX) - max(pr.minX, r.minX)
            let yOverlap = min(pr.maxY, r.maxY) - max(pr.minY, r.minY)
            let hGap = max(r.minX - pr.maxX, pr.minX - r.maxX)   // > 0 when separated horizontally
            let vGap = max(r.minY - pr.maxY, pr.minY - r.maxY)
            if yOverlap > 0, hGap >= 0, hGap <= tolerance {
                let edge = r.minX >= pr.maxX ? (pr.maxX + r.minX) / 2 : (r.maxX + pr.minX) / 2
                if abs(point.x - edge) <= edgeThreshold { result.insert(zone) }
            } else if xOverlap > 0, vGap >= 0, vGap <= tolerance {
                let edge = r.minY >= pr.maxY ? (pr.maxY + r.minY) / 2 : (r.maxY + pr.minY) / 2
                if abs(point.y - edge) <= edgeThreshold { result.insert(zone) }
            }
        }
        return result
    }

    /// Bounding rectangle of the given zones.
    static func boundingRect(of selected: Set<ZoneIndex>, in zones: [CGRect]) -> CGRect? {
        let rects = selected.sorted().compactMap { zones.indices.contains($0) ? zones[$0] : nil }
        guard let first = rects.first else { return nil }
        return rects.reduce(first) { $0.union($1) }
    }

    /// The layout in effect for `screen`. Single entry point for "which layout applies here";
    /// today every screen uses the globally active layout (per-monitor assignment plugs in here).
    static func layout(for screen: NSScreen) -> Layout {
        LayoutStore.shared.active
    }

    /// Zones for one screen, in AppKit coordinates (origin bottom-left of primary screen), by `ZoneIndex`.
    static func zones(for screen: NSScreen) -> [CGRect] {
        zones(layout: layout(for: screen), in: screen.visibleFrame, centerAspect: Prefs.aspect, gap: Prefs.gap)
    }

    /// Every connected screen with its zones.
    static func allZones() -> [(screen: NSScreen, zones: [CGRect])] {
        NSScreen.screens.map { ($0, zones(for: $0)) }
    }

    /// The screen containing most of an AppKit-space rect, else the main screen.
    static func screen(containing rect: CGRect) -> NSScreen? {
        NSScreen.screens.max { area($0.frame.intersection(rect)) < area($1.frame.intersection(rect)) }
            .flatMap { area($0.frame.intersection(rect)) > 0 ? $0 : nil } ?? NSScreen.main
    }

    private static func area(_ r: CGRect) -> CGFloat { r.isNull ? 0 : r.width * r.height }

    /// Convert between AppKit coordinates (origin bottom-left of primary screen) and
    /// Accessibility/Quartz coordinates (origin top-left of primary screen). The flip is its own inverse.
    static func toAX(_ rect: CGRect) -> CGRect {
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: rect.minX, y: primaryH - rect.maxY, width: rect.width, height: rect.height)
    }
    static func fromAX(_ rect: CGRect) -> CGRect { toAX(rect) }
}
