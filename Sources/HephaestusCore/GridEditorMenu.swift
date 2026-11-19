import AppKit

/// Entry points for the grid editor. #8 (hotkey) should call `GridEditor.open(on:editing:)`.
enum GridEditor {
    /// Opens the grid editor on `screen`. With `editing == nil` it starts from three equal columns. With a layout
    /// it starts from that layout when its zones tile the screen (custom layouts are updated in place, built-ins are
    /// saved as a copy). Returns false when the layout cannot be edited as a grid.
    @discardableResult
    static func open(on screen: NSScreen, editing: Layout? = nil) -> Bool {
        let model: GridModel
        let name: String
        if let editing {
            guard let m = GridModel(layout: editing) else { return false }
            model = m
            name = LayoutEditorSave.copyName(of: editing)
        } else {
            model = GridModel()
            name = "New Grid Layout"
        }
        LayoutEditorController.open(editor: GridEditorView(model: model), on: screen, name: name, editing: editing)
        return true
    }

    /// Whether `layout` can be opened with `open(on:editing:)`.
    static func canEdit(_ layout: Layout) -> Bool {
        (layout.kind == .grid || layout.isBuiltIn) && GridModel(layout: layout) != nil
    }
}

/// "New Grid Layout…" / "Edit Layout…" menu items for the screen the layout menu was built for.
final class GridEditorMenu: NSObject {
    private var screen: NSScreen?

    func addItems(to menu: NSMenu, screen: NSScreen?) {
        self.screen = screen
        let new = NSMenuItem(title: "New Grid Layout…", action: #selector(newLayout), keyEquivalent: "")
        new.target = self
        new.isEnabled = screen != nil
        menu.addItem(new)

        let newCanvas = NSMenuItem(title: "New Canvas Layout…", action: #selector(newCanvasLayout), keyEquivalent: "")
        newCanvas.target = self
        newCanvas.isEnabled = screen != nil
        menu.addItem(newCanvas)

        // The editor (grid or canvas) is chosen by LayoutEditors from the layout (#7).
        let layout = screen.map { ZoneLayout.layout(for: $0) }
        let edit = NSMenuItem(title: layout.map(LayoutEditors.editTitle(for:)) ?? "Edit Layout…", action: #selector(editLayout), keyEquivalent: "")
        edit.target = self
        edit.isEnabled = layout.map(LayoutEditors.canEdit) ?? false
        menu.addItem(edit)

        if let layout, LayoutEditors.canCopyAsCanvas(layout) {
            let copy = NSMenuItem(title: "Copy “\(layout.name)” as New Canvas…", action: #selector(copyAsCanvas), keyEquivalent: "")
            copy.target = self
            menu.addItem(copy)
        }
    }

    @objc private func newCanvasLayout() {
        guard let screen else { return }
        CanvasEditor.open(on: screen)
    }

    @objc private func copyAsCanvas() {
        guard let screen else { return }
        CanvasEditor.open(on: screen, editing: ZoneLayout.layout(for: screen))
    }

    @objc private func newLayout() {
        guard let screen else { return }
        GridEditor.open(on: screen)
    }

    @objc private func editLayout() {
        guard let screen else { return }
        LayoutEditors.open(on: screen, editing: ZoneLayout.layout(for: screen))
    }
}
