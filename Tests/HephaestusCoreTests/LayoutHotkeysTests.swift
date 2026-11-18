import Carbon.HIToolbox
import Foundation
import Testing
@testable import HephaestusCore

private func makeHotkeys() -> (LayoutHotkeys, LayoutStore) {
    let defaults = UserDefaults(suiteName: "hephaestus-tests-\(UUID().uuidString)")!
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("hephaestus-tests-\(UUID().uuidString)", isDirectory: true).appendingPathComponent("layouts.json")
    let layouts = LayoutStore(fileURL: url, defaults: defaults)
    return (LayoutHotkeys(layouts: layouts, defaults: defaults), layouts)
}

@Suite struct LayoutHotkeysTests {
    @Test func assignAndLookup() {
        let (h, layouts) = makeHotkeys()
        let ids = layouts.all.map(\.id)
        h.assign(number: 3, layoutID: ids[1])
        #expect(h.layout(forNumber: 3)?.id == ids[1])
        #expect(h.number(forLayoutID: ids[1]) == 3)
        #expect(h.layout(forNumber: 4) == nil)
    }

    @Test func numberMovesBetweenLayouts() {
        let (h, layouts) = makeHotkeys()
        let ids = layouts.all.map(\.id)
        h.assign(number: 1, layoutID: ids[0])
        h.assign(number: 1, layoutID: ids[1])
        #expect(h.layout(forNumber: 1)?.id == ids[1])
        #expect(h.number(forLayoutID: ids[0]) == nil)
    }

    @Test func layoutKeepsOnlyOneNumber() {
        let (h, layouts) = makeHotkeys()
        let id = layouts.all[0].id
        h.assign(number: 1, layoutID: id)
        h.assign(number: 2, layoutID: id)
        #expect(h.numbers == [2])
    }

    @Test func removeAndInvalidInput() {
        let (h, layouts) = makeHotkeys()
        let id = layouts.all[0].id
        h.assign(number: 5, layoutID: id)
        h.remove(number: 5)
        #expect(h.numbers.isEmpty)
        h.assign(number: 10, layoutID: id)
        h.assign(number: -1, layoutID: id)
        h.assign(number: 2, layoutID: "nope")
        #expect(h.map.isEmpty)
    }

    @Test func orderedByNumberAndIgnoresDeletedLayouts() {
        let (h, layouts) = makeHotkeys()
        let ids = layouts.all.map(\.id)
        h.assign(number: 7, layoutID: ids[0])
        h.assign(number: 0, layoutID: ids[1])
        h.assign(number: 2, layoutID: ids[2])
        #expect(h.numbers == [0, 2, 7])
        #expect(h.orderedLayouts.map(\.id) == [ids[1], ids[2], ids[0]])
        // A stale entry (layout deleted) is ignored.
        h.map = h.map.merging([9: "custom.gone"]) { $1 }
        #expect(h.numbers == [0, 2, 7])
    }

    @Test func pureAssigning() {
        let m = LayoutHotkeys.assigning(number: 1, layoutID: "b", in: [1: "a", 2: "b"])
        #expect(m == [1: "b"])
        #expect(LayoutHotkeys.removing(number: 1, from: m).isEmpty)
    }

    @Test func modifiers() {
        #expect(HotkeyModifiers.controlOptionCommand.carbon == controlKey | optionKey | cmdKey)
        #expect(HotkeyModifiers(carbon: 0).isValid == false)
        #expect(HotkeyModifiers(carbon: controlKey | 0x1) == .control)
        #expect(HotkeyModifiers.controlOptionCommand.symbols == "⌃⌥⌘")
    }

    @Test func keyCodes() {
        #expect(LayoutHotkeyKeys.digitKeyCodes.count == 10)
        #expect(Set(LayoutHotkeyKeys.digitKeyCodes).count == 10)
        #expect(LayoutHotkeyKeys.digitKeyCodes[0] == kVK_ANSI_0)
        #expect(LayoutHotkeyKeys.digitKeyCodes[9] == kVK_ANSI_9)
        #expect(LayoutHotkeyKeys.keyCode(forLetter: "e") == kVK_ANSI_E)
        #expect(LayoutHotkeyKeys.keyCode(forLetter: "") == nil)
        #expect(LayoutHotkeyKeys.keyCode(forLetter: "EE") == nil)
        #expect(LayoutHotkeyKeys.letters.count == 26)
    }

    @Test func editorTargetFallsBackToNew() {
        let l = LayoutTemplates.builtIn[0]
        #expect(editorTarget(for: l, canEdit: { _ in true }) == l)
        #expect(editorTarget(for: l, canEdit: { _ in false }) == nil)
    }
}
