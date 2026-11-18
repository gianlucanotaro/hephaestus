import AppKit
import SwiftUI

extension Prefs {
    static let edgeThresholdKey = "adjacentHighlightDistance"
    static let spanScreensKey = "spanLayoutsAcrossScreens"
    static let layoutGapOverridesKey = "builtInLayoutGaps"
    static let defaultEdgeThreshold: CGFloat = 24
    static let edgeThresholdRange: ClosedRange<Double> = 0...100

    static func registerSpacingDefaults() {
        UserDefaults.standard.register(defaults: [edgeThresholdKey: Double(defaultEdgeThreshold), spanScreensKey: false])
    }

    /// Distance (points) from the edge between two adjacent zones within which both highlight together.
    static var edgeThreshold: CGFloat {
        let v = UserDefaults.standard.object(forKey: edgeThresholdKey) as? Double ?? Double(defaultEdgeThreshold)
        return CGFloat(min(max(v, edgeThresholdRange.lowerBound), edgeThresholdRange.upperBound))
    }
    /// Treat all screens as one large surface for zones.
    static var spanAllScreens: Bool { UserDefaults.standard.bool(forKey: spanScreensKey) }

    /// Gap overrides for built-in layouts (they are never written to layouts.json): layout id -> points.
    static var builtInGapOverrides: [String: Double] {
        UserDefaults.standard.dictionary(forKey: layoutGapOverridesKey) as? [String: Double] ?? [:]
    }
}

extension ZoneLayout {
    /// Smallest rect containing all `frames`; nil when empty.
    static func unionFrame(of frames: [CGRect]) -> CGRect? {
        guard let first = frames.first else { return nil }
        return frames.dropFirst().reduce(first) { $0.union($1) }
    }

    /// Gap for `layout`: its own, else the built-in override, else the global gap. Never negative.
    static func effectiveGap(for layout: Layout, overrides: [String: Double] = Prefs.builtInGapOverrides,
                             globalGap: CGFloat = Prefs.gap) -> CGFloat {
        max(0, layout.gap.map { CGFloat($0) } ?? overrides[layout.id].map { CGFloat($0) } ?? globalGap)
    }

    /// Frame zones are computed in: the screen's usable frame, or the union of all usable frames when spanning.
    static func surfaceFrame(for screen: NSScreen, span: Bool = Prefs.spanAllScreens) -> CGRect {
        guard span else { return screen.visibleFrame }
        return unionFrame(of: NSScreen.screens.map(\.visibleFrame)) ?? screen.visibleFrame
    }

    /// Screens that each own a zone set: every screen, or just one representative when spanning
    /// (the spanned surface is keyed by that screen).
    static func surfaceScreens(span: Bool = Prefs.spanAllScreens) -> [NSScreen] {
        span ? Array(NSScreen.screens.prefix(1)) : NSScreen.screens
    }

    /// Pure: the element that owns the zone surface `element` belongs to. Without spanning every screen owns its own
    /// surface; with spanning, the first one (the representative) owns the single shared surface.
    static func owner<T>(of element: T, in all: [T], span: Bool) -> T {
        span ? (all.first ?? element) : element
    }

    /// The screen whose layout/assignment governs `screen`'s zones (itself, or the representative when spanning).
    static func surfaceOwner(of screen: NSScreen, span: Bool = Prefs.spanAllScreens) -> NSScreen {
        owner(of: screen, in: NSScreen.screens, span: span)
    }

    /// The screen (surface owner) for a cursor position, or nil if the point is on no screen.
    static func surfaceScreen(at point: CGPoint, span: Bool = Prefs.spanAllScreens) -> NSScreen? {
        guard let hit = NSScreen.screens.first(where: { $0.frame.contains(point) }) else { return nil }
        return span ? NSScreen.screens.first : hit
    }
}

/// Menu item "Zone gap: N" with a submenu to set the active layout's gap (or reset to the global default).
final class LayoutGapMenu: NSObject {
    static let shared = LayoutGapMenu()
    static let presets: [Double] = [0, 4, 8, 12, 16, 24, 32]

    /// Stores `gap` (nil = follow global) for `layoutID`: custom layouts persist it in layouts.json,
    /// built-ins in UserDefaults.
    static func setGap(_ gap: Double?, forLayoutID id: String, store: LayoutStore = .shared,
                       defaults: UserDefaults = .standard) {
        if var custom = store.custom.first(where: { $0.id == id }) {
            custom.gap = gap
            store.upsert(custom)
            return
        }
        var overrides = defaults.dictionary(forKey: Prefs.layoutGapOverridesKey) as? [String: Double] ?? [:]
        overrides[id] = gap
        defaults.set(overrides, forKey: Prefs.layoutGapOverridesKey)
        NotificationCenter.default.post(name: LayoutStore.didChange, object: store)
    }

    func menuItem() -> NSMenuItem {
        let layout = Self.currentLayout()
        targetLayoutID = layout.id
        let current = layout.gap ?? Prefs.builtInGapOverrides[layout.id]
        let item = NSMenuItem(title: "Zone gap: \(Int(ZoneLayout.effectiveGap(for: layout))) pt", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let def = NSMenuItem(title: "Default (\(Int(Prefs.gap)) pt)", action: #selector(pick(_:)), keyEquivalent: "")
        def.target = self
        def.state = current == nil ? .on : .off
        sub.addItem(def)
        sub.addItem(.separator())
        for v in Self.presets {
            let i = NSMenuItem(title: "\(Int(v)) pt", action: #selector(pick(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = v
            i.state = current == v ? .on : .off
            sub.addItem(i)
        }
        item.submenu = sub
        return item
    }

    /// The layout the menu was last built for (the cursor has left the screen's content by the time an item is picked).
    private var targetLayoutID: String?

    /// The layout of the screen under the cursor (per-screen layouts: there is no single "active" layout any more).
    private static func currentLayout() -> Layout {
        ZoneLayout.screenUnderCursor().map { ZoneLayout.layout(for: $0) } ?? LayoutStore.shared.active
    }

    @objc private func pick(_ sender: NSMenuItem) {
        Self.setGap(sender.representedObject as? Double, forLayoutID: targetLayoutID ?? Self.currentLayout().id)
    }
}

/// Settings section for adjacent-highlight distance and spanning zones across screens.
struct SpacingSettingsView: View {
    @AppStorage(Prefs.edgeThresholdKey) private var threshold = Double(Prefs.defaultEdgeThreshold)
    @AppStorage(Prefs.spanScreensKey) private var span = false

    var body: some View {
        Group {
            HStack {
                Text("Adjacent highlight distance")
                Slider(value: $threshold, in: Prefs.edgeThresholdRange, step: 1)
                Text("\(Int(threshold)) pt").monospacedDigit().frame(width: 50, alignment: .trailing)
            }
            Text("The gap above is the default; each layout can override it from the menu bar (Zone gap).")
                .font(.footnote).foregroundStyle(.secondary)
            Toggle("Span layouts across all screens as one surface", isOn: $span)
            Text("Windows may then span screens. Off: each screen has its own zones.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}
