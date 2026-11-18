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

/// Modifier key that, while held during a drag, extends the selection across several zones.
enum MultiZoneModifier: String, CaseIterable {
    case control, option, command

    var title: String {
        switch self {
        case .control: return "Control"
        case .option: return "Option"
        case .command: return "Command"
        }
    }
    var flag: NSEvent.ModifierFlags {
        switch self {
        case .control: return .control
        case .option: return .option
        case .command: return .command
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
    private var multiToggled = false   // middle mouse button toggles multi-zone spanning

    /// Screens the overlay is currently built for, the screen under the cursor, and its highlighted zone.
    private var overlayScreenIDs: [UInt32] = []
    private var cursorScreen: NSScreen?
    private var currentSelection: Set<ZoneIndex> = []
    /// Zones collected while multi-zone mode is on; cleared when it turns off or the cursor changes screen.
    private var accumulated: Set<ZoneIndex> = []

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
            guard isWindowDrag else { break }
            if Prefs.dragActivation != .button, event.buttonNumber == 2 {
                multiToggled.toggle()
            } else if Prefs.dragActivation == .button {
                toggled.toggle()
            }
            refresh()
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
        guard pid != getpid(), WindowEligibility.canSnap(window: window) else { return }
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
              let screen = screen(at: NSEvent.mouseLocation)
        else { return }
        let selected = selection(on: screen)
        guard let rect = ZoneLayout.boundingRect(of: selected, in: ZoneLayout.zones(for: screen)) else { return }
        WindowMover.move(window, toAppKitRect: rect)
    }

    private var isMultiZone: Bool {
        multiToggled || NSEvent.modifierFlags.contains(Prefs.multiZoneModifier.flag)
    }

    /// Zones that would receive the window if dropped now: the hovered zone(s), plus every zone
    /// visited so far while multi-zone mode is on.
    private func selection(on screen: NSScreen) -> Set<ZoneIndex> {
        let hovered = ZoneLayout.selection(at: NSEvent.mouseLocation, in: ZoneLayout.zones(for: screen),
                                         gap: ZoneLayout.effectiveGap(for: ZoneLayout.layout(for: screen)),
                                         overlap: Prefs.overlapResolution)
        guard isMultiZone else { accumulated = []; return hovered }
        accumulated.formUnion(hovered)
        return accumulated
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
        let screens = Prefs.showZonesOnAllScreens ? ZoneLayout.surfaceScreens() : [screen]
        let ids = screens.map(\.displayID)
        if ids != overlayScreenIDs {
            overlay.showDrag(on: screens)
            overlayScreenIDs = ids
            cursorScreen = nil
            currentSelection = []
        }
        if cursorScreen !== screen { accumulated = [] }
        let selected = selection(on: screen)
        if cursorScreen !== screen || selected != currentSelection {
            overlay.highlight(selected, on: screen)
            cursorScreen = screen
            currentSelection = selected
        }
    }

    private func hideOverlay() {
        guard !overlayScreenIDs.isEmpty else { return }
        overlay.hide()
        overlayScreenIDs = []
        cursorScreen = nil
        currentSelection = []
        accumulated = []
    }

    private func screen(at point: CGPoint) -> NSScreen? {
        ZoneLayout.surfaceScreen(at: point)
    }

    private func reset() {
        hideOverlay()
        tracked = nil
        startFrame = nil
        checksWithoutMove = 0
        isWindowDrag = false
        toggled = false
        multiToggled = false
    }
}
