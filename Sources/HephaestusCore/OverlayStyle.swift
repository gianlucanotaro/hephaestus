import AppKit

/// Appearance of the zone overlay shown while dragging, read from `Prefs`.
struct OverlayStyle {
    var highlight: NSColor
    var inactive: NSColor
    var border: NSColor
    var number: NSColor
    /// Fill opacity of the highlighted zone (0...1); inactive zones are drawn dimmer.
    var opacity: CGFloat
    var showNumbers: Bool

    /// Dynamic system colors resolve against the drawing view's appearance, so they follow light/dark mode.
    static var current: OverlayStyle {
        let d = UserDefaults.standard
        let opacity = CGFloat(min(max(d.double(forKey: Prefs.opacityKey), 0.05), 1))
        let numbers = d.bool(forKey: Prefs.showNumbersKey)
        if d.bool(forKey: Prefs.useSystemColorsKey) {
            return OverlayStyle(highlight: .controlAccentColor, inactive: .systemGray, border: .secondaryLabelColor,
                                number: .labelColor, opacity: opacity, showNumbers: numbers)
        }
        func color(_ key: String, _ fallback: NSColor) -> NSColor { NSColor(hex: d.string(forKey: key) ?? "") ?? fallback }
        return OverlayStyle(highlight: color(Prefs.highlightColorKey, .systemBlue),
                            inactive: color(Prefs.inactiveColorKey, .systemGray),
                            border: color(Prefs.borderColorKey, .systemBlue),
                            number: color(Prefs.numberColorKey, .white),
                            opacity: opacity, showNumbers: numbers)
    }
}

extension NSColor {
    /// Parses `#RRGGBB`.
    convenience init?(hex: String) {
        var h = hex.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? .black
        return String(format: "#%02X%02X%02X", Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)),
                      Int(round(c.blueComponent * 255)))
    }
}
