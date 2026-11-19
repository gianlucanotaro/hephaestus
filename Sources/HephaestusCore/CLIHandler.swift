import AppKit
import HephaestusIPC

// Request handling for the command-line interface (issue #17). Everything is injected so the logic is testable
// without real displays or sockets. Main-thread only (the stores are).

struct MonitorSnapshot: Equatable {
    var uuid: String
    var name: String
    var width: Int
    var height: Int
    var isMain: Bool
    var orientation: ScreenOrientation

    init(uuid: String, name: String, width: Int, height: Int, isMain: Bool, orientation: ScreenOrientation) {
        self.uuid = uuid; self.name = name; self.width = width; self.height = height
        self.isMain = isMain; self.orientation = orientation
    }

    init(screen: NSScreen) {
        self.init(uuid: screen.displayUUID, name: screen.localizedName, width: Int(screen.frame.width),
                  height: Int(screen.frame.height), isMain: screen == NSScreen.screens.first,
                  orientation: screen.orientation)
    }
}

struct CLIFailure: Error { let message: String }

final class CLIHandler {
    private let layouts: LayoutStore
    private let screenLayouts: ScreenLayoutStore
    private let hotkeys: LayoutHotkeys
    private let monitors: () -> [MonitorSnapshot]
    /// 0-based index of the monitor under the cursor.
    private let cursorMonitor: () -> Int?
    private let openEditor: () -> Void
    private let openSettings: () -> Void
    /// Span-all-screens on: the first monitor owns the single zone surface (same rule as `ZoneLayout.setLayout`).
    private let spanAll: () -> Bool

    init(layouts: LayoutStore = .shared, screenLayouts: ScreenLayoutStore = .shared, hotkeys: LayoutHotkeys = .shared,
         monitors: @escaping () -> [MonitorSnapshot] = { NSScreen.screens.map(MonitorSnapshot.init(screen:)) },
         cursorMonitor: @escaping () -> Int? = { ZoneLayout.screenUnderCursor().flatMap { NSScreen.screens.firstIndex(of: $0) } },
         openEditor: @escaping () -> Void = openEditorForCursorScreen,
         spanAll: @escaping () -> Bool = { Prefs.spanAllScreens },
         openSettings: @escaping () -> Void) {
        self.spanAll = spanAll
        self.layouts = layouts
        self.screenLayouts = screenLayouts
        self.hotkeys = hotkeys
        self.monitors = monitors
        self.cursorMonitor = cursorMonitor
        self.openEditor = openEditor
        self.openSettings = openSettings
    }

    /// Finds a layout by exact id, else by case-insensitive name. Duplicate names are reported as ambiguous.
    func resolveLayout(_ query: String) -> Result<Layout, CLIFailure> {
        if let l = layouts.layout(id: query) { return .success(l) }
        let matches = layouts.all.filter { $0.name.caseInsensitiveCompare(query) == .orderedSame }
        switch matches.count {
        case 1: return .success(matches[0])
        case 0: return .failure(CLIFailure(message: "Unknown layout '\(query)'. Run 'hephaestus-cli get-layouts' to list layouts."))
        default:
            let ids = matches.map(\.id).joined(separator: ", ")
            return .failure(CLIFailure(message: "Layout name '\(query)' is ambiguous; use one of the ids: \(ids)"))
        }
    }

    func handle(_ request: Request) -> Response {
        switch request.command {
        case .openEditor:
            openEditor()
            return Response(message: "Opened the layout editor.")
        case .openSettings:
            openSettings()
            return Response(message: "Opened settings.")
        case .getMonitors, .getActiveLayout:
            return Response(monitors: monitorInfos())
        case .getLayouts:
            return Response(layouts: layouts.all.map(layoutInfo))
        case .getHotkeys:
            let list = hotkeys.numbers.compactMap { n in
                hotkeys.layout(forNumber: n).map { HotkeyInfo(number: n, layoutID: $0.id, layoutName: $0.name) }
            }
            return Response(hotkeys: list, hotkeyModifiers: Prefs.layoutHotkeyModifiers.symbols)
        case .setLayout: return setLayout(request)
        case .setHotkey:
            guard let n = request.number, LayoutHotkeys.validNumbers.contains(n) else {
                return .failure("Invalid hotkey number (expected 0-9).")
            }
            guard let query = request.layout else { return .failure("Missing layout.") }
            switch resolveLayout(query) {
            case .failure(let e): return .failure(e.message)
            case .success(let l):
                hotkeys.assign(number: n, layoutID: l.id)
                return Response(message: "Hotkey \(n) now selects '\(l.name)'.")
            }
        case .removeHotkey:
            guard let n = request.number, LayoutHotkeys.validNumbers.contains(n) else {
                return .failure("Invalid hotkey number (expected 0-9).")
            }
            guard hotkeys.layout(forNumber: n) != nil else { return .failure("Hotkey \(n) is not assigned.") }
            hotkeys.remove(number: n)
            return Response(message: "Removed hotkey \(n).")
        }
    }

    private func setLayout(_ request: Request) -> Response {
        guard let query = request.layout else { return .failure("Missing layout.") }
        let list = monitors()
        guard !list.isEmpty else { return .failure("No monitors found.") }
        if request.all == true, request.monitor != nil { return .failure("--monitor and --all cannot be combined.") }
        let targets: [Int]
        if request.all == true {
            targets = Array(list.indices)
        } else if let m = request.monitor {
            guard (1...list.count).contains(m) else {
                return .failure("Unknown monitor \(m). Run 'hephaestus-cli get-monitors' (valid: 1-\(list.count)).")
            }
            targets = [m - 1]
        } else {
            targets = [cursorMonitor() ?? 0]
        }
        switch resolveLayout(query) {
        case .failure(let e): return .failure(e.message)
        case .success(let layout):
            let span = spanAll()
            for i in targets { screenLayouts.setLayout(id: layout.id, uuid: ZoneLayout.owner(of: list[i], in: list, span: span).uuid) }
            let where_ = targets.count == list.count && list.count > 1 ? "all monitors"
                : "monitor " + targets.map { String($0 + 1) }.joined(separator: ", ")
            return Response(message: "Applied '\(layout.name)' to \(where_).")
        }
    }

    private func monitorInfos() -> [MonitorInfo] {
        let all = monitors()
        let span = spanAll()
        return all.enumerated().map { i, m in
            let owner = ZoneLayout.owner(of: m, in: all, span: span)
            let l = screenLayouts.layout(uuid: owner.uuid, orientation: owner.orientation)
            return MonitorInfo(index: i + 1, name: m.name, uuid: m.uuid, width: m.width, height: m.height,
                               isMain: m.isMain, layoutID: l.id, layoutName: l.name)
        }
    }

    private func layoutInfo(_ l: Layout) -> LayoutInfo {
        LayoutInfo(id: l.id, name: l.name, kind: l.kind.rawValue, builtIn: l.isBuiltIn,
                   zones: l.zones.map { ZoneRect(x: $0.x, y: $0.y, w: $0.w, h: $0.h) },
                   hotkey: hotkeys.number(forLayoutID: l.id))
    }
}
