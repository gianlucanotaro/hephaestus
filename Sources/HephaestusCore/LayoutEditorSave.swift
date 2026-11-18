import Foundation

/// Pure save logic shared by every layout editor (grid now, canvas in #7). Stores are injected so it is testable.
enum LayoutEditorSave {
    /// Trimmed name, or nil when blank.
    static func cleanName(_ name: String) -> String? {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    static func freshID() -> String { "custom.\(UUID().uuidString.lowercased())" }

    /// Id to save under: the existing custom layout's id when editing one, else a fresh id.
    /// Built-ins are never overwritten (they are copied to a new id).
    static func targetID(editing existing: Layout?) -> String {
        if let existing, !existing.isBuiltIn { return existing.id }
        return freshID()
    }

    /// Stores `layout` as a custom layout and assigns it to the given displays. Returns false (and assigns
    /// nothing) when the layout is invalid or rejected by the store.
    @discardableResult
    static func commit(_ layout: Layout, assignTo displayUUIDs: [String],
                       layouts: LayoutStore = .shared, screens: ScreenLayoutStore = .shared) -> Bool {
        guard layouts.upsert(layout) else { return false }
        for uuid in displayUUIDs { screens.setLayout(id: layout.id, uuid: uuid) }
        return true
    }

    /// Display name for a copied layout ("Columns copy").
    static func copyName(of layout: Layout) -> String { layout.isBuiltIn ? "\(layout.name) copy" : layout.name }
}
