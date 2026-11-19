import AppKit
import SwiftUI

// Temporary layout-name indicator shown on any layout change of a screen (issue #9).

enum IndicatorPosition: String, CaseIterable {
    case topLeft, topCenter, topRight, center, bottomLeft, bottomCenter, bottomRight

    var title: String {
        switch self {
        case .topLeft: return "Top left"
        case .topCenter: return "Top center"
        case .topRight: return "Top right"
        case .center: return "Center"
        case .bottomLeft: return "Bottom left"
        case .bottomCenter: return "Bottom center"
        case .bottomRight: return "Bottom right"
        }
    }

    /// Rect of `size` inside `frame` (AppKit space, bottom-left origin), inset by `margin` from the edges.
    func rect(size: CGSize, in frame: CGRect, margin: CGFloat = 24) -> CGRect {
        let left = frame.minX + margin
        let right = frame.maxX - margin - size.width
        let midX = frame.midX - size.width / 2
        let top = frame.maxY - margin - size.height
        let bottom = frame.minY + margin
        let midY = frame.midY - size.height / 2
        let origin: CGPoint
        switch self {
        case .topLeft: origin = CGPoint(x: left, y: top)
        case .topCenter: origin = CGPoint(x: midX, y: top)
        case .topRight: origin = CGPoint(x: right, y: top)
        case .center: origin = CGPoint(x: midX, y: midY)
        case .bottomLeft: origin = CGPoint(x: left, y: bottom)
        case .bottomCenter: origin = CGPoint(x: midX, y: bottom)
        case .bottomRight: origin = CGPoint(x: right, y: bottom)
        }
        return CGRect(origin: origin, size: size)
    }
}

enum IndicatorLimits {
    static let textSize = 8.0...128.0
    static let padding = 0.0...64.0
    static let durationMs = 300.0...10000.0
    static func clamp(_ v: Double, _ r: ClosedRange<Double>) -> Double { min(max(v, r.lowerBound), r.upperBound) }
}

extension Prefs {
    static let indicatorEnabledKey = "layoutIndicatorEnabled"
    static let indicatorPositionKey = "layoutIndicatorPosition"
    static let indicatorTextColorKey = "layoutIndicatorTextColor"
    static let indicatorBackgroundColorKey = "layoutIndicatorBackgroundColor"
    static let indicatorTextSizeKey = "layoutIndicatorTextSize"
    static let indicatorPaddingKey = "layoutIndicatorPadding"
    static let indicatorDurationKey = "layoutIndicatorDurationMs"

    static func registerIndicatorDefaults() {
        UserDefaults.standard.register(defaults: [
            indicatorEnabledKey: true, indicatorPositionKey: IndicatorPosition.center.rawValue,
            indicatorTextColorKey: "#FFFFFF", indicatorBackgroundColorKey: "#262626",
            indicatorTextSizeKey: 36.0, indicatorPaddingKey: 12.0, indicatorDurationKey: 1500.0,
        ])
    }
}

/// Indicator appearance, read from `Prefs` with every number clamped to its allowed range.
struct IndicatorStyle {
    var enabled: Bool
    var position: IndicatorPosition
    var textColor: NSColor
    var backgroundColor: NSColor
    var textSize: CGFloat
    var padding: CGFloat
    var duration: TimeInterval

    static var current: IndicatorStyle {
        let d = UserDefaults.standard
        return IndicatorStyle(
            enabled: d.bool(forKey: Prefs.indicatorEnabledKey),
            position: IndicatorPosition(rawValue: d.string(forKey: Prefs.indicatorPositionKey) ?? "") ?? .center,
            textColor: NSColor(hex: d.string(forKey: Prefs.indicatorTextColorKey) ?? "") ?? .white,
            backgroundColor: NSColor(hex: d.string(forKey: Prefs.indicatorBackgroundColorKey) ?? "") ?? NSColor(hex: "#262626")!,
            textSize: CGFloat(IndicatorLimits.clamp(d.double(forKey: Prefs.indicatorTextSizeKey), IndicatorLimits.textSize)),
            padding: CGFloat(IndicatorLimits.clamp(d.double(forKey: Prefs.indicatorPaddingKey), IndicatorLimits.padding)),
            duration: IndicatorLimits.clamp(d.double(forKey: Prefs.indicatorDurationKey), IndicatorLimits.durationMs) / 1000)
    }
}

enum LayoutChangeDiff {
    /// UUIDs of screens present in both snapshots whose layout id differs (new/removed screens are not "changes").
    static func changedScreens(before: [String: String], after: [String: String]) -> [String] {
        after.keys.filter { uuid in before[uuid].map { $0 != after[uuid] } ?? false }.sorted()
    }
}

/// Watches layout changes and shows one click-through window per changed screen; a repeat change on the same
/// screen reuses its window and restarts the timer.
final class LayoutIndicator {
    private struct Entry { let window: NSWindow; var hide: DispatchWorkItem? }
    private var entries: [String: Entry] = [:]
    private var snapshot: [String: String] = [:]
    private var observers: [NSObjectProtocol] = []

    static func snapshotCurrent() -> [String: String] {
        Dictionary(NSScreen.screens.map { ($0.displayUUID, ZoneLayout.layout(for: $0).id) }, uniquingKeysWith: { a, _ in a })
    }

    func start() {
        snapshot = Self.snapshotCurrent()
        let nc = NotificationCenter.default
        for name in [ScreenLayoutStore.didChange, LayoutStore.didChange] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.layoutsMayHaveChanged() })
        }
        observers.append(nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.snapshot = Self.snapshotCurrent()   // display (un)plugged: not a layout change
        })
    }

    private func layoutsMayHaveChanged() {
        let now = Self.snapshotCurrent()
        let changed = LayoutChangeDiff.changedScreens(before: snapshot, after: now)
        snapshot = now
        guard IndicatorStyle.current.enabled else { return }
        for uuid in changed {
            if let screen = NSScreen.screens.first(where: { $0.displayUUID == uuid }), let id = now[uuid],
               let layout = LayoutStore.shared.layout(id: id) { show(layout.name, on: screen) }
        }
    }

    func show(_ name: String, on screen: NSScreen) {
        let style = IndicatorStyle.current
        let uuid = screen.displayUUID
        entries[uuid]?.hide?.cancel()
        let field = NSTextField(labelWithString: name)
        field.font = .systemFont(ofSize: style.textSize, weight: .semibold)
        field.textColor = style.textColor
        field.alignment = .center
        field.lineBreakMode = .byTruncatingTail
        field.sizeToFit()
        let maxWidth = max(screen.visibleFrame.width - 48, 50)
        let textSize = CGSize(width: min(field.frame.width, maxWidth - 2 * style.padding), height: field.frame.height)
        let size = CGSize(width: textSize.width + 2 * style.padding, height: textSize.height + 2 * style.padding)
        let rect = style.position.rect(size: size, in: screen.visibleFrame)

        let box = NSView(frame: CGRect(origin: .zero, size: size))
        box.wantsLayer = true
        box.layer?.backgroundColor = style.backgroundColor.cgColor
        box.layer?.cornerRadius = min(14 + style.padding / 2, size.height / 2)
        field.frame = CGRect(origin: CGPoint(x: style.padding, y: style.padding), size: textSize)
        box.addSubview(field)

        let window = entries[uuid]?.window ?? {
            let w = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.level = .statusBar
            w.ignoresMouseEvents = true
            w.hasShadow = false
            w.isReleasedWhenClosed = false
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            return w
        }()
        window.contentView = box
        window.setFrame(rect, display: true)
        window.orderFrontRegardless()

        let work = DispatchWorkItem { [weak self] in
            self?.entries[uuid]?.window.orderOut(nil)
            self?.entries[uuid] = nil
        }
        entries[uuid] = Entry(window: window, hide: work)
        DispatchQueue.main.asyncAfter(deadline: .now() + style.duration, execute: work)
    }
}

/// Layout name popup section (Appearance tab).
struct LayoutIndicatorSettingsView: View {
    @AppStorage(Prefs.indicatorEnabledKey) private var enabled = true
    @AppStorage(Prefs.indicatorPositionKey) private var position = IndicatorPosition.center.rawValue
    @AppStorage(Prefs.indicatorTextColorKey) private var textColor = "#FFFFFF"
    @AppStorage(Prefs.indicatorBackgroundColorKey) private var backgroundColor = "#262626"
    @AppStorage(Prefs.indicatorTextSizeKey) private var textSize = 36.0
    @AppStorage(Prefs.indicatorPaddingKey) private var padding = 12.0
    @AppStorage(Prefs.indicatorDurationKey) private var duration = 1500.0

    private func colorBinding(_ hex: Binding<String>) -> Binding<Color> {
        Binding(get: { Color(nsColor: NSColor(hex: hex.wrappedValue) ?? .gray) },
                set: { hex.wrappedValue = NSColor($0).hexString })
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, unit: String) -> some View {
        HStack {
            Text(title)
            Slider(value: value, in: range, step: 1)
            Text("\(Int(value.wrappedValue)) \(unit)").monospacedDigit().frame(width: 70, alignment: .trailing)
        }
    }

    var body: some View {
        Group {
            Text("Layout name popup").font(.headline)
            Toggle("Show layout name when the layout changes", isOn: $enabled)
            if enabled {
                Picker("Position", selection: $position) {
                    ForEach(IndicatorPosition.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                }
                ColorPicker("Text color", selection: colorBinding($textColor))
                ColorPicker("Background color", selection: colorBinding($backgroundColor))
                slider("Text size", $textSize, IndicatorLimits.textSize, unit: "pt")
                slider("Padding", $padding, IndicatorLimits.padding, unit: "px")
                slider("Duration", $duration, IndicatorLimits.durationMs, unit: "ms")
            }
        }
    }
}

/// Mouse-wheel layout cycling toggle (Activation tab).
struct WheelCycleSetting: View {
    @AppStorage(Prefs.wheelCycleKey) private var wheel = false

    var body: some View {
        Group {
            Toggle("Cycle layouts with the mouse wheel while dragging", isOn: $wheel)
            Text("Scrolls through hotkey-numbered layouts (or custom layouts) on the screen under the cursor. Needs Accessibility; relaunch after granting it.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}
