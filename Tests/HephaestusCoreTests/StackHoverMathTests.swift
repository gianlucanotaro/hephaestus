import CoreGraphics
import Testing
@testable import HephaestusCore

@Suite struct StackHoverMathTests {
    private func item(_ id: Int, zones: [Int], screen: String = "A", min: Bool = false, pid: Int32 = 1,
                      frame: CGRect = .zero) -> StackMath.Item {
        .init(id: id, pid: pid, screenUUID: screen, zones: zones, frame: frame, minimized: min)
    }

    @Test func groupsByScreenAndFirstZone() {
        let s = StackMath.stacks([item(0, zones: [1]), item(1, zones: [0, 1]), item(2, zones: [1, 2]),
                                  item(3, zones: [0]), item(4, zones: [1], screen: "B")])
        #expect(s.count == 2)   // A/0: {1,3}; A/1: {0,2}; B/1 has only one
        #expect(s[0].key == .init(screenUUID: "A", zone: 0)); #expect(s[0].ids == [1, 3])
        #expect(s[1].key == .init(screenUUID: "A", zone: 1)); #expect(s[1].ids == [0, 2])
    }

    @Test func minimizedAndSingletonsAreNotStacks() {
        #expect(StackMath.stacks([item(0, zones: [0]), item(1, zones: [0], min: true)]).isEmpty)
        #expect(StackMath.stacks([item(0, zones: [])]).isEmpty)
    }

    @Test func zRankMatchesByPidAndBounds() {
        let a = CGRect(x: 0, y: 0, width: 100, height: 100), b = CGRect(x: 0, y: 0, width: 100, height: 100)
        let items = [item(0, zones: [0], pid: 1), item(1, zones: [0], pid: 2), item(2, zones: [0], pid: 3)]
        let entries: [StackMath.CGEntry] = [
            .init(pid: 2, bounds: b.insetBy(dx: -1, dy: 0), layer: 0),
            .init(pid: 9, bounds: a, layer: 0),
            .init(pid: 1, bounds: a, layer: 25),   // wrong layer: ignored
            .init(pid: 1, bounds: a, layer: 0),
        ]
        let r = StackMath.zRanks(items: items, frames: [a, b, a], entries: entries)
        #expect(r[1] == 0); #expect(r[0] == 3); #expect(r[2] == nil)
        #expect(StackMath.sortedFrontToBack([0, 1, 2], ranks: r) == [1, 0, 2])
    }

    @Test func sameAppWindowsUseEntriesOnce() {
        let f = CGRect(x: 0, y: 0, width: 50, height: 50)
        let items = [item(0, zones: [0]), item(1, zones: [0])]
        let r = StackMath.zRanks(items: items, frames: [f, f],
                                 entries: [.init(pid: 1, bounds: f, layer: 0), .init(pid: 1, bounds: f, layer: 0)])
        #expect(r == [0: 0, 1: 1])
    }

    @Test func sortKeepsTrackerOrderOnTies() {
        #expect(StackMath.sortedFrontToBack([5, 6, 7], ranks: [:]) == [5, 6, 7])
        #expect(StackMath.sortedFrontToBack([5, 6, 7], ranks: [7: 0]) == [7, 5, 6])
    }

    @Test func badgeSitsTopRightInsideTitleBar() {
        let w = CGRect(x: 100, y: 100, width: 800, height: 600)
        let b = StackMath.badgeRect(of: w), bar = StackMath.titleBarRect(of: w)
        #expect(bar.maxY == w.maxY); #expect(bar.height == 40)
        #expect(b.maxX == w.maxX - StackMath.badgeInset)
        #expect(bar.contains(b))
        #expect(StackMath.inTrigger(CGPoint(x: 500, y: 690), frame: w))
        #expect(!StackMath.inTrigger(CGPoint(x: 500, y: 600), frame: w))
    }

    @Test func trayLayoutWrapsAndFits() {
        let a = StackMath.trayLayout(count: 4, maxWidth: 2000)
        #expect(a.columns == 4); #expect(a.rows == 1)
        let b = StackMath.trayLayout(count: 8, maxWidth: 2000)
        #expect(b.columns == 6); #expect(b.rows == 2)
        let c = StackMath.trayLayout(count: 6, maxWidth: 700)
        #expect(c.columns == 4); #expect(c.rows == 2); #expect(c.size.width <= 700)
        #expect(StackMath.trayLayout(count: 2, maxWidth: 10).columns == 1)
    }

    @Test func trayCentredBelowTitleBarAndClamped() {
        let visible = CGRect(x: 0, y: 0, width: 1920, height: 1000)
        let size = CGSize(width: 700, height: 300)
        let w = CGRect(x: 600, y: 100, width: 800, height: 880)
        let t = StackMath.trayRect(size: size, window: w, visible: visible)
        #expect(t.midX == w.midX)
        #expect(t.maxY == w.maxY - StackMath.titleBarHeight - StackMath.trayGapToWindow)
        let left = StackMath.trayRect(size: size, window: CGRect(x: 0, y: 100, width: 300, height: 880), visible: visible)
        #expect(left.minX == 0)
        #expect(visible.contains(left))
    }

    @Test func trayFlipsAboveWhenNoRoomBelow() {
        let visible = CGRect(x: 0, y: 0, width: 1920, height: 1000)
        let size = CGSize(width: 700, height: 300)
        let w = CGRect(x: 600, y: 600, width: 800, height: 200)   // below fits (maxY 752)
        #expect(StackMath.trayRect(size: size, window: w, visible: visible).maxY == 752)
        let low = CGRect(x: 600, y: 0, width: 800, height: 300)   // below < 0; above fits
        let t = StackMath.trayRect(size: size, window: low, visible: visible)
        #expect(t.minY == low.maxY + StackMath.trayGapToWindow)
    }

    @Test func cardRectsRowMajorInsideTray() {
        let l = StackMath.trayLayout(count: 8, maxWidth: 3000)
        let tray = CGRect(origin: .zero, size: l.size)
        let cards = StackMath.cardRects(count: 8, columns: l.columns, tray: tray)
        #expect(cards.allSatisfy { tray.contains($0) })
        #expect(cards[1].minX > cards[0].maxX)
        #expect(cards[6].maxY < cards[0].minY)   // second row is lower
    }

    @Test func headerText() {
        #expect(StackMath.headerTitle(zoneTitle: "Zone 2", count: 4) == "ZONE 2 · 4 WINDOWS")
        #expect(StackMath.headerTitle(zoneTitle: "Zone 1", count: 1) == "ZONE 1 · 1 WINDOW")
    }

    @Test func hoverOpensAfterDelayAndClosesAfterGrace() {
        var h = StackMath.Hover()
        #expect(h.update(now: 0, inTrigger: true, inTray: false, suppressed: false) == nil)
        #expect(h.update(now: 0.1, inTrigger: true, inTray: false, suppressed: false) == nil)
        #expect(h.update(now: 0.3, inTrigger: true, inTray: false, suppressed: false) == .open)
        #expect(h.update(now: 0.4, inTrigger: false, inTray: true, suppressed: false) == nil)   // tray keeps it open
        #expect(h.update(now: 5, inTrigger: false, inTray: false, suppressed: false) == nil)   // starts grace
        #expect(h.update(now: 5.1, inTrigger: false, inTray: false, suppressed: false) == nil)
        #expect(h.update(now: 5.4, inTrigger: false, inTray: false, suppressed: false) == .close)
        #expect(h.state == .idle)
    }

    @Test func leavingBeforeDelayCancels() {
        var h = StackMath.Hover()
        _ = h.update(now: 0, inTrigger: true, inTray: false, suppressed: false)
        #expect(h.update(now: 0.1, inTrigger: false, inTray: false, suppressed: false) == nil)
        #expect(h.state == .idle)
    }

    @Test func returningDuringGraceKeepsOpen() {
        var h = StackMath.Hover()
        _ = h.update(now: 0, inTrigger: true, inTray: false, suppressed: false)
        _ = h.update(now: 1, inTrigger: true, inTray: false, suppressed: false)
        _ = h.update(now: 2, inTrigger: false, inTray: false, suppressed: false)
        #expect(h.update(now: 2.2, inTrigger: true, inTray: false, suppressed: false) == nil)
        #expect(h.state == .open)
    }

    @Test func dismissLatchesUntilPointerLeaves() {
        var h = StackMath.Hover()
        _ = h.update(now: 0, inTrigger: true, inTray: false, suppressed: false)
        _ = h.update(now: 1, inTrigger: true, inTray: false, suppressed: false)
        #expect(h.dismiss() == .close)
        #expect(h.update(now: 2, inTrigger: true, inTray: false, suppressed: false) == nil)
        #expect(h.state == .dismissed)
        _ = h.update(now: 3, inTrigger: false, inTray: false, suppressed: false)
        #expect(h.state == .idle)
        #expect(h.dismiss() == nil)
    }

    @Test func suppressionClosesImmediately() {
        var h = StackMath.Hover()
        _ = h.update(now: 0, inTrigger: true, inTray: false, suppressed: false)
        _ = h.update(now: 1, inTrigger: true, inTray: false, suppressed: false)
        #expect(h.update(now: 1.1, inTrigger: true, inTray: false, suppressed: true) == .close)
        #expect(h.update(now: 1.2, inTrigger: false, inTray: false, suppressed: true) == nil)
    }
}
