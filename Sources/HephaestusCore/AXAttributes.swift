import ApplicationServices

/// Typed, failure-tolerant readers for Accessibility attributes. All downcasts from `CFTypeRef` to
/// `AXUIElement`/`AXValue` live here, behind `CFGetTypeID` checks, so callers never force-cast.
enum AX {
    /// Attribute names that have no `kAX…` constant in the public headers.
    static let enhancedUserInterface = "AXEnhancedUserInterface"
    static let fullScreen = "AXFullScreen"

    /// The raw attribute value, or nil when the attribute is missing or the call fails.
    static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        return ref
    }

    /// `ref` as an `AXUIElement`, or nil when it is nil or of another CF type.
    static func element(_ ref: CFTypeRef?) -> AXUIElement? {
        guard let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return (ref as! AXUIElement)  // safe: type id checked above
    }

    /// An attribute whose value is another element (e.g. `kAXFocusedWindowAttribute`, `kAXParentAttribute`).
    static func element(_ owner: AXUIElement, _ attribute: String) -> AXUIElement? {
        element(value(owner, attribute))
    }

    /// A string attribute, or nil when missing or not a string.
    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        value(element, attribute) as? String
    }

    /// A boolean attribute; false when missing or not a boolean.
    static func bool(_ element: AXUIElement, _ attribute: String) -> Bool {
        (value(element, attribute) as? Bool) ?? false
    }

    /// The window title, or "" when unavailable.
    static func title(of element: AXUIElement) -> String {
        string(element, kAXTitleAttribute) ?? ""
    }

    /// True when the element's role is `AXWindow`.
    static func isWindow(_ element: AXUIElement) -> Bool {
        string(element, kAXRoleAttribute) == (kAXWindowRole as String)
    }

    /// The AX windows of the application with process id `pid`, or nil when AX cannot list them.
    static func windows(pid: pid_t) -> [AXUIElement]? {
        value(AXUIElementCreateApplication(pid), kAXWindowsAttribute) as? [AXUIElement]
    }

    /// The owning process id of an element (0 when AX cannot tell).
    static func pid(of element: AXUIElement) -> pid_t {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        return pid
    }

    /// A `CGPoint` attribute value, or nil when missing or not an `AXValue` holding a point.
    static func point(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        guard let ref = value(element, attribute), CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(ref as! AXValue, .cgPoint, &p) ? p : nil  // safe: type id checked above
    }

    /// A `CGSize` attribute value, or nil when missing or not an `AXValue` holding a size.
    static func size(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        guard let ref = value(element, attribute), CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(ref as! AXValue, .cgSize, &s) ? s : nil  // safe: type id checked above
    }
}
