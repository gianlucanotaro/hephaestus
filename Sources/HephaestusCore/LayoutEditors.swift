import AppKit

/// Canvas editor entry points (issue #7).
enum CanvasEditor {
    /// Opens the canvas editor on `screen`. With `editing == nil` it starts with one zone. With a layout it starts
    /// from that layout's zones (any kind, overlapping or not). A custom canvas layout is updated in place; any
    /// other layout (grid, built-in) is saved as a new canvas copy. Returns false if the layout is invalid.
    @discardableResult
    static func open(on screen: NSScreen, editing: Layout? = nil) -> Bool {
        let size = screen.visibleFrame.size
        let model: CanvasModel
        let name: String
        let target: Layout?
        if let editing {
            guard let m = CanvasModel(layout: editing, screenSize: size) else { return false }
            model = m
            let inPlace = editing.kind == .canvas && !editing.isBuiltIn
            target = inPlace ? editing : nil      // converting kinds never overwrites the original
            name = inPlace ? editing.name : LayoutEditors.copyName(of: editing)
        } else {
            model = CanvasModel(screenSize: size)
            name = "New Canvas Layout"
            target = nil
        }
        LayoutEditorController.open(editor: CanvasEditorView(model: model), on: screen, name: name, editing: target)
        return true
    }
}

/// Picks the right editor for a layout. #8 (hotkey) should call `LayoutEditors.open(on:editing:)` with the
/// screen's current layout (`ZoneLayout.layout(for: screen)`).
enum LayoutEditors {
    /// Opens the best editor: canvas layouts -> canvas editor; grid layouts and grid-shaped built-ins -> grid
    /// editor; anything else (e.g. overlapping Focus) -> canvas copy. Returns false only for an invalid layout.
    /// For "new layout" use `GridEditor.open(on:)` / `CanvasEditor.open(on:)`.
    @discardableResult
    static func open(on screen: NSScreen, editing layout: Layout) -> Bool {
        switch route(for: layout) {
        case .grid: return GridEditor.open(on: screen, editing: layout)
        case .canvas: return CanvasEditor.open(on: screen, editing: layout)
        case nil: return false
        }
    }

    enum Route: Equatable { case grid, canvas }

    /// Which editor `open` uses for `layout`; nil when it is not editable at all (invalid).
    static func route(for layout: Layout) -> Route? {
        if layout.kind == .canvas && !layout.isBuiltIn { return layout.isValid ? .canvas : nil }
        if GridEditor.canEdit(layout) { return .grid }
        return layout.isValid ? .canvas : nil
    }

    static func canEdit(_ layout: Layout) -> Bool { route(for: layout) != nil }

    /// Menu title for "edit the screen's current layout".
    static func editTitle(for layout: Layout) -> String {
        switch route(for: layout) {
        case .grid?: return layout.isBuiltIn ? "Copy “\(layout.name)” as New Grid…" : "Edit “\(layout.name)”…"
        case .canvas?: return layout.kind == .canvas && !layout.isBuiltIn ? "Edit “\(layout.name)”…" : "Copy “\(layout.name)” as New Canvas…"
        case nil: return "Edit Layout…"
        }
    }

    /// Whether to offer an extra "edit as canvas copy" item (grid-shaped layouts normally open in the grid editor).
    static func canCopyAsCanvas(_ layout: Layout) -> Bool { route(for: layout) == .grid }

    /// Name for a layout copied into another editor ("Columns copy").
    static func copyName(of layout: Layout) -> String { "\(layout.name) copy" }
}
