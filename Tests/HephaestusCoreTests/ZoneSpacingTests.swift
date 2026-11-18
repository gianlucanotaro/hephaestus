import Foundation
import Testing
@testable import HephaestusCore

@Suite struct ZoneSpacingTests {
    private let frame = CGRect(x: 0, y: 25, width: 3000, height: 1000)

    @Test func perLayoutGapOverridesGlobal() {
        var l = LayoutTemplates.builtIn[2]
        #expect(ZoneLayout.effectiveGap(for: l, overrides: [:], globalGap: 8) == 8)
        l.gap = 20
        #expect(ZoneLayout.effectiveGap(for: l, overrides: [:], globalGap: 8) == 20)
        l.gap = 0
        #expect(ZoneLayout.effectiveGap(for: l, overrides: [:], globalGap: 8) == 0)
    }

    @Test func builtInOverrideUsedWhenNoOwnGap() {
        let l = LayoutTemplates.builtIn[2]
        #expect(ZoneLayout.effectiveGap(for: l, overrides: [l.id: 16], globalGap: 8) == 16)
        #expect(ZoneLayout.effectiveGap(for: l, overrides: ["other": 16], globalGap: 8) == 8)
    }

    @Test func nilGapMatchesOldGlobalGapGeometry() {
        for layout in LayoutTemplates.builtIn {
            let g = ZoneLayout.effectiveGap(for: layout, overrides: [:], globalGap: 12)
            #expect(ZoneLayout.zones(layout: layout, in: frame, gap: g) == ZoneLayout.zones(layout: layout, in: frame, gap: 12))
        }
    }

    @Test func gapChangesZoneSize() {
        var l = LayoutTemplates.builtIn[2]
        l.gap = 20
        let z = ZoneLayout.zones(layout: l, in: frame, gap: ZoneLayout.effectiveGap(for: l, overrides: [:], globalGap: 8))
        #expect(z[0] == CGRect(x: 10, y: 35, width: 980, height: 980))
    }

    @Test func jsonBackwardCompatible() throws {
        let old = #"{"id":"c1","name":"X","kind":"canvas","zones":[{"x":0,"y":0,"w":1,"h":1}]}"#
        let l = try JSONDecoder().decode(Layout.self, from: Data(old.utf8))
        #expect(l.gap == nil)
        #expect(l.isValid)
        // nil gap is not written; a set gap round-trips.
        let enc = try LayoutStore.encode(l)
        #expect(!String(decoding: enc, as: UTF8.self).contains("gap"))
        var g = l
        g.gap = 6
        #expect(try JSONDecoder().decode(Layout.self, from: LayoutStore.encode(g)).gap == 6)
    }

    @Test func invalidGapRejected() {
        var l = Layout(id: "c", name: "C", kind: .canvas, zones: [RelRect(x: 0, y: 0, w: 1, h: 1)])
        l.gap = -1
        #expect(!l.isValid)
        l.gap = .nan
        #expect(!l.isValid)
        l.gap = 0
        #expect(l.isValid)
    }

    @Test func thresholdControlsAdjacentSelection() {
        // Two columns, gap 0: shared edge at x = 100.
        let zones = [CGRect(x: 0, y: 0, width: 100, height: 100), CGRect(x: 100, y: 0, width: 100, height: 100)]
        let p = CGPoint(x: 80, y: 50)   // 20pt from the edge
        #expect(ZoneLayout.selection(at: p, in: zones, gap: 0, edgeThreshold: 24) == [0, 1])
        #expect(ZoneLayout.selection(at: p, in: zones, gap: 0, edgeThreshold: 10) == [0])
        #expect(ZoneLayout.selection(at: p, in: zones, gap: 0, edgeThreshold: 0) == [0])
    }

    @Test func thresholdPrefDefaultAndClamp() {
        let key = Prefs.edgeThresholdKey
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.set(500.0, forKey: key)
        #expect(Prefs.edgeThreshold == 100)
        UserDefaults.standard.set(-5.0, forKey: key)
        #expect(Prefs.edgeThreshold == 0)
        #expect(Prefs.defaultEdgeThreshold == 24)
    }

    @Test func unionFrame() {
        #expect(ZoneLayout.unionFrame(of: []) == nil)
        let a = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        #expect(ZoneLayout.unionFrame(of: [a]) == a)
        let b = CGRect(x: -1440, y: 100, width: 1440, height: 900)
        let c = CGRect(x: 1920, y: -200, width: 1000, height: 800)
        #expect(ZoneLayout.unionFrame(of: [a, b, c]) == CGRect(x: -1440, y: -200, width: 4360, height: 1280))
    }

    @Test func spannedZonesCoverUnion() {
        let u = ZoneLayout.unionFrame(of: [CGRect(x: 0, y: 0, width: 1000, height: 800),
                                           CGRect(x: 1000, y: 0, width: 1000, height: 800)])!
        let z = ZoneLayout.zones(layout: LayoutTemplates.builtIn[2], in: u, gap: 0)
        #expect(ZoneLayout.boundingRect(of: [0, 1, 2], in: z) == u)
        #expect(z[0].width == 2000.0 / 3)
    }
}
