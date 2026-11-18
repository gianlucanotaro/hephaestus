import CoreGraphics
import Foundation
import Testing
@testable import HephaestusCore

@Suite struct NewWindowPlacementTests {
    typealias M = NewWindowPlacementMath

    private func ctx(_ edit: (inout M.Context) -> Void = { _ in }) -> M.Context {
        var c = M.Context(lastZoneSetting: true, activeScreenSetting: false, placeable: true, appHidden: false,
                          alreadyTracked: false, createdInZone: false, stillAtCreationFrame: true, hasLastZone: true)
        edit(&c)
        return c
    }

    @Test func decisionBasics() {
        #expect(M.decide(ctx()) == .lastZone)
        #expect(M.decide(ctx { $0.hasLastZone = false }) == .skip)
        #expect(M.decide(ctx { $0.hasLastZone = false; $0.activeScreenSetting = true }) == .activeScreen)
        #expect(M.decide(ctx { $0.lastZoneSetting = false; $0.activeScreenSetting = true }) == .activeScreen)
        #expect(M.decide(ctx { $0.lastZoneSetting = false }) == .skip)
    }

    @Test func decisionGates() {
        #expect(M.decide(ctx { $0.placeable = false }) == .skip)
        #expect(M.decide(ctx { $0.appHidden = true }) == .skip)
        #expect(M.decide(ctx { $0.alreadyTracked = true }) == .skip)
        #expect(M.decide(ctx { $0.createdInZone = true }) == .skip)
        #expect(M.decide(ctx { $0.stillAtCreationFrame = false }) == .skip)
    }

    @Test func placeableTraits() {
        let ok = M.WindowTraits(role: "AXWindow", subrole: "AXStandardWindow")
        #expect(M.isPlaceable(ok))
        var t = ok; t.subrole = "AXDialog"; #expect(!M.isPlaceable(t))
        t = ok; t.subrole = "AXFloatingWindow"; #expect(!M.isPlaceable(t))
        t = ok; t.role = "AXSheet"; #expect(!M.isPlaceable(t))
        t = ok; t.subrole = nil; #expect(!M.isPlaceable(t))
        t = ok; t.minimized = true; #expect(!M.isPlaceable(t))
        t = ok; t.fullscreen = true; #expect(!M.isPlaceable(t))
        t = ok; t.modal = true; #expect(!M.isPlaceable(t))
    }

    private let a = M.ScreenGeometry(uuid: "A", visibleFrame: CGRect(x: 0, y: 0, width: 300, height: 100),
        zones: [CGRect(x: 0, y: 0, width: 100, height: 100), CGRect(x: 100, y: 0, width: 100, height: 100),
                CGRect(x: 200, y: 0, width: 100, height: 100)])
    private let b = M.ScreenGeometry(uuid: "B", visibleFrame: CGRect(x: 300, y: 0, width: 200, height: 100),
        zones: [CGRect(x: 300, y: 0, width: 100, height: 100), CGRect(x: 400, y: 0, width: 100, height: 100)])

    @Test func zoneResolution() {
        let last = LastAssignment(zones: [1], layoutID: "x", screenUUID: "A")
        #expect(M.resolveZoneTarget(last: last, screens: [a, b], activeUUID: "B")?.rect == a.zones[1])
        // remembered screen gone -> active screen
        let t = M.resolveZoneTarget(last: last, screens: [b], activeUUID: "B")
        #expect(t?.screenUUID == "B" && t?.rect == b.zones[1])
        // fewer zones -> clamped to last
        let high = LastAssignment(zones: [2], layoutID: "x", screenUUID: "B")
        let c = M.resolveZoneTarget(last: high, screens: [a, b], activeUUID: "A")
        #expect(c?.zones == [1] && c?.rect == b.zones[1])
        // multi-zone spans
        let span = LastAssignment(zones: [0, 1], layoutID: "x", screenUUID: "A")
        #expect(M.resolveZoneTarget(last: span, screens: [a], activeUUID: nil)?.rect == CGRect(x: 0, y: 0, width: 200, height: 100))
        #expect(M.resolveZoneTarget(last: last, screens: [], activeUUID: nil) == nil)
    }

    @Test func clampInside() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        #expect(M.clamp(CGRect(x: 90, y: -20, width: 30, height: 30), into: bounds) == CGRect(x: 70, y: 0, width: 30, height: 30))
        #expect(M.clamp(CGRect(x: 0, y: 0, width: 300, height: 50), into: bounds) == CGRect(x: 0, y: 0, width: 100, height: 50))
    }

    @Test func activeScreenFrames() {
        let target = CGRect(x: 1000, y: 0, width: 500, height: 400)
        let src = CGRect(x: 0, y: 0, width: 800, height: 400)
        let w = CGRect(x: 100, y: 50, width: 200, height: 100)
        #expect(M.activeScreenFrame(window: w, from: src, to: target) == CGRect(x: 1100, y: 50, width: 200, height: 100))
        // offset would overflow -> clamped
        let w2 = CGRect(x: 700, y: 50, width: 200, height: 100)
        #expect(M.activeScreenFrame(window: w2, from: src, to: target) == CGRect(x: 1300, y: 50, width: 200, height: 100))
        // unknown source -> centered
        #expect(M.activeScreenFrame(window: w, from: nil, to: target) == CGRect(x: 1150, y: 150, width: 200, height: 100))
        // already there -> no move
        #expect(M.activeScreenFrame(window: CGRect(x: 1100, y: 50, width: 200, height: 100), from: target, to: target) == nil)
    }

    @Test func insideZoneAndActiveScreen() {
        #expect(M.isInsideZone(a.zones[1].offsetBy(dx: 3, dy: 2), zones: a.zones))
        #expect(!M.isInsideZone(CGRect(x: 10, y: 10, width: 50, height: 50), zones: a.zones))
        let frames = [(uuid: "A", frame: a.visibleFrame), (uuid: "B", frame: b.visibleFrame)]
        #expect(M.activeScreenUUID(cursor: CGPoint(x: 350, y: 10), frames: frames, fallback: "A") == "B")
        #expect(M.activeScreenUUID(cursor: CGPoint(x: 9999, y: 10), frames: frames, fallback: "A") == "A")
    }
}
