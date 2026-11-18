import AppKit

// Reusable layout editor SHELL (issue #6). The grid editor (GridEditorView) is the first content; the canvas
// editor (#7) plugs in by implementing `LayoutEditing` and passing its view to `LayoutEditorController.open`.
//
// The shell owns everything that is not specific to how zones are edited: the borderless full-screen window on
// the target screen, the dimmed backdrop, the toolbar (name field, Undo/Redo, Save, Cancel), Esc-to-cancel, and the
// save flow (named custom layout + "which screens use it?" prompt). Pure save rules live in `LayoutEditorSave`.

/// Content of a layout editor. The view's bounds ARE the target screen's `visibleFrame` (flipped, origin
/// top-left, same as `RelRect`), so relative coordinates are `point.x / bounds.width`, `point.y / bounds.height`.
/// Edit in a zone-only space: the `gap` is applied at snap time, never drawn or saved by the editor.
protocol LayoutEditing: NSView {
    /// Set by the shell; call after every model change so Undo/Redo buttons refresh.
    var onChange: (() -> Void)? { get set }
    var canUndo: Bool { get }
    var canRedo: Bool { get }
    var hasChanges: Bool { get }
    func undo()
    func redo()
    /// The layout to save, or nil if the current state cannot be saved (the shell then shows an error).
    func makeLayout(id: String, name: String) -> Layout?
    /// Extra controls placed in the toolbar between Redo and Cancel (e.g. the grid editor's Merge button).
    var toolbarItems: [NSView] { get }
    /// One line of help shown under the toolbar.
    var hint: String { get }
}

final class LayoutEditorWindow: NSWindow {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Esc cancels even while the name field is being edited.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53 { onEscape?(); return }
        super.sendEvent(event)
    }
}

/// Dim backdrop covering the whole screen; flipped so frames use the same top-left origin as layouts.
private final class BackdropView: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.45).setFill()
        bounds.fill()
    }
}

final class LayoutEditorController: NSObject, NSTextFieldDelegate {
    /// The editor currently on screen (only one at a time).
    private(set) static var current: LayoutEditorController?

    /// Opens an editor for `screen`. If one is already open it is brought to front instead (returns it).
    /// - Parameters:
    ///   - editing: the layout being edited; a custom one is updated in place, a built-in is saved as a copy.
    ///   - name: initial text of the name field.
    @discardableResult
    static func open(editor: LayoutEditing, on screen: NSScreen, name: String, editing: Layout? = nil) -> LayoutEditorController {
        if let current {
            current.window.makeKeyAndOrderFront(nil)
            return current
        }
        let controller = LayoutEditorController(editor: editor, screen: screen, name: name, editing: editing)
        current = controller
        controller.show()
        return controller
    }

    let screen: NSScreen
    let editor: LayoutEditing
    private let editing: Layout?
    private let window: LayoutEditorWindow
    private let nameField = NSTextField()
    private let undoButton = NSButton()
    private let redoButton = NSButton()

    private init(editor: LayoutEditing, screen: NSScreen, name: String, editing: Layout?) {
        self.editor = editor
        self.screen = screen
        self.editing = editing
        let frame = screen.frame
        window = LayoutEditorWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        super.init()

        window.setFrame(frame, display: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating            // above normal windows, below alerts and the menu bar
        window.acceptsMouseMovedEvents = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenAuxiliary]
        window.onEscape = { [weak self] in self?.cancel() }

        let backdrop = BackdropView(frame: NSRect(origin: .zero, size: frame.size))
        window.contentView = backdrop

        // The editor view covers exactly the screen's usable area (visibleFrame), flipped to a top-left origin.
        let vf = screen.visibleFrame
        editor.frame = NSRect(x: vf.minX - frame.minX, y: frame.maxY - vf.maxY, width: vf.width, height: vf.height)
        backdrop.addSubview(editor)

        nameField.stringValue = name
        nameField.placeholderString = "Layout name"
        nameField.delegate = self
        nameField.target = self
        nameField.action = #selector(save)   // Return in the name field saves
        nameField.widthAnchor.constraint(equalToConstant: 200).isActive = true
        configure(undoButton, "Undo", #selector(undo))
        configure(redoButton, "Redo", #selector(redo))
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelAction))
        let saveButton = NSButton(title: "Save", target: self, action: #selector(save))
        saveButton.bezelStyle = .rounded
        saveButton.hasDestructiveAction = false

        let row = NSStackView(views: [NSTextField(labelWithString: "Name"), nameField, undoButton, redoButton]
            + editor.toolbarItems + [cancelButton, saveButton])
        row.orientation = .horizontal
        row.spacing = 8
        let hint = NSTextField(labelWithString: editor.hint)
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        let column = NSStackView(views: [row, hint])
        column.orientation = .vertical
        column.spacing = 6
        column.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)

        let bar = NSVisualEffectView()
        bar.material = .hudWindow
        bar.blendingMode = .withinWindow
        bar.state = .active
        bar.wantsLayer = true
        bar.layer?.cornerRadius = 12
        bar.translatesAutoresizingMaskIntoConstraints = false
        column.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(column)
        backdrop.addSubview(bar)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: bar.leadingAnchor), column.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            column.topAnchor.constraint(equalTo: bar.topAnchor), column.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            bar.centerXAnchor.constraint(equalTo: editor.centerXAnchor),
            bar.topAnchor.constraint(equalTo: editor.topAnchor, constant: 16),
        ])

        editor.onChange = { [weak self] in self?.refreshToolbar() }
        refreshToolbar()
    }

    private func configure(_ b: NSButton, _ title: String, _ action: Selector) {
        b.title = title
        b.target = self
        b.action = action
        b.bezelStyle = .rounded
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(editor)
    }

    private func refreshToolbar() {
        undoButton.isEnabled = editor.canUndo
        redoButton.isEnabled = editor.canRedo
    }

    @objc private func undo() { editor.undo(); window.makeFirstResponder(editor) }
    @objc private func redo() { editor.redo(); window.makeFirstResponder(editor) }
    @objc private func cancelAction() { cancel() }

    /// Closes the editor without saving anything.
    func cancel() { close() }

    private func close() {
        window.orderOut(nil)
        window.close()
        if LayoutEditorController.current === self { LayoutEditorController.current = nil }
    }

    @objc private func save() {
        guard let name = LayoutEditorSave.cleanName(nameField.stringValue) else {
            NSSound.beep()
            window.makeFirstResponder(nameField)
            return
        }
        guard let layout = editor.makeLayout(id: LayoutEditorSave.targetID(editing: editing), name: name), layout.isValid else {
            NSSound.beep()
            return
        }
        guard let uuids = askScreens(for: layout) else { return }
        if LayoutEditorSave.commit(layout, assignTo: uuids) { close() } else { NSSound.beep() }
    }

    /// Asks which screens should use the layout; the edited screen is preselected. nil = user went back.
    private func askScreens(for layout: Layout) -> [String]? {
        let alert = NSAlert()
        alert.messageText = "Save “\(layout.name)”"
        alert.informativeText = "Use this layout on:"
        let boxes = NSScreen.screens.map { s -> NSButton in
            let b = NSButton(checkboxWithTitle: "\(s.localizedName) (\(Int(s.frame.width))×\(Int(s.frame.height)))", target: nil, action: nil)
            b.state = s.displayUUID == screen.displayUUID ? .on : .off
            return b
        }
        let stack = NSStackView(views: boxes)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.frame = NSRect(origin: .zero, size: stack.fittingSize)
        alert.accessoryView = stack
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Back")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return zip(NSScreen.screens, boxes).filter { $0.1.state == .on }.map { $0.0.displayUUID }
    }
}
