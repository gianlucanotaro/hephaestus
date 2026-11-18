import AppKit
import Carbon.HIToolbox

/// AppKit canvas for editing a `GridModel` (issue #6). All editing rules live in `GridModel`; this view only
/// translates mouse/keyboard input into model calls and draws the result. Not unit-tested (needs a GUI).
///
/// Mouse: click a zone to split it (Shift rotates the divider), drag a divider to resize, drag on empty zone area
/// to rubber-band select (Cmd-click toggles), then Merge. Keyboard: Tab / Shift-Tab / Ctrl-Tab move focus between
/// zones and dividers; S splits the focused zone (Shift = other orientation); arrows move the focused divider
/// (Shift = bigger step); Space toggles selection; M merges the selection; Delete merges the focused zone with a
/// neighbor (or the selection); Cmd-Z / Cmd-Shift-Z undo / redo; Esc is handled by the shell (cancel).
final class GridEditorView: NSView, LayoutEditing {
    private(set) var model: GridModel
    private(set) var selection = Set<Int>()
    private(set) var focus: GridFocus?

    var onChange: (() -> Void)?
    var canUndo: Bool { model.canUndo }
    var canRedo: Bool { model.canRedo }
    var hasChanges: Bool { model.hasChanges }
    var toolbarItems: [NSView] { [mergeButton] }
    var hint: String {
        "Click: split (Shift rotates)  ·  Drag divider: resize  ·  Drag zones: select, then Merge  ·  Tab/S/arrows/Delete: keyboard  ·  Esc: cancel"
    }

    private let mergeButton = NSButton(title: "Merge", target: nil, action: nil)

    private enum Drag {
        case none
        case pending(start: CGPoint)           // mouse down on a zone; becomes a click or a rubber-band
        case divider(GridModel.Divider)
        case band(start: CGPoint, current: CGPoint)
    }
    private var drag = Drag.none
    private var hover: CGPoint?
    private var hoverDivider: GridModel.Divider?

    /// Pixels either side of a divider that still grab it.
    private let grab: CGFloat = 6
    private let stepSmall = 0.01, stepLarge = 0.05

    init(model: GridModel = GridModel()) {
        self.model = model
        super.init(frame: .zero)
        mergeButton.target = self
        mergeButton.action = #selector(mergeSelection)
        mergeButton.bezelStyle = .rounded
        updateMergeButton()
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func makeLayout(id: String, name: String) -> Layout? { model.layout(id: id, name: name) }
    func undo() { if model.undo() { afterEdit(keepFocus: false) } }
    func redo() { if model.redo() { afterEdit(keepFocus: false) } }

    // MARK: Coordinates

    private func rel(_ p: CGPoint) -> (x: Double, y: Double) {
        (Double(p.x / max(bounds.width, 1)), Double(p.y / max(bounds.height, 1)))
    }
    private func viewRect(_ r: RelRect) -> CGRect {
        CGRect(x: r.x * bounds.width, y: r.y * bounds.height, width: r.w * bounds.width, height: r.h * bounds.height)
    }
    private func dividerAt(_ p: CGPoint) -> GridModel.Divider? {
        let r = rel(p)
        return model.divider(atX: r.x, y: r.y, toleranceX: Double(grab / max(bounds.width, 1)),
                             toleranceY: Double(grab / max(bounds.height, 1)))
    }
    private var splitOrientation: DividerOrientation {
        NSEvent.modifierFlags.contains(.shift) ? .horizontal : .vertical
    }

    // MARK: State changes

    private func afterEdit(keepFocus: Bool) {
        let ids = Set(model.zones.map(\.id))
        selection = selection.intersection(ids)
        if !keepFocus || !isFocusValid { focus = nil }
        updateMergeButton()
        needsDisplay = true
        onChange?()
    }

    private var isFocusValid: Bool {
        switch focus {
        case nil: return true
        case .zone(let id)?: return model.zone(id: id) != nil
        case .divider(let d)?: return model.dividers.contains(d)
        }
    }

    private func updateMergeButton() { mergeButton.isEnabled = model.canMerge(selection) }

    @objc private func mergeSelection() {
        if let id = model.merge(selection) {
            selection = []
            focus = .zone(id)
            afterEdit(keepFocus: true)
        } else { NSSound.beep() }
        window?.makeFirstResponder(self)
    }

    private func split(_ id: Int, orientation: DividerOrientation, at position: Double) {
        if let ids = model.split(id, orientation: orientation, at: position) {
            selection = []
            focus = .zone(ids.first)
            afterEdit(keepFocus: true)
        } else { NSSound.beep() }
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        hover = convert(event.locationInWindow, from: nil)
        hoverDivider = hover.flatMap(dividerAt)
        updateCursor()
        needsDisplay = true
    }
    override func mouseExited(with event: NSEvent) { hover = nil; hoverDivider = nil; NSCursor.arrow.set(); needsDisplay = true }
    override func flagsChanged(with event: NSEvent) { needsDisplay = true }

    private func updateCursor() {
        switch hoverDivider?.orientation {
        case .vertical?: NSCursor.resizeLeftRight.set()
        case .horizontal?: NSCursor.resizeUpDown.set()
        case nil: NSCursor.crosshair.set()
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        hover = p
        if let d = dividerAt(p) {
            model.beginGesture()
            drag = .divider(d)
            focus = .divider(d)
        } else if event.modifierFlags.contains(.command) {
            let r = rel(p)
            if let id = model.zoneID(atX: r.x, y: r.y) {
                if !selection.insert(id).inserted { selection.remove(id) }
                focus = .zone(id)
            }
            drag = .none
        } else {
            drag = .pending(start: p)
        }
        updateMergeButton()
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        hover = p
        switch drag {
        case .divider(let d):
            let r = rel(p)
            if model.moveDivider(d, to: d.orientation == .vertical ? r.x : r.y) { onChange?() }
        case .pending(let start):
            if hypot(p.x - start.x, p.y - start.y) > 4 { drag = .band(start: start, current: p); selectBand(start, p) }
        case .band(let start, _):
            drag = .band(start: start, current: p)
            selectBand(start, p)
        case .none: break
        }
        needsDisplay = true
    }

    private func selectBand(_ a: CGPoint, _ b: CGPoint) {
        let (x0, y0) = rel(CGPoint(x: min(a.x, b.x), y: min(a.y, b.y)))
        let (x1, y1) = rel(CGPoint(x: max(a.x, b.x), y: max(a.y, b.y)))
        selection = model.zoneIDs(intersecting: RelRect(x: x0, y: y0, w: max(x1 - x0, 1e-6), h: max(y1 - y0, 1e-6)))
        updateMergeButton()
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        defer { drag = .none; hoverDivider = dividerAt(p); needsDisplay = true }
        switch drag {
        case .divider:
            model.endGesture()
            afterEdit(keepFocus: true)
        case .pending:
            let r = rel(p)
            if let id = model.zoneID(atX: r.x, y: r.y) {
                let o = splitOrientation
                split(id, orientation: o, at: o == .vertical ? r.x : r.y)
            }
        case .band, .none: break
        }
    }

    // MARK: Keyboard

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "z",
              window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        if event.modifierFlags.contains(.shift) { redo() } else { undo() }
        return true
    }

    override func keyDown(with event: NSEvent) {
        let shift = event.modifierFlags.contains(.shift)
        switch Int(event.keyCode) {
        case kVK_Tab:   // Tab / Shift-Tab / Ctrl-Tab all walk the focus order
            focus = model.nextFocus(after: focus, reverse: shift)
        case kVK_Space:
            if case .zone(let id)? = focus { if !selection.insert(id).inserted { selection.remove(id) } }
        case kVK_Delete, kVK_ForwardDelete:
            deleteFocused()
            return
        case kVK_LeftArrow: nudge(dx: -1, dy: 0, large: shift)
        case kVK_RightArrow: nudge(dx: 1, dy: 0, large: shift)
        case kVK_UpArrow: nudge(dx: 0, dy: -1, large: shift)
        case kVK_DownArrow: nudge(dx: 0, dy: 1, large: shift)
        default:
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "s": splitFocused(orientation: shift ? .horizontal : .vertical)
            case "m": mergeSelection()
            default: super.keyDown(with: event); return
            }
        }
        updateMergeButton()
        needsDisplay = true
    }

    private func splitFocused(orientation: DividerOrientation) {
        guard case .zone(let id)? = focus, let z = model.zone(id: id) else { NSSound.beep(); return }
        let r = model.rect(of: z)
        split(id, orientation: orientation, at: orientation == .vertical ? r.x + r.w / 2 : r.y + r.h / 2)
    }

    private func nudge(dx: Int, dy: Int, large: Bool) {
        guard case .divider(let d)? = focus else { return }
        let step = large ? stepLarge : stepSmall
        let delta = d.orientation == .vertical ? Double(dx) * step : Double(dy) * step
        guard delta != 0 else { return }
        if model.nudgeDivider(d, by: delta) { onChange?() }
    }

    private func deleteFocused() {
        var merged: Int?
        if selection.count >= 2 { merged = model.merge(selection) }
        else if case .zone(let id)? = focus { merged = model.deleteZone(id) }
        else if case .divider(let d)? = focus { merged = model.merge([d.before, d.after]) }
        if let merged {
            selection = []
            focus = .zone(merged)
            afterEdit(keepFocus: true)
        } else { NSSound.beep() }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let accent = NSColor.controlAccentColor
        let zones = model.orderedZones
        for (i, z) in zones.enumerated() {
            let r = viewRect(model.rect(of: z))
            let selected = selection.contains(z.id)
            (selected ? accent.withAlphaComponent(0.45) : NSColor.white.withAlphaComponent(0.10)).setFill()
            r.fill()
            NSColor.white.withAlphaComponent(0.35).setStroke()
            let outline = NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5))
            outline.lineWidth = 1
            outline.stroke()
            drawLabel("\(i + 1)", size: min(96, max(24, min(r.width, r.height) / 3)), in: r, dy: -8)
            drawLabel("\(Int(r.width)) × \(Int(r.height))", size: 13, in: r, dy: min(r.height / 2 - 14, 44), alpha: 0.7)
            if case .zone(z.id)? = focus {
                accent.setStroke()
                let ring = NSBezierPath(rect: r.insetBy(dx: 4, dy: 4))
                ring.lineWidth = 3
                ring.stroke()
            }
        }

        // Preview of where a click would split.
        if let hover, hoverDivider == nil, case .none = drag {
            drawSplitPreview(at: hover, accent: accent)
        }
        drawDividers(accent)
        drawBand()
    }

    private func drawSplitPreview(at p: CGPoint, accent: NSColor) {
        let r = rel(p)
        guard let id = model.zoneID(atX: r.x, y: r.y), let z = model.zone(id: id) else { return }
        let zr = viewRect(model.rect(of: z))
        let path = NSBezierPath()
        if splitOrientation == .vertical {
            path.move(to: CGPoint(x: p.x, y: zr.minY)); path.line(to: CGPoint(x: p.x, y: zr.maxY))
        } else {
            path.move(to: CGPoint(x: zr.minX, y: p.y)); path.line(to: CGPoint(x: zr.maxX, y: p.y))
        }
        accent.withAlphaComponent(0.9).setStroke()
        path.lineWidth = 2
        path.setLineDash([6, 4], count: 2, phase: 0)
        path.stroke()
    }

    private func drawDividers(_ accent: NSColor) {
        for d in model.dividers {
            let p = model.position(of: d), e = model.extent(of: d)
            let active: Bool
            switch drag { case .divider(let a): active = a == d; default: active = false }
            let highlighted = active || hoverDivider == d || focus == .divider(d)
            let path = NSBezierPath()
            if d.orientation == .vertical {
                path.move(to: CGPoint(x: p * bounds.width, y: e.from * bounds.height))
                path.line(to: CGPoint(x: p * bounds.width, y: e.to * bounds.height))
            } else {
                path.move(to: CGPoint(x: e.from * bounds.width, y: p * bounds.height))
                path.line(to: CGPoint(x: e.to * bounds.width, y: p * bounds.height))
            }
            path.lineWidth = highlighted ? 6 : 3
            (highlighted ? accent : NSColor.white.withAlphaComponent(0.85)).setStroke()
            path.stroke()
        }
    }

    private func drawBand() {
        guard case .band(let a, let b) = drag else { return }
        let r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
        NSColor.controlAccentColor.withAlphaComponent(0.15).setFill(); r.fill()
        NSColor.controlAccentColor.setStroke()
        let path = NSBezierPath(rect: r)
        path.lineWidth = 1
        path.stroke()
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
