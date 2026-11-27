import CoreGraphics
import Testing
@testable import HephaestusCore

@Suite struct DragSnapMathTests {
    let start = CGRect(x: 100, y: 100, width: 400, height: 300)

    @Test func movedBeyondThreshold() {
        let r = DragSnapMath.classify(start: start, now: start.offsetBy(dx: 4, dy: 0))
        #expect(r.moved && !r.resized)
    }

    @Test func movedExactlyThresholdIsNotMoved() {
        let r = DragSnapMath.classify(start: start, now: start.offsetBy(dx: 3, dy: 0))
        #expect(!r.moved)
    }

    @Test func diagonalMoveUsesDistance() {
        let r = DragSnapMath.classify(start: start, now: start.offsetBy(dx: 2.5, dy: 2.5))
        #expect(r.moved)
    }

    @Test func resizeDetected() {
        var now = start; now.size.width += 3
        #expect(DragSnapMath.classify(start: start, now: now).resized)
        now = start; now.size.height -= 3
        #expect(DragSnapMath.classify(start: start, now: now).resized)
    }

    @Test func resizeAtThresholdIsNotResize() {
        var now = start; now.size.width += 2
        #expect(!DragSnapMath.classify(start: start, now: now).resized)
    }

    @Test func giveUp() {
        #expect(DragSnapMath.shouldGiveUp(resized: true, checksWithoutMove: 0))
        #expect(!DragSnapMath.shouldGiveUp(resized: false, checksWithoutMove: 40))
        #expect(DragSnapMath.shouldGiveUp(resized: false, checksWithoutMove: 41))
    }

    @Test func buttonToggleRules() {
        #expect(DragSnapMath.toggle(buttonNumber: 2, activation: .shift) == .multiZone)
        #expect(DragSnapMath.toggle(buttonNumber: 2, activation: .always) == .multiZone)
        #expect(DragSnapMath.toggle(buttonNumber: 3, activation: .shift) == .none)
        #expect(DragSnapMath.toggle(buttonNumber: 2, activation: .button) == .activation)
        #expect(DragSnapMath.toggle(buttonNumber: 4, activation: .button) == .activation)
    }
}
