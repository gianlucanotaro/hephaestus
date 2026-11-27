import AppKit
import ApplicationServices

/// Moves, resizes and looks up other apps' windows through the Accessibility API.
enum WindowMover {
    /// Verify-and-retry timing and tolerances for `move`, and how far `window(containing:)` climbs AXParent.
    private static let retryDelays: [TimeInterval] = [0.08, 0.25]
    private static let frameTolerance: CGFloat = 2
    private static let maxParentDepth = 20

    /// Whether this process is trusted for Accessibility; with `prompt` the system permission dialog may appear.
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
        guard let window = focusedWindow(prompt: true) else { return false }
        guard WindowEligibility.canSnap(window: window) else { NSSound.beep(); return false }

        guard let current = frame(of: window).map(ZoneLayout.fromAX),
              let hostScreen = ZoneLayout.screen(containing: current),
              case let screen = ZoneLayout.surfaceOwner(of: hostScreen),
              case let zones = ZoneLayout.zones(for: screen),
              case let index = pick(zones.count),
              zones.indices.contains(index)
        else { return false }
        let target = zones[index]

        snap(window, toAppKitRect: target, zones: [index], on: screen, from: current)
        return true
    }

    /// The focused window of the frontmost app, unless that app is this one. Nil without Accessibility access
    /// (`prompt` controls whether the system permission dialog may appear) or when there is no focused window.
    static func focusedWindow(prompt: Bool) -> AXUIElement? {
        guard ensureAccessibility(prompt: prompt),
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return nil }
        return AX.element(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedWindowAttribute)
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
        let app = AXUIElementCreateApplication(AX.pid(of: window))
        let wasEnhanced = (AX.value(app, AX.enhancedUserInterface) as? Bool) == true
        if wasEnhanced { AXUIElementSetAttributeValue(app, AX.enhancedUserInterface as CFString, kCFBooleanFalse) }
        defer { if wasEnhanced { AXUIElementSetAttributeValue(app, AX.enhancedUserInterface as CFString, kCFBooleanTrue) } }

        apply(window, rect)
        // Verify: slow apps (Electron) or a clamped size can leave the window off target. Retry the position
        // (the size may legitimately stay larger than the zone when the app has a minimum size).
        for delay in retryDelays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard let f = frame(of: window), !WindowStateMath.frameMatches(f, rect, tolerance: frameTolerance) else { return }
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
        if let f = frame(of: window), abs(f.minX - origin.x) > frameTolerance || abs(f.minY - origin.y) > frameTolerance {
            setPosition(window, &origin)
        }
    }

    /// The window element that is `element` or contains it.
    static func window(containing element: AXUIElement) -> AXUIElement? {
        if AX.isWindow(element) { return element }
        if let w = AX.element(element, kAXWindowAttribute) { return w }
        // Some apps (Electron, Java, custom-drawn UIs) don't expose AXWindow: walk up AXParent instead.
        var current = element
        for _ in 0..<maxParentDepth {
            guard let up = AX.element(current, kAXParentAttribute) else { return nil }
            if AX.isWindow(up) { return up }
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
            guard let windows = AX.windows(pid: pid) else { return nil }
            return windows.first { win in
                guard let f = frame(of: win) else { return false }
                return abs(f.minX - bounds.minX) < 3 && abs(f.minY - bounds.minY) < 3
                    && abs(f.width - bounds.width) < 3 && abs(f.height - bounds.height) < 3
            }
        }
        return nil
    }

    /// Window frame in AX (top-left origin) coordinates; nil when position or size cannot be read as proper AX values.
    static func frame(of w: AXUIElement) -> CGRect? {
        guard let p = AX.point(w, kAXPositionAttribute), let sz = AX.size(w, kAXSizeAttribute) else { return nil }
        return CGRect(origin: p, size: sz)
    }

    /// Set the window size via AX (no verification).
    static func setSize(_ w: AXUIElement, _ size: inout CGSize) {
        if let v = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, v) }
    }

    /// Set the window position (AX coordinates) via AX (no verification).
    static func setPosition(_ w: AXUIElement, _ point: inout CGPoint) {
        if let v = AXValueCreate(.cgPoint, &point) { AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, v) }
    }
}
