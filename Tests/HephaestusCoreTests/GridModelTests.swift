import Foundation
import Testing
@testable import HephaestusCore

private func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

/// Asserts the zones tile the unit square exactly (area 1, no overlap) and are all valid.
private func expectTiles(_ m: GridModel, sourceLocation: SourceLocation = #_sourceLocation) {
    let rects = m.zoneRects
    let allValid = rects.allSatisfy { $0.isValid }
    #expect(allValid, sourceLocation: sourceLocation)
    #expect(near(rects.reduce(0) { $0 + $1.w * $1.h }, 1), sourceLocation: sourceLocation)
    #expect(GridModel(zones: rects) != nil, sourceLocation: sourceLocation)
}

@Suite struct GridModelTests {
    @Test func startsWithThreeEqualColumns() {
        let m = GridModel()
        #expect(sameRects(m.zoneRects, LayoutTemplates.columns(3)))
        #expect(m.dividers.count == 2)
        #expect(!m.hasChanges)
    }

    @Test func splitVerticalAndHorizontal() throws {
        var m = GridModel()
        let splitResult = m.split(1, orientation: .horizontal, at: 0.25)
        let ids = try #require(splitResult)
        #expect(m.zones.count == 4)
        expectTiles(m)
        let top = try #require(m.zone(id: ids.first)), bottom = try #require(m.zone(id: ids.second))
        #expect(near(m.rect(of: top).h, 0.25) && near(m.rect(of: bottom).h, 0.75))
        // Neighbouring columns now span both rows, still one zone each.
        #expect(m.zone(id: 0)?.rowSpan == 2)
        // Split the left column vertically.
        m.split(0, orientation: .vertical, at: 0.1)
        #expect(m.zones.count == 5)
        expectTiles(m)
        #expect(m.zoneRects.first.map { near($0.w, 0.1) } == true)
    }

    @Test func splitPositionClampsToMinSize() throws {
        var m = GridModel()
        m.split(0, orientation: .vertical, at: 0.0001)
        let r = m.zoneRects
        #expect(near(r[0].w, GridModel.defaultMinSize))
        #expect(near(r[0].w + r[1].w, 1.0 / 3))
        expectTiles(m)
    }

    @Test func splitRejectedWhenTooSmall() {
        var m = GridModel(minSize: 0.2)   // columns are 1/3: halves would be 1/6 < 0.2
        let r = m.split(0, orientation: .vertical, at: 0.1); #expect(r == nil)
        #expect(m.zones.count == 3 && !m.canUndo)
    }

    @Test func splitIsOrderedLeftToRightThenTopToBottom() {
        var m = GridModel()
        m.split(0, orientation: .horizontal, at: 0.5)
        let r = m.zoneRects
        #expect(r[0].x == 0 && r[0].y == 0 && r[1].x == 0 && near(r[1].y, 0.5))
    }

    @Test func moveDividerAndClamp() throws {
        var m = GridModel()
        let d = try #require(m.dividers.first)
        let r = m.moveDivider(d, to: 0.2); #expect(r)
        #expect(near(m.zoneRects[0].w, 0.2) && near(m.zoneRects[1].w, 1.0 / 3 + 1.0 / 3 - 0.2))
        // Cannot crush the middle column (next divider at 2/3).
        m.moveDivider(d, to: 0.99)
        #expect(near(m.zoneRects[1].w, GridModel.defaultMinSize))
        m.moveDivider(d, to: -5)
        #expect(near(m.zoneRects[0].w, GridModel.defaultMinSize))
        expectTiles(m)
        let r2 = m.moveDivider(d, to: m.position(of: d)); #expect(!r2)
    }

    @Test func nudge() throws {
        var m = GridModel()
        let d = try #require(m.dividers.first)
        let p = m.position(of: d)
        let r = m.nudgeDivider(d, by: 0.01); #expect(r)
        #expect(near(m.position(of: d), p + 0.01))
    }

    @Test func dragIsOneUndoStep() throws {
        var m = GridModel()
        let d = try #require(m.dividers.first)
        m.beginGesture()
        for p in stride(from: 0.30, to: 0.5, by: 0.02) { m.moveDivider(d, to: p) }
        m.endGesture()
        let r = m.undo(); #expect(r)
        #expect(!m.hasChanges && !m.canUndo)
    }

    @Test func mergeAdjacentColumns() {
        var m = GridModel()
        let r = m.merge([0, 1]); #expect(r == 0)
        #expect(m.zones.count == 2)
        #expect(m.zoneRects.map(\.w).map { Int(($0 * 3).rounded()) } == [2, 1])
        #expect(m.xEdges.count == 3)   // the vanished divider's track was compacted away
        expectTiles(m)
    }

    @Test func mergeRejectsNonRectangle() {
        var m = GridModel()
        m.split(0, orientation: .horizontal, at: 0.5)   // zones: TL, BL, middle, right
        let ordered = m.orderedZones
        let tl = ordered[0].id, bl = ordered[1].id, mid = ordered[2].id, right = ordered[3].id
        #expect(m.canMerge([tl, bl]))
        #expect(!m.canMerge([bl, right]))   // not contiguous
        #expect(!m.canMerge([tl, mid]))     // leaves the BL cell out of the bounding box
        #expect(m.canMerge([tl, bl, mid]))
        let before = m.zones
        let r = m.merge([tl, right]); #expect(r == nil)
        #expect(m.zones == before)
        #expect(!m.canMerge([tl]))
        #expect(!m.canMerge([]))
    }

    @Test func mergeRejectsLShape() {
        var m = GridModel(columns: 2)
        m.split(1, orientation: .horizontal, at: 0.5)
        m.split(0, orientation: .horizontal, at: 0.5)
        let o = m.orderedZones   // LT, LB, RT, RB
        #expect(!m.canMerge([o[0].id, o[1].id, o[2].id]))
        #expect(m.canMerge([o[0].id, o[1].id]))
        #expect(m.canMerge([o[0].id, o[1].id, o[2].id, o[3].id]))
    }

    @Test func mergeAllCollapsesToOneZone() {
        var m = GridModel()
        m.split(1, orientation: .horizontal, at: 0.5)
        let r = m.merge(Set(m.zones.map(\.id))); #expect(r != nil)
        #expect(m.zones.count == 1 && m.cols == [1] && m.rows == [1])
        #expect(m.zoneRects == [RelRect(x: 0, y: 0, w: 1, h: 1)])
    }

    @Test func deleteMergesWithNeighbor() {
        var m = GridModel()
        let r = m.deleteZone(0); #expect(r != nil)   // merges with the zone to the right
        #expect(m.zones.count == 2)
        expectTiles(m)
        var single = GridModel(columns: 1)
        let r2 = single.deleteZone(0); #expect(r2 == nil)
    }

    @Test func deleteFindsVerticalNeighbor() {
        var m = GridModel(columns: 1)
        m.split(0, orientation: .horizontal, at: 0.5)
        let o = m.orderedZones
        let r = m.deleteZone(o[1].id); #expect(r != nil)
        #expect(m.zones.count == 1)
    }

    @Test func deleteWithoutRectangularNeighborRejects() {
        var m = GridModel(columns: 2)
        m.split(1, orientation: .horizontal, at: 0.5)   // left tall, right top/bottom
        let tall = m.orderedZones[0].id
        let r = m.deleteZone(tall); #expect(r == nil)
        #expect(m.zones.count == 3)
    }

    @Test func undoRedo() {
        var m = GridModel()
        m.split(1, orientation: .vertical, at: 0.5)
        m.merge([0, 1])
        #expect(m.hasChanges && m.canUndo && !m.canRedo)
        m.undo(); m.undo()
        #expect(sameRects(m.zoneRects, LayoutTemplates.columns(3)) && !m.hasChanges)
        let r = m.undo(); #expect(!r)
        let r2 = m.redo(); #expect(r2)
        #expect(m.zones.count == 4)
        m.undo()
        m.split(0, orientation: .horizontal, at: 0.5)   // new edit clears redo
        #expect(!m.canRedo)
    }

    @Test func revertDiscardsEverything() {
        var m = GridModel()
        m.split(0, orientation: .vertical, at: 0.1)
        m.revert()
        #expect(!m.hasChanges && !m.canUndo && sameRects(m.zoneRects, LayoutTemplates.columns(3)))
    }

    @Test func layoutRoundTrip() throws {
        var m = GridModel()
        m.split(1, orientation: .horizontal, at: 0.3)
        m.split(2, orientation: .vertical, at: 0.8)
        let layout = m.layout(id: "custom.x", name: "Mine")
        #expect(layout.kind == .grid && layout.isValid)
        let data = try JSONEncoder().encode(layout)
        let back = try JSONDecoder().decode(Layout.self, from: data)
        let m2 = try #require(GridModel(layout: back))
        #expect(m2.zones.count == m.zones.count)
        for (a, b) in zip(m.zoneRects, m2.zoneRects) {
            #expect(near(a.x, b.x) && near(a.y, b.y) && near(a.w, b.w) && near(a.h, b.h))
        }
    }

    @Test func importsBuiltInTilingsButNotOverlaps() {
        for id in ["builtin.columns", "builtin.rows", "builtin.grid", "builtin.priority-grid", LayoutTemplates.ultrawideID] {
            let l = LayoutTemplates.builtIn.first { $0.id == id }!
            let m = GridModel(layout: l)
            #expect(m != nil, "\(id)")
            if let m { #expect(m.zones.count == l.zones.count); expectTiles(m) }
        }
        #expect(GridModel(layout: LayoutTemplates.builtIn.first { $0.id == "builtin.focus" }!) == nil)
        #expect(GridModel(zones: [RelRect(x: 0, y: 0, w: 0.5, h: 1)]) == nil)   // leaves a gap
        #expect(GridModel(zones: []) == nil)
    }

    @Test func priorityGridDividers() throws {
        let m = try #require(GridModel(layout: LayoutTemplates.builtIn.first { $0.id == "builtin.priority-grid" }!))
        #expect(m.dividers.count == 3)   // two vertical segments (one per right-hand zone) + the horizontal one
        let h = try #require(m.dividers.first { $0.orientation == .horizontal })
        #expect(near(m.position(of: h), 0.5) && near(m.extent(of: h).from, 2.0 / 3) && near(m.extent(of: h).to, 1))
    }

    @Test func hitTesting() {
        var m = GridModel()
        #expect(m.zoneID(atX: 0.1, y: 0.5) == 0 && m.zoneID(atX: 0.5, y: 0.5) == 1 && m.zoneID(atX: 1, y: 1) == 2)
        #expect(m.divider(atX: 0.34, y: 0.5, toleranceX: 0.01, toleranceY: 0.01)?.boundary == 1)
        #expect(m.divider(atX: 0.45, y: 0.5, toleranceX: 0.01, toleranceY: 0.01) == nil)
        m.split(0, orientation: .horizontal, at: 0.5)
        // The horizontal divider exists only inside the left column.
        #expect(m.divider(atX: 0.1, y: 0.5, toleranceX: 0.01, toleranceY: 0.01)?.orientation == .horizontal)
        #expect(m.divider(atX: 0.5, y: 0.5, toleranceX: 0.01, toleranceY: 0.01) == nil)
        #expect(m.zoneIDs(intersecting: RelRect(x: 0.3, y: 0.1, w: 0.1, h: 0.1)).count == 2)
    }

    @Test func focusCycle() {
        let m = GridModel()
        let order = m.focusOrder
        #expect(order.count == 5)   // 3 zones + 2 dividers
        #expect(m.nextFocus(after: nil) == order.first)
        #expect(m.nextFocus(after: nil, reverse: true) == order.last)
        #expect(m.nextFocus(after: order.last) == order.first)
        #expect(m.nextFocus(after: order.first, reverse: true) == order.last)
        #expect(m.nextFocus(after: order[1]) == order[2])
        #expect(m.nextFocus(after: .zone(99)) == order.first)
    }

    @Test func manyRandomEditsAlwaysTile() {
        var m = GridModel()
        var seed: UInt64 = 12345
        func rnd() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 11) / Double(1 << 53) }
        for _ in 0..<300 {
            let ids = m.zones.map(\.id)
            switch Int(rnd() * 4) {
            case 0: m.split(ids[Int(rnd() * Double(ids.count))], orientation: rnd() < 0.5 ? .vertical : .horizontal, at: rnd())
            case 1: if let d = m.dividers.randomElement() { m.moveDivider(d, to: rnd()) }
            case 2: m.deleteZone(ids[Int(rnd() * Double(ids.count))])
            default: if m.canUndo, rnd() < 0.3 { m.undo() }
            }
            expectTiles(m)
            #expect(m.cols.allSatisfy { $0 >= GridModel.defaultMinSize - 1e-9 } && m.rows.allSatisfy { $0 >= GridModel.defaultMinSize - 1e-9 })
        }
    }
}

@Suite struct LayoutEditorSaveTests {
    private func stores() -> (ScreenLayoutStore, LayoutStore) {
        let defaults = UserDefaults(suiteName: "hephaestus-tests-\(UUID().uuidString)")!
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hephaestus-tests-\(UUID().uuidString)", isDirectory: true).appendingPathComponent("layouts.json")
        let layouts = LayoutStore(fileURL: url, defaults: defaults)
        return (ScreenLayoutStore(layouts: layouts, defaults: defaults), layouts)
    }

    @Test func saveAssignsToChosenScreens() {
        let (screens, layouts) = stores()
        let l = GridModel().layout(id: LayoutEditorSave.targetID(editing: nil), name: "Mine")
        #expect(l.id.hasPrefix("custom."))
        #expect(LayoutEditorSave.commit(l, assignTo: ["A", "B"], layouts: layouts, screens: screens))
        #expect(layouts.layout(id: l.id)?.name == "Mine")
        #expect(screens.layout(uuid: "A", orientation: .landscape).id == l.id)
        #expect(screens.layout(uuid: "B", orientation: .landscape).id == l.id)
        #expect(screens.assignments["C"] == nil)
    }

    @Test func editingCustomKeepsIdBuiltInGetsFreshId() {
        let custom = Layout(id: "custom.abc", name: "x", kind: .grid, zones: LayoutTemplates.columns(2))
        #expect(LayoutEditorSave.targetID(editing: custom) == "custom.abc")
        let builtIn = LayoutTemplates.builtIn[2]
        #expect(LayoutEditorSave.targetID(editing: builtIn) != builtIn.id)
        #expect(LayoutEditorSave.copyName(of: builtIn) == "\(builtIn.name) copy")
    }

    @Test func updateReplacesInPlace() {
        let (screens, layouts) = stores()
        var m = GridModel()
        LayoutEditorSave.commit(m.layout(id: "custom.1", name: "A"), assignTo: [], layouts: layouts, screens: screens)
        m.split(0, orientation: .horizontal, at: 0.5)
        LayoutEditorSave.commit(m.layout(id: "custom.1", name: "A2"), assignTo: [], layouts: layouts, screens: screens)
        #expect(layouts.custom.count == 1 && layouts.custom[0].zones.count == 4 && layouts.custom[0].name == "A2")
    }

    @Test func invalidNameAndBuiltInRejected() {
        let (screens, layouts) = stores()
        #expect(LayoutEditorSave.cleanName("   ") == nil)
        #expect(LayoutEditorSave.cleanName(" a ") == "a")
        let bad = GridModel().layout(id: "custom.z", name: " ")
        #expect(!LayoutEditorSave.commit(bad, assignTo: ["A"], layouts: layouts, screens: screens))
        #expect(screens.assignments.isEmpty)
        let builtin = GridModel().layout(id: LayoutTemplates.builtIn[2].id, name: "n")
        #expect(!LayoutEditorSave.commit(builtin, assignTo: ["A"], layouts: layouts, screens: screens))
    }
}

private func sameRects(_ a: [RelRect], _ b: [RelRect]) -> Bool {
    a.count == b.count && zip(a, b).allSatisfy { near($0.x, $1.x) && near($0.y, $1.y) && near($0.w, $1.w) && near($0.h, $1.h) }
}
