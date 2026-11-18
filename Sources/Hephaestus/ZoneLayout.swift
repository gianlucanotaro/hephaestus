import AppKit

enum Zone: String, CaseIterable {
    case left, center, right

    var title: String { rawValue.capitalized }
}

/// User-configurable layout, persisted in UserDefaults.
enum Prefs {
    static let displayIDKey = "displayID"      // 0 = auto (widest aspect ratio)
    static let aspectWKey = "aspectW"
    static let aspectHKey = "aspectH"
    static let gapKey = "gap"

    static func register() {
        UserDefaults.standard.register(defaults: [
            displayIDKey: 0, aspectWKey: 16.0, aspectHKey: 9.0, gapKey: 8.0,
        ])
    }

    static var displayID: UInt32 { UInt32(UserDefaults.standard.integer(forKey: displayIDKey)) }
    static var aspect: CGFloat {
        let w = UserDefaults.standard.double(forKey: aspectWKey)
        let h = UserDefaults.standard.double(forKey: aspectHKey)
        return h > 0 && w > 0 ? CGFloat(w / h) : 16.0 / 9.0
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
    static func zones(in frame: CGRect, centerAspect: CGFloat, gap: CGFloat) -> [Zone: CGRect] {
        let centerW = min(frame.height * centerAspect, frame.width)
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

    /// The screen to carve up: the chosen display, else the one with the widest aspect ratio.
    static func targetScreen() -> NSScreen? {
        let id = Prefs.displayID
        if id != 0, let s = NSScreen.screens.first(where: { $0.displayID == id }) { return s }
        return NSScreen.screens.max { $0.frame.width / $0.frame.height < $1.frame.width / $1.frame.height }
    }

    /// Zones in AppKit coordinates (origin bottom-left of primary screen), for overlays.
    static func currentZones() -> (screen: NSScreen, zones: [Zone: CGRect])? {
        guard let screen = targetScreen() else { return nil }
        return (screen, zones(in: screen.visibleFrame, centerAspect: Prefs.aspect, gap: Prefs.gap))
    }

    /// Convert an AppKit rect to Accessibility/Quartz coordinates (origin top-left of primary screen).
    static func toAX(_ rect: CGRect) -> CGRect {
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: rect.minX, y: primaryH - rect.maxY, width: rect.width, height: rect.height)
    }
}
