import AppKit

/// What the tray shows for one window of a stack.
struct StackCardInfo {
    var appName: String
    var title: String
    var icon: NSImage?
    var tint: NSColor
    var isFront: Bool
}

/// Borderless panel that never takes focus: used for the badge and the tray (#46).
final class StackPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        appearance = NSAppearance(named: .darkAqua)   // dark in every system appearance, like the mock
    }
}

enum StackPalette {
    static let ember = [NSColor(hex: 0xffd166), NSColor(hex: 0xff8a3d), NSColor(hex: 0xe5483a)]
    static let accent = NSColor(hex: 0xff8a3d)
    static let trayFill = NSColor(hex: 0x1d1f27)

    /// Average colour of an app icon (opaque pixels only); a neutral blue-gray when unavailable.
    static func tint(of image: NSImage?) -> NSColor {
        let neutral = NSColor(white: 0.55, alpha: 1)
        guard let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return neutral }
        let n = 8
        var px = [UInt8](repeating: 0, count: n * n * 4)
        let drawn: Bool = px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
            return true
        }
        guard drawn else { return neutral }
        var r = 0.0, g = 0.0, b = 0.0, a = 0.0
        for i in 0..<(n * n) {
            r += Double(px[i * 4]); g += Double(px[i * 4 + 1]); b += Double(px[i * 4 + 2]); a += Double(px[i * 4 + 3])
        }
        guard a > 0 else { return neutral }
        return NSColor(red: r / a, green: g / a, blue: b / a, alpha: 1)
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                  blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }
}

/// Ember pill with the stacked-windows glyph and the stack size. Mouse events pass through to the window below.
final class StackBadgeView: NSView {
    var count = 2 { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds
        let pill = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
        NSGradient(colors: StackPalette.ember)?.draw(in: pill, angle: -90)
        NSColor.white.withAlphaComponent(0.35).setStroke()
        pill.lineWidth = 1
        pill.stroke()

        let glyph = NSImage(systemSymbolName: "square.on.square", accessibilityDescription: "Stacked windows")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        if let glyph {
            let g = glyph.size
            let tinted = NSImage(size: g, flipped: false) { rect in
                glyph.draw(in: rect)
                NSColor.white.set()
                rect.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: CGRect(x: 12, y: (r.height - g.height) / 2, width: g.width, height: g.height))
        }
        let text = "\(count)" as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .bold), .foregroundColor: NSColor.white]
        let s = text.size(withAttributes: attrs)
        text.draw(at: CGPoint(x: r.width - 12 - s.width, y: (r.height - s.height) / 2), withAttributes: attrs)
    }
}

/// The dark rounded tray with one card per window. Click a card to pick it.
final class StackTrayView: NSView {
    var header = ""
    var cards: [StackCardInfo] = []
    var columns = 1
    var onPick: ((Int) -> Void)?
    private var hoverIndex: Int?
    private let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency

    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var cardRects: [CGRect] {
        StackMath.cardRects(count: cards.count, columns: columns, tray: bounds)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    private func index(at event: NSEvent) -> Int? {
        let p = convert(event.locationInWindow, from: nil)
        return cardRects.firstIndex { $0.contains(p) }
    }

    override func mouseMoved(with event: NSEvent) {
        let i = index(at: event)
        if i != hoverIndex { hoverIndex = i; needsDisplay = true }
    }
    override func mouseExited(with event: NSEvent) {
        if hoverIndex != nil { hoverIndex = nil; needsDisplay = true }
    }
    override func mouseDown(with event: NSEvent) {
        if let i = index(at: event) { onPick?(i) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let outer = bounds.insetBy(dx: 0.5, dy: 0.5)
        let bg = NSBezierPath(roundedRect: outer, xRadius: 22, yRadius: 22)
        StackPalette.trayFill.withAlphaComponent(reduceTransparency ? 1 : 0.94).setFill()
        bg.fill()
        NSColor.white.withAlphaComponent(0.18).setStroke()
        bg.lineWidth = 1
        bg.stroke()

        let pad = StackMath.trayPadding
        let headerAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .kern: 1.2,
            .foregroundColor: NSColor.white.withAlphaComponent(0.72),
        ]
        (header as NSString).draw(at: CGPoint(x: pad, y: bounds.maxY - pad - 14), withAttributes: headerAttrs)
        let hint = "Esc to dismiss" as NSString
        let hintAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11),
                                                        .foregroundColor: NSColor.white.withAlphaComponent(0.45)]
        hint.draw(at: CGPoint(x: bounds.maxX - pad - hint.size(withAttributes: hintAttrs).width, y: bounds.maxY - pad - 14),
                  withAttributes: hintAttrs)

        for (i, r) in cardRects.enumerated() where i < cards.count { drawCard(cards[i], in: r, hovered: i == hoverIndex) }
    }

    private func drawCard(_ c: StackCardInfo, in r: CGRect, hovered: Bool) {
        let shape = NSBezierPath(roundedRect: r, xRadius: 14, yRadius: 14)
        if c.isFront {
            StackPalette.accent.withAlphaComponent(0.16).setFill()
        } else {
            NSColor.white.withAlphaComponent(hovered ? 0.13 : 0.07).setFill()
        }
        shape.fill()
        if c.isFront {
            StackPalette.accent.setStroke()
            shape.lineWidth = 2
            shape.stroke()
        }

        // Mini window glyph standing in for a thumbnail (no Screen Recording needed).
        let glyph = CGRect(x: r.minX + 12, y: r.maxY - 12 - 92, width: r.width - 24, height: 92)
        let body = NSBezierPath(roundedRect: glyph, xRadius: 6, yRadius: 6)
        c.tint.blended(withFraction: 0.78, of: NSColor(white: 0.14, alpha: 1))?.setFill()
        body.fill()
        NSGraphicsContext.saveGraphicsState()
        body.addClip()
        c.tint.withAlphaComponent(0.55).setFill()
        CGRect(x: glyph.minX, y: glyph.maxY - 14, width: glyph.width, height: 14).fill()
        NSGraphicsContext.restoreGraphicsState()
        c.tint.withAlphaComponent(0.85).setFill()
        NSBezierPath(roundedRect: CGRect(x: glyph.minX + 10, y: glyph.maxY - 34, width: glyph.width * 0.55, height: 5),
                     xRadius: 2.5, yRadius: 2.5).fill()
        c.tint.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: CGRect(x: glyph.minX + 10, y: glyph.maxY - 48, width: glyph.width * 0.8, height: 5),
                     xRadius: 2.5, yRadius: 2.5).fill()

        // App icon + name.
        let rowTop = r.maxY - 12 - 92 - 10
        c.icon?.draw(in: CGRect(x: r.minX + 12, y: rowTop - 18, width: 18, height: 18))
        let namePara = NSMutableParagraphStyle()
        namePara.lineBreakMode = .byTruncatingTail
        (c.appName as NSString).draw(
            in: CGRect(x: r.minX + 36, y: rowTop - 17, width: r.width - 48, height: 16),
            withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.white,
                             .paragraphStyle: namePara])

        // Window title, up to two lines.
        let titleRect = CGRect(x: r.minX + 12, y: rowTop - 18 - 8 - 30, width: r.width - 24, height: 30)
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byWordWrapping
        ((c.title.isEmpty ? "Untitled" : c.title) as NSString).draw(
            with: titleRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.white.withAlphaComponent(0.62),
                         .paragraphStyle: para])

        if c.isFront {
            let tag = CGRect(x: r.minX + 12, y: r.minY + 9, width: 46, height: 14)
            let p = NSBezierPath(roundedRect: tag, xRadius: 7, yRadius: 7)
            NSGradient(colors: StackPalette.ember)?.draw(in: p, angle: -90)
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9, weight: .heavy), .kern: 0.4,
                                                        .foregroundColor: NSColor(hex: 0x1d1f27)]
            let s = ("FRONT" as NSString).size(withAttributes: attrs)
            ("FRONT" as NSString).draw(at: CGPoint(x: tag.midX - s.width / 2, y: tag.midY - s.height / 2), withAttributes: attrs)
        }
    }
}
