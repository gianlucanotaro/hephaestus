import Testing
@testable import HephaestusCore

@Suite struct ZoneCyclingTests {
    private func c(_ id: Int, order: Int, pid: Int32 = 1, title: String = "") -> CycleCandidate {
        CycleCandidate(id: id, order: order, pid: pid, title: title)
    }

    @Test func nextWrapsAround() {
        let l = [c(10, order: 0), c(11, order: 1), c(12, order: 2)]
        #expect(ZoneCycling.nextWindow(in: l, current: 10, direction: .next) == 11)
        #expect(ZoneCycling.nextWindow(in: l, current: 12, direction: .next) == 10)
    }

    @Test func previousWrapsAround() {
        let l = [c(10, order: 0), c(11, order: 1), c(12, order: 2)]
        #expect(ZoneCycling.nextWindow(in: l, current: 11, direction: .previous) == 10)
        #expect(ZoneCycling.nextWindow(in: l, current: 10, direction: .previous) == 12)
    }

    @Test func orderIgnoresInputOrderAndBreaksTiesByPidThenTitle() {
        let l = [c(1, order: 5, pid: 9), c(2, order: 5, pid: 3, title: "b"), c(3, order: 5, pid: 3, title: "a"), c(4, order: 0)]
        #expect(ZoneCycling.ordered(l).map(\.id) == [4, 3, 2, 1])
        #expect(ZoneCycling.nextWindow(in: l, current: 4, direction: .next) == 3)
    }

    @Test func aloneOrEmptyIsNil() {
        #expect(ZoneCycling.nextWindow(in: [c(1, order: 0)], current: 1, direction: .next) == nil)
        #expect(ZoneCycling.nextWindow(in: [], current: 1, direction: .previous) == nil)
    }

    @Test func unknownCurrentStartsAtEnds() {
        let l = [c(1, order: 0), c(2, order: 1)]
        #expect(ZoneCycling.nextWindow(in: l, current: 99, direction: .next) == 1)
        #expect(ZoneCycling.nextWindow(in: l, current: 99, direction: .previous) == 2)
    }
}
