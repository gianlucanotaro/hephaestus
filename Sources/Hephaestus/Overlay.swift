import AppKit

/// Translucent, click-through outlines showing where each zone sits.
final class Overlay {
    private var windows: [NSWindow] = []
    private var hideWork: DispatchWorkItem?
    var isVisible: Bool { !windows.isEmpty }

    func toggle() { isVisible ? hide() : show(autoHideAfter: nil) }

    func show(autoHideAfter seconds: TimeInterval? = 1.5) {
        hide()
        guard let (_, zones) = ZoneLayout.currentZones() else { return }
        let colors: [Zone: NSColor] = [.left: .systemBlue, .center: .systemGreen, .right: .systemOrange]
        for zone in Zone.allCases {
            guard let rect = zones[zone] else { continue }
            let w = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.level = .statusBar
            w.ignoresMouseEvents = true
            w.hasShadow = false
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            w.contentView = ZoneView(color: colors[zone] ?? .gray, label: zone.title)
            w.orderFrontRegardless()
            windows.append(w)
        }
        if let seconds {
            let work = DispatchWorkItem { [weak self] in self?.hide() }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
        }
    }

    func hide() {
        hideWork?.cancel()
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
    }
}

private final class ZoneView: NSView {
    let color: NSColor
    let label: String
    init(color: NSColor, label: String) {
        self.color = color; self.label = label
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 12, yRadius: 12)
        color.withAlphaComponent(0.12).setFill(); path.fill()
        color.withAlphaComponent(0.9).setStroke(); path.lineWidth = 4; path.stroke()
        let text = "\(label)  \(Int(bounds.width))×\(Int(bounds.height))" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 28, weight: .semibold), .foregroundColor: color,
        ]
        let size = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attrs)
    }
}
