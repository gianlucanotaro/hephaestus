import AppKit
import Carbon.HIToolbox
import SwiftUI
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let screenMenu = ScreenLayoutMenu()
    private let gridEditorMenu = GridEditorMenu()
    private var statusItem: NSStatusItem!
    private let overlay = Overlay()
    private let hotKeys = HotKeys()
    private lazy var dragSnap = DragSnapController(overlay: overlay)
    private lazy var layoutHotkeys = LayoutHotkeyRegistrar(hotKeys: hotKeys, overlay: overlay)
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.register()
        _ = WindowMover.ensureAccessibility(prompt: true)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.split.3x1", accessibilityDescription: "Hephaestus")
        screenMenu.onPick = { [weak self] in self?.overlay.show() }
        ScreenLayoutStore.shared.start()
        rebuildMenu()
        dragSnap.start()

        hotKeys.register(keyCode: kVK_LeftArrow) { WindowMover.snapFrontWindow(slot: .first) }
        hotKeys.register(keyCode: kVK_UpArrow) { WindowMover.snapFrontWindow(slot: .middle) }
        hotKeys.register(keyCode: kVK_RightArrow) { WindowMover.snapFrontWindow(slot: .last) }
        hotKeys.register(keyCode: kVK_ANSI_Z) { [weak self] in self?.overlay.toggle() }
        layoutHotkeys.start()

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.rebuildMenu() }
        NotificationCenter.default.addObserver(forName: LayoutStore.didChange,
                                               object: nil, queue: .main) { [weak self] _ in self?.rebuildMenu() }
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.delegate = self
        populate(menu)
        statusItem.menu = menu
    }

    /// The "Layout" items depend on the screen under the cursor, so refresh right before the menu opens.
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === statusItem.menu { populate(menu) }
    }

    private func populate(_ menu: NSMenu) {
        menu.removeAllItems()
        for (screen, zones) in ZoneLayout.allZones() {
            menu.addItem(withTitle: "\(screen.localizedName) \(Int(screen.frame.width))×\(Int(screen.frame.height))  →  \(zones.map { "\(Int($0.width))" }.joined(separator: " / "))",
                         action: nil, keyEquivalent: "").isEnabled = false
        }
        menu.addItem(.separator())
        let store = LayoutStore.shared
        let layoutsMenu = NSMenu()
        let current = screenMenu.addLayoutItems(to: layoutsMenu)
        let currentLayout = current.map { ZoneLayout.layout(for: $0) } ?? store.active
        layoutsMenu.addItem(.separator())
        gridEditorMenu.addItems(to: layoutsMenu, screen: current)
        layoutsMenu.addItem(.separator())
        layoutsMenu.addItem(withTitle: "Import Layout…", action: #selector(importLayout), keyEquivalent: "").target = self
        layoutsMenu.addItem(withTitle: "Export Layout…", action: #selector(exportLayout), keyEquivalent: "").target = self
        let layoutsItem = NSMenuItem(title: "Layout (\(current?.localizedName ?? "this screen")): \(currentLayout.name)", action: nil, keyEquivalent: "")
        layoutsItem.submenu = layoutsMenu
        menu.addItem(layoutsItem)
        menu.addItem(screenMenu.defaultsItem())
        menu.addItem(.separator())
        for index in currentLayout.zones.indices {
            let item = NSMenuItem(title: "Snap window → \(Layout.zoneTitle(index))", action: #selector(snap(_:)), keyEquivalent: "")
            item.representedObject = index
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Show Zones", action: #selector(showZones), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Hephaestus", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc private func snap(_ sender: NSMenuItem) {
        // The menu steals focus briefly; wait for the previous app to become frontmost again.
        guard let zone = sender.representedObject as? ZoneIndex else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { WindowMover.snapFrontWindow(to: zone) }
    }

    @objc private func importLayout() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a Hephaestus layout JSON file"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let layout = try LayoutStore.shared.importLayout(from: url)
            if let screen = screenMenu.screen ?? ZoneLayout.screenUnderCursor() { ZoneLayout.setLayout(id: layout.id, for: screen) }
            overlay.show()
        } catch {
            showError("Could not import layout", error)
        }
    }

    @objc private func exportLayout() {
        NSApp.activate(ignoringOtherApps: true)
        let layout = screenMenu.screen.map { ZoneLayout.layout(for: $0) } ?? LayoutStore.shared.active
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(layout.name).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try LayoutStore.shared.export(layout, to: url) } catch { showError("Could not export layout", error) }
    }

    private func showError(_ title: String, _ error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    @objc private func showZones() { overlay.show() }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let view = SettingsView { [weak self] in
                self?.rebuildMenu()
                self?.overlay.show()
            }
            let w = NSWindow(contentViewController: NSHostingController(rootView: view))
            w.title = "Hephaestus Settings"
            w.styleMask = [.titled, .closable]
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

/// Entry point called from the thin executable target. Never returns.
public func runHephaestus() {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
