import CoreGraphics
import Testing
@testable import HephaestusCore

@Suite struct RotationPlanTests {
    @Test func ordersLeftToRight() {
        let frames = [CGRect(x: 1920, y: 0, width: 100, height: 100), CGRect(x: -1000, y: 0, width: 100, height: 100),
                      CGRect(x: 0, y: 0, width: 100, height: 100)]
        #expect(RotationPlan.orderedScreenIndices(frames: frames) == [1, 2, 0])
    }

    @Test func twoScreensSwapAndKeepZone() {
        let w = [RotationWindow(id: 0, screen: 0, zone: 2), RotationWindow(id: 1, screen: 1, zone: 0)]
        let r = RotationPlan.plan(windows: w, zoneCounts: [3, 3], direction: .right)
        #expect(r == [RotationMove(id: 0, fromScreen: 0, toScreen: 1, zone: 2), RotationMove(id: 1, fromScreen: 1, toScreen: 0, zone: 0)])
        #expect(RotationPlan.plan(windows: w, zoneCounts: [3, 3], direction: .left).map(\.toScreen) == [1, 0])
    }

    @Test func threeScreensWrap() {
        let w = (0..<3).map { RotationWindow(id: $0, screen: $0, zone: 1) }
        #expect(RotationPlan.plan(windows: w, zoneCounts: [3, 3, 3], direction: .right).map(\.toScreen) == [1, 2, 0])
        #expect(RotationPlan.plan(windows: w, zoneCounts: [3, 3, 3], direction: .left).map(\.toScreen) == [2, 0, 1])
    }

    @Test func clampsZoneToDestinationLayout() {
        let w = [RotationWindow(id: 0, screen: 0, zone: 4), RotationWindow(id: 1, screen: 1, zone: 1)]
        let r = RotationPlan.plan(windows: w, zoneCounts: [5, 2], direction: .right)
        #expect(r[0].zone == 1)
        #expect(r[1].zone == 1)
    }

    @Test func singleScreenIsNoOp() {
        #expect(RotationPlan.plan(windows: [RotationWindow(id: 0, screen: 0, zone: 0)], zoneCounts: [3], direction: .right).isEmpty)
        #expect(RotationPlan.plan(windows: [], zoneCounts: [], direction: .left).isEmpty)
    }

    @Test func windowWithoutZoneStaysZoneless() {
        let r = RotationPlan.plan(windows: [RotationWindow(id: 7, screen: 0, zone: nil)], zoneCounts: [3, 3], direction: .right)
        #expect(r == [RotationMove(id: 7, fromScreen: 0, toScreen: 1, zone: nil)])
    }

    @Test func bestZoneByOverlap() {
        let zones = [CGRect(x: 0, y: 0, width: 100, height: 100), CGRect(x: 100, y: 0, width: 100, height: 100)]
        #expect(RotationPlan.bestZone(for: CGRect(x: 110, y: 10, width: 80, height: 80), in: zones) == 1)
        #expect(RotationPlan.bestZone(for: CGRect(x: 0, y: 0, width: 100, height: 100), in: zones) == 0)
        #expect(RotationPlan.bestZone(for: CGRect(x: 50, y: 0, width: 100, height: 300), in: zones) == nil)
        #expect(RotationPlan.bestZone(for: CGRect(x: 500, y: 0, width: 10, height: 10), in: zones) == nil)
    }

    @Test func proportionalMove() {
        let r = RotationPlan.proportionalRect(CGRect(x: 100, y: 50, width: 400, height: 200),
                                              from: CGRect(x: 0, y: 0, width: 1000, height: 500),
                                              to: CGRect(x: 2000, y: 0, width: 2000, height: 1000))
        #expect(r == CGRect(x: 2200, y: 100, width: 800, height: 400))
    }

    @Test func holdStateMachine() {
        var s = RotationHoldState(triggerKeyCode: 7, modifier: .maskAlternate)
        let opt = CGEventFlags.maskAlternate
        #expect(s.handle(.keyDown, keyCode: 124, flags: opt).action == .none)
        let down = s.handle(.keyDown, keyCode: 7, flags: opt)
        #expect(down.action == .showPreview && down.swallow)
        #expect(s.handle(.keyDown, keyCode: 7, flags: opt, isRepeat: true).action == .none)
        let right = s.handle(.keyDown, keyCode: 124, flags: opt)
        #expect(right.action == .rotate(.right) && right.swallow)
        #expect(s.handle(.keyDown, keyCode: 123, flags: opt).action == .rotate(.left))
        #expect(s.handle(.keyDown, keyCode: 123, flags: opt, isRepeat: true).action == .none)
        // Releasing the modifier first ends the hold; the trigger key-up is still swallowed.
        #expect(s.handle(.flagsChanged, keyCode: 58, flags: []).action == .hidePreview)
        #expect(s.handle(.keyUp, keyCode: 7, flags: []).swallow)
        #expect(!s.held)
        #expect(!s.handle(.keyUp, keyCode: 7, flags: []).swallow)
    }

    @Test func holdEndsOnTriggerKeyUp() {
        var s = RotationHoldState(triggerKeyCode: 7, modifier: .maskAlternate)
        _ = s.handle(.keyDown, keyCode: 7, flags: .maskAlternate)
        #expect(s.handle(.keyUp, keyCode: 7, flags: .maskAlternate).action == .hidePreview)
    }

    @Test func disabledPassesEverythingThrough() {
        var s = RotationHoldState(triggerKeyCode: 7, modifier: .maskAlternate)
        s.enabled = false
        let r = s.handle(.keyDown, keyCode: 7, flags: .maskAlternate)
        #expect(r.action == .none && !r.swallow && !s.held)
    }
}
