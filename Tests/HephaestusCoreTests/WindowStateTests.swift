import CoreGraphics
import Foundation
import Testing
@testable import HephaestusCore

@Suite struct WindowStateTests {
    @Test func frameMatchTolerance() {
        let a = CGRect(x: 0, y: 0, width: 100, height: 100)
        #expect(WindowStateMath.frameMatches(a, a.offsetBy(dx: 5, dy: -5)))
        #expect(!WindowStateMath.frameMatches(a, a.offsetBy(dx: 20, dy: 0)))
        #expect(!WindowStateMath.frameMatches(a, CGRect(x: 0, y: 0, width: 130, height: 100)))
    }

    @Test func unsnapKeepsCursorProportion() {
        let current = CGRect(x: 100, y: 100, width: 400, height: 200)
        let f = WindowStateMath.unsnapFrame(current: current, cursor: CGPoint(x: 300, y: 150),
                                            restoreSize: CGSize(width: 200, height: 100))
        #expect(f.size == CGSize(width: 200, height: 100))
        // cursor was at 50% / 25% of the window; still is
        #expect(f.minX == 200 && f.minY == 125)
    }

    @Test func unsnapClampsCursorOutsideWindow() {
        let f = WindowStateMath.unsnapFrame(current: CGRect(x: 0, y: 0, width: 100, height: 100),
                                            cursor: CGPoint(x: 500, y: -50), restoreSize: CGSize(width: 40, height: 40))
        #expect(f.maxX == 500 && f.minY == -50)
    }

    @Test func clampZones() {
        #expect(WindowStateMath.clampZones([0, 4, 5], count: 3) == [0, 2])
        #expect(WindowStateMath.clampZones([1], count: 3) == [1])
        #expect(WindowStateMath.clampZones([1], count: 0) == [])
    }

    @Test func reapplyTargetSpansAndClamps() {
        let zones = [CGRect(x: 0, y: 0, width: 10, height: 10), CGRect(x: 10, y: 0, width: 10, height: 10)]
        #expect(WindowStateMath.reapplyTarget(zones: [0, 1], in: zones) == CGRect(x: 0, y: 0, width: 20, height: 10))
        #expect(WindowStateMath.reapplyTarget(zones: [7], in: zones) == zones[1])
        #expect(WindowStateMath.reapplyTarget(zones: [0], in: []) == nil)
    }

    @Test func resolveScreen() {
        #expect(WindowStateMath.resolveScreen(home: "a", available: ["a", "b"], fallback: "b") == "a")
        #expect(WindowStateMath.resolveScreen(home: "x", available: ["a", "b"], fallback: "b") == "b")
        #expect(WindowStateMath.resolveScreen(home: "x", available: ["a"], fallback: nil) == "a")
        #expect(WindowStateMath.resolveScreen(home: "x", available: [], fallback: nil) == nil)
    }

    @Test func preSnapFrameBookkeeping() {
        let pre = CGRect(x: 1, y: 1, width: 500, height: 400)
        let zoneA = CGRect(x: 0, y: 0, width: 300, height: 800)
        #expect(WindowStateMath.preSnapFrame(existing: nil, current: pre) == pre)
        // moving zone-to-zone (window still in zone A) keeps the original pre-snap frame
        #expect(WindowStateMath.preSnapFrame(existing: (pre, zoneA), current: zoneA) == pre)
        // window was moved elsewhere by the user: its current frame is the new pre-snap frame
        let moved = CGRect(x: 900, y: 50, width: 640, height: 480)
        #expect(WindowStateMath.preSnapFrame(existing: (pre, zoneA), current: moved) == moved)
    }

    @Test func bestMatchPrefersTitleAndRequiresFrame() {
        let snapped = CGRect(x: 0, y: 0, width: 300, height: 800)
        let c = [WindowStateMath.Candidate(title: "B", frame: snapped),
                 WindowStateMath.Candidate(title: "A", frame: snapped.offsetBy(dx: 2, dy: 0)),
                 WindowStateMath.Candidate(title: "A", frame: CGRect(x: 500, y: 0, width: 300, height: 800))]
        #expect(WindowStateMath.bestMatch(title: "A", snapped: snapped, candidates: c) == 1)
        #expect(WindowStateMath.bestMatch(title: "Z", snapped: snapped, candidates: c) == 0)
        #expect(WindowStateMath.bestMatch(title: "A", snapped: snapped, candidates: c, excluding: [1]) == 0)
        #expect(WindowStateMath.bestMatch(title: "A", snapped: CGRect(x: 9000, y: 0, width: 1, height: 1), candidates: c) == nil)
    }

    @Test func reapplyActions() {
        typealias M = WindowStateMath
        func act(d: Bool = false, ds: Bool = true, l: Bool = false, ls: Bool = true,
                 idChanged: Bool = false, moved: Bool = false) -> M.ReapplyAction {
            M.reapplyAction(displayTrigger: d, displaySetting: ds, layoutTrigger: l, layoutSetting: ls,
                            layoutIDChanged: idChanged, movedExternally: moved)
        }
        #expect(act(d: true) == .apply)
        #expect(act(d: true, moved: true) == .apply)
        #expect(act(d: true, ds: false) == .keep)
        #expect(act(l: true) == .apply)
        #expect(act(l: true, moved: true) == .drop)
        #expect(act(l: true, ls: false, idChanged: true) == .drop)
        #expect(act(l: true, ls: false) == .keep)
        #expect(act() == .keep)
    }

    @Test func codecRoundTripAndRejects() throws {
        let file = WindowStateFile(
            assignments: [PersistedAssignment(bundleID: "com.x", titleHint: "t", zones: [0, 1], layoutID: "builtin.a",
                                              screenUUID: "U", preSnapFrame: CGRect(x: 1, y: 2, width: 3, height: 4),
                                              snappedFrame: CGRect(x: 5, y: 6, width: 7, height: 8))],
            lastByBundle: ["com.x": LastAssignment(zones: [1], layoutID: "builtin.a", screenUUID: "U")])
        let data = try #require(WindowStateCodec.encode(file))
        #expect(WindowStateCodec.decode(data) == file)
        #expect(WindowStateCodec.decode(Data("nope".utf8)) == nil)
        var future = file
        future.version = 2
        #expect(WindowStateCodec.decode(try #require(WindowStateCodec.encode(future))) == nil)
    }
}
