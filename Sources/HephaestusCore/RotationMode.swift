import AppKit
import ApplicationServices

// MARK: - Prefs

enum RotationModifier: String, CaseIterable {
    case option, control, command, shift

    var title: String { rawValue.capitalized }
    var flag: CGEventFlags {
        switch self {
        case .option: return .maskAlternate
        case .control: return .maskControl
        case .command: return .maskCommand
        case .shift: return .maskShift
        }
    }
}

/// ANSI letter keys selectable as the rotation trigger (virtual key codes).
enum RotationKey {
    static let letters: [(title: String, code: Int)] = [
        ("A", 0), ("B", 11), ("C", 8), ("D", 2), ("E", 14), ("F", 3), ("G", 5), ("H", 4), ("I", 34), ("J", 38),
        ("K", 40), ("L", 37), ("M", 46), ("N", 45), ("O", 31), ("P", 35), ("Q", 12), ("R", 15), ("S", 1), ("T", 17),
        ("U", 32), ("V", 9), ("W", 13), ("X", 7), ("Y", 16), ("Z", 6),
    ]
}

extension Prefs {
    static let rotationEnabledKey = "rotationEnabled"
    static let rotationModifierKey = "rotationModifier"
    static let rotationKeyCodeKey = "rotationKeyCode"

    static func registerRotationDefaults() {
        UserDefaults.standard.register(defaults: [
            rotationEnabledKey: false, rotationModifierKey: RotationModifier.option.rawValue, rotationKeyCodeKey: 7,  // Option+X
        ])
    }

    static var rotationEnabled: Bool { UserDefaults.standard.bool(forKey: rotationEnabledKey) }
    static var rotationModifier: RotationModifier {
        RotationModifier(rawValue: UserDefaults.standard.string(forKey: rotationModifierKey) ?? "") ?? .option
    }
    static var rotationKeyCode: Int { UserDefaults.standard.integer(forKey: rotationKeyCodeKey) }
}

// MARK: - Window discovery

/// Which windows take part in rotation: exactly those that may snap anywhere else (type policy + excluded apps).
enum RotationEligibility {
    static func isEligible(_ window: AXUIElement) -> Bool { WindowEligibility.canSnap(window: window) }
}

struct RotatableWindow {
    let element: AXUIElement
    let appName: String
    /// AppKit-space frame.
    let frame: CGRect
}

enum RotationWindows {
    /// Eligible windows of all other regular apps whose frame lies on a connected screen (windows on other Spaces
    /// are generally not reported by AX and are therefore skipped).
    static func collect() -> [RotatableWindow] {
        var result: [RotatableWindow] = []
        let me = ProcessInfo.processInfo.processIdentifier
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && app.processIdentifier != me {
            guard let windows = AX.windows(pid: app.processIdentifier) else { continue }
            for w in windows where RotationEligibility.isEligible(w) {
                guard let ax = WindowMover.frame(of: w) else { continue }
                let frame = ZoneLayout.fromAX(ax)
                guard NSScreen.screens.contains(where: { $0.frame.intersects(frame) }) else { continue }
                result.append(RotatableWindow(element: w, appName: app.localizedName ?? "Window", frame: frame))
            }
        }
        return result
    }
}

// MARK: - Controller

/// Rotation mode: hold the shortcut (default Option+X) and press Left/Right to move every window one screen over.
///
/// Key tracking uses a `CGEventTap` (public API) so the keystrokes can be swallowed. An active tap needs the
/// Accessibility permission the app already requires. If the tap cannot be created (permission missing), it falls
/// back to global+local `NSEvent` monitors, which cannot swallow events: the shortcut then also reaches the focused app.
final class RotationController {
    private var state = RotationHoldState(triggerKeyCode: 7, modifier: .maskAlternate)
    private let preview = RotationPreview()
    private var lastDirection = RotationDirection.right
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var monitors: [Any] = []
    private var defaultsObserver: NSObjectProtocol?

    func start() {
        applyPrefs()
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.applyPrefs()
        }
        if !installTap() { installMonitors() }
    }

    private func applyPrefs() {
        state.enabled = Prefs.rotationEnabled
        state.triggerKeyCode = Prefs.rotationKeyCode
        state.modifier = Prefs.rotationModifier.flag
        if !state.enabled { preview.hide() }
    }

    // MARK: Event sources

    private func installTap() -> Bool {
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let controller = Unmanaged<RotationController>.fromOpaque(refcon).takeUnretainedValue()
            return controller.handleTap(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
        }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: CGEventMask(mask), callback: callback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        tap = port
        tapSource = source
        return true
    }

    /// Returns true when the event must be swallowed.
    private func handleTap(type: CGEventType, event: CGEvent) -> Bool {
        if ShortcutRecording.isActive { return false }   // the settings recorder must see the keys
        let kind: RotationHoldState.Kind
        switch type {
        case .keyDown: kind = .keyDown
        case .keyUp: kind = .keyUp
        case .flagsChanged: kind = .flagsChanged
        default:
            if let tap, type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        return apply(state.handle(kind, keyCode: code, flags: event.flags, isRepeat: isRepeat))
    }

    private func installMonitors() {
        let handler: (NSEvent) -> Void = { [weak self] e in
            guard let self else { return }
            let kind: RotationHoldState.Kind = e.type == .keyDown ? .keyDown : e.type == .keyUp ? .keyUp : .flagsChanged
            let flags = CGEventFlags(rawValue: UInt64(e.modifierFlags.rawValue))
            let isRepeat = (e.type == .keyDown || e.type == .keyUp) ? e.isARepeat : false
            _ = self.apply(self.state.handle(kind, keyCode: Int(e.keyCode), flags: flags, isRepeat: isRepeat))
        }
        let types: NSEvent.EventTypeMask = [.keyDown, .keyUp, .flagsChanged]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: types, handler: handler) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: types, handler: { handler($0); return $0 }) { monitors.append(l) }
    }

    // MARK: Actions

    private func apply(_ result: (action: RotationHoldState.Action, swallow: Bool)) -> Bool {
        switch result.action {
        case .none: break
        case .showPreview: refreshPreview()
        case .hidePreview: preview.hide()
        case let .rotate(direction):
            lastDirection = direction
            rotate(direction)
            // Windows need a moment to settle before the next preview is computed from their new frames.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                if self?.state.held == true { self?.refreshPreview() }
            }
        }
        return result.swallow
    }

    /// Windows on ordered screens, and the plan for `direction`.
    private func makePlan(_ direction: RotationDirection) -> (windows: [RotatableWindow], screens: [NSScreen], moves: [RotationMove])? {
        guard WindowMover.ensureAccessibility(prompt: false), NSScreen.screens.count > 1,
              !Prefs.spanAllScreens else { return nil }   // spanning = one surface: nothing to rotate between
        let all = NSScreen.screens
        let order = RotationPlan.orderedScreenIndices(frames: all.map(\.frame))
        let screens = order.map { all[$0] }
        let zones = screens.map { ZoneLayout.zones(for: $0) }
        let windows = RotationWindows.collect()
        let inputs: [RotationWindow] = windows.enumerated().compactMap { i, w in
            guard let s = ZoneLayout.screen(containing: w.frame), let si = screens.firstIndex(of: s) else { return nil }
            return RotationWindow(id: i, screen: si, zone: Self.currentZone(of: w, on: s, zones: zones[si]))
        }
        let moves = RotationPlan.plan(windows: inputs, zoneCounts: zones.map(\.count), direction: direction)
        return (windows, screens, moves)
    }

    /// The zone a window occupies: the tracker's record when still valid (same screen + layout, window unmoved),
    /// else the best frame overlap (>= 50% of the window).
    private static func currentZone(of w: RotatableWindow, on screen: NSScreen, zones: [CGRect]) -> ZoneIndex? {
        if let rec = WindowTracker.shared.record(for: w.element), rec.screenUUID == screen.displayUUID,
           rec.layoutID == ZoneLayout.layout(for: screen).id,
           let z = rec.zones.first, zones.indices.contains(z), WindowStateMath.frameMatches(w.frame, rec.snappedFrame) {
            return z
        }
        return RotationPlan.bestZone(for: w.frame, in: zones)
    }

    /// Destination rect (AppKit space) of a planned move.
    private func destinationRect(_ move: RotationMove, window: RotatableWindow, screens: [NSScreen]) -> CGRect {
        let target = screens[move.toScreen]
        if let z = move.zone {
            let zones = ZoneLayout.zones(for: target)
            if zones.indices.contains(z) { return zones[z] }
        }
        return RotationPlan.proportionalRect(window.frame, from: screens[move.fromScreen].visibleFrame, to: target.visibleFrame)
    }

    private func rotate(_ direction: RotationDirection) {
        guard let p = makePlan(direction) else { return }
        for move in p.moves {
            let w = p.windows[move.id]
            let rect = destinationRect(move, window: w, screens: p.screens)
            if let z = move.zone {
                WindowMover.snap(w.element, toAppKitRect: rect, zones: [z], on: p.screens[move.toScreen], from: w.frame)
            } else {
                // Proportional move: no longer sitting in a zone, so the tracker must not keep an assignment.
                WindowMover.move(w.element, toAppKitRect: rect)
                WindowTracker.shared.unregister(w.element)
            }
        }
    }

    private func refreshPreview() {
        guard let p = makePlan(lastDirection) else { preview.hide(); return }
        preview.show(p.moves.map { m in
            let w = p.windows[m.id]
            return (rect: destinationRect(m, window: w, screens: p.screens), label: w.appName)
        })
    }
}

// MARK: - Preview

/// Click-through outlines (same window style as `Overlay`) of where each window would land on the next rotation.
final class RotationPreview {
    private var windows: [NSWindow] = []

    func show(_ items: [(rect: CGRect, label: String)]) {
        hide()
        let style = OverlayStyle.current
        for item in items {
            let w = NSWindow(contentRect: item.rect, styleMask: .borderless, backing: .buffered, defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.level = .statusBar
            w.ignoresMouseEvents = true
            w.hasShadow = false
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            w.contentView = RotationPreviewView(style: style, label: item.label)
            w.orderFrontRegardless()
            windows.append(w)
        }
    }

    func hide() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
    }
}

private final class RotationPreviewView: NSView {
    let style: OverlayStyle
    let label: String
    init(style: OverlayStyle, label: String) {
        self.style = style
        self.label = label
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 12, yRadius: 12)
            style.highlight.withAlphaComponent(style.opacity * 0.6).setFill(); path.fill()
            style.highlight.withAlphaComponent(0.9).setStroke(); path.lineWidth = 4; path.stroke()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 28, weight: .semibold), .foregroundColor: style.number,
            ]
            let text = label as NSString
            let size = text.size(withAttributes: attrs)
            text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attrs)
        }
    }
}
