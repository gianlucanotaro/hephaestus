import Foundation
import Testing
@testable import HephaestusCore

/// The pre-layout-model algorithm, copied verbatim, as the parity reference.
private func oldUltrawide(_ frame: CGRect, aspect: CGFloat, gap: CGFloat) -> [CGRect] {
    var centerW = frame.height * aspect
    if (frame.width - centerW) / 2 < frame.width * 0.10 { centerW = frame.width * 0.5 }
    let sideW = (frame.width - centerW) / 2
    let inset = gap / 2
    func r(_ x: CGFloat, _ w: CGFloat) -> CGRect {
        CGRect(x: x, y: frame.minY, width: w, height: frame.height).insetBy(dx: inset, dy: inset)
    }
    return [r(frame.minX, sideW), r(frame.minX + sideW, centerW), r(frame.minX + sideW + centerW, sideW)]
}

private func tempURL(_ name: String = "layouts.json") -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("hephaestus-tests-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent(name)
}

private func makeStore(_ url: URL = tempURL()) -> LayoutStore {
    LayoutStore(fileURL: url, defaults: UserDefaults(suiteName: "hephaestus-tests-\(UUID().uuidString)")!)
}

@Suite struct GeometryTests {
    @Test func ultrawideParity() {
        let frames = [CGRect(x: 0, y: 25, width: 3440, height: 1415), CGRect(x: -1440, y: 0, width: 1440, height: 900),
                      CGRect(x: 100, y: 50, width: 1512, height: 944), CGRect(x: 0, y: 0, width: 5120, height: 1440)]
        for frame in frames {
            for gap in [0, 8, 24] as [CGFloat] {
                let new = ZoneLayout.zones(layout: LayoutTemplates.ultrawide, in: frame, centerAspect: 16.0 / 9, gap: gap)
                #expect(new == oldUltrawide(frame, aspect: 16.0 / 9, gap: gap))
            }
        }
    }

    @Test func ultrawideNarrowFallbackIs25_50_25() {
        let z = ZoneLayout.zones(layout: LayoutTemplates.ultrawide, in: CGRect(x: 0, y: 0, width: 1600, height: 1000),
                                 centerAspect: 16.0 / 9, gap: 0)
        #expect(z.map(\.width) == [400, 800, 400])
    }

    @Test func templateZoneCounts() {
        let counts = Dictionary(uniqueKeysWithValues: LayoutTemplates.builtIn.map { ($0.name, $0.zones.count) })
        #expect(counts == ["Ultrawide 3-way": 3, "Focus": 3, "Columns": 3, "Rows": 3, "Grid": 6, "Priority Grid": 3])
        #expect(LayoutTemplates.builtIn.allSatisfy { $0.isValid })
        #expect(LayoutTemplates.builtIn[0].id == LayoutTemplates.defaultID)
    }

    @Test func templateBoundsStayInsideFrame() {
        let frame = CGRect(x: 10, y: 20, width: 1000, height: 600)
        for layout in LayoutTemplates.builtIn {
            for r in ZoneLayout.zones(layout: layout, in: frame, gap: 0) {
                #expect(frame.contains(r.insetBy(dx: 0.001, dy: 0.001)))
            }
        }
    }

    @Test func columnsRowsGridGeometry() {
        let frame = CGRect(x: 0, y: 0, width: 900, height: 600)
        let cols = ZoneLayout.zones(layout: LayoutTemplates.builtIn[2], in: frame, gap: 0)
        #expect(cols == [CGRect(x: 0, y: 0, width: 300, height: 600), CGRect(x: 300, y: 0, width: 300, height: 600),
                         CGRect(x: 600, y: 0, width: 300, height: 600)])
        // Rows: zone 0 is the TOP row, which in AppKit space has the highest y.
        let rows = ZoneLayout.zones(layout: LayoutTemplates.builtIn[3], in: frame, gap: 0)
        #expect(rows[0] == CGRect(x: 0, y: 400, width: 900, height: 200))
        #expect(rows[2] == CGRect(x: 0, y: 0, width: 900, height: 200))
        let grid = ZoneLayout.zones(layout: LayoutTemplates.builtIn[4], in: frame, gap: 0)
        #expect(grid[0] == CGRect(x: 0, y: 300, width: 300, height: 300))
        #expect(grid[5] == CGRect(x: 600, y: 0, width: 300, height: 300))
        #expect(ZoneLayout.zones(layout: LayoutTemplates.builtIn[5], in: frame, gap: 0).count == 3)
    }

    @Test func gapInsetsEveryZone() {
        let z = ZoneLayout.zones(layout: LayoutTemplates.builtIn[2], in: CGRect(x: 0, y: 0, width: 900, height: 600), gap: 10)
        #expect(z[0] == CGRect(x: 5, y: 5, width: 290, height: 590))
    }

    @Test func snapSlots() {
        #expect(SnapSlot.first.index(count: 3) == 0)
        #expect(SnapSlot.middle.index(count: 3) == 1)
        #expect(SnapSlot.last.index(count: 3) == 2)
        #expect(SnapSlot.last.index(count: 6) == 5)
        #expect(SnapSlot.middle.index(count: 1) == 0)
    }

    @Test func selectionAndBoundingRect() {
        let zones = ZoneLayout.zones(layout: LayoutTemplates.builtIn[2], in: CGRect(x: 0, y: 0, width: 900, height: 600), gap: 8)
        #expect(ZoneLayout.selection(at: CGPoint(x: 150, y: 300), in: zones, gap: 8) == [0])
        #expect(ZoneLayout.selection(at: CGPoint(x: 450, y: 300), in: zones, gap: 8) == [1])
        // Near the shared edge between zones 0 and 1 (x = 300) both are selected.
        #expect(ZoneLayout.selection(at: CGPoint(x: 298, y: 300), in: zones, gap: 8) == [0, 1])
        #expect(ZoneLayout.selection(at: CGPoint(x: -500, y: 300), in: zones, gap: 8).isEmpty)
        let bounds = ZoneLayout.boundingRect(of: [0, 2], in: zones)
        #expect(bounds == zones[0].union(zones[2]))
        #expect(ZoneLayout.boundingRect(of: [], in: zones) == nil)
        #expect(ZoneLayout.boundingRect(of: [7], in: zones) == nil)
    }
}

@Suite struct PersistenceTests {
    private let custom = Layout(id: "custom.a", name: "Mine", kind: .canvas,
                                zones: [RelRect(x: 0, y: 0, w: 0.5, h: 1), RelRect(x: 0.5, y: 0.25, w: 0.5, h: 0.5)])

    @Test func jsonRoundTrip() throws {
        for layout in LayoutTemplates.builtIn + [custom] {
            let data = try LayoutStore.encode(layout)
            #expect(try JSONDecoder().decode(Layout.self, from: data) == layout)
        }
    }

    @Test func saveAndReload() {
        let url = tempURL()
        let store = makeStore(url)
        #expect(store.upsert(custom))
        #expect(FileManager.default.fileExists(atPath: url.path))
        let reloaded = makeStore(url)
        #expect(reloaded.custom == [custom])
        #expect(reloaded.layout(id: "custom.a") == custom)
    }

    @Test func missingFileIsFine() {
        let store = makeStore()
        #expect(store.custom.isEmpty)
        #expect(store.all.count == LayoutTemplates.builtIn.count)
    }

    @Test func corruptFileIsToleratedAndMovedAside() throws {
        let url = tempURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ not json ]]".utf8).write(to: url)
        let store = makeStore(url)
        #expect(store.custom.isEmpty)
        #expect(FileManager.default.fileExists(atPath: url.appendingPathExtension("corrupt").path))
        #expect(store.upsert(custom))   // still usable afterwards
    }

    @Test func invalidAndDuplicateLayoutsAreDropped() {
        let bad = Layout(id: "custom.bad", name: "Bad", kind: .canvas, zones: [RelRect(x: 0.8, y: 0, w: 0.5, h: 1)])
        let empty = Layout(id: "custom.empty", name: "Empty", kind: .grid, zones: [])
        let clash = Layout(id: LayoutTemplates.ultrawideID, name: "Clash", kind: .canvas, zones: [RelRect(x: 0, y: 0, w: 1, h: 1)])
        #expect(LayoutStore.sanitize([bad, empty, clash, custom, custom]) == [custom])
        #expect(!makeStore().upsert(clash))
    }

    @Test func activeLayoutFallsBackToDefault() {
        let store = makeStore()
        #expect(store.active.id == LayoutTemplates.defaultID)
        store.setActive(id: "does.not.exist")
        #expect(store.active.id == LayoutTemplates.defaultID)
        store.setActive(id: "builtin.grid")
        #expect(store.active.name == "Grid")
    }

    @Test func importExport() throws {
        let store = makeStore()
        let file = tempURL("export.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try store.export(LayoutTemplates.builtIn[4], to: file)
        // Importing a built-in gets a fresh id and becomes a custom layout.
        let imported = try store.importLayout(from: file)
        #expect(imported.id != "builtin.grid")
        #expect(imported.kind == .canvas)
        #expect(imported.zones == LayoutTemplates.builtIn[4].zones)
        #expect(store.custom == [imported])

        try Data("{\"nope\": 1}".utf8).write(to: file)
        #expect(throws: LayoutIOError.self) { try store.importLayout(from: file) }
    }
}
