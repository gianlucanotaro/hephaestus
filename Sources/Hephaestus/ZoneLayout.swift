import AppKit

enum Zone: String, CaseIterable {
    case left, center, right

    var title: String { rawValue.capitalized }
}

/// User-configurable layout, persisted in UserDefaults.
enum Prefs {
    static let aspectWKey = "aspectW"
    static let aspectHKey = "aspectH"
    static let gapKey = "gap"
    static let dragActivationKey = "dragActivation"

    static func register() {
        UserDefaults.standard.register(defaults: [
            aspectWKey: 16.0, aspectHKey: 9.0, gapKey: 8.0, dragActivationKey: DragActivation.shift.rawValue,
        ])
    }

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
    /// Pure geometry: a centered rect with the given aspect ratio at full height,
    /// and the leftover width split evenly into left/right. Same coordinate space as `frame`.
    /// Screens too narrow for that (sides under 10% of the width, e.g. a 16:10 laptop panel)
    /// fall back to a proportional 25/50/25 split so every screen still gets three zones.
    static func zones(in frame: CGRect, centerAspect: CGFloat, gap: CGFloat) -> [Zone: CGRect] {
        var centerW = frame.height * centerAspect
        if (frame.width - centerW) / 2 < frame.width * 0.10 { centerW = frame.width * 0.5 }
        let sideW = (frame.width - centerW) / 2
        let inset = gap / 2
        func r(_ x: CGFloat, _ w: CGFloat) -> CGRect {
            CGRect(x: x, y: frame.minY, width: w, height: frame.height).insetBy(dx: inset, dy: inset)
        }
        return [
            .left: r(frame.minX, sideW),
            .center: r(frame.minX + sideW, centerW),
            .right: r(frame.minX + sideW + centerW, sideW),
        ]
    }

    /// Zones for one screen, in AppKit coordinates (origin bottom-left of primary screen).
    static func zones(for screen: NSScreen) -> [Zone: CGRect] {
        zones(in: screen.visibleFrame, centerAspect: Prefs.aspect, gap: Prefs.gap)
    }

    /// Every connected screen with its zones.
    static func allZones() -> [(screen: NSScreen, zones: [Zone: CGRect])] {
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
