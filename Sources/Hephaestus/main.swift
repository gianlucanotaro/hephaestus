import AppKit
import Carbon.HIToolbox
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let overlay = Overlay()
    private let hotKeys = HotKeys()
    private lazy var dragSnap = DragSnapController(overlay: overlay)
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.register()
        _ = WindowMover.ensureAccessibility(prompt: true)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.split.3x1", accessibilityDescription: "Hephaestus")
        rebuildMenu()
        dragSnap.start()

        hotKeys.register(keyCode: kVK_LeftArrow) { WindowMover.snapFrontWindow(to: .left) }
        hotKeys.register(keyCode: kVK_UpArrow) { WindowMover.snapFrontWindow(to: .center) }
        hotKeys.register(keyCode: kVK_RightArrow) { WindowMover.snapFrontWindow(to: .right) }
        hotKeys.register(keyCode: kVK_ANSI_Z) { [weak self] in self?.overlay.toggle() }

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.rebuildMenu() }
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        for (screen, zones) in ZoneLayout.allZones() {
            menu.addItem(withTitle: "\(screen.localizedName) \(Int(screen.frame.width))×\(Int(screen.frame.height))  →  \(Zone.allCases.map { "\(Int(zones[$0]!.width))" }.joined(separator: " / "))",
                         action: nil, keyEquivalent: "").isEnabled = false
        }
        menu.addItem(.separator())
        for z in Zone.allCases {
            let item = NSMenuItem(title: "Snap window → \(z.title)", action: #selector(snap(_:)), keyEquivalent: "")
            item.representedObject = z.rawValue
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Show Zones", action: #selector(showZones), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Hephaestus", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    @objc private func snap(_ sender: NSMenuItem) {
        // The menu steals focus briefly; wait for the previous app to become frontmost again.
        guard let raw = sender.representedObject as? String, let zone = Zone(rawValue: raw) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { WindowMover.snapFrontWindow(to: zone) }
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

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
