import Carbon.HIToolbox
import Foundation
import Testing
@testable import HephaestusCore

/// Three side-by-side zones, 0...300 x 0...100 (AppKit space: y up).
private let row: [CGRect] = [CGRect(x: 0, y: 0, width: 100, height: 100), CGRect(x: 100, y: 0, width: 100, height: 100),
                             CGRect(x: 200, y: 0, width: 100, height: 100)]
/// 2x2 grid; indices left-to-right, ties top-to-bottom: 0 TL, 1 BL, 2 TR, 3 BR.
private let grid: [CGRect] = [CGRect(x: 0, y: 50, width: 100, height: 50), CGRect(x: 0, y: 0, width: 100, height: 50),
                              CGRect(x: 100, y: 50, width: 100, height: 50), CGRect(x: 100, y: 0, width: 100, height: 50)]
/// Overlapping "focus"-style stack: each zone is offset diagonally from the previous.
private let focus: [CGRect] = [CGRect(x: 0, y: 60, width: 100, height: 100), CGRect(x: 40, y: 30, width: 100, height: 100),
                               CGRect(x: 80, y: 0, width: 100, height: 100)]

@Suite struct LocateTests {
    @Test func exactMatchAndBestOverlap() {
        #expect(ZoneNavigation.bestZone(for: row[1], in: row) == 1)
        #expect(ZoneNavigation.bestZone(for: CGRect(x: 90, y: 0, width: 100, height: 100), in: row) == 1)
        #expect(ZoneNavigation.bestZone(for: CGRect(x: 10, y: 10, width: 50, height: 50), in: row) == 0)
    }
    @Test func noOverlapFallsBackToNearestCenter() {
        #expect(ZoneNavigation.bestZone(for: CGRect(x: 1000, y: 0, width: 10, height: 10), in: row) == 2)
        #expect(ZoneNavigation.bestZone(for: CGRect(x: 0, y: 0, width: 10, height: 10), in: []) == nil)
        #expect(ZoneNavigation.zoneSpan(of: row[0], in: []).isEmpty)
    }
    @Test func spanDetection() {
        #expect(ZoneNavigation.zoneSpan(of: row[0], in: row) == [0])
        #expect(ZoneNavigation.zoneSpan(of: row[0].union(row[1]), in: row) == [0, 1])
        #expect(ZoneNavigation.zoneSpan(of: CGRect(x: 0, y: 0, width: 300, height: 100), in: row) == [0, 1, 2])
        // Random-sized window: just the best zone.
        #expect(ZoneNavigation.zoneSpan(of: CGRect(x: 120, y: 20, width: 40, height: 40), in: row) == [1])
    }
    @Test func nestedZoneExactMatchStaysSingle() {
        let zones = [CGRect(x: 0, y: 0, width: 200, height: 100), CGRect(x: 0, y: 0, width: 100, height: 100)]
        #expect(ZoneNavigation.zoneSpan(of: zones[0], in: zones) == [0])
        #expect(ZoneNavigation.zoneSpan(of: zones[1], in: zones) == [1])
    }
}

@Suite struct RelativeTests {
    @Test func rowNavigation() {
        #expect(ZoneNavigation.nearest(from: row[1], direction: .right, in: row, excluding: [1]) == 2)
        #expect(ZoneNavigation.nearest(from: row[1], direction: .left, in: row, excluding: [1]) == 0)
        #expect(ZoneNavigation.nearest(from: row[2], direction: .right, in: row, excluding: [2]) == nil)
        #expect(ZoneNavigation.nearest(from: row[0], direction: .up, in: row, excluding: [0]) == nil)
        #expect(ZoneNavigation.nearest(from: row[0], direction: .down, in: row, excluding: [0]) == nil)
    }
    @Test func gridNavigationAllDirections() {
        #expect(ZoneNavigation.nearest(from: grid[0], direction: .right, in: grid, excluding: [0]) == 2)
        #expect(ZoneNavigation.nearest(from: grid[0], direction: .down, in: grid, excluding: [0]) == 1)
        #expect(ZoneNavigation.nearest(from: grid[3], direction: .up, in: grid, excluding: [3]) == 2)
        #expect(ZoneNavigation.nearest(from: grid[3], direction: .left, in: grid, excluding: [3]) == 1)
        #expect(ZoneNavigation.nearest(from: grid[1], direction: .up, in: grid, excluding: [1]) == 0)
    }
    @Test func prefersPerpendicularOverlapOverCloserDiagonal() {
        // Right of a tall zone: a small zone far above vs. a farther zone aligned.
        let zones = [CGRect(x: 0, y: 0, width: 100, height: 100),
                     CGRect(x: 110, y: 200, width: 100, height: 40),
                     CGRect(x: 300, y: 10, width: 100, height: 80)]
        #expect(ZoneNavigation.nearest(from: zones[0], direction: .right, in: zones, excluding: [0]) == 2)
        // With no aligned candidate the diagonal one is still reachable.
        #expect(ZoneNavigation.nearest(from: zones[0], direction: .right, in: Array(zones.prefix(2)), excluding: [0]) == 1)
    }
    @Test func focusStyleOverlappingLayout() {
        // Zones overlap but centers progress right/down; a window on zone 1 can go either way.
        #expect(ZoneNavigation.nearest(from: focus[1], direction: .right, in: focus, excluding: [1]) == 2)
        #expect(ZoneNavigation.nearest(from: focus[1], direction: .left, in: focus, excluding: [1]) == 0)
        #expect(ZoneNavigation.nearest(from: focus[1], direction: .up, in: focus, excluding: [1]) == 0)
        #expect(ZoneNavigation.nearest(from: focus[1], direction: .down, in: focus, excluding: [1]) == 2)
        #expect(ZoneNavigation.nearest(from: focus[0], direction: .left, in: focus, excluding: [0]) == nil)
    }
    @Test func emptyAndSingle() {
        #expect(ZoneNavigation.nearest(from: row[0], direction: .right, in: []) == nil)
        #expect(ZoneNavigation.nearest(from: row[0], direction: .right, in: [row[0]], excluding: [0]) == nil)
    }
    @Test func entryZoneOnArrival() {
        #expect(ZoneNavigation.entryZone(direction: .right, ref: row[2], in: row) == 0)
        #expect(ZoneNavigation.entryZone(direction: .left, ref: row[0], in: row) == 2)
        // Grid: arriving rightwards from a top-row window enters the top-left zone (index 0).
        #expect(ZoneNavigation.entryZone(direction: .right, ref: CGRect(x: -100, y: 60, width: 50, height: 30), in: grid) == 0)
        #expect(ZoneNavigation.entryZone(direction: .right, ref: CGRect(x: -100, y: 5, width: 50, height: 30), in: grid) == 1)
        #expect(ZoneNavigation.entryZone(direction: .down, ref: CGRect(x: 110, y: 200, width: 50, height: 30), in: grid) == 2)
        #expect(ZoneNavigation.entryZone(direction: .up, ref: row[0], in: []) == nil)
    }
}

@Suite struct ExpandTests {
    @Test func expandsToAdjacent() {
        #expect(ZoneNavigation.expand(span: [0], direction: .right, in: row) == [0, 1])
        #expect(ZoneNavigation.expand(span: [0, 1], direction: .right, in: row) == [0, 1, 2])
        #expect(ZoneNavigation.expand(span: [1], direction: .left, in: row) == [0, 1])
        let box = ZoneLayout.boundingRect(of: [0, 1], in: row)
        #expect(box == CGRect(x: 0, y: 0, width: 200, height: 100))
    }
    @Test func nothingBeyondEdge() {
        #expect(ZoneNavigation.expand(span: [0, 1, 2], direction: .right, in: row) == nil)
        #expect(ZoneNavigation.expand(span: [2], direction: .right, in: row) == nil)
        #expect(ZoneNavigation.expand(span: [0], direction: .up, in: row) == nil)
        #expect(ZoneNavigation.expand(span: [], direction: .right, in: row) == nil)
    }
    @Test func gridExpandsVerticallyAndNotDiagonally() {
        #expect(ZoneNavigation.expand(span: [0], direction: .down, in: grid) == [0, 1])
        #expect(ZoneNavigation.expand(span: [0], direction: .right, in: grid) == [0, 2])
        // Span of the left column expanding right grabs one zone at a time.
        let e = ZoneNavigation.expand(span: [0, 1], direction: .right, in: grid)
        #expect(e == [0, 1, 2])
    }
    @Test func expandIgnoresDiagonalZones() {
        let zones = [CGRect(x: 0, y: 0, width: 100, height: 100), CGRect(x: 110, y: 200, width: 100, height: 100)]
        #expect(ZoneNavigation.expand(span: [0], direction: .right, in: zones) == nil)
    }
}

@Suite struct MoveTargetTests {
    private let left = NavScreen(frame: CGRect(x: 0, y: 0, width: 300, height: 100), zones: row)
    private let right = NavScreen(frame: CGRect(x: 300, y: 0, width: 300, height: 100),
                                  zones: row.map { $0.offsetBy(dx: 300, dy: 0) })
    private var both: [NavScreen] { [left, right] }

    @Test func zoneIndexStepsAndWraps() {
        let t = { (w: CGRect, d: NavDirection, cross: Bool) in
            ZoneNavigation.moveTarget(window: w, screens: [left], currentScreen: 0, mode: .zoneIndex, direction: d, crossScreens: cross)
        }
        #expect(t(row[0], .right, false) == .zone(screen: 0, zone: 1))
        #expect(t(row[1], .left, false) == .zone(screen: 0, zone: 0))
        #expect(t(row[2], .right, false) == .zone(screen: 0, zone: 0))   // wraps
        #expect(t(row[0], .left, false) == .zone(screen: 0, zone: 2))
        #expect(t(row[0], .up, false) == nil)
    }
    @Test func zoneIndexSingleZoneDoesNotWrapOntoItself() {
        let s = NavScreen(frame: CGRect(x: 0, y: 0, width: 100, height: 100), zones: [row[0]])
        #expect(ZoneNavigation.moveTarget(window: row[0], screens: [s], currentScreen: 0, mode: .zoneIndex,
                                          direction: .right, crossScreens: false) == nil)
    }
    @Test func zoneIndexCrossesScreens() {
        let r = { (w: CGRect, cs: Int, d: NavDirection) in
            ZoneNavigation.moveTarget(window: w, screens: both, currentScreen: cs, mode: .zoneIndex, direction: d, crossScreens: true)
        }
        #expect(r(row[2], 0, .right) == .zone(screen: 1, zone: 0))
        #expect(r(row[1], 0, .right) == .zone(screen: 0, zone: 2))
        #expect(r(row[0].offsetBy(dx: 300, dy: 0), 1, .left) == .zone(screen: 0, zone: 2))
        #expect(r(row[0], 0, .left) == nil)   // no screen further left
    }
    @Test func relativeStaysOnScreenAtEdge() {
        #expect(ZoneNavigation.moveTarget(window: row[2], screens: both, currentScreen: 0, mode: .relative,
                                          direction: .right, crossScreens: false) == nil)
        #expect(ZoneNavigation.moveTarget(window: row[0], screens: both, currentScreen: 0, mode: .relative,
                                          direction: .right, crossScreens: false) == .zone(screen: 0, zone: 1))
    }
    @Test func relativeCrossesScreensEnteringNearestEdge() {
        #expect(ZoneNavigation.moveTarget(window: row[2], screens: both, currentScreen: 0, mode: .relative,
                                          direction: .right, crossScreens: true) == .zone(screen: 1, zone: 0))
        #expect(ZoneNavigation.moveTarget(window: row[0].offsetBy(dx: 300, dy: 0), screens: both, currentScreen: 1,
                                          mode: .relative, direction: .left, crossScreens: true) == .zone(screen: 0, zone: 2))
        // Nothing above or below: stays put.
        #expect(ZoneNavigation.moveTarget(window: row[1], screens: both, currentScreen: 0, mode: .relative,
                                          direction: .up, crossScreens: true) == nil)
    }
    @Test func relativeVerticalScreenStack() {
        let top = NavScreen(frame: CGRect(x: 0, y: 100, width: 300, height: 100), zones: row.map { $0.offsetBy(dx: 0, dy: 100) })
        let target = ZoneNavigation.moveTarget(window: row[1], screens: [left, top], currentScreen: 0, mode: .relative,
                                               direction: .up, crossScreens: true)
        #expect(target == .zone(screen: 1, zone: 1))
    }
    @Test func directModeAndBadScreenIndexReturnNil() {
        #expect(ZoneNavigation.moveTarget(window: row[0], screens: both, currentScreen: 0, mode: .direct,
                                          direction: .right, crossScreens: true) == nil)
        #expect(ZoneNavigation.moveTarget(window: row[0], screens: both, currentScreen: 5, mode: .relative,
                                          direction: .right, crossScreens: true) == nil)
    }
    @Test func screenWithoutZonesIsSkippedWhenCrossing() {
        let empty = NavScreen(frame: CGRect(x: 300, y: 0, width: 300, height: 100), zones: [])
        let far = NavScreen(frame: CGRect(x: 600, y: 0, width: 300, height: 100), zones: row.map { $0.offsetBy(dx: 600, dy: 0) })
        #expect(ZoneNavigation.moveTarget(window: row[2], screens: [left, empty, far], currentScreen: 0, mode: .relative,
                                          direction: .right, crossScreens: true) == .zone(screen: 2, zone: 0))
    }
}

@Suite struct BindingTests {
    private func cfg(_ mode: KeyboardNavMode, _ m: Int = controlKey | optionKey, _ e: Int = controlKey | optionKey | shiftKey) -> KeyboardNavConfig {
        KeyboardNavConfig(mode: mode, directModifiers: m, moveModifiers: m, expandModifiers: e)
    }
    @Test func directIsTheDefaultAndMatchesLegacyHotkeys() {
        let b = cfg(.direct).bindings
        #expect(b.map(\.action) == [.snap(.first), .snap(.middle), .snap(.last)])
        #expect(b.map(\.keyCode) == [kVK_LeftArrow, kVK_UpArrow, kVK_RightArrow])
        #expect(b.allSatisfy { $0.modifiers == controlKey | optionKey })
    }
    @Test func bindingCountsPerMode() {
        #expect(cfg(.zoneIndex).bindings.count == 2)
        #expect(cfg(.relative).bindings.count == 8)
    }
    @Test func conflictingModifiersDropDuplicatesAndFlag() {
        let c = cfg(.relative, controlKey | optionKey, controlKey | optionKey)
        #expect(c.hasConflict)
        #expect(c.bindings.count == 4)
        #expect(!cfg(.relative).hasConflict)
    }
    @Test func modifierSanitizing() {
        #expect(HotKeyModifiers.sanitized(0, fallback: controlKey) == controlKey)
        #expect(HotKeyModifiers.sanitized(1 << 20, fallback: optionKey) == optionKey)
        #expect(HotKeyModifiers.sanitized(cmdKey | 0x10000, fallback: optionKey) == cmdKey)
        #expect(HotKeyModifiers.symbols(controlKey | optionKey | cmdKey) == "⌃⌥⌘")
    }
}
