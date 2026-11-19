import Foundation

// Pure model behind the grid layout editor (issue #6). No AppKit: every editing rule lives here so it is unit-tested.
//
// A grid is a set of column tracks and row tracks (relative sizes summing to 1) plus zones that each cover a
// rectangular span of cells. Coordinates are zone-only (the gap is applied later, at snap time) and relative to
// the screen's visibleFrame, origin TOP-left, y down: the same convention as `RelRect` / the layout file format.
//
// Splitting adds a track line across the whole grid; zones the line crosses simply span one more track, so the
// grid always tiles the unit square exactly. Dividers are the visible edges between two different zones.

/// Orientation of a divider LINE. A `.vertical` divider separates left/right zones and moves along x.
enum DividerOrientation: Hashable, CaseIterable {
    case vertical, horizontal
    var rotated: DividerOrientation { self == .vertical ? .horizontal : .vertical }
}

/// What has keyboard focus in the editor.
enum GridFocus: Hashable {
    case zone(Int)
    case divider(GridModel.Divider)
}

struct GridModel {
    /// A zone covering cells `[col, col+colSpan) x [row, row+rowSpan)`. `id` is stable across edits (except for
    /// merged zones, which keep the smallest id), so UI selection can be held by id.
    struct Zone: Equatable, Identifiable {
        var id: Int
        var col: Int, row: Int, colSpan: Int, rowSpan: Int

        func start(_ o: DividerOrientation) -> Int { o == .vertical ? col : row }
        func span(_ o: DividerOrientation) -> Int { o == .vertical ? colSpan : rowSpan }
        mutating func set(_ o: DividerOrientation, start: Int, span: Int) {
            if o == .vertical { col = start; colSpan = span } else { row = start; rowSpan = span }
        }
    }

    /// A visible edge segment: the line at track boundary `boundary` (between tracks `boundary-1` and `boundary`
    /// of the axis it moves along), spanning tracks `[start, end)` of the other axis, between zones `before`
    /// (left/top) and `after` (right/bottom).
    struct Divider: Hashable {
        var orientation: DividerOrientation
        var boundary: Int
        var start: Int
        var end: Int
        var before: Int
        var after: Int
    }

    struct Snapshot: Equatable {
        var cols: [Double]
        var rows: [Double]
        var zones: [Zone]
        var nextID: Int
    }

    /// Smallest track size (fraction of the screen's width/height) a split or divider move may produce.
    static let defaultMinSize = 0.04

    private(set) var cols: [Double]
    private(set) var rows: [Double]
    private(set) var zones: [Zone]
    private var nextID: Int
    let minSize: Double

    private var original: Snapshot
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    private var gestureBase: Snapshot?

    // MARK: Creation

    /// FancyZones start state: `columns` equal columns (default three).
    init(columns: Int = 3, minSize: Double = GridModel.defaultMinSize) {
        let n = max(1, columns)
        self.minSize = minSize
        cols = Array(repeating: 1 / Double(n), count: n)
        rows = [1]
        zones = (0..<n).map { Zone(id: $0, col: $0, row: 0, colSpan: 1, rowSpan: 1) }
        nextID = n
        original = Snapshot(cols: cols, rows: rows, zones: zones, nextID: n)
    }

    /// Builds a grid from rects that tile the unit square exactly (no gaps or overlaps); nil otherwise
    /// (e.g. the overlapping "Focus" layout or a canvas layout).
    init?(zones rects: [RelRect], minSize: Double = GridModel.defaultMinSize) {
        let eps = 1e-6
        guard !rects.isEmpty, rects.allSatisfy(\.isValid) else { return nil }
        func edges(_ values: [Double]) -> [Double] {
            var out: [Double] = []
            for v in values.sorted() where out.last.map({ v - $0 > eps }) ?? true { out.append(v) }
            return out
        }
        let xs = edges(rects.flatMap { [$0.x, $0.x + $0.w] })
        let ys = edges(rects.flatMap { [$0.y, $0.y + $0.h] })
        guard xs.count >= 2, ys.count >= 2, abs(xs[0]) < eps, abs(xs[xs.count - 1] - 1) < eps,
              abs(ys[0]) < eps, abs(ys[ys.count - 1] - 1) < eps else { return nil }
        func index(_ list: [Double], _ v: Double) -> Int? { list.firstIndex { abs($0 - v) < eps } }
        var found: [Zone] = []
        var covered = Set<[Int]>()
        for r in rects {
            guard let c0 = index(xs, r.x), let c1 = index(xs, r.x + r.w),
                  let r0 = index(ys, r.y), let r1 = index(ys, r.y + r.h), c1 > c0, r1 > r0 else { return nil }
            for c in c0..<c1 { for rr in r0..<r1 { if !covered.insert([c, rr]).inserted { return nil } } }
            found.append(Zone(id: 0, col: c0, row: r0, colSpan: c1 - c0, rowSpan: r1 - r0))
        }
        guard covered.count == (xs.count - 1) * (ys.count - 1) else { return nil }
        found.sort { ($0.col, $0.row) < ($1.col, $1.row) }
        for i in found.indices { found[i].id = i }
        self.minSize = minSize
        cols = (1..<xs.count).map { xs[$0] - xs[$0 - 1] }
        rows = (1..<ys.count).map { ys[$0] - ys[$0 - 1] }
        zones = found
        nextID = found.count
        original = Snapshot(cols: cols, rows: rows, zones: zones, nextID: nextID)
    }

    /// Grid for editing `layout`; nil when its zones do not tile the screen.
    init?(layout: Layout, minSize: Double = GridModel.defaultMinSize) {
        self.init(zones: layout.zones, minSize: minSize)
    }

    // MARK: Geometry

    private func cumulative(_ sizes: [Double]) -> [Double] {
        var out = [0.0]
        for s in sizes { out.append(out[out.count - 1] + s) }
        out[out.count - 1] = 1   // absorb float drift so the last edge is exactly 1
        return out
    }
    /// Track boundaries (count = tracks + 1, first 0, last 1).
    var xEdges: [Double] { cumulative(cols) }
    var yEdges: [Double] { cumulative(rows) }
    func edges(_ o: DividerOrientation) -> [Double] { o == .vertical ? xEdges : yEdges }

    func rect(of zone: Zone) -> RelRect {
        let xe = xEdges, ye = yEdges
        return RelRect(x: xe[zone.col], y: ye[zone.row],
                       w: xe[zone.col + zone.colSpan] - xe[zone.col], h: ye[zone.row + zone.rowSpan] - ye[zone.row])
    }

    /// Zones in `ZoneIndex` order: left-to-right, ties top-to-bottom.
    var orderedZones: [Zone] { zones.sorted { ($0.col, $0.row) < ($1.col, $1.row) } }
    var zoneRects: [RelRect] { orderedZones.map(rect(of:)) }
    func zone(id: Int) -> Zone? { zones.first { $0.id == id } }
    /// Position of a zone in the saved layout (what the editor shows as "Zone N" minus one).
    func zoneIndex(of id: Int) -> ZoneIndex? { orderedZones.firstIndex { $0.id == id } }

    /// The zone containing the relative point (x, y).
    func zoneID(atX x: Double, y: Double) -> Int? {
        let px = min(max(x, 0), 1 - 1e-9), py = min(max(y, 0), 1 - 1e-9)
        return zones.first { let r = rect(of: $0); return px >= r.x && px < r.x + r.w && py >= r.y && py < r.y + r.h }?.id
    }

    /// Ids of zones whose rect intersects the relative rectangle (drag-select).
    func zoneIDs(intersecting area: RelRect) -> Set<Int> {
        Set(zones.filter {
            let r = rect(of: $0)
            return r.x < area.x + area.w && area.x < r.x + r.w && r.y < area.y + area.h && area.y < r.y + r.h
        }.map(\.id))
    }

    // MARK: Dividers

    private func owners() -> [[Int]] {
        var m = Array(repeating: Array(repeating: -1, count: cols.count), count: rows.count)
        for z in zones { for r in z.row..<(z.row + z.rowSpan) { for c in z.col..<(z.col + z.colSpan) { m[r][c] = z.id } } }
        return m
    }

    /// All visible divider segments: vertical ones first, then horizontal, each by boundary then start.
    var dividers: [Divider] {
        let m = owners()
        var out: [Divider] = []
        for o in DividerOrientation.allCases {
            let along = o == .vertical ? cols.count : rows.count   // tracks on the axis the divider moves along
            let across = o == .vertical ? rows.count : cols.count
            guard along > 1 else { continue }
            for b in 1..<along {
                var open: Divider?
                for t in 0..<across {
                    let (a, c) = o == .vertical ? (m[t][b - 1], m[t][b]) : (m[b - 1][t], m[b][t])
                    if a != c {
                        if var d = open, d.before == a, d.after == c { d.end = t + 1; open = d } else {
                            if let d = open { out.append(d) }
                            open = Divider(orientation: o, boundary: b, start: t, end: t + 1, before: a, after: c)
                        }
                    } else if let d = open { out.append(d); open = nil }
                }
                if let d = open { out.append(d) }
            }
        }
        return out
    }

    /// Relative position of the divider line along its axis.
    func position(of d: Divider) -> Double { edges(d.orientation)[d.boundary] }

    /// Relative extent of a divider along the other axis: (from, to).
    func extent(of d: Divider) -> (from: Double, to: Double) {
        let e = edges(d.orientation.rotated)
        return (e[d.start], e[d.end])
    }

    /// The divider nearest to the relative point within `tolerance` (relative units, per axis), if any.
    /// `toleranceX`/`toleranceY` differ because a pixel is a different fraction of width and height.
    func divider(atX x: Double, y: Double, toleranceX: Double, toleranceY: Double) -> Divider? {
        var best: (Divider, Double)?
        for d in dividers {
            let p = position(of: d), e = extent(of: d)
            let dist: Double
            if d.orientation == .vertical {
                guard y >= e.from - toleranceY, y <= e.to + toleranceY else { continue }
                dist = abs(x - p) / max(toleranceX, 1e-9)
            } else {
                guard x >= e.from - toleranceX, x <= e.to + toleranceX else { continue }
                dist = abs(y - p) / max(toleranceY, 1e-9)
            }
            if dist <= 1, best == nil || dist < best!.1 { best = (d, dist) }
        }
        return best?.0
    }

    // MARK: Editing

    private var snapshot: Snapshot { Snapshot(cols: cols, rows: rows, zones: zones, nextID: nextID) }
    private mutating func restore(_ s: Snapshot) { cols = s.cols; rows = s.rows; zones = s.zones; nextID = s.nextID }

    /// Runs `body`; if it reports a change, records an undo step (unless inside a drag gesture).
    private mutating func edit(_ body: (inout GridModel) -> Bool) -> Bool {
        let before = snapshot
        guard body(&self) else { restore(before); return false }
        if gestureBase == nil { undoStack.append(before); redoStack.removeAll() }
        return true
    }

    private func sizes(_ o: DividerOrientation) -> [Double] { o == .vertical ? cols : rows }
    private mutating func setSizes(_ o: DividerOrientation, _ s: [Double]) { if o == .vertical { cols = s } else { rows = s } }

    /// Splits `zoneID` with a divider of `orientation` at relative position `at` along the axis the divider
    /// moves on (x for vertical, y for horizontal). The position is clamped so both halves keep `minSize`.
    /// Returns the ids of the two resulting zones (left/top first), or nil if the zone is too small to split.
    @discardableResult
    mutating func split(_ zoneID: Int, orientation: DividerOrientation, at position: Double) -> (first: Int, second: Int)? {
        var result: (Int, Int)?
        _ = edit { m in
            guard let z = m.zone(id: zoneID) else { return false }
            let e = m.edges(orientation)
            let s0 = z.start(orientation), s1 = s0 + z.span(orientation)
            let p = min(max(position, e[s0]), e[s1])
            // The track containing p (the last one when p sits exactly on the zone's far edge).
            var t = s0
            while t < s1 - 1 && p >= e[t + 1] { t += 1 }
            let lo = e[t] + m.minSize, hi = e[t + 1] - m.minSize
            guard lo <= hi else { return false }
            let q = min(max(p, lo), hi)
            var s = m.sizes(orientation)
            s.replaceSubrange(t...t, with: [q - e[t], e[t + 1] - q])
            m.setSizes(orientation, s)
            let newID = m.nextID
            m.nextID += 1
            var out: [Zone] = []
            for var other in m.zones {
                let start = other.start(orientation), span = other.span(orientation)
                if other.id == z.id {
                    var first = other, second = other
                    first.set(orientation, start: start, span: t - start + 1)
                    second.set(orientation, start: t + 1, span: start + span - t)
                    second.id = newID
                    out += [first, second]
                    continue
                }
                if start > t { other.set(orientation, start: start + 1, span: span) }
                else if start + span - 1 >= t { other.set(orientation, start: start, span: span + 1) }
                out.append(other)
            }
            m.zones = out
            result = (z.id, newID)
            return true
        }
        return result
    }

    /// Moves a divider (the whole track boundary it sits on) to `position`, clamped so no track — hence no
    /// zone — gets smaller than `minSize`. Returns false when nothing moved.
    @discardableResult
    mutating func moveDivider(_ d: Divider, to position: Double) -> Bool {
        edit { m in
            let o = d.orientation
            let e = m.edges(o)
            guard d.boundary >= 1, d.boundary < e.count - 1 else { return false }
            let lo = e[d.boundary - 1] + m.minSize, hi = e[d.boundary + 1] - m.minSize
            guard lo <= hi else { return false }
            let p = min(max(position, lo), hi)
            guard abs(p - e[d.boundary]) > 1e-12 else { return false }
            var s = m.sizes(o)
            s[d.boundary - 1] = p - e[d.boundary - 1]
            s[d.boundary] = e[d.boundary + 1] - p
            m.setSizes(o, s)
            return true
        }
    }

    /// Keyboard nudge: moves the divider by `delta` (relative units; negative = left/up).
    @discardableResult
    mutating func nudgeDivider(_ d: Divider, by delta: Double) -> Bool { moveDivider(d, to: position(of: d) + delta) }

    /// The divider matching `d`'s line after edits that may have renumbered nothing but changed segments.
    func currentDivider(matching d: Divider) -> Divider? {
        dividers.first { $0.orientation == d.orientation && $0.boundary == d.boundary && $0.before == d.before && $0.after == d.after }
            ?? dividers.first { $0.orientation == d.orientation && $0.boundary == d.boundary }
    }

    /// True when `ids` (at least two) exactly fill a rectangle of cells, so they can become one zone.
    func canMerge(_ ids: Set<Int>) -> Bool {
        guard ids.count >= 2 else { return false }
        let sel = zones.filter { ids.contains($0.id) }
        guard sel.count == ids.count else { return false }
        let c0 = sel.map(\.col).min()!, r0 = sel.map(\.row).min()!
        let c1 = sel.map { $0.col + $0.colSpan }.max()!, r1 = sel.map { $0.row + $0.rowSpan }.max()!
        // Zones never overlap, so equal area means the selection fills the bounding box.
        return sel.reduce(0) { $0 + $1.colSpan * $1.rowSpan } == (c1 - c0) * (r1 - r0)
    }

    /// Merges the selected zones into one when they form a rectangle; otherwise rejects (returns nil, model
    /// unchanged). The merged zone keeps the smallest id.
    @discardableResult
    mutating func merge(_ ids: Set<Int>) -> Int? {
        guard canMerge(ids) else { return nil }
        var result: Int?
        _ = edit { m in
            let sel = m.zones.filter { ids.contains($0.id) }
            let c0 = sel.map(\.col).min()!, r0 = sel.map(\.row).min()!
            let c1 = sel.map { $0.col + $0.colSpan }.max()!, r1 = sel.map { $0.row + $0.rowSpan }.max()!
            let keep = sel.map(\.id).min()!
            m.zones.removeAll { ids.contains($0.id) }
            m.zones.append(Zone(id: keep, col: c0, row: r0, colSpan: c1 - c0, rowSpan: r1 - r0))
            m.compact()
            result = keep
            return true
        }
        return result
    }

    /// Neighbor that `zoneID` could merge with into a rectangle, preferring right, left, below, above.
    func mergeNeighbor(of zoneID: Int) -> Int? {
        guard let z = zone(id: zoneID) else { return nil }
        let rank: (Zone) -> Int? = { w in
            if w.col == z.col + z.colSpan { return 0 }
            if w.col + w.colSpan == z.col { return 1 }
            if w.row == z.row + z.rowSpan { return 2 }
            if w.row + w.rowSpan == z.row { return 3 }
            return nil
        }
        return zones.filter { $0.id != z.id && rank($0) != nil && canMerge([z.id, $0.id]) }
            .min { rank($0)! < rank($1)! }?.id
    }

    /// Keyboard Delete: merges the zone with a neighbor it forms a rectangle with. Returns the merged zone's id.
    @discardableResult
    mutating func deleteZone(_ zoneID: Int) -> Int? {
        guard let n = mergeNeighbor(of: zoneID) else { return nil }
        return merge([zoneID, n])
    }

    /// Removes track boundaries that no divider sits on any more (after merges), keeping sizes consistent.
    private mutating func compact() {
        for o in DividerOrientation.allCases {
            var b = sizes(o).count - 1
            while b >= 1 {
                if !dividers.contains(where: { $0.orientation == o && $0.boundary == b }) {
                    var s = sizes(o)
                    s[b - 1] += s[b]
                    s.remove(at: b)
                    setSizes(o, s)
                    for i in zones.indices {
                        let start = zones[i].start(o), span = zones[i].span(o)
                        if start > b { zones[i].set(o, start: start - 1, span: span) }
                        else if start < b && start + span > b { zones[i].set(o, start: start, span: span - 1) }
                    }
                }
                b -= 1
            }
        }
    }

    // MARK: Undo / cancel

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    /// True when the grid differs from how it was opened (cancel can skip a confirmation otherwise).
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

    /// Groups many `moveDivider` calls (a mouse drag) into a single undo step.
    mutating func beginGesture() { if gestureBase == nil { gestureBase = snapshot } }
    mutating func endGesture() {
        guard let base = gestureBase else { return }
        gestureBase = nil
        if base != snapshot { undoStack.append(base); redoStack.removeAll() }
    }

    /// Cancel: discard every edit and return to the opening state (also clears undo history).
    mutating func revert() {
        restore(original)
        undoStack.removeAll(); redoStack.removeAll(); gestureBase = nil
    }

    // MARK: Keyboard focus

    /// Tab order: zones in `ZoneIndex` order, then dividers.
    var focusOrder: [GridFocus] { orderedZones.map { .zone($0.id) } + dividers.map { .divider($0) } }

    /// Next (or previous) focus target after `current`, wrapping around; the first/last item when `current` is nil
    /// or no longer exists.
    func nextFocus(after current: GridFocus?, reverse: Bool = false) -> GridFocus? {
        let order = focusOrder
        guard !order.isEmpty else { return nil }
        guard let current, let i = order.firstIndex(of: current) else { return reverse ? order.last : order.first }
        return order[(i + (reverse ? order.count - 1 : 1)) % order.count]
    }

    // MARK: Layout conversion

    /// A `.grid` layout with relative zones in `ZoneIndex` order.
    func layout(id: String, name: String) -> Layout {
        Layout(id: id, name: name, kind: .grid, zones: zoneRects)
    }
}
