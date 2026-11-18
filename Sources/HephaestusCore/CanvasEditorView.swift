import AppKit
import Carbon.HIToolbox

/// AppKit canvas for editing a `CanvasModel` (issue #7). All editing rules live in `CanvasModel`; this view only
/// translates mouse/keyboard input into model calls and draws the result. Not unit-tested (needs a GUI).
///
/// Mouse: drag a zone to move it, drag one of the 8 handles of the selected zone to resize, double-click empty
/// space (or the Add Zone button) to add a zone, click empty space does nothing. Keyboard: arrows move the selected
/// zone 10 px (Ctrl: 1 px); Shift+arrows resize 10 px (Ctrl+Shift: 2 px); Delete removes; Tab / Shift-Tab cycle the
/// selection; [ and ] lower / raise; Cmd-Z / Cmd-Shift-Z undo / redo; Esc is handled by the shell (cancel).
/// Note: macOS may reserve Ctrl+arrow for Mission Control; disable that shortcut in System Settings to use it.
final class CanvasEditorView: NSView, LayoutEditing {
    private(set) var model: CanvasModel

    var onChange: (() -> Void)?
    var canUndo: Bool { model.canUndo }
    var canRedo: Bool { model.canRedo }
    var hasChanges: Bool { model.hasChanges }
    var toolbarItems: [NSView] { [addButton, deleteButton, raiseButton, lowerButton] }
    var hint: String {
        "Drag: move / resize handles  ·  Double-click empty space or Add Zone: new zone  ·  Arrows: move 10 px (Ctrl 1)  ·  Shift+arrows: resize 10 px (Ctrl 2)  ·  Tab: select  ·  Delete  ·  Esc: cancel"
    }

    private let addButton = NSButton(title: "Add Zone", target: nil, action: nil)
    private let deleteButton = NSButton(title: "Delete", target: nil, action: nil)
    private let raiseButton = NSButton(title: "Raise", target: nil, action: nil)
    private let lowerButton = NSButton(title: "Lower", target: nil, action: nil)

    private enum Drag {
        case none
        case move(id: Int, base: RelRect, start: CGPoint)
        case resize(id: Int, handle: ResizeHandle, base: RelRect, start: CGPoint)
    }
    private var drag = Drag.none
    private var hoverCursor: NSCursor = .arrow

    /// Points around a handle centre that grab it, and the drawn handle size.
    private let grab: CGFloat = 9
    private let handleSize: CGFloat = 10

    init(model: CanvasModel) {
        self.model = model
        super.init(frame: .zero)
        for (button, action) in [(addButton, #selector(addZone)), (deleteButton, #selector(deleteSelected)),
                                 (raiseButton, #selector(raise)), (lowerButton, #selector(lower))] {
            button.target = self
            button.action = action
            button.bezelStyle = .rounded
        }
        updateButtons()
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func makeLayout(id: String, name: String) -> Layout? { model.layout(id: id, name: name) }
    func undo() { if model.undo() { afterEdit() } }
    func redo() { if model.redo() { afterEdit() } }

    // MARK: Coordinates

    private func rel(_ p: CGPoint) -> (x: Double, y: Double) {
        (Double(p.x / max(bounds.width, 1)), Double(p.y / max(bounds.height, 1)))
    }
    private func viewRect(_ r: RelRect) -> CGRect {
        CGRect(x: r.x * bounds.width, y: r.y * bounds.height, width: r.w * bounds.width, height: r.h * bounds.height)
    }

    // MARK: State changes

    private func afterEdit() {
        updateButtons()
        needsDisplay = true
        onChange?()
    }

    private func updateButtons() {
        deleteButton.isEnabled = model.zones.count > 1 && model.selectedID != nil
        let index = model.selectedID.flatMap(model.zoneIndex(of:))
        raiseButton.isEnabled = index.map { $0 < model.zones.count - 1 } ?? false
        lowerButton.isEnabled = index.map { $0 > 0 } ?? false
    }

    @objc private func addZone() { model.addZone(); afterEdit(); window?.makeFirstResponder(self) }
    @objc private func deleteSelected() {
        if let id = model.selectedID, model.deleteZone(id) { afterEdit() } else { NSSound.beep() }
        window?.makeFirstResponder(self)
    }
    @objc private func raise() { reorderSelected(.forward) }
    @objc private func lower() { reorderSelected(.backward) }
    private func reorderSelected(_ op: CanvasModel.ZOrder) {
        if let id = model.selectedID, model.reorder(id, op) { afterEdit() }
        window?.makeFirstResponder(self)
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    private func hit(at p: CGPoint) -> (id: Int, handle: ResizeHandle?)? {
        let r = rel(p)
        return model.hit(atX: r.x, y: r.y, toleranceX: Double(grab / max(bounds.width, 1)),
                         toleranceY: Double(grab / max(bounds.height, 1)))
    }

    private func cursor(for handle: ResizeHandle?) -> NSCursor {
        switch handle {
        case .left?, .right?: return .resizeLeftRight
        case .top?, .bottom?: return .resizeUpDown
        case .some: return .crosshair
        case nil: return .openHand
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        (hit(at: p).map { cursor(for: $0.handle) } ?? .arrow).set()
    }
    override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        guard let h = hit(at: p), let zone = model.zone(id: h.id) else {
            if event.clickCount >= 2 {
                let r = rel(p)
                model.addZone(centeredAtX: r.x, y: r.y)
                afterEdit()
            }
            drag = .none
            return
        }
        model.select(h.id)
        model.beginGesture()
        if let handle = h.handle {
            drag = .resize(id: h.id, handle: handle, base: zone.rect, start: p)
        } else {
            drag = .move(id: h.id, base: zone.rect, start: p)
            NSCursor.closedHand.set()
        }
        updateButtons()
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        switch drag {
        case .move(let id, let base, let start):
            let d = delta(from: start, to: p)
            model.setRect(id, CanvasModel.moved(base, dx: d.x, dy: d.y))
        case .resize(let id, let handle, let base, let start):
            let d = delta(from: start, to: p)
            model.setRect(id, model.resized(base, handle: handle, dx: d.x, dy: d.y))
        case .none: return
        }
        needsDisplay = true
        onChange?()
    }

    private func delta(from a: CGPoint, to b: CGPoint) -> (x: Double, y: Double) {
        (Double((b.x - a.x) / max(bounds.width, 1)), Double((b.y - a.y) / max(bounds.height, 1)))
    }

    override func mouseUp(with event: NSEvent) {
        if case .none = drag { return }
        drag = .none
        model.endGesture()
        afterEdit()
        mouseMoved(with: event)
    }

    // MARK: Keyboard

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "z",
              window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        if event.modifierFlags.contains(.shift) { redo() } else { undo() }
        return true
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags
        let shift = flags.contains(.shift), ctrl = flags.contains(.control)
        let key = Int(event.keyCode)
        switch key {
        case kVK_Tab:
            model.selectNext(reverse: shift)
            updateButtons()
            needsDisplay = true
        case kVK_Delete, kVK_ForwardDelete:
            deleteSelected()
        case kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow:
            arrow(key, shift: shift, ctrl: ctrl)
        default:
            switch event.charactersIgnoringModifiers {
            case "]": raise()
            case "[": lower()
            default: super.keyDown(with: event)
            }
        }
    }

    private func arrow(_ key: Int, shift: Bool, ctrl: Bool) {
        guard let id = model.selectedID else { return }
        let sx: Double = key == kVK_LeftArrow ? -1 : key == kVK_RightArrow ? 1 : 0
        let sy: Double = key == kVK_UpArrow ? -1 : key == kVK_DownArrow ? 1 : 0
        let step = CanvasKeyboard.step(resize: shift, fine: ctrl)
        let changed = shift
            ? model.resizeBy(id, dwPx: sx * step, dhPx: sy * step)
            : model.nudge(id, dxPx: sx * step, dyPx: sy * step)
        if changed { afterEdit() }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let accent = NSColor.controlAccentColor
        for (i, z) in model.zones.enumerated() {
            let r = viewRect(z.rect)
            let selected = z.id == model.selectedID
            (selected ? accent.withAlphaComponent(0.35) : NSColor.white.withAlphaComponent(0.12)).setFill()
            r.fill()
            (selected ? accent : NSColor.white.withAlphaComponent(0.55)).setStroke()
            let outline = NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5))
            outline.lineWidth = selected ? 2 : 1
            outline.stroke()
            drawLabel("\(i + 1)", size: min(96, max(20, min(r.width, r.height) / 3)), in: r, dy: -6)
            drawLabel("\(Int(r.width)) × \(Int(r.height))", size: 12, in: r, dy: min(r.height / 2 - 12, 40), alpha: 0.7)
        }
        if let z = model.selectedZone { drawHandles(on: viewRect(z.rect), accent: accent) }
    }

    private func drawHandles(on r: CGRect, accent: NSColor) {
        for h in ResizeHandle.allCases {
            let p = h.point(on: RelRect(x: r.minX, y: r.minY, w: r.width, h: r.height))
            let square = CGRect(x: p.x - handleSize / 2, y: p.y - handleSize / 2, width: handleSize, height: handleSize)
            NSColor.white.setFill()
            square.fill()
            accent.setStroke()
            let path = NSBezierPath(rect: square)
            path.lineWidth = 1.5
            path.stroke()
        }
    }

    private func drawLabel(_ text: String, size: CGFloat, in rect: CGRect, dy: CGFloat, alpha: CGFloat = 0.95) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(alpha),
        ]
        let s = text as NSString
        let sz = s.size(withAttributes: attrs)
        s.draw(at: CGPoint(x: rect.midX - sz.width / 2, y: rect.midY - sz.height / 2 + dy), withAttributes: attrs)
    }
}

/// Keyboard step sizes (points on the target screen) from the issue: move 10 / Ctrl 1, resize 10 / Ctrl 2.
enum CanvasKeyboard {
    static func step(resize: Bool, fine: Bool) -> Double {
        switch (resize, fine) {
        case (false, false): return 10
        case (false, true): return 1
        case (true, false): return 10
        case (true, true): return 2
        }
    }
}
