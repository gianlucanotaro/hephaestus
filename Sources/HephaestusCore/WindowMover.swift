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
              let screen = ZoneLayout.screen(containing: ZoneLayout.fromAX(current)),
              case let zones = ZoneLayout.zones(for: screen),
              case let index = pick(zones.count),
              zones.indices.contains(index)
        else { return false }
        let target = zones[index]

        move(window, toAppKitRect: target)
        return true
    }

    /// Move/resize a window to an AppKit-space rect.
    static func move(_ window: AXUIElement, toAppKitRect target: CGRect) {
        let rect = ZoneLayout.toAX(target)
        var origin = rect.origin
        var size = rect.size
        // Size, position, size again: some apps clamp size based on the screen the window is on.
        setSize(window, &size)
        setPosition(window, &origin)
        setSize(window, &size)
    }

    /// The window element that is `element` or contains it.
    static func window(containing element: AXUIElement) -> AXUIElement? {
        var role: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
           (role as? String) == kAXWindowRole as String { return element }
        var win: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &win) == .success,
              let w = win else { return nil }
        return (w as! AXUIElement)
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
