import Foundation

// Wire protocol between `hephaestus-cli` and the running app: one JSON object per line over a unix-domain
// socket (request line, response line, then the connection closes). Foundation only, shared by both sides.

public enum IPC {
    /// Messages larger than this are rejected (both directions), so a rogue peer cannot make us buffer unboundedly.
    public static let maxMessageBytes = 256 * 1024

    public static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Hephaestus", isDirectory: true)
    }
    /// Well-known socket path. The directory is created 0700 and the socket 0600 by the server.
    public static var socketPath: String { supportDirectory.appendingPathComponent("cli.sock").path }
    /// `sockaddr_un.sun_path` holds 104 bytes on macOS (including the NUL).
    public static let maxSocketPathBytes = 103
}

public enum CommandName: String, Codable, CaseIterable, Sendable {
    case openEditor = "open-editor"
    case getMonitors = "get-monitors"
    case getLayouts = "get-layouts"
    case getActiveLayout = "get-active-layout"
    case setLayout = "set-layout"
    case openSettings = "open-settings"
    case getHotkeys = "get-hotkeys"
    case setHotkey = "set-hotkey"
    case removeHotkey = "remove-hotkey"
}

public struct Request: Codable, Equatable, Sendable {
    public var command: CommandName
    /// Layout id or name (`set-layout`, `set-hotkey`).
    public var layout: String?
    /// 1-based monitor index as printed by `get-monitors` (`set-layout`).
    public var monitor: Int?
    /// Apply to every monitor (`set-layout`).
    public var all: Bool?
    /// Hotkey number 0-9 (`set-hotkey`, `remove-hotkey`).
    public var number: Int?

    public init(command: CommandName, layout: String? = nil, monitor: Int? = nil, all: Bool? = nil, number: Int? = nil) {
        self.command = command
        self.layout = layout
        self.monitor = monitor
        self.all = all
        self.number = number
    }
}

public struct ZoneRect: Codable, Equatable, Sendable {
    /// Relative to the screen's usable area, 0...1, origin top-left.
    public var x, y, w, h: Double
    public init(x: Double, y: Double, w: Double, h: Double) { self.x = x; self.y = y; self.w = w; self.h = h }
}

public struct MonitorInfo: Codable, Equatable, Sendable {
    /// 1-based.
    public var index: Int
    public var name: String
    public var uuid: String
    public var width: Int
    public var height: Int
    public var isMain: Bool
    public var layoutID: String
    public var layoutName: String
    public init(index: Int, name: String, uuid: String, width: Int, height: Int, isMain: Bool, layoutID: String, layoutName: String) {
        self.index = index; self.name = name; self.uuid = uuid; self.width = width; self.height = height
        self.isMain = isMain; self.layoutID = layoutID; self.layoutName = layoutName
    }
}

public struct LayoutInfo: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var kind: String
    public var builtIn: Bool
    public var zones: [ZoneRect]
    /// Hotkey number (0-9) if assigned.
    public var hotkey: Int?
    public init(id: String, name: String, kind: String, builtIn: Bool, zones: [ZoneRect], hotkey: Int?) {
        self.id = id; self.name = name; self.kind = kind; self.builtIn = builtIn; self.zones = zones; self.hotkey = hotkey
    }
}

public struct HotkeyInfo: Codable, Equatable, Sendable {
    public var number: Int
    public var layoutID: String
    public var layoutName: String
    public init(number: Int, layoutID: String, layoutName: String) {
        self.number = number; self.layoutID = layoutID; self.layoutName = layoutName
    }
}

public struct Response: Codable, Equatable, Sendable {
    public var ok: Bool
    public var error: String?
    public var message: String?
    public var monitors: [MonitorInfo]?
    public var layouts: [LayoutInfo]?
    public var hotkeys: [HotkeyInfo]?
    /// Modifier symbols shared by the numbered hotkeys, e.g. "⌃⌥⌘".
    public var hotkeyModifiers: String?

    public init(ok: Bool = true, error: String? = nil, message: String? = nil, monitors: [MonitorInfo]? = nil,
                layouts: [LayoutInfo]? = nil, hotkeys: [HotkeyInfo]? = nil, hotkeyModifiers: String? = nil) {
        self.ok = ok; self.error = error; self.message = message; self.monitors = monitors
        self.layouts = layouts; self.hotkeys = hotkeys; self.hotkeyModifiers = hotkeyModifiers
    }

    public static func failure(_ message: String) -> Response { Response(ok: false, error: message) }
}

public enum ProtocolError: Error, Equatable, CustomStringConvertible {
    case tooLarge
    case malformed
    public var description: String {
        switch self {
        case .tooLarge: return "message too large"
        case .malformed: return "malformed message"
        }
    }
}

/// Line-delimited JSON codec.
public enum Codec {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        var data = try enc.encode(value)
        guard data.count < IPC.maxMessageBytes else { throw ProtocolError.tooLarge }
        data.append(0x0A)
        return data
    }

    /// Decodes one message; accepts an optional trailing newline.
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        guard data.count <= IPC.maxMessageBytes else { throw ProtocolError.tooLarge }
        do { return try JSONDecoder().decode(type, from: data) } catch { throw ProtocolError.malformed }
    }
}
