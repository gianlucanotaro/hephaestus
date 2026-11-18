import Foundation
import Testing
@testable import HephaestusCore

@Suite struct LayoutCyclingTests {
    private func layout(_ id: String) -> Layout {
        var l = LayoutTemplates.builtIn[0]
        l.id = id
        return l
    }

    @Test func nextWraps() {
        let o = ["a", "b", "c"]
        #expect(LayoutCycleOrder.next(from: "a", in: o, direction: .forward) == "b")
        #expect(LayoutCycleOrder.next(from: "c", in: o, direction: .forward) == "a")
        #expect(LayoutCycleOrder.next(from: "a", in: o, direction: .backward) == "c")
        #expect(LayoutCycleOrder.next(from: "x", in: o, direction: .forward) == "a")
        #expect(LayoutCycleOrder.next(from: "x", in: o, direction: .backward) == "c")
        #expect(LayoutCycleOrder.next(from: "a", in: [], direction: .forward) == nil)
    }

    @Test func orderPrefersHotkeys() {
        let all = LayoutTemplates.builtIn + [layout("custom.1"), layout("custom.2")]
        #expect(LayoutCycleOrder.order(hotkeyOrdered: [layout("custom.2"), layout("custom.1")], all: all) == ["custom.2", "custom.1"])
        #expect(LayoutCycleOrder.order(hotkeyOrdered: [layout("custom.2")], all: all) == ["custom.1", "custom.2"])
        let builtIns = LayoutTemplates.builtIn
        #expect(LayoutCycleOrder.order(hotkeyOrdered: [], all: builtIns) == builtIns.map(\.id))
        let one = builtIns + [layout("custom.1")]
        #expect(LayoutCycleOrder.order(hotkeyOrdered: [], all: one) == one.map(\.id))
    }

    @Test func accumulatorThresholdAndDebounce() {
        var a = ScrollAccumulator()
        #expect(a.add(delta: -10, threshold: 40, at: 0) == nil)
        #expect(a.add(delta: -20, threshold: 40, at: 0.01) == nil)
        #expect(a.add(delta: -20, threshold: 40, at: 0.02) == .forward)
        // rest of the flick within the debounce window does not fire again
        #expect(a.add(delta: -50, threshold: 40, at: 0.05) == nil)
        #expect(a.add(delta: 50, threshold: 40, at: 0.5) == .backward)
    }

    @Test func accumulatorReversalAndWheel() {
        var a = ScrollAccumulator()
        #expect(a.add(delta: -30, threshold: 40, at: 0) == nil)
        #expect(a.add(delta: 30, threshold: 40, at: 0.01) == nil)   // reversal discards the earlier 30
        #expect(a.add(delta: 1, threshold: 1, at: 1) == .backward)
        #expect(a.add(delta: 0, threshold: 1, at: 2) == nil)
    }
}

@Suite struct LayoutIndicatorTests {
    private let frame = CGRect(x: 100, y: 50, width: 1000, height: 800)
    private let size = CGSize(width: 200, height: 60)

    @Test func placement() {
        let m: CGFloat = 24
        #expect(IndicatorPosition.topLeft.rect(size: size, in: frame) == CGRect(x: 100 + m, y: 850 - m - 60, width: 200, height: 60))
        #expect(IndicatorPosition.topRight.rect(size: size, in: frame).maxX == 1100 - m)
        #expect(IndicatorPosition.bottomLeft.rect(size: size, in: frame).origin == CGPoint(x: 100 + m, y: 50 + m))
        #expect(IndicatorPosition.bottomRight.rect(size: size, in: frame).origin == CGPoint(x: 1100 - m - 200, y: 50 + m))
        #expect(IndicatorPosition.center.rect(size: size, in: frame) == CGRect(x: 500, y: 420, width: 200, height: 60))
        #expect(IndicatorPosition.topCenter.rect(size: size, in: frame).midX == frame.midX)
        #expect(IndicatorPosition.bottomCenter.rect(size: size, in: frame).minY == 50 + m)
        for p in IndicatorPosition.allCases { #expect(frame.contains(p.rect(size: size, in: frame))) }
        #expect(IndicatorPosition.allCases.count == 7)
    }

    @Test func diff() {
        let before = ["A": "x", "B": "y"]
        #expect(LayoutChangeDiff.changedScreens(before: before, after: ["A": "x", "B": "y"]).isEmpty)
        #expect(LayoutChangeDiff.changedScreens(before: before, after: ["A": "z", "B": "y"]) == ["A"])
        #expect(LayoutChangeDiff.changedScreens(before: before, after: ["A": "z", "B": "w"]) == ["A", "B"])
        #expect(LayoutChangeDiff.changedScreens(before: before, after: ["A": "x", "C": "q"]).isEmpty)
    }

    @Test func clamp() {
        #expect(IndicatorLimits.clamp(1, IndicatorLimits.textSize) == 8)
        #expect(IndicatorLimits.clamp(999, IndicatorLimits.textSize) == 128)
        #expect(IndicatorLimits.clamp(100, IndicatorLimits.durationMs) == 300)
        #expect(IndicatorLimits.clamp(12, IndicatorLimits.padding) == 12)
    }
}
