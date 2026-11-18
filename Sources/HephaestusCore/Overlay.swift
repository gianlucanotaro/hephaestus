import AppKit

/// Translucent, click-through outlines showing where each zone sits.
final class Overlay {
    private var windows: [NSWindow] = []
    private var dragViews: [DragKey: ZoneView] = [:]
    private var hideWork: DispatchWorkItem?
    var isVisible: Bool { !windows.isEmpty }

    func toggle() { isVisible ? hide() : show(autoHideAfter: nil) }

    func show(autoHideAfter seconds: TimeInterval? = 1.5) {
        hide()
        let palette: [NSColor] = [.systemBlue, .systemGreen, .systemOrange, .systemPurple, .systemPink, .systemTeal]
        for (_, zones) in ZoneLayout.allZones() {
            for (index, rect) in zones.enumerated() {
                let w = makeWindow(rect)
                w.contentView = ZoneView(look: .preview(color: palette[index % palette.count], label: Layout.zoneTitle(index)))
                w.orderFrontRegardless()
                windows.append(w)
            }
        }
        if let seconds {
            let work = DispatchWorkItem { [weak self] in self?.hide() }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
        }
    }

    /// Drag mode: zones of the given screens, each zone highlightable as a drop target.
    func showDrag(on screens: [NSScreen]) {
        hide()
        let style = OverlayStyle.current
        for screen in screens {
            let zones = ZoneLayout.zones(for: screen)
            for (index, rect) in zones.enumerated() {
                let w = makeWindow(rect)
                let view = ZoneView(look: .drag(style: style, number: index + 1))
                w.contentView = view
                w.orderFrontRegardless()
                windows.append(w)
                dragViews[DragKey(screen: screen.displayID, zone: index)] = view
            }
        }
    }

    /// Highlights `zones` on `screen` and dims every other zone.
    func highlight(_ zones: Set<ZoneIndex>, on screen: NSScreen?) {
        for (key, view) in dragViews { view.highlighted = key.screen == screen?.displayID && zones.contains(key.zone) }
    }

    func hide() {
        hideWork?.cancel()
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        dragViews.removeAll()
    }

    private func makeWindow(_ rect: CGRect) -> NSWindow {
        let w = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.level = .statusBar
        w.ignoresMouseEvents = true
        w.hasShadow = false
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        return w
    }
}

private struct DragKey: Hashable {
    let screen: UInt32
    let zone: ZoneIndex
}

private final class ZoneView: NSView {
    enum Look {
        case preview(color: NSColor, label: String)
        case drag(style: OverlayStyle, number: Int)
    }

    let look: Look
    var highlighted = false { didSet { if highlighted != oldValue { needsDisplay = true } } }
    init(look: Look) {
        self.look = look
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 12, yRadius: 12)
        switch look {
        case let .preview(color, label):
            color.withAlphaComponent(highlighted ? 0.40 : 0.12).setFill(); path.fill()
            color.withAlphaComponent(0.9).setStroke(); path.lineWidth = 4; path.stroke()
            drawText("\(label)  \(Int(bounds.width))×\(Int(bounds.height))", size: 28, color: color)
        case let .drag(style, number):
            // Dynamic system colors resolve against the view's appearance, so draw inside it.
            effectiveAppearance.performAsCurrentDrawingAppearance {
                let fill = highlighted ? style.highlight : style.inactive
                fill.withAlphaComponent(highlighted ? style.opacity : style.opacity * 0.4).setFill(); path.fill()
                (highlighted ? style.highlight : style.border).withAlphaComponent(0.9).setStroke()
                path.lineWidth = highlighted ? 6 : 3; path.stroke()
                if style.showNumbers { drawText("\(number)", size: 96, color: style.number.withAlphaComponent(highlighted ? 1 : 0.7)) }
            }
        }
    }

    private func drawText(_ string: String, size: CGFloat, color: NSColor) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: .semibold), .foregroundColor: color,
        ]
        let text = string as NSString
        let textSize = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: bounds.midX - textSize.width / 2, y: bounds.midY - textSize.height / 2), withAttributes: attrs)
    }
}
