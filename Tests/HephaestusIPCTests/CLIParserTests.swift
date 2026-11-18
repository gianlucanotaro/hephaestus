import Foundation
import Testing
@testable import HephaestusIPC

private func request(_ args: [String]) -> Request? {
    if case .success(.request(let r)) = CLIParser.parse(args) { return r }
    return nil
}
private func error(_ args: [String]) -> String? {
    if case .failure(let e) = CLIParser.parse(args) { return e.description }
    return nil
}

@Suite struct CLIParserTests {
    @Test func helpAndVersion() {
        for a in ["--help", "-h", "help"] { #expect(CLIParser.parse([a]) == .success(.help)) }
        #expect(CLIParser.parse(["--version"]) == .success(.version))
    }

    @Test func simpleCommands() {
        for c in [CommandName.openEditor, .getMonitors, .getLayouts, .getActiveLayout, .openSettings, .getHotkeys] {
            #expect(request([c.rawValue]) == Request(command: c))
            #expect(error([c.rawValue, "extra"]) != nil)
        }
    }

    @Test func setLayoutForms() {
        #expect(request(["set-layout", "Focus"]) == Request(command: .setLayout, layout: "Focus"))
        #expect(request(["set-layout", "Focus", "--monitor", "2"]) == Request(command: .setLayout, layout: "Focus", monitor: 2))
        #expect(request(["set-layout", "--monitor", "2", "Focus"]) == Request(command: .setLayout, layout: "Focus", monitor: 2))
        #expect(request(["set-layout", "Focus", "--all"]) == Request(command: .setLayout, layout: "Focus", all: true))
    }

    @Test func setLayoutErrors() {
        #expect(error(["set-layout"]) != nil)
        #expect(error(["set-layout", "A", "--monitor"]) != nil)
        #expect(error(["set-layout", "A", "--monitor", "x"]) != nil)
        #expect(error(["set-layout", "A", "--monitor", "0"]) != nil)
        #expect(error(["set-layout", "A", "--monitor", "1", "--all"]) != nil)
        #expect(error(["set-layout", "A", "--bogus"]) != nil)
        #expect(error(["set-layout", "A", "B"]) != nil)
    }

    @Test func hotkeys() {
        #expect(request(["set-hotkey", "3", "Focus"]) == Request(command: .setHotkey, layout: "Focus", number: 3))
        #expect(request(["remove-hotkey", "0"]) == Request(command: .removeHotkey, number: 0))
        #expect(error(["set-hotkey", "10", "Focus"])?.contains("0-9") == true)
        #expect(error(["set-hotkey", "-1", "Focus"]) != nil)
        #expect(error(["set-hotkey", "a", "Focus"]) != nil)
        #expect(error(["set-hotkey", "1"]) != nil)
        #expect(error(["remove-hotkey"]) != nil)
        #expect(error(["remove-hotkey", "12"]) != nil)
    }

    @Test func unknownAndMissing() {
        #expect(error([])?.contains("missing") == true)
        #expect(error(["frobnicate"])?.contains("unknown command") == true)
    }

    @Test func usageListsEveryCommand() {
        for c in CommandName.allCases { #expect(CLIParser.usage.contains(c.rawValue)) }
    }
}
