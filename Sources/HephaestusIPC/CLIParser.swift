import Foundation

public enum ParsedCommand: Equatable {
    case help
    case version
    case request(Request)
}

public struct UsageError: Error, Equatable, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// Hand-written argument parser (no dependencies). `arguments` excludes the program name.
public enum CLIParser {
    public static let usage = """
    Usage: hephaestus-cli <command> [options]

    Commands:
      open-editor                       Open the layout editor on the screen under the cursor
      get-monitors                      List monitors (1-based index) and their layouts
      get-layouts                       List layouts with an ASCII preview of their zones
      get-active-layout                 Show the layout active on each monitor
      set-layout <layout> [--monitor N | --all]
                                        Apply a layout (id or name) to monitor N (see get-monitors),
                                        to all monitors, or to the monitor under the cursor
      open-settings                     Open the settings window
      get-hotkeys                       List layout hotkey numbers (0-9)
      set-hotkey <0-9> <layout>         Assign a hotkey number to a layout (id or name)
      remove-hotkey <0-9>               Remove a hotkey number

    Options:
      -h, --help, help                  Show this help
      --version                         Show the version

    The commands talk to the running Hephaestus app (start it with: open -a Hephaestus).
    """

    public static func parse(_ arguments: [String]) -> Result<ParsedCommand, UsageError> {
        guard let first = arguments.first else { return .failure(UsageError("missing command")) }
        let rest = Array(arguments.dropFirst())
        switch first {
        case "-h", "--help", "help": return .success(.help)
        case "--version", "-v", "version": return .success(.version)
        default: break
        }
        guard let name = CommandName(rawValue: first) else {
            return .failure(UsageError("unknown command '\(first)'"))
        }
        switch name {
        case .openEditor, .getMonitors, .getLayouts, .getActiveLayout, .openSettings, .getHotkeys:
            guard rest.isEmpty else { return .failure(UsageError("'\(first)' takes no arguments")) }
            return .success(.request(Request(command: name)))
        case .setLayout: return parseSetLayout(rest)
        case .setHotkey:
            guard rest.count == 2 else { return .failure(UsageError("usage: set-hotkey <0-9> <layout>")) }
            return number(rest[0]).map { .request(Request(command: .setHotkey, layout: rest[1], number: $0)) }
        case .removeHotkey:
            guard rest.count == 1 else { return .failure(UsageError("usage: remove-hotkey <0-9>")) }
            return number(rest[0]).map { .request(Request(command: .removeHotkey, number: $0)) }
        }
    }

    private static func number(_ s: String) -> Result<Int, UsageError> {
        guard let n = Int(s), (0...9).contains(n) else {
            return .failure(UsageError("invalid hotkey number '\(s)' (expected 0-9)"))
        }
        return .success(n)
    }

    private static func parseSetLayout(_ args: [String]) -> Result<ParsedCommand, UsageError> {
        var layout: String?
        var monitor: Int?
        var all = false
        var i = 0
        while i < args.count {
            let a = args[i]
            switch a {
            case "--all": all = true
            case "--monitor":
                guard i + 1 < args.count else { return .failure(UsageError("--monitor needs a value")) }
                guard let n = Int(args[i + 1]), n >= 1 else {
                    return .failure(UsageError("invalid monitor '\(args[i + 1])' (expected a number from get-monitors, starting at 1)"))
                }
                guard monitor == nil else { return .failure(UsageError("--monitor given twice")) }
                monitor = n
                i += 1
            default:
                if a.hasPrefix("--") { return .failure(UsageError("unknown option '\(a)'")) }
                guard layout == nil else { return .failure(UsageError("unexpected argument '\(a)'")) }
                layout = a
            }
            i += 1
        }
        guard let layout, !layout.isEmpty else { return .failure(UsageError("usage: set-layout <layout> [--monitor N | --all]")) }
        if all && monitor != nil { return .failure(UsageError("--monitor and --all cannot be combined")) }
        return .success(.request(Request(command: .setLayout, layout: layout, monitor: monitor, all: all ? true : nil)))
    }
}
