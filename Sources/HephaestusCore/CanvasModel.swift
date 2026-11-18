import Foundation

// Pure model behind the canvas layout editor (issue #7). No AppKit: every editing rule lives here so it is
// unit-tested; `CanvasEditorView` only translates input into these calls.
//
// A canvas is an ordered list of free-form zones (they may overlap). Rects are relative to the target screen's
// visibleFrame, origin TOP-left, y down: the same convention as `RelRect` / the layout file format. The list is
// BACK-TO-FRONT: the last zone is drawn (and hit-tested) on top, and a zone's position in the list is its
// `ZoneIndex` ("Zone N") once saved, so z-order changes renumber zones. `screenSize` (points of the visibleFrame
// of the screen being edited) is only used to turn pixel steps (keyboard) and minimum sizes into relative values.

/// The eight resize handles of a zone.
enum ResizeHandle: CaseIterable, Equatable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    var movesLeft: Bool { self == .topLeft || self == .left || self == .bottomLeft }
    var movesRight: Bool { self == .topRight || self == .right || self == .bottomRight }
    var movesTop: Bool { self == .topLeft || self == .top || self == .topRight }
    var movesBottom: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }

    /// Center of this handle on `r`.
    func point(on r: RelRect) -> (x: Double, y: Double) {
        let x = movesLeft ? r.x : movesRight ? r.x + r.w : r.x + r.w / 2
        let y = movesTop ? r.y : movesBottom ? r.y + r.h : r.y + r.h / 2
        return (x, y)
    }
}

struct CanvasModel {
    struct Zone: Equatable, Identifiable {
        var id: Int
        var rect: RelRect
    }

    struct Snapshot: Equatable {
        var zones: [Zone]
        var nextID: Int
    }

    /// Smallest zone edge in points on the target screen.
    static let defaultMinSizePx = 40.0
    /// Size of a newly added zone, as a fraction of the screen.
    static let defaultZoneSize = (w: 0.3, h: 0.3)
    /// Offset between a new zone and the zone it is placed next to, as a fraction of the screen.
    static let cascadeStep = 0.05

    let screenSize: CGSize
    let minSizePx: Double
    /// Back-to-front.
    private(set) var zones: [Zone]
    private(set) var selectedID: Int?
    private var nextID: Int

    private var original: Snapshot
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    private var gestureBase: Snapshot?

    // MARK: Creation

    /// FancyZones start state: ONE zone, centered.
    init(screenSize: CGSize, minSizePx: Double = CanvasModel.defaultMinSizePx) {
        self.screenSize = CGSize(width: max(screenSize.width, 1), height: max(screenSize.height, 1))
        self.minSizePx = minSizePx
        let (w, h) = CanvasModel.defaultZoneSize
        zones = [Zone(id: 0, rect: RelRect(x: (1 - w) / 2, y: (1 - h) / 2, w: w, h: h))]
        nextID = 1
        selectedID = 0
        original = Snapshot(zones: zones, nextID: nextID)
    }

    /// Opens any layout (canvas, grid, template - overlapping or not) as an editable canvas, keeping zone order.
    /// nil when the layout is not valid (no zones, or a zone outside the screen).
    init?(layout: Layout, screenSize: CGSize, minSizePx: Double = CanvasModel.defaultMinSizePx) {
        guard layout.isValid else { return nil }
        self.screenSize = CGSize(width: max(screenSize.width, 1), height: max(screenSize.height, 1))
        self.minSizePx = minSizePx
        zones = layout.zones.enumerated().map { Zone(id: $0.offset, rect: $0.element) }
        nextID = zones.count
        selectedID = zones.last?.id
        original = Snapshot(zones: zones, nextID: nextID)
    }

    // MARK: Queries

    var zoneRects: [RelRect] { zones.map(\.rect) }
    var minWidth: Double { min(1, minSizePx / Double(screenSize.width)) }
    var minHeight: Double { min(1, minSizePx / Double(screenSize.height)) }

    func zone(id: Int) -> Zone? { zones.first { $0.id == id } }
    /// Position of the zone in the layout (its future `ZoneIndex`).
    func zoneIndex(of id: Int) -> ZoneIndex? { zones.firstIndex { $0.id == id } }
    var selectedZone: Zone? { selectedID.flatMap(zone(id:)) }

    /// Topmost zone containing the point.
    func zoneID(atX x: Double, y: Double) -> Int? {
        zones.last { x >= $0.rect.x && x <= $0.rect.x + $0.rect.w && y >= $0.rect.y && y <= $0.rect.y + $0.rect.h }?.id
    }

    /// What a mouse press at (x, y) grabs: the selected zone's handles first (they stick out past the zone), then
    /// the topmost zone body. `toleranceX/Y` are the handle grab radius in relative units.
    func hit(atX x: Double, y: Double, toleranceX: Double, toleranceY: Double) -> (id: Int, handle: ResizeHandle?)? {
        if let z = selectedZone {
            // Corners win over edges when both are in range.
            let order: [ResizeHandle] = [.topLeft, .topRight, .bottomRight, .bottomLeft, .top, .right, .bottom, .left]
            for h in order {
                let p = h.point(on: z.rect)
                if abs(p.x - x) <= toleranceX && abs(p.y - y) <= toleranceY { return (z.id, h) }
            }
        }
        return zoneID(atX: x, y: y).map { ($0, nil) }
    }

    // MARK: Pure geometry

    /// `r` shifted by (dx, dy), kept inside the unit square.
    static func moved(_ r: RelRect, dx: Double, dy: Double) -> RelRect {
        RelRect(x: min(max(r.x + dx, 0), 1 - r.w), y: min(max(r.y + dy, 0), 1 - r.h), w: r.w, h: r.h)
    }

    /// `r` with the edges owned by `handle` moved by (dx, dy), clamped to the unit square and to the minimum size.
    func resized(_ r: RelRect, handle: ResizeHandle, dx: Double, dy: Double) -> RelRect {
        var left = r.x, right = r.x + r.w, top = r.y, bottom = r.y + r.h
        // A zone already smaller than the minimum may keep its size but never shrink further.
        let mw = min(minWidth, r.w), mh = min(minHeight, r.h)
        if handle.movesLeft { left = min(max(left + dx, 0), right - mw) }
        if handle.movesRight { right = max(min(right + dx, 1), left + mw) }
        if handle.movesTop { top = min(max(top + dy, 0), bottom - mh) }
        if handle.movesBottom { bottom = max(min(bottom + dy, 1), top + mh) }
        return RelRect(x: left, y: top, w: right - left, h: bottom - top)
    }

    // MARK: Editing

    private var snapshot: Snapshot { Snapshot(zones: zones, nextID: nextID) }
    private mutating func restore(_ s: Snapshot) {
        zones = s.zones; nextID = s.nextID
        if let id = selectedID, zone(id: id) == nil { selectedID = zones.last?.id }
    }

    /// Runs `body`; records an undo step if it changed the zones (unless inside a drag gesture).
    private mutating func edit(_ body: (inout CanvasModel) -> Void) -> Bool {
        let before = snapshot
        body(&self)
        guard snapshot != before else { return false }
        if gestureBase == nil { undoStack.append(before); redoStack.removeAll() }
        return true
    }

    /// Selects a zone (or nothing). Not an undo step.
    mutating func select(_ id: Int?) {
        selectedID = id.flatMap { zone(id: $0) != nil ? $0 : nil }
    }

    /// Tab / Shift-Tab: next zone in z-order (wrapping); the first (last when reversed) when nothing is selected.
    mutating func selectNext(reverse: Bool = false) {
        guard !zones.isEmpty else { selectedID = nil; return }
        guard let id = selectedID, let i = zoneIndex(of: id) else {
            selectedID = reverse ? zones.last?.id : zones.first?.id
            return
        }
        selectedID = zones[(i + (reverse ? zones.count - 1 : 1)) % zones.count].id
    }

    /// Adds a zone of the default size on top and selects it. Without a center it is offset down-right from the
    /// selected (else topmost) zone so it does not hide it, wrapping to the top-left when it would leave the screen.
    @discardableResult
    mutating func addZone(centeredAtX cx: Double? = nil, y cy: Double? = nil) -> Int {
        let (w, h) = CanvasModel.defaultZoneSize
        var x: Double, y: Double
        if let cx, let cy {
            x = cx - w / 2; y = cy - h / 2
        } else if let ref = selectedZone ?? zones.last {
            x = ref.rect.x + CanvasModel.cascadeStep; y = ref.rect.y + CanvasModel.cascadeStep
            if x + w > 1 || y + h > 1 { x = 0; y = 0 }
        } else {
            x = (1 - w) / 2; y = (1 - h) / 2
        }
        x = min(max(x, 0), 1 - w); y = min(max(y, 0), 1 - h)
        let id = nextID
        _ = edit { m in
            m.zones.append(Zone(id: id, rect: RelRect(x: x, y: y, w: w, h: h)))
            m.nextID += 1
        }
        selectedID = id
        return id
    }

    /// Deletes a zone; the last remaining zone cannot be deleted (a layout needs one). Selects the zone below it.
    @discardableResult
    mutating func deleteZone(_ id: Int) -> Bool {
        guard zones.count > 1, let i = zoneIndex(of: id) else { return false }
        _ = edit { $0.zones.remove(at: i) }
        selectedID = zones[min(i, zones.count - 1)].id
        return true
    }

    /// Replaces a zone's rect (clamped into the screen, never smaller than the minimum unless it already was).
    /// Returns false when nothing changed.
    @discardableResult
    mutating func setRect(_ id: Int, _ rect: RelRect) -> Bool {
        guard let i = zoneIndex(of: id), [rect.x, rect.y, rect.w, rect.h].allSatisfy(\.isFinite) else { return false }
        let w = min(max(rect.w, min(minWidth, zones[i].rect.w)), 1)
        let h = min(max(rect.h, min(minHeight, zones[i].rect.h)), 1)
        let clamped = CanvasModel.moved(RelRect(x: rect.x, y: rect.y, w: w, h: h), dx: 0, dy: 0)
        return edit { $0.zones[i].rect = clamped }
    }

    @discardableResult
    mutating func move(_ id: Int, dx: Double, dy: Double) -> Bool {
        guard let z = zone(id: id) else { return false }
        return setRect(id, CanvasModel.moved(z.rect, dx: dx, dy: dy))
    }

    @discardableResult
    mutating func resize(_ id: Int, handle: ResizeHandle, dx: Double, dy: Double) -> Bool {
        guard let z = zone(id: id) else { return false }
        return setRect(id, resized(z.rect, handle: handle, dx: dx, dy: dy))
    }

    // Keyboard steps in points on the target screen (positive = right / down).

    @discardableResult
    mutating func nudge(_ id: Int, dxPx: Double, dyPx: Double) -> Bool {
        move(id, dx: dxPx / Double(screenSize.width), dy: dyPx / Double(screenSize.height))
    }

    /// Grows (positive) or shrinks the zone by moving its right / bottom edge; the top-left corner stays put.
    @discardableResult
    mutating func resizeBy(_ id: Int, dwPx: Double, dhPx: Double) -> Bool {
        resize(id, handle: .bottomRight, dx: dwPx / Double(screenSize.width), dy: dhPx / Double(screenSize.height))
    }

    // MARK: Z-order (list order; renumbers zones)

    enum ZOrder { case front, back, forward, backward }

    @discardableResult
    mutating func reorder(_ id: Int, _ op: ZOrder) -> Bool {
        guard let i = zoneIndex(of: id) else { return false }
        let target: Int
        switch op {
        case .front: target = zones.count - 1
        case .back: target = 0
        case .forward: target = min(i + 1, zones.count - 1)
        case .backward: target = max(i - 1, 0)
        }
        guard target != i else { return false }
        return edit { m in let z = m.zones.remove(at: i); m.zones.insert(z, at: target) }
    }

    // MARK: Undo / cancel

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    /// True when the canvas differs from how it was opened.
    var hasChanges: Bool { snapshot != original }

    @discardableResult
    mutating func undo() -> Bool {
        guard let s = undoStack.popLast() else { return false }
        redoStack.append(snapshot)
        restore(s)
        return true
    }

    @discardableResult
    mutating func redo() -> Bool {
        guard let s = redoStack.popLast() else { return false }
        undoStack.append(snapshot)
        restore(s)
        return true
    }

    /// Groups many `setRect`/`move`/`resize` calls (a mouse drag) into a single undo step.
    mutating func beginGesture() { if gestureBase == nil { gestureBase = snapshot } }
    mutating func endGesture() {
        guard let base = gestureBase else { return }
        gestureBase = nil
        if base != snapshot { undoStack.append(base); redoStack.removeAll() }
    }

    /// Cancel: discard every edit and return to the opening state (also clears undo history).
    mutating func revert() {
        restore(original)
        selectedID = zones.last?.id
        undoStack.removeAll(); redoStack.removeAll(); gestureBase = nil
    }

    // MARK: Layout conversion

    /// A `.canvas` layout; zone order (z-order) is preserved.
    func layout(id: String, name: String) -> Layout {
        Layout(id: id, name: name, kind: .canvas, zones: zoneRects)
    }
}
