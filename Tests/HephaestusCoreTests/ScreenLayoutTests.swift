import Foundation
import Testing
@testable import HephaestusCore

private func makeStores() -> (ScreenLayoutStore, LayoutStore, UserDefaults) {
    let defaults = UserDefaults(suiteName: "hephaestus-tests-\(UUID().uuidString)")!
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("hephaestus-tests-\(UUID().uuidString)", isDirectory: true).appendingPathComponent("layouts.json")
    let layouts = LayoutStore(fileURL: url, defaults: defaults)
    return (ScreenLayoutStore(layouts: layouts, defaults: defaults), layouts, defaults)
}

@Suite struct ScreenLayoutTests {
    @Test func orientation() {
        #expect(ScreenOrientation(size: CGSize(width: 3440, height: 1440)) == .landscape)
        #expect(ScreenOrientation(size: CGSize(width: 1080, height: 1920)) == .portrait)
        #expect(ScreenOrientation(size: CGSize(width: 1000, height: 1000)) == .landscape)
    }

    @Test func unassignedFallsBackToActive() {
        let (s, layouts, _) = makeStores()
        #expect(s.layout(uuid: "A", orientation: .landscape).id == layouts.active.id)
    }

    @Test func orientationDefaultsApply() {
        let (s, layouts, _) = makeStores()
        let ids = layouts.all.map(\.id)
        #expect(ids.count >= 3)
        s.setDefaultLayout(id: ids[1], for: .portrait)
        #expect(s.layout(uuid: "P", orientation: .portrait).id == ids[1])
        #expect(s.layout(uuid: "L", orientation: .landscape).id == layouts.active.id)
    }

    @Test func assignmentPersistsPerUUID() {
        let (s, layouts, defaults) = makeStores()
        let ids = layouts.all.map(\.id)
        s.setLayout(id: ids[1], uuid: "A")
        #expect(s.layout(uuid: "A", orientation: .landscape).id == ids[1])
        #expect(s.layout(uuid: "B", orientation: .landscape).id == layouts.active.id)
        let reloaded = ScreenLayoutStore(layouts: layouts, defaults: defaults)
        #expect(reloaded.layout(uuid: "A", orientation: .landscape).id == ids[1])
    }

    @Test func unknownIDsAreIgnoredOrFallBack() {
        let (s, layouts, _) = makeStores()
        s.setLayout(id: "nope", uuid: "A")
        #expect(s.assignments.isEmpty)
        s.setDefaultLayout(id: "nope", for: .landscape)
        #expect(s.layout(uuid: "A", orientation: .landscape).id == layouts.active.id)
        // A deleted custom layout falls back to the default.
        let custom = Layout(id: "custom.x", name: "X", kind: .grid, zones: [RelRect(x: 0, y: 0, w: 1, h: 1)])
        #expect(layouts.upsert(custom))
        s.setLayout(id: "custom.x", uuid: "A")
        #expect(s.layout(uuid: "A", orientation: .landscape).id == "custom.x")
        layouts.remove(id: "custom.x")
        #expect(s.layout(uuid: "A", orientation: .landscape).id == layouts.active.id)
    }

    @Test func materializePinsDefaultsForNewDisplaysOnly() {
        let (s, layouts, _) = makeStores()
        let ids = layouts.all.map(\.id)
        s.setDefaultLayout(id: ids[1], for: .portrait)
        s.setLayout(id: ids[2], uuid: "OLD")
        #expect(s.materialize([("OLD", .landscape), ("NEW", .portrait)]))
        #expect(s.assignments["OLD"] == ids[2])
        #expect(s.assignments["NEW"] == ids[1])
        // Changing the default later does not move an already-pinned display.
        s.setDefaultLayout(id: ids[0], for: .portrait)
        #expect(s.layout(uuid: "NEW", orientation: .portrait).id == ids[1])
        #expect(!s.materialize([("OLD", .landscape), ("NEW", .portrait)]))
    }

    @Test func notifiesOnChange() {
        let (s, layouts, _) = makeStores()
        nonisolated(unsafe) var count = 0
        let token = NotificationCenter.default.addObserver(forName: ScreenLayoutStore.didChange, object: s, queue: nil) { _ in count += 1 }
        s.setLayout(id: layouts.all[1].id, uuid: "A")
        s.clearAssignment(uuid: "A")
        NotificationCenter.default.removeObserver(token)
        #expect(count == 2)
    }
}
