import AppKit

/// Index of a zone inside a layout's `zones` array. Stable for a given layout; zones are ordered
/// left-to-right (ties: top-to-bottom), so index 0 is the leftmost zone.
typealias ZoneIndex = Int

/// A rectangle relative to a screen's usable frame: every value in 0...1.
/// File-format convention: origin is the TOP-left corner and y grows downward (like FancyZones/CSS),
/// so layout files are easy to read and write by hand. `ZoneLayout` converts to AppKit space.
struct RelRect: Codable, Equatable {
    var x: Double
    var y: Double
    var w: Double
    var h: Double

    init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x; self.y = y; self.w = w; self.h = h
    }

    /// True when finite, non-empty and fully inside the unit square (with float tolerance).
    var isValid: Bool {
        let eps = 1e-9
        return [x, y, w, h].allSatisfy(\.isFinite) && w > 0 && h > 0
            && x >= -eps && y >= -eps && x + w <= 1 + eps && y + h <= 1 + eps
    }

    /// Resolve against `frame` (AppKit space, bottom-left origin).
    func resolve(in frame: CGRect) -> CGRect {
        CGRect(x: frame.minX + x * frame.width,
               y: frame.maxY - (y + h) * frame.height,
               width: w * frame.width, height: h * frame.height)
    }
}

enum LayoutKind: String, Codable {
    case template   // generated built-in
    case grid       // user layout built from a grid
    case canvas     // user layout with free-form (possibly overlapping) zones
}

/// Layouts whose geometry cannot be expressed purely as relative rects.
enum TemplateRule: String, Codable {
    /// Centered rect of `Prefs.aspect` at full height; side zones share the rest; falls back to
    /// 25/50/25 when the sides would be under 10% of the width. The layout's own `zones` are only
    /// the nominal 25/50/25 split.
    case ultrawideThreeWay
}

struct Layout: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var kind: LayoutKind
    var zones: [RelRect]
    var rule: TemplateRule?

    init(id: String, name: String, kind: LayoutKind, zones: [RelRect], rule: TemplateRule? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.zones = zones; self.rule = rule
    }

    var isBuiltIn: Bool { LayoutTemplates.builtIn.contains { $0.id == id } }

    /// Usable layouts have a non-blank id/name and at least one valid zone.
    var isValid: Bool {
        !id.isEmpty && !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !zones.isEmpty && zones.allSatisfy(\.isValid)
    }

    /// "Zone N" (1-based) — what menus and overlays call a zone.
    static func zoneTitle(_ index: ZoneIndex) -> String { "Zone \(index + 1)" }
}

/// Which zone a "snap left / middle / right" action targets, independent of the layout's zone count.
enum SnapSlot {
    case first, middle, last
    func index(count: Int) -> ZoneIndex {
        switch self {
        case .first: return 0
        case .middle: return max(0, count / 2)
        case .last: return max(0, count - 1)
        }
    }
}

/// Pure generators for the built-in layouts. All return zones in left-to-right, top-to-bottom order.
enum LayoutTemplates {
    static let ultrawideID = "builtin.ultrawide-3way"
    static let defaultID = ultrawideID

    static func columns(_ n: Int) -> [RelRect] {
        let n = max(1, n)
        return (0..<n).map { RelRect(x: Double($0) / Double(n), y: 0, w: 1 / Double(n), h: 1) }
    }

    static func rows(_ n: Int) -> [RelRect] {
        let n = max(1, n)
        return (0..<n).map { RelRect(x: 0, y: Double($0) / Double(n), w: 1, h: 1 / Double(n)) }
    }

    /// `rows` x `cols` equal cells in reading order (row by row).
    static func grid(rows: Int, cols: Int) -> [RelRect] {
        let rows = max(1, rows), cols = max(1, cols)
        return (0..<rows).flatMap { r in
            (0..<cols).map { c in
                RelRect(x: Double(c) / Double(cols), y: Double(r) / Double(rows), w: 1 / Double(cols), h: 1 / Double(rows))
            }
        }
    }

    /// One large main zone (left two thirds) plus two stacked zones on the right.
    static func priorityGrid() -> [RelRect] {
        [RelRect(x: 0, y: 0, w: 2.0 / 3, h: 1),
         RelRect(x: 2.0 / 3, y: 0, w: 1.0 / 3, h: 0.5),
         RelRect(x: 2.0 / 3, y: 0.5, w: 1.0 / 3, h: 0.5)]
    }

    /// Three cascading, overlapping 60% x 60% zones (FancyZones "Focus").
    static func focus() -> [RelRect] {
        (0..<3).map { RelRect(x: 0.1 + 0.1 * Double($0), y: 0.1 + 0.1 * Double($0), w: 0.6, h: 0.6) }
    }

    /// Nominal 25/50/25 zones; real geometry comes from `TemplateRule.ultrawideThreeWay`.
    static var ultrawide: Layout {
        Layout(id: ultrawideID, name: "Ultrawide 3-way", kind: .template,
               zones: [RelRect(x: 0, y: 0, w: 0.25, h: 1), RelRect(x: 0.25, y: 0, w: 0.5, h: 1),
                       RelRect(x: 0.75, y: 0, w: 0.25, h: 1)],
               rule: .ultrawideThreeWay)
    }

    /// Built-in layouts in menu order; the default (Ultrawide 3-way) first.
    static let builtIn: [Layout] = [
        ultrawide,
        Layout(id: "builtin.focus", name: "Focus", kind: .template, zones: focus()),
        Layout(id: "builtin.columns", name: "Columns", kind: .template, zones: columns(3)),
        Layout(id: "builtin.rows", name: "Rows", kind: .template, zones: rows(3)),
        Layout(id: "builtin.grid", name: "Grid", kind: .template, zones: grid(rows: 2, cols: 3)),
        Layout(id: "builtin.priority-grid", name: "Priority Grid", kind: .template, zones: priorityGrid()),
    ]
}

// MARK: - Persistence

/// On-disk format of layouts.json.
struct LayoutFile: Codable {
    var version = 1
    var layouts: [Layout]
}

enum LayoutIOError: LocalizedError {
    case invalid
    var errorDescription: String? { "The file is not a valid Hephaestus layout." }
}

/// Single source of truth for layouts: built-ins plus custom layouts stored in
/// `~/Library/Application Support/Hephaestus/layouts.json`. Main-thread use only.
/// Posts `LayoutStore.didChange` whenever the layout list or the active layout changes.
final class LayoutStore {
    static let didChange = Notification.Name("HephaestusLayoutsDidChange")
    static let shared = LayoutStore()

    static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Hephaestus", isDirectory: true)
            .appendingPathComponent("layouts.json")
    }

    let fileURL: URL
    private let defaults: UserDefaults
    private(set) var custom: [Layout] = []

    init(fileURL: URL = LayoutStore.defaultFileURL, defaults: UserDefaults = .standard) {
        self.fileURL = fileURL
        self.defaults = defaults
        load()
    }

    /// Built-ins followed by custom layouts.
    var all: [Layout] { LayoutTemplates.builtIn + custom }

    func layout(id: String) -> Layout? { all.first { $0.id == id } }

    /// The globally active layout; falls back to the default if the stored id no longer exists.
    var active: Layout {
        layout(id: defaults.string(forKey: Prefs.activeLayoutKey) ?? "") ?? LayoutTemplates.builtIn[0]
    }

    func setActive(id: String) {
        guard layout(id: id) != nil else { return }
        defaults.set(id, forKey: Prefs.activeLayoutKey)
        notify()
    }

    /// Adds or replaces a custom layout (matched by id). Invalid layouts and built-in ids are rejected.
    @discardableResult
    func upsert(_ layout: Layout) -> Bool {
        guard layout.isValid, !layout.isBuiltIn else { return false }
        if let i = custom.firstIndex(where: { $0.id == layout.id }) { custom[i] = layout } else { custom.append(layout) }
        save()
        notify()
        return true
    }

    func remove(id: String) {
        guard custom.contains(where: { $0.id == id }) else { return }
        custom.removeAll { $0.id == id }
        save()
        notify()
    }

    /// Reads layouts.json. A missing file is fine; a corrupt one is moved aside (`.corrupt`) and ignored.
    func load() {
        guard let data = try? Data(contentsOf: fileURL) else { custom = []; return }
        if let file = try? JSONDecoder().decode(LayoutFile.self, from: data) {
            custom = Self.sanitize(file.layouts)
        } else {
            custom = []
            let aside = fileURL.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: fileURL, to: aside)
        }
    }

    /// Writes custom layouts atomically, creating the directory if needed. Returns false on failure.
    @discardableResult
    func save() -> Bool {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.encode(LayoutFile(layouts: custom)).write(to: fileURL, options: .atomic)
            return true
        } catch {
            NSLog("Hephaestus: could not save layouts: \(error)")
            return false
        }
    }

    /// Drops invalid layouts, built-in ids and duplicate ids.
    static func sanitize(_ layouts: [Layout]) -> [Layout] {
        var seen = Set(LayoutTemplates.builtIn.map(\.id))
        return layouts.filter { $0.isValid && seen.insert($0.id).inserted }
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(value)
    }

    // MARK: Import / export

    /// Writes a single layout as JSON.
    func export(_ layout: Layout, to url: URL) throws {
        try Self.encode(layout).write(to: url, options: .atomic)
    }

    /// Reads a layout JSON file (a single layout, or a layouts.json-style file whose first layout is used),
    /// stores it as a custom layout (given a fresh id if it collides with an existing one) and returns it.
    @discardableResult
    func importLayout(from url: URL) throws -> Layout {
        let data = try Data(contentsOf: url)
        let dec = JSONDecoder()
        var layout: Layout
        if let single = try? dec.decode(Layout.self, from: data) {
            layout = single
        } else if let first = (try? dec.decode(LayoutFile.self, from: data))?.layouts.first {
            layout = first
        } else {
            throw LayoutIOError.invalid
        }
        guard layout.isValid else { throw LayoutIOError.invalid }
        if layout.kind == .template { layout.kind = .canvas }
        if self.layout(id: layout.id) != nil { layout.id = "custom.\(UUID().uuidString.lowercased())" }
        guard upsert(layout) else { throw LayoutIOError.invalid }
        return layout
    }

    private func notify() { NotificationCenter.default.post(name: Self.didChange, object: self) }
}

extension Prefs {
    static let activeLayoutKey = "activeLayoutID"

    static func registerLayoutDefaults() {
        UserDefaults.standard.register(defaults: [activeLayoutKey: LayoutTemplates.defaultID])
    }
}
