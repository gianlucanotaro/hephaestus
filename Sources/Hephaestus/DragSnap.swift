import AppKit
import ApplicationServices

/// How zones are activated while dragging a window.
enum DragActivation: String, CaseIterable {
    case shift, button, always

    var title: String {
        switch self {
        case .shift: return "Hold Shift while dragging"
        case .button: return "Click another mouse button to toggle"
        case .always: return "Always show zones while dragging"
        }
    }
}

/// Watches global mouse events, detects when another app's window is being dragged,
/// shows the zones (per `DragActivation`) and snaps the window to the zone under the cursor on release.
final class DragSnapController {
    private let overlay: Overlay
    private var monitor: Any?

    private var tracked: AXUIElement?
    private var startFrame: CGRect?
    private var checksWithoutMove = 0
    private var isWindowDrag = false
    private var toggled = false

    /// Screens the overlay is currently built for, the screen under the cursor, and its highlighted zone.
    private var overlayScreenIDs: [UInt32] = []
    private var cursorScreen: NSScreen?
    private var currentZone: Zone?

    init(overlay: Overlay) { self.overlay = overlay }

    func start() {
        guard monitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .otherMouseDown, .flagsChanged]
        monitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in self?.handle(event) }
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown: begin()
        case .leftMouseDragged: dragged()
        case .leftMouseUp: end()
        case .otherMouseDown:
            if isWindowDrag, Prefs.dragActivation == .button { toggled.toggle(); refresh() }
        case .flagsChanged:
            if isWindowDrag { refresh() }
        default: break
        }
    }

    /// Mouse went down: remember the window under the cursor (if any).
    private func begin() {
        reset()
        guard AXIsProcessTrusted() else { return }
        let ax = ZoneLayout.toAX(CGRect(origin: NSEvent.mouseLocation, size: .zero)).origin
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(ax.x), Float(ax.y), &element) == .success,
              let element, let window = WindowMover.window(containing: element)
        else { return }
        var pid: pid_t = 0
        AXUIElementGetPid(window, &pid)
        guard pid != getpid() else { return }
        tracked = window
        startFrame = WindowMover.frame(of: window)
    }

    /// A drag only counts as a window drag once the window itself moved without resizing.
    /// This ignores text selection, scrollbar drags and window resizes.
    private func dragged() {
        if !isWindowDrag {
            guard let window = tracked, let start = startFrame else { return }
            guard let now = WindowMover.frame(of: window) else { return }
            let moved = hypot(now.minX - start.minX, now.minY - start.minY) > 3
            let resized = abs(now.width - start.width) > 2 || abs(now.height - start.height) > 2
            if moved && !resized {
                isWindowDrag = true
            } else {
                checksWithoutMove += 1
                if resized || checksWithoutMove > 40 { tracked = nil }   // stop polling AX
                return
            }
        }
        refresh()
    }

    private func end() {
        defer { reset() }
        guard isWindowDrag, let window = tracked, isActive,
              let screen = screen(at: NSEvent.mouseLocation),
              let zone = zone(at: NSEvent.mouseLocation, on: screen),
              let rect = ZoneLayout.zones(for: screen)[zone]
        else { return }
        WindowMover.move(window, toAppKitRect: rect)
    }

    private var isActive: Bool {
        switch Prefs.dragActivation {
        case .always: return true
        case .shift: return NSEvent.modifierFlags.contains(.shift)
        case .button: return toggled
        }
    }

    /// Show/hide the overlay and update the highlighted zone for the current cursor position.
    private func refresh() {
        guard isActive, let screen = screen(at: NSEvent.mouseLocation) else {
            hideOverlay()
            return
        }
        let screens = Prefs.showZonesOnAllScreens ? NSScreen.screens : [screen]
        let ids = screens.map(\.displayID)
        if ids != overlayScreenIDs {
            overlay.showDrag(on: screens)
            overlayScreenIDs = ids
            cursorScreen = nil
            currentZone = nil
        }
        let zone = zone(at: NSEvent.mouseLocation, on: screen)
        if cursorScreen !== screen || zone != currentZone {
            overlay.highlight(zone.map { [$0] } ?? [], on: screen)
            cursorScreen = screen
            currentZone = zone
        }
    }

    private func hideOverlay() {
        guard !overlayScreenIDs.isEmpty else { return }
        overlay.hide()
        overlayScreenIDs = []
        cursorScreen = nil
        currentZone = nil
    }

    private func screen(at point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) }
    }

    /// Zone under the cursor; the gap between zones counts as part of the nearest one.
    private func zone(at point: CGPoint, on screen: NSScreen) -> Zone? {
        let slack = Prefs.gap / 2
        return ZoneLayout.zones(for: screen).first { $0.value.insetBy(dx: -slack, dy: -slack).contains(point) }?.key
    }

    private func reset() {
        hideOverlay()
        tracked = nil
        startFrame = nil
        checksWithoutMove = 0
        isWindowDrag = false
        toggled = false
    }
}
