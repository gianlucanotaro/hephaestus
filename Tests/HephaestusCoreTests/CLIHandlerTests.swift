import Foundation
import Testing
import HephaestusIPC
@testable import HephaestusCore

private final class Fixture {
    let layouts: LayoutStore
    let screens: ScreenLayoutStore
    let hotkeys: LayoutHotkeys
    var editorOpened = 0
    var settingsOpened = 0
    var cursor: Int? = 1
    var span = false
    lazy var handler = CLIHandler(
        layouts: layouts, screenLayouts: screens, hotkeys: hotkeys,
        monitors: { [MonitorSnapshot(uuid: "A", name: "Left", width: 1920, height: 1080, isMain: true, orientation: .landscape),
                     MonitorSnapshot(uuid: "B", name: "Right", width: 1080, height: 1920, isMain: false, orientation: .portrait)] },
        cursorMonitor: { [unowned self] in cursor },
        openEditor: { [unowned self] in editorOpened += 1 },
        spanAll: { [unowned self] in span },
        openSettings: { [unowned self] in settingsOpened += 1 })

    init() {
        let defaults = UserDefaults(suiteName: "hephaestus-tests-\(UUID().uuidString)")!
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hephaestus-tests-\(UUID().uuidString)", isDirectory: true).appendingPathComponent("layouts.json")
        layouts = LayoutStore(fileURL: url, defaults: defaults)
        screens = ScreenLayoutStore(layouts: layouts, defaults: defaults)
        hotkeys = LayoutHotkeys(layouts: layouts, defaults: defaults)
    }

    func run(_ r: Request) -> Response { handler.handle(r) }
    var ids: [String] { layouts.all.map(\.id) }
}

@Suite struct CLIHandlerTests {
    @Test func monitorsAndLayouts() {
        let f = Fixture()
        let m = f.run(Request(command: .getMonitors)).monitors ?? []
        #expect(m.map(\.index) == [1, 2])
        #expect(m[0].isMain && !m[1].isMain)
        #expect(m[0].layoutID == f.layouts.active.id)
        let l = f.run(Request(command: .getLayouts)).layouts ?? []
        #expect(l.count == f.layouts.all.count)
        #expect(l.allSatisfy { !$0.zones.isEmpty })
    }

    @Test func setLayoutByIdNameAndTarget() {
        let f = Fixture()
        let target = f.layouts.all[1]
        // by id on monitor 2
        #expect(f.run(Request(command: .setLayout, layout: target.id, monitor: 2)).ok)
        #expect(f.screens.layout(uuid: "B", orientation: .portrait).id == target.id)
        #expect(f.screens.layout(uuid: "A", orientation: .landscape).id != target.id)
        // by name, case-insensitive, no flags -> monitor under cursor (index 1 = second)
        let other = f.layouts.all[2]
        #expect(f.run(Request(command: .setLayout, layout: other.name.uppercased())).ok)
        #expect(f.screens.layout(uuid: "B", orientation: .portrait).id == other.id)
        // --all
        #expect(f.run(Request(command: .setLayout, layout: target.id, all: true)).ok)
        #expect(f.screens.layout(uuid: "A", orientation: .landscape).id == target.id)
        #expect(f.screens.layout(uuid: "B", orientation: .portrait).id == target.id)
    }

    @Test func setLayoutWithSpanAssignsTheSurfaceOwner() {
        let f = Fixture()
        f.span = true
        let target = f.layouts.all[1]
        // Monitor 2 targeted, but with span on the first monitor owns the surface (same rule as ZoneLayout.setLayout).
        #expect(f.run(Request(command: .setLayout, layout: target.id, monitor: 2)).ok)
        #expect(f.screens.assignments["A"] == target.id)
        #expect(f.screens.assignments["B"] == nil)
        let m = f.run(Request(command: .getMonitors)).monitors ?? []
        #expect(m.allSatisfy { $0.layoutID == target.id })
    }

    @Test func setLayoutErrors() {
        let f = Fixture()
        let before = f.screens.assignments
        let unknown = f.run(Request(command: .setLayout, layout: "nope", monitor: 1))
        #expect(!unknown.ok && unknown.error?.contains("Unknown layout") == true)
        let badMonitor = f.run(Request(command: .setLayout, layout: f.ids[0], monitor: 3))
        #expect(!badMonitor.ok && badMonitor.error?.contains("Unknown monitor") == true)
        #expect(!f.run(Request(command: .setLayout, layout: f.ids[0], monitor: 0)).ok)
        #expect(!f.run(Request(command: .setLayout)).ok)
        #expect(f.screens.assignments == before)
    }

    @Test func hotkeysLifecycle() {
        let f = Fixture()
        #expect(f.run(Request(command: .getHotkeys)).hotkeys == [])
        let l = f.layouts.all[1]
        #expect(f.run(Request(command: .setHotkey, layout: l.name, number: 4)).ok)
        let list = f.run(Request(command: .getHotkeys)).hotkeys ?? []
        #expect(list == [HotkeyInfo(number: 4, layoutID: l.id, layoutName: l.name)])
        #expect((f.run(Request(command: .getLayouts)).layouts ?? []).first { $0.id == l.id }?.hotkey == 4)
        #expect(f.run(Request(command: .removeHotkey, number: 4)).ok)
        #expect(!f.run(Request(command: .removeHotkey, number: 4)).ok)
        #expect(!f.run(Request(command: .setHotkey, layout: l.id, number: 10)).ok)
        #expect(!f.run(Request(command: .setHotkey, layout: "nope", number: 1)).ok)
        #expect(f.hotkeys.map.isEmpty)
    }

    @Test func openCommands() {
        let f = Fixture()
        #expect(f.run(Request(command: .openEditor)).ok)
        #expect(f.run(Request(command: .openSettings)).ok)
        #expect(f.editorOpened == 1 && f.settingsOpened == 1)
    }

    @Test func realSocketRoundTrip() throws {
        let path = "/tmp/hph-\(UUID().uuidString.prefix(8)).sock"
        let server = CLIServer(path: path) { req in Response(message: "got \(req.command.rawValue)") }
        #expect(server.start())
        defer { server.stop() }
        var st = stat()
        #expect(stat(path, &st) == 0)
        #expect(st.st_mode & 0o777 == 0o600)
        // The server hands requests to the main queue; run the client off-main while the main queue is serviced.
        var result: Result<Response, Error>?
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            result = Result { try SocketClient.send(Request(command: .getMonitors), socketPath: path, timeout: 5) }
            done.signal()
        }
        let deadline = Date().addingTimeInterval(5)
        while done.wait(timeout: .now()) == .timedOut && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        #expect(try result?.get().message == "got get-monitors")
    }
}
