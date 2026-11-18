import CoreGraphics
import Testing
@testable import HephaestusCore

private func std(_ edit: (inout WindowTraits) -> Void = { _ in }) -> WindowTraits {
    var t = WindowTraits(role: "AXWindow", subrole: "AXStandardWindow")
    edit(&t)
    return t
}
private let strict = EligibilityPolicy()
private let all = EligibilityPolicy(allowDialogs: true, allowFloating: true, allowChildWindows: true)

@Suite struct EligibilityTests {
    @Test func standardSnaps() { #expect(WindowEligibility.isSnappable(std(), policy: strict)) }

    @Test func fullscreenAndMinimizedNever() {
        #expect(!WindowEligibility.isSnappable(std { $0.isFullScreen = true }, policy: all))
        #expect(!WindowEligibility.isSnappable(std { $0.isMinimized = true }, policy: all))
    }

    @Test func sheetsAndOtherRolesNever() {
        #expect(!WindowEligibility.isSnappable(WindowTraits(role: "AXSheet", subrole: nil), policy: all))
        #expect(!WindowEligibility.isSnappable(WindowTraits(role: "AXWindow", subrole: "AXSheet"), policy: all))
        #expect(!WindowEligibility.isSnappable(WindowTraits(role: "AXPopover", subrole: nil), policy: all))
        #expect(!WindowEligibility.isSnappable(WindowTraits(), policy: all))
        #expect(!WindowEligibility.isSnappable(std { $0.subrole = "AXUnknown" }, policy: all))
    }

    @Test func dialogsNeedToggle() {
        for sub in ["AXDialog", "AXSystemDialog"] {
            let t = std { $0.subrole = sub }
            #expect(!WindowEligibility.isSnappable(t, policy: strict))
            #expect(WindowEligibility.isSnappable(t, policy: EligibilityPolicy(allowDialogs: true)))
            #expect(!WindowEligibility.isSnappable(t, policy: EligibilityPolicy(allowFloating: true)))
        }
    }

    @Test func floatingNeedsToggle() {
        let t = std { $0.subrole = "AXFloatingWindow" }
        #expect(!WindowEligibility.isSnappable(t, policy: strict))
        #expect(WindowEligibility.isSnappable(t, policy: EligibilityPolicy(allowFloating: true)))
    }

    @Test func modalNeedsDialogToggle() {
        let t = std { $0.isModal = true }
        #expect(!WindowEligibility.isSnappable(t, policy: strict))
        #expect(!WindowEligibility.isSnappable(t, policy: EligibilityPolicy(allowFloating: true)))
        #expect(WindowEligibility.isSnappable(t, policy: EligibilityPolicy(allowDialogs: true)))
    }

    @Test func childWindowsNeedToggle() {
        let t = std { $0.hasParentWindow = true }
        #expect(!WindowEligibility.isSnappable(t, policy: strict))
        #expect(WindowEligibility.isSnappable(t, policy: EligibilityPolicy(allowChildWindows: true)))
    }
}

@Suite struct ExclusionTests {
    @Test func matching() {
        let list = "  slack \n\ncom.apple.finder\n"
        #expect(AppExclusion.matches(bundleID: "com.tinyspeck.slackmacgap", name: "Slack", list: list))
        #expect(AppExclusion.matches(bundleID: "com.apple.finder", name: "Finder", list: list))
        #expect(AppExclusion.matches(bundleID: nil, name: "SLACK", list: list))
        #expect(!AppExclusion.matches(bundleID: "com.apple.Safari", name: "Safari", list: list))
    }
    @Test func emptyListAndBlankLinesMatchNothing() {
        #expect(!AppExclusion.matches(bundleID: "a", name: "b", list: ""))
        #expect(!AppExclusion.matches(bundleID: "a", name: "b", list: " \n  \n"))
        #expect(!AppExclusion.matches(bundleID: nil, name: nil, list: "x"))
    }
}

@Suite struct ZoneResolutionTests {
    // Big zone 0 with a small zone 1 inside and an offset zone 2 overlapping the big one.
    let zones = [CGRect(x: 0, y: 0, width: 100, height: 100),
                 CGRect(x: 40, y: 40, width: 20, height: 20),
                 CGRect(x: 30, y: 0, width: 100, height: 100)]

    @Test func smallest() {
        #expect(ZoneResolution.primaryZone(at: CGPoint(x: 50, y: 50), in: zones, gap: 0, policy: .smallest) == 1)
        #expect(ZoneResolution.primaryZone(at: CGPoint(x: 10, y: 10), in: zones, gap: 0, policy: .smallest) == 0)
    }
    @Test func largestTiesToLowestIndex() {
        #expect(ZoneResolution.primaryZone(at: CGPoint(x: 50, y: 50), in: zones, gap: 0, policy: .largest) == 0)
    }
    @Test func positional() {
        #expect(ZoneResolution.primaryZone(at: CGPoint(x: 35, y: 50), in: zones, gap: 0, policy: .positional) == 0)
        #expect(ZoneResolution.primaryZone(at: CGPoint(x: 90, y: 50), in: zones, gap: 0, policy: .positional) == 2)
    }
    @Test func nonOverlappingIgnoresPolicyAndKeepsGapBehavior() {
        let z = [CGRect(x: 4, y: 4, width: 92, height: 92), CGRect(x: 104, y: 4, width: 92, height: 92)]
        for p in OverlapResolution.allCases {
            #expect(ZoneResolution.primaryZone(at: CGPoint(x: 50, y: 50), in: z, gap: 8, policy: p) == 0)
            #expect(ZoneResolution.primaryZone(at: CGPoint(x: 98, y: 50), in: z, gap: 8, policy: p) == 0)   // in the gap
            #expect(ZoneResolution.primaryZone(at: CGPoint(x: 102, y: 50), in: z, gap: 8, policy: p) == 1)
            #expect(ZoneResolution.primaryZone(at: CGPoint(x: 500, y: 50), in: z, gap: 8, policy: p) == nil)
        }
        let t = [CGRect(x: 0, y: 0, width: 50, height: 50), CGRect(x: 50, y: 0, width: 50, height: 50)]
        #expect(ZoneResolution.primaryZone(at: CGPoint(x: 50, y: 10), in: t, gap: 0, policy: .largest) == 1)
    }
    @Test func selectionUsesOverlapPolicy() {
        let s = ZoneLayout.selection(at: CGPoint(x: 50, y: 50), in: zones, gap: 0, overlap: .largest)
        #expect(s.contains(0))
    }
}
