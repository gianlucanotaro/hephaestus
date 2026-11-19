import CoreGraphics
import Foundation
import Testing
@testable import HephaestusCore

@Suite struct PinnedWindowsTests {
    private func win(_ n: Int, pid: Int32, _ r: CGRect, layer: Int = 0, alpha: Double = 1) -> WindowSnapshot {
        WindowSnapshot(number: n, pid: pid, bounds: r, layer: layer, alpha: alpha)
    }
    private let a = CGRect(x: 0, y: 0, width: 500, height: 400)
    private let b = CGRect(x: 300, y: 100, width: 500, height: 400)
    private let far = CGRect(x: 2000, y: 0, width: 300, height: 300)

    // MARK: PinList

    @Test func toggleAddsThenRemoves() {
        var list = PinList<Int>()
        let r1 = list.toggle(1, matches: { $0 == 1 })
        let r2 = list.toggle(2, matches: { $0 == 2 })
        let r3 = list.toggle(1, matches: { $0 == 1 })
        #expect(r1 && r2 && !r3)
        #expect(list.items == [2])
    }

    @Test func removeKeepsOrder() {
        var list = PinList<Int>()
        for i in 1...5 { list.toggle(i, matches: { $0 == i }) }
        let n = list.remove(where: { $0 % 2 == 0 })
        #expect(n == 2)
        #expect(list.items == [1, 3, 5])
        list.removeAll()
        #expect(list.items.isEmpty)
    }

    // MARK: Raise decision

    @Test func pinnedOnTopNeedsNoRaise() {
        let pins = [PinTarget(key: 1, pid: 10, bounds: a)]
        let wins = [win(1, pid: 10, a), win(2, pid: 20, b)]
        #expect(PinRaise.windowsToRaise(pinned: pins, windows: wins).isEmpty)
    }

    @Test func overlappingWindowAboveObscures() {
        let pins = [PinTarget(key: 1, pid: 10, bounds: a)]
        let wins = [win(2, pid: 20, b), win(1, pid: 10, a)]
        #expect(PinRaise.windowsToRaise(pinned: pins, windows: wins) == [1])
    }

    @Test func nonOverlappingOrOtherLayerOrOwnWindowsDoNotObscure() {
        let pins = [PinTarget(key: 1, pid: 10, bounds: a)]
        let base = win(1, pid: 10, a)
        #expect(PinRaise.windowsToRaise(pinned: pins, windows: [win(2, pid: 20, far), base]).isEmpty)
        #expect(PinRaise.windowsToRaise(pinned: pins, windows: [win(2, pid: 20, b, layer: 25), base]).isEmpty)
        #expect(PinRaise.windowsToRaise(pinned: pins, windows: [win(2, pid: 20, b, alpha: 0), base]).isEmpty)
        #expect(PinRaise.windowsToRaise(pinned: pins, windows: [win(2, pid: 99, b), base], ignoringPid: 99).isEmpty)
        // Edge-touching only.
        #expect(PinRaise.windowsToRaise(pinned: pins, windows: [win(2, pid: 20, CGRect(x: 500, y: 0, width: 100, height: 100)), base]).isEmpty)
    }

    @Test func unmatchedPinIsSkipped() {
        let pins = [PinTarget(key: 1, pid: 10, bounds: a)]   // minimized / other Space: not on screen
        #expect(PinRaise.windowsToRaise(pinned: pins, windows: [win(2, pid: 20, b)]).isEmpty)
    }

    @Test func boundsMatchWithinTolerance() {
        let pins = [PinTarget(key: 1, pid: 10, bounds: a.offsetBy(dx: 1, dy: -1))]
        let wins = [win(2, pid: 20, b), win(1, pid: 10, a)]
        #expect(PinRaise.windowsToRaise(pinned: pins, windows: wins) == [1])
    }

    @Test func pinsKeepRelativeOrder() {
        // Pin 1 (low priority) is above pin 2 (high priority): pin 1 is fine only if it is the lower one.
        let pins = [PinTarget(key: 1, pid: 10, bounds: a), PinTarget(key: 2, pid: 20, bounds: b)]
        let ok = [win(2, pid: 20, b), win(1, pid: 10, a)]
        #expect(PinRaise.windowsToRaise(pinned: pins, windows: ok).isEmpty)
        let wrong = [win(1, pid: 10, a), win(2, pid: 20, b)]
        #expect(PinRaise.windowsToRaise(pinned: pins, windows: wrong) == [2])
    }

    @Test func severalObscuredAreRaisedLowestPriorityFirst() {
        let pins = [PinTarget(key: 1, pid: 10, bounds: a), PinTarget(key: 2, pid: 20, bounds: b)]
        let wins = [win(3, pid: 30, CGRect(x: 0, y: 0, width: 900, height: 600)), win(2, pid: 20, b), win(1, pid: 10, a)]
        #expect(PinRaise.windowsToRaise(pinned: pins, windows: wins) == [1, 2])
    }

    // MARK: Rate limiting

    @Test func gateLimitsPerKey() {
        var g = RaiseGate()
        let first = g.allowRaise(key: 1, now: 10)
        let tooSoon = g.allowRaise(key: 1, now: 10.1)
        let otherKey = g.allowRaise(key: 2, now: 10.1)
        let later = g.allowRaise(key: 1, now: 10.2)
        g.forget(key: 1)
        let afterForget = g.allowRaise(key: 1, now: 10.21)
        #expect(first && !tooSoon && otherKey && later && afterForget)
    }

    @Test func gateEchoWindow() {
        var g = RaiseGate()
        #expect(!g.isEcho(now: 5))
        _ = g.allowRaise(key: 1, now: 10)
        #expect(g.isEcho(now: 10.2))
        #expect(!g.isEcho(now: 10.31))
    }

    // MARK: Menu text

    @Test func toggleItemTitles() {
        #expect(PinMenuLogic.toggleItem(isPinned: false, featureEnabled: true) == ("Pin Window on Top", true))
        #expect(PinMenuLogic.toggleItem(isPinned: true, featureEnabled: true) == ("Unpin Window", true))
        #expect(PinMenuLogic.toggleItem(isPinned: nil, featureEnabled: true).enabled == false)
        #expect(PinMenuLogic.toggleItem(isPinned: false, featureEnabled: false).enabled == false)
    }

    @Test func listTitles() {
        #expect(PinMenuLogic.listTitle(appName: "Safari", windowTitle: "Docs") == "Safari — Docs")
        #expect(PinMenuLogic.listTitle(appName: "Safari", windowTitle: "  ") == "Safari")
        #expect(PinMenuLogic.listTitle(appName: "A", windowTitle: String(repeating: "x", count: 100)).count == 50)
        #expect(PinMenuLogic.submenuTitle(count: 0) == "Pinned Windows")
        #expect(PinMenuLogic.submenuTitle(count: 2) == "Pinned Windows (2)")
    }

    // MARK: Shortcut

    @Test func pinShortcutDefaultsToControlOptionP() {
        let spec = ShortcutSpecs.spec(.pinWindow)
        #expect(spec.defaultShortcut.keyCode == 35)
        #expect(spec.defaultShortcut.modifiers == .controlOption)
    }

    @Test func pinShortcutOnlyActiveWhenEnabled() {
        let d = UserDefaults(suiteName: "pin-tests")!
        d.removePersistentDomain(forName: "pin-tests")
        #expect(ShortcutStore.entries(defaults: d).first { $0.id == .pinWindow }?.active == true)
        d.set(false, forKey: Prefs.pinnedWindowsEnabledKey)
        #expect(ShortcutStore.entries(defaults: d).first { $0.id == .pinWindow }?.active == false)
    }
}

@Suite struct PinForceTests {
    @Test func forceDecision() {
        func f(_ e: Bool = true, _ o: Bool = true, _ p: Bool = false, _ s: Bool = false, _ m: Bool = false) -> Bool {
            PinForce.shouldForce(enabled: e, stillObscured: o, pinnedAppIsFrontmost: p, frontmostIsSelf: s, mouseButtonDown: m)
        }
        #expect(f())
        #expect(!f(false))
        #expect(!f(true, false))
        #expect(!f(true, true, true))
        #expect(!f(true, true, false, true))
        #expect(!f(true, true, false, false, true))
    }

    @Test func forceGateBacksOffAfterFailures() {
        var g = RaiseGate()
        let a = g.allowForce(key: 1, now: 100)
        let tooSoon = g.allowForce(key: 1, now: 100.5)
        #expect(a && !tooSoon)
        g.recordForce(key: 1, succeeded: false)
        #expect(g.forceDelay(key: 1) == 3.0)
        let early = g.allowForce(key: 1, now: 102)
        let later = g.allowForce(key: 1, now: 103.1)
        #expect(!early && later)
        g.recordForce(key: 1, succeeded: true)
        #expect(g.forceDelay(key: 1) == 1.5)
        for _ in 0..<10 { g.recordForce(key: 2, succeeded: false) }
        #expect(g.forceDelay(key: 2) == 30)
    }

    @Test func forceCountsAsEcho() {
        var g = RaiseGate()
        _ = g.allowForce(key: 1, now: 50)
        #expect(g.isEcho(now: 50.1))
    }
}
