import Carbon.HIToolbox
import Foundation
import Testing
@testable import HephaestusCore

/// Cross-feature composition checks (the pieces were built separately; these pin how they fit together).
@Suite struct IntegrationTests {
    private let frame = CGRect(x: 0, y: 25, width: 3000, height: 1000)

    // MARK: Hotkey defaults

    /// (keyCode, carbon modifiers) of every default Carbon hotkey, per keyboard mode (modes are mutually exclusive).
    private func defaultHotkeys(mode: KeyboardNavMode) -> [(key: Int, mods: Int)] {
        let nav = KeyboardNavConfig(mode: mode, directModifiers: KeyboardNavConfig.defaultDirect,
                                    moveModifiers: KeyboardNavConfig.defaultMove, expandModifiers: KeyboardNavConfig.defaultExpand)
        var out = nav.bindings.map { (key: $0.keyCode, mods: $0.modifiers) }
        out.append((Int(kVK_ANSI_Z), controlKey | optionKey))                       // zone preview (AppDelegate)
        out.append((Int(kVK_PageDown), controlKey | optionKey))                     // cycle next
        out.append((Int(kVK_PageUp), controlKey | optionKey))                       // cycle previous
        let layoutMods = HotkeyModifiers.controlOptionCommand.carbon
        out += LayoutHotkeys.validNumbers.map { (LayoutHotkeyKeys.digitKeyCodes[$0], layoutMods) }
        out.append((LayoutHotkeyKeys.keyCode(forLetter: "E")!, layoutMods))         // open editor
        return out
    }

    @Test func defaultHotkeysNeverCollide() {
        for mode in KeyboardNavMode.allCases {
            let all = defaultHotkeys(mode: mode)
            let unique = Set(all.map { "\($0.key)/\($0.mods)" })
            #expect(unique.count == all.count, "collision in mode \(mode)")
        }
    }

    // MARK: Geometry composition

    @Test func spanOwnerIsTheRepresentativeScreen() {
        let screens = ["A", "B", "C"]
        #expect(ZoneLayout.owner(of: "C", in: screens, span: false) == "C")
        #expect(ZoneLayout.owner(of: "C", in: screens, span: true) == "A")
        #expect(ZoneLayout.owner(of: "X", in: [String](), span: true) == "X")
    }

    @Test func spanSurfaceIsTheUnionOfUsableFrames() {
        let a = CGRect(x: 0, y: 25, width: 2000, height: 975)
        let b = CGRect(x: 2000, y: 0, width: 1000, height: 1000)
        #expect(ZoneLayout.unionFrame(of: [a, b]) == CGRect(x: 0, y: 0, width: 3000, height: 1000))
    }

    @Test func layoutGapDrivesZoneGeometryAndHitTesting() {
        var layout = LayoutTemplates.builtIn.first { $0.id == "builtin.columns" } ?? LayoutTemplates.builtIn[2]
        layout.gap = 40
        let gap = ZoneLayout.effectiveGap(for: layout, overrides: [:], globalGap: 8)
        #expect(gap == 40)
        let zones = ZoneLayout.zones(layout: layout, in: frame, gap: gap)
        // Just inside the gap next to zone 0: zone 0 alone (the gap belongs to the nearest zone), no edge tolerance.
        let nearZero = CGPoint(x: zones[0].maxX + 5, y: frame.midY)
        #expect(ZoneLayout.selection(at: nearZero, in: zones, gap: gap, edgeThreshold: 0) == [0])
        // The middle of the gap with the edge tolerance selects both neighbours.
        let between = CGPoint(x: (zones[0].maxX + zones[1].minX) / 2, y: frame.midY)
        #expect(ZoneLayout.selection(at: between, in: zones, gap: gap, edgeThreshold: 100) == [0, 1])
    }

    @Test func overlapPolicyComposesWithGap() {
        let focus = LayoutTemplates.builtIn.first { $0.id == "builtin.focus" }!
        let zones = ZoneLayout.zones(layout: focus, in: frame, gap: 8)
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let smallest = ZoneLayout.selection(at: center, in: zones, gap: 8, edgeThreshold: 0, overlap: .smallest)
        let largest = ZoneLayout.selection(at: center, in: zones, gap: 8, edgeThreshold: 0, overlap: .largest)
        #expect(smallest.count == 1 && largest.count == 1)
        let area: (ZoneIndex) -> CGFloat = { zones[$0].width * zones[$0].height }
        #expect(area(smallest.first!) <= area(largest.first!))
    }

    // MARK: Tracker-first zone lookup

    @Test func trackedZonesWinWhenWindowUnmoved() {
        let zones = [CGRect(x: 0, y: 0, width: 100, height: 100), CGRect(x: 100, y: 0, width: 100, height: 100)]
        // The window overlaps zone 0 by frame, but the tracker says zone 1 and it sits at the tracked frame.
        let f = CGRect(x: 100, y: 0, width: 100, height: 100)
        #expect(ZoneNavigation.currentZones(tracked: ([1], f), frame: f, in: zones) == [1])
        // Tracker record whose frame no longer matches (moved by someone else) falls back to geometry.
        let moved = CGRect(x: 0, y: 0, width: 100, height: 100)
        #expect(ZoneNavigation.currentZones(tracked: ([1], f), frame: moved, in: zones) == [0])
        // Stale zone index (layout shrank) falls back too; no record falls back.
        #expect(ZoneNavigation.currentZones(tracked: ([5], moved), frame: moved, in: zones) == [0])
        #expect(ZoneNavigation.currentZones(tracked: nil, frame: moved, in: zones) == [0])
    }

    // MARK: Eligibility delegation

    @Test func placementUsesTheSharedClassifier() {
        var t = WindowTraits()
        t.role = "AXWindow"; t.subrole = "AXDialog"
        #expect(!NewWindowPlacementMath.isPlaceable(t))
        #expect(NewWindowPlacementMath.isPlaceable(t, policy: EligibilityPolicy(allowDialogs: true))
                == WindowEligibility.isSnappable(t, policy: EligibilityPolicy(allowDialogs: true)))
    }
}
