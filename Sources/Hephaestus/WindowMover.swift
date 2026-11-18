import AppKit
import ApplicationServices

enum WindowMover {
    static func ensureAccessibility(prompt: Bool) -> Bool {
        let opts = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    @discardableResult
    static func snapFrontWindow(to zone: Zone) -> Bool {
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

        guard let current = frame(of: window),
              let screen = ZoneLayout.screen(containing: ZoneLayout.fromAX(current)),
              let target = ZoneLayout.zones(for: screen)[zone]
        else { return false }

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
