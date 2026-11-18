import Foundation
import Testing
@testable import HephaestusIPC

@Suite struct ProtocolTests {
    @Test func requestRoundTrip() throws {
        let r = Request(command: .setLayout, layout: "Focus", monitor: 2, all: nil, number: nil)
        let data = try Codec.encode(r)
        #expect(data.last == 0x0A)
        #expect(try Codec.decode(Request.self, from: data.dropLast()) == r)
        #expect(try Codec.decode(Request.self, from: data) == r)  // trailing newline is plain JSON whitespace
    }

    @Test func responseRoundTrip() throws {
        let resp = Response(
            message: "hi",
            monitors: [MonitorInfo(index: 1, name: "Studio", uuid: "U", width: 3440, height: 1440, isMain: true, layoutID: "a", layoutName: "A")],
            layouts: [LayoutInfo(id: "a", name: "A", kind: "grid", builtIn: false, zones: [ZoneRect(x: 0, y: 0, w: 1, h: 1)], hotkey: 3)],
            hotkeys: [HotkeyInfo(number: 3, layoutID: "a", layoutName: "A")], hotkeyModifiers: "⌃⌥⌘")
        #expect(try Codec.decode(Response.self, from: Codec.encode(resp)) == resp)
        #expect(try Codec.decode(Response.self, from: Codec.encode(Response.failure("x"))) == .failure("x"))
    }

    @Test func rejectsGarbageUnknownCommandsAndOversize() {
        #expect(throws: ProtocolError.malformed) { try Codec.decode(Request.self, from: Data("nope".utf8)) }
        #expect(throws: ProtocolError.malformed) { try Codec.decode(Request.self, from: Data(#"{"command":"rm -rf"}"#.utf8)) }
        #expect(throws: ProtocolError.tooLarge) { try Codec.decode(Request.self, from: Data(count: IPC.maxMessageBytes + 1)) }
    }

    @Test func socketPathFitsSockaddr() {
        #expect(makeSockAddr("/tmp/x.sock") != nil)
        #expect(makeSockAddr("/" + String(repeating: "a", count: 200)) == nil)
    }

    @Test func notRunningMessage() {
        let path = "/tmp/hph-missing-\(UUID().uuidString.prefix(8)).sock"
        #expect(throws: ClientError.notRunning) { try SocketClient.send(Request(command: .getMonitors), socketPath: path) }
        #expect(ClientError.notRunning.description == "Hephaestus is not running. Start it with: open -a Hephaestus")
    }

    @Test func versionIsSet() { #expect(!HephaestusVersion.current.isEmpty) }
}
