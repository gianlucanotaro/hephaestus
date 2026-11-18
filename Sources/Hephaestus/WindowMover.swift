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
              let (_, zones) = ZoneLayout.currentZones(),
              let target = zones[zone],
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return false }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &ref) == .success,
              let win = ref
        else { return false }
        let window = win as! AXUIElement

        let rect = ZoneLayout.toAX(target)
        var origin = rect.origin
        var size = rect.size
        // Size, position, size again: some apps clamp size based on the screen the window is on.
        setSize(window, &size)
        setPosition(window, &origin)
        setSize(window, &size)
        return true
    }

    private static func setSize(_ w: AXUIElement, _ size: inout CGSize) {
        if let v = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, v) }
    }

    private static func setPosition(_ w: AXUIElement, _ point: inout CGPoint) {
        if let v = AXValueCreate(.cgPoint, &point) { AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, v) }
    }
}
