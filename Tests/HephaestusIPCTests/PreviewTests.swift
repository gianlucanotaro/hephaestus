import Foundation
import Testing
@testable import HephaestusIPC

@Suite struct PreviewTests {
    @Test func singleZone() {
        let art = AsciiPreview.render([ZoneRect(x: 0, y: 0, w: 1, h: 1)], width: 10, height: 4)
        #expect(art == """
        +---------+
        |         |
        |    1    |
        |         |
        +---------+
        """)
    }

    @Test func threeColumnsAreNumberedAndShareEdges() {
        let zones = (0..<3).map { ZoneRect(x: Double($0) / 3, y: 0, w: 1.0 / 3, h: 1) }
        let art = AsciiPreview.render(zones, width: 12, height: 4)
        let lines = art.split(separator: "\n")
        #expect(lines.count == 5)
        #expect(lines[0] == "+---+---+---+")
        #expect(lines[4] == "+---+---+---+")
        #expect(art.contains("1") && art.contains("2") && art.contains("3"))
        #expect(lines.allSatisfy { $0.count <= 13 })
    }

    @Test func emptyAndDegenerate() {
        #expect(AsciiPreview.render([]) == "")
        #expect(!AsciiPreview.render([ZoneRect(x: 0.5, y: 0.5, w: 0, h: 0)]).isEmpty)  // never crashes, stays in bounds
        #expect(!AsciiPreview.render([ZoneRect(x: 0.9, y: 0.9, w: 0.5, h: 0.5)]).isEmpty)
    }

    @Test func outputRendering() {
        let layout = LayoutInfo(id: "x", name: "X", kind: "grid", builtIn: false, zones: [ZoneRect(x: 0, y: 0, w: 1, h: 1)], hotkey: 2)
        let text = CLIOutput.render(Request(command: .getLayouts), Response(layouts: [layout]))
        #expect(text.hasPrefix("X  [x]  grid  hotkey 2\n    +"))
        let mon = MonitorInfo(index: 1, name: "M", uuid: "u", width: 100, height: 50, isMain: true, layoutID: "x", layoutName: "X")
        #expect(CLIOutput.render(Request(command: .getMonitors), Response(monitors: [mon])) == "1: M (main)  100x50  layout: X")
        #expect(CLIOutput.render(Request(command: .getHotkeys), Response(hotkeys: [])) == "No hotkeys assigned.")
        #expect(CLIOutput.render(Request(command: .openSettings), Response()) == "OK")
    }
}
