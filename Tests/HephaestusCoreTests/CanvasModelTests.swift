import Foundation
import Testing
@testable import HephaestusCore

private func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }
private let screen = CGSize(width: 2000, height: 1000)

@Suite struct CanvasModelTests {
    @Test func startsWithOneValidZone() {
        let m = CanvasModel(screenSize: screen)
        #expect(m.zones.count == 1)
        #expect(m.zones[0].rect.isValid)
        #expect(m.selectedID == m.zones[0].id)
        #expect(!m.hasChanges && !m.canUndo)
    }

    @Test func addOffsetsFromSelectedAndSelectsNew() throws {
        var m = CanvasModel(screenSize: screen)
        let first = m.zones[0].rect
        let id = m.addZone()
        #expect(m.zones.count == 2 && m.selectedID == id && m.zones.last?.id == id)
        let added = try #require(m.zone(id: id)).rect
        #expect(near(added.x, first.x + CanvasModel.cascadeStep) && near(added.y, first.y + CanvasModel.cascadeStep))
        #expect(added.w == CanvasModel.defaultZoneSize.w)
        #expect(m.canUndo)
    }

    @Test func addWrapsWhenOffScreen() {
        var m = CanvasModel(screenSize: screen)
        for _ in 0..<30 { m.addZone() }
        #expect(m.zones.allSatisfy { $0.rect.isValid })
        #expect(Set(m.zones.map(\.id)).count == 31)
    }

    @Test func addAtPointIsCenteredAndClamped() throws {
        var m = CanvasModel(screenSize: screen)
        let a = m.addZone(centeredAtX: 0.5, y: 0.5)
        let r = try #require(m.zone(id: a)).rect
        #expect(near(r.x + r.w / 2, 0.5) && near(r.y + r.h / 2, 0.5))
        let b = m.addZone(centeredAtX: 0.999, y: 0.001)
        let rb = try #require(m.zone(id: b)).rect
        #expect(rb.isValid && near(rb.x + rb.w, 1) && near(rb.y, 0))
    }

    @Test func moveClampsToScreen() throws {
        var m = CanvasModel(screenSize: screen)
        let id = m.zones[0].id
        let r1 = m.move(id, dx: 5, dy: 5)
        #expect(r1)
        let r = try #require(m.zone(id: id)).rect
        #expect(near(r.x + r.w, 1) && near(r.y + r.h, 1) && near(r.w, 0.3))
        let noop = m.move(id, dx: 1, dy: 1)   // already at the corner: no change, no undo step
        #expect(!noop)
        let r2 = m.move(id, dx: -9, dy: -9)
        #expect(r2)
        #expect(m.zones[0].rect.x == 0 && m.zones[0].rect.y == 0)
    }

    @Test func resizeEachHandleKeepsOppositeEdge() {
        let m = CanvasModel(screenSize: screen)
        let r = RelRect(x: 0.4, y: 0.4, w: 0.2, h: 0.2)
        for h in ResizeHandle.allCases {
            let out = m.resized(r, handle: h, dx: 0.05, dy: 0.05)
            #expect(out.isValid)
            if !h.movesLeft { #expect(near(out.x, r.x)) }
            if !h.movesRight { #expect(near(out.x + out.w, r.x + r.w)) }
            if !h.movesTop { #expect(near(out.y, r.y)) }
            if !h.movesBottom { #expect(near(out.y + out.h, r.y + r.h)) }
        }
        let br = m.resized(r, handle: .bottomRight, dx: 0.1, dy: 0.05)
        #expect(near(br.w, 0.3) && near(br.h, 0.25))
        let tl = m.resized(r, handle: .topLeft, dx: -0.1, dy: -0.05)
        #expect(near(tl.x, 0.3) && near(tl.y, 0.35) && near(tl.w, 0.3) && near(tl.h, 0.25))
    }

    @Test func resizeHonorsMinimumSizeAndScreenBounds() {
        let m = CanvasModel(screenSize: screen)   // 40 px min = 0.02 wide, 0.04 tall
        let r = RelRect(x: 0.4, y: 0.4, w: 0.2, h: 0.2)
        let shrunk = m.resized(r, handle: .bottomRight, dx: -0.5, dy: -0.5)
        #expect(near(shrunk.w, m.minWidth) && near(shrunk.h, m.minHeight))
        #expect(near(shrunk.x, 0.4) && near(shrunk.y, 0.4))
        let pastLeft = m.resized(r, handle: .left, dx: 0.9, dy: 0)   // drag left edge across the right edge
        #expect(near(pastLeft.x + pastLeft.w, 0.6) && near(pastLeft.w, m.minWidth))
        let grown = m.resized(r, handle: .topLeft, dx: -5, dy: -5)
        #expect(near(grown.x, 0) && near(grown.y, 0) && near(grown.x + grown.w, 0.6))
        let grownBR = m.resized(r, handle: .bottomRight, dx: 5, dy: 5)
        #expect(near(grownBR.x + grownBR.w, 1) && near(grownBR.y + grownBR.h, 1))
    }

    @Test func keyboardStepsConvertPixelsToRelative() throws {
        var m = CanvasModel(screenSize: screen)   // 2000 x 1000 pt
        let id = m.zones[0].id
        let r0 = m.zones[0].rect
        let r3 = m.nudge(id, dxPx: 10, dyPx: 0)
        #expect(r3)
        #expect(near(m.zones[0].rect.x, r0.x + 10.0 / 2000))
        let r4 = m.nudge(id, dxPx: 0, dyPx: -1)
        #expect(r4)
        #expect(near(m.zones[0].rect.y, r0.y - 1.0 / 1000))
        let r5 = m.resizeBy(id, dwPx: 10, dhPx: 0)
        #expect(r5)
        #expect(near(m.zones[0].rect.w, r0.w + 10.0 / 2000) && near(m.zones[0].rect.h, r0.h))
        let r6 = m.resizeBy(id, dwPx: 0, dhPx: -2)
        #expect(r6)
        #expect(near(m.zones[0].rect.h, r0.h - 2.0 / 1000))
        #expect(CanvasKeyboard.step(resize: false, fine: false) == 10)
        #expect(CanvasKeyboard.step(resize: false, fine: true) == 1)
        #expect(CanvasKeyboard.step(resize: true, fine: false) == 10)
        #expect(CanvasKeyboard.step(resize: true, fine: true) == 2)
    }

    @Test func deleteKeepsAtLeastOneZoneAndSelectsNeighbor() {
        var m = CanvasModel(screenSize: screen)
        let r7 = m.deleteZone(m.zones[0].id)
        #expect(!r7)
        let a = m.zones[0].id, b = m.addZone(), c = m.addZone()
        let r8 = m.deleteZone(b)
        #expect(r8)
        #expect(m.zones.map(\.id) == [a, c] && m.selectedID == c)
        let r9 = m.deleteZone(c)
        #expect(r9)
        #expect(m.selectedID == a)
        let r10 = m.deleteZone(999)
        #expect(!r10)
    }

    @Test func tabCyclesSelection() {
        var m = CanvasModel(screenSize: screen)
        let a = m.zones[0].id, b = m.addZone(), c = m.addZone()
        #expect(m.selectedID == c)
        m.selectNext(); #expect(m.selectedID == a)
        m.selectNext(); #expect(m.selectedID == b)
        m.selectNext(reverse: true); #expect(m.selectedID == a)
        m.selectNext(reverse: true); #expect(m.selectedID == c)
        m.select(nil); m.selectNext(); #expect(m.selectedID == a)
        m.select(12345); #expect(m.selectedID == nil)
    }

    @Test func zOrderRenumbersZones() {
        var m = CanvasModel(screenSize: screen)
        let a = m.zones[0].id, b = m.addZone(), c = m.addZone()
        let r11 = m.reorder(a, .front)
        #expect(r11)
        #expect(m.zones.map(\.id) == [b, c, a])
        let r12 = m.reorder(a, .back)
        #expect(r12)
        #expect(m.zones.map(\.id) == [a, b, c])
        let r13 = m.reorder(a, .forward)
        #expect(r13)
        #expect(m.zones.map(\.id) == [b, a, c])
        let r14 = m.reorder(a, .backward)
        #expect(r14)
        #expect(m.zones.map(\.id) == [a, b, c])
        let r15 = m.reorder(a, .backward)
        #expect(!r15)
        let r16 = m.reorder(c, .front)
        #expect(!r16)
        #expect(m.zoneIndex(of: c) == 2)
        m.undo(); m.undo()
        #expect(m.zones.map(\.id) == [a, b, c])
    }

    @Test func hitTestingTopmostAndHandles() {
        var m = CanvasModel(screenSize: screen)
        let a = m.zones[0].id
        m.move(a, dx: -9, dy: -9)                       // a: (0,0,0.3,0.3)
        let b = m.addZone(centeredAtX: 0.2, y: 0.2)     // b overlaps a, on top
        #expect(m.zoneID(atX: 0.2, y: 0.2) == b)
        #expect(m.zoneID(atX: 0.01, y: 0.01) == a)
        #expect(m.zoneID(atX: 0.9, y: 0.9) == nil)
        let rb = m.zone(id: b)!.rect
        let hit = m.hit(atX: rb.x + rb.w, y: rb.y + rb.h, toleranceX: 0.005, toleranceY: 0.005)
        #expect(hit?.id == b && hit?.handle == .bottomRight)
        let mid = m.hit(atX: rb.x + rb.w / 2, y: rb.y, toleranceX: 0.005, toleranceY: 0.005)
        #expect(mid?.handle == .top)
        #expect(m.hit(atX: rb.x + rb.w / 2, y: rb.y + rb.h / 2, toleranceX: 0.005, toleranceY: 0.005)?.handle == nil)
        #expect(m.hit(atX: 0.9, y: 0.9, toleranceX: 0.005, toleranceY: 0.005) == nil)
    }

    // MARK: Undo

    @Test func dragGestureIsOneUndoStep() {
        var m = CanvasModel(screenSize: screen)
        let id = m.zones[0].id
        let start = m.zones[0].rect
        m.beginGesture()
        for i in 1...20 { m.setRect(id, CanvasModel.moved(start, dx: Double(i) * 0.01, dy: 0)) }
        m.endGesture()
        #expect(!near(m.zones[0].rect.x, start.x))
        let r17 = m.undo()
        #expect(r17)
        #expect(m.zones[0].rect == start)
        #expect(!m.canUndo)
        let r18 = m.redo()
        #expect(r18)
        #expect(near(m.zones[0].rect.x, start.x + 0.2))
    }

    @Test func emptyGestureAddsNoUndoStep() {
        var m = CanvasModel(screenSize: screen)
        m.beginGesture(); m.endGesture()
        #expect(!m.canUndo)
        let id = m.zones[0].id
        m.beginGesture()
        m.move(id, dx: 0.1, dy: 0); m.move(id, dx: -0.1, dy: 0)   // dragged back to the start
        m.endGesture()
        #expect(!m.canUndo)
    }

    @Test func undoRedoAddDeleteAndNewEditClearsRedo() {
        var m = CanvasModel(screenSize: screen)
        let a = m.zones[0].id
        let b = m.addZone()
        m.deleteZone(a)
        #expect(m.zones.map(\.id) == [b])
        m.undo(); #expect(m.zones.map(\.id) == [a, b])
        m.undo(); #expect(m.zones.map(\.id) == [a] && m.selectedID == a)
        #expect(m.canRedo)
        m.addZone()
        #expect(!m.canRedo)
        // ids are not reused after undo
        #expect(Set(m.zones.map(\.id)).count == m.zones.count)
    }

    @Test func revertRestoresOpeningState() {
        var m = CanvasModel(layout: Layout(id: "custom.x", name: "X", kind: .canvas, zones: LayoutTemplates.focus()), screenSize: screen)!
        let before = m.zoneRects
        m.addZone(); m.move(m.zones[0].id, dx: 0.1, dy: 0); m.deleteZone(m.zones[1].id)
        #expect(m.hasChanges)
        m.revert()
        #expect(m.zoneRects == before && !m.hasChanges && !m.canUndo && !m.canRedo)
    }

    // MARK: Layout conversion

    @Test func opensFocusBuiltInAsCanvasInOrder() throws {
        let focus = try #require(LayoutTemplates.builtIn.first { $0.id == "builtin.focus" })
        let m = try #require(CanvasModel(layout: focus, screenSize: screen))
        #expect(m.zoneRects == focus.zones)
        #expect(m.layout(id: "custom.f", name: "F").kind == .canvas)
    }

    @Test func opensGridAndTemplateLayouts() throws {
        let grid = Layout(id: "custom.g", name: "G", kind: .grid, zones: LayoutTemplates.priorityGrid())
        #expect(CanvasModel(layout: grid, screenSize: screen)?.zones.count == 3)
        #expect(CanvasModel(layout: LayoutTemplates.ultrawide, screenSize: screen)?.zones.count == 3)
        let bad = Layout(id: "custom.b", name: "B", kind: .canvas, zones: [RelRect(x: 0.9, y: 0, w: 0.5, h: 1)])
        #expect(CanvasModel(layout: bad, screenSize: screen) == nil)
    }

    @Test func overlappingZonesRoundTripThroughStoreWithOrder() throws {
        var m = CanvasModel(screenSize: screen)
        m.addZone(); m.addZone(); m.addZone()
        let first = m.zones[0].id
        m.reorder(first, .front)                       // change z-order so the order is not creation order
        let rects = m.zoneRects
        // They really overlap.
        #expect(m.zones.count == 4 && m.zoneID(atX: 0.5, y: 0.5) != nil)

        let defaults = UserDefaults(suiteName: "hephaestus-tests-\(UUID().uuidString)")!
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hephaestus-tests-\(UUID().uuidString)", isDirectory: true).appendingPathComponent("layouts.json")
        let store = LayoutStore(fileURL: url, defaults: defaults)
        let layout = m.layout(id: "custom.overlap", name: "Overlap")
        #expect(store.upsert(layout))

        let reloaded = LayoutStore(fileURL: url, defaults: defaults)
        let loaded = try #require(reloaded.layout(id: "custom.overlap"))
        #expect(loaded.kind == .canvas)
        #expect(loaded.zones == rects)                  // identical rects, identical order
        let reopened = try #require(CanvasModel(layout: loaded, screenSize: screen))
        #expect(reopened.zoneRects == rects)
        #expect(!reopened.hasChanges)
    }

    @Test func jsonRoundTripPreservesOrder() throws {
        var m = CanvasModel(screenSize: screen)
        m.addZone(); m.addZone()
        let layout = m.layout(id: "custom.j", name: "J")
        let data = try JSONEncoder().encode(layout)
        #expect(try JSONDecoder().decode(Layout.self, from: data) == layout)
    }
}

@Suite struct LayoutEditorRoutingTests {
    @Test func routesByKind() {
        let canvas = Layout(id: "custom.c", name: "C", kind: .canvas, zones: LayoutTemplates.focus())
        let grid = Layout(id: "custom.g", name: "G", kind: .grid, zones: LayoutTemplates.columns(3))
        let focus = LayoutTemplates.builtIn.first { $0.id == "builtin.focus" }!
        let columns = LayoutTemplates.builtIn.first { $0.id == "builtin.columns" }!
        #expect(LayoutEditors.route(for: canvas) == .canvas)
        #expect(LayoutEditors.route(for: grid) == .grid)
        #expect(LayoutEditors.route(for: focus) == .canvas)
        #expect(LayoutEditors.route(for: columns) == .grid)
        #expect(LayoutEditors.canCopyAsCanvas(grid) && !LayoutEditors.canCopyAsCanvas(canvas))
        let invalid = Layout(id: "custom.i", name: "I", kind: .canvas, zones: [])
        #expect(LayoutEditors.route(for: invalid) == nil && !LayoutEditors.canEdit(invalid))
    }
}
