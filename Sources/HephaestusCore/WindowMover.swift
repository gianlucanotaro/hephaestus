import AppKit
import ApplicationServices

enum WindowMover {
    static func ensureAccessibility(prompt: Bool) -> Bool {
        let opts = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    /// Snap to the first / middle / last zone of the layout on the window's screen.
    @discardableResult
    static func snapFrontWindow(slot: SnapSlot) -> Bool {
        snapFrontWindow { slot.index(count: $0) }
    }

    @discardableResult
    static func snapFrontWindow(to zone: ZoneIndex) -> Bool {
        snapFrontWindow { _ in zone }
    }

    /// `pick` receives the zone count of the target screen's layout and returns the zone index to use.
    private static func snapFrontWindow(pick: (Int) -> ZoneIndex) -> Bool {
        guard ensureAccessibility(prompt: true),
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return false }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &ref) == .success,
              let win = ref
        else { return false }
        let window = win as! AXUIElement
        guard WindowEligibility.canSnap(window: window) else { NSSound.beep(); return false }

        guard let current = frame(of: window),
              let hostScreen = ZoneLayout.screen(containing: ZoneLayout.fromAX(current)),
              case let screen = ZoneLayout.surfaceOwner(of: hostScreen),
              case let zones = ZoneLayout.zones(for: screen),
              case let index = pick(zones.count),
              zones.indices.contains(index)
        else { return false }
        let target = zones[index]

        snap(window, toAppKitRect: target, zones: [index], on: screen, from: ZoneLayout.fromAX(current))
        return true
    }

    /// Move a window into zones AND record it with the `WindowTracker` (so unsnap-on-drag, re-apply, cycling and
    /// keyboard navigation know about it). Every "put a window into zones" path should use this.
    /// `currentFrame` is the window's AppKit-space frame BEFORE the move.
    static func snap(_ window: AXUIElement, toAppKitRect rect: CGRect, zones: Set<ZoneIndex>, on screen: NSScreen,
                     from currentFrame: CGRect) {
        move(window, toAppKitRect: rect)
        WindowTracker.shared.register(window: window, zones: zones, screen: screen, currentFrame: currentFrame, snappedFrame: rect)
    }

    /// Move/resize a window to an AppKit-space rect.
    static func move(_ window: AXUIElement, toAppKitRect target: CGRect) {
        let rect = ZoneLayout.toAX(target)
        // Apps with AXEnhancedUserInterface animate and drop AX moves; switch it off for the duration (as other
        // window managers do).
        var pid: pid_t = 0
        AXUIElementGetPid(window, &pid)
        let app = AXUIElementCreateApplication(pid)
        var enhanced: CFTypeRef?
        let wasEnhanced = AXUIElementCopyAttributeValue(app, "AXEnhancedUserInterface" as CFString, &enhanced) == .success
            && (enhanced as? Bool) == true
        if wasEnhanced { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse) }
        defer { if wasEnhanced { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) } }

        apply(window, rect)
        // Verify: slow apps (Electron) or a clamped size can leave the window off target. Retry the position
        // (the size may legitimately stay larger than the zone when the app has a minimum size).
        for delay in [0.08, 0.25] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard let f = frame(of: window), abs(f.minX - rect.minX) > 2 || abs(f.minY - rect.minY) > 2
                        || abs(f.width - rect.width) > 2 || abs(f.height - rect.height) > 2 else { return }
                apply(window, rect)
            }
        }
    }

    private static func apply(_ window: AXUIElement, _ rect: CGRect) {
        var origin = rect.origin
        var size = rect.size
        // Size, position, size again: some apps clamp size based on the screen the window is on.
        setSize(window, &size)
        setPosition(window, &origin)
        setSize(window, &size)
        // If the app clamped the size, the OS may have shifted the window to keep it on screen: reassert origin.
        if let f = frame(of: window), abs(f.minX - origin.x) > 2 || abs(f.minY - origin.y) > 2 {
            setPosition(window, &origin)
        }
    }

    /// The window element that is `element` or contains it.
    static func window(containing element: AXUIElement) -> AXUIElement? {
        var role: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
           (role as? String) == kAXWindowRole as String { return element }
        var win: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &win) == .success,
           let w = win, CFGetTypeID(w) == AXUIElementGetTypeID() { return (w as! AXUIElement) }
        // Some apps (Electron, Java, custom-drawn UIs) don't expose AXWindow: walk up AXParent instead.
        var current = element
        for _ in 0..<20 {
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parent) == .success,
                  let p = parent, CFGetTypeID(p) == AXUIElementGetTypeID() else { return nil }
            let up = p as! AXUIElement
            var r: CFTypeRef?
            if AXUIElementCopyAttributeValue(up, kAXRoleAttribute as CFString, &r) == .success,
               (r as? String) == kAXWindowRole as String { return up }
            current = up
        }
        return nil
    }

    /// Fallback when the AX hit-test fails: the topmost on-screen window under `axPoint` (AX coordinates),
    /// matched to the owning app's AX window with the same frame.
    static func window(atAXPoint axPoint: CGPoint) -> AXUIElement? {
        guard let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        for info in infos {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let b = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let w = b["Width"], let h = b["Height"]
            else { continue }
            let bounds = CGRect(x: x, y: y, width: w, height: h)
            guard bounds.contains(axPoint) else { continue }
            let app = AXUIElementCreateApplication(pid)
            var list: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &list) == .success,
                  let windows = list as? [AXUIElement] else { return nil }
            return windows.first { win in
                guard let f = frame(of: win) else { return false }
                return abs(f.minX - bounds.minX) < 3 && abs(f.minY - bounds.minY) < 3
                    && abs(f.width - bounds.width) < 3 && abs(f.height - bounds.height) < 3
            }
        }
        return nil
    }

    /// Window frame in AX (top-left origin) coordinates.
    static func frame(of w: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?, sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &sizeRef) == .success
        else { return nil }
        var p = CGPoint.zero, sz = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &p)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &sz)
        return CGRect(origin: p, size: sz)
    }

    private static func setSize(_ w: AXUIElement, _ size: inout CGSize) {
        if let v = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, v) }
    }

    private static func setPosition(_ w: AXUIElement, _ point: inout CGPoint) {
        if let v = AXValueCreate(.cgPoint, &point) { AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, v) }
    }
}
