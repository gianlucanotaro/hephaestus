import CoreGraphics
import Foundation

/// Pure logic for stack hover (#46): grouping tracked windows into per-zone stacks, z-order matching, badge/tray
/// geometry, hit regions and the hover state machine. No AppKit/AX here so everything is unit-tested.
/// Rects are AppKit space (origin bottom-left) unless a function says otherwise.
enum StackMath {
    // MARK: Layout constants (points)

    static let titleBarHeight: CGFloat = 40
    static let badgeSize = CGSize(width: 56, height: 26)
    static let badgeInset: CGFloat = 12
    static let cardSize = CGSize(width: 152, height: 196)
    static let cardGap: CGFloat = 12
    static let trayPadding: CGFloat = 28
    static let trayHeaderHeight: CGFloat = 36
    static let trayGapToWindow: CGFloat = 8
    static let maxColumns = 6

    // MARK: Grouping

    /// A tracked window reduced to what grouping needs. `id` is the caller's index (tracker order).
    struct Item: Equatable {
        var id: Int
        var pid: Int32
        var screenUUID: String
        var zones: [Int]
        var frame: CGRect
        var minimized: Bool
    }

    struct StackKey: Hashable { var screenUUID: String; var zone: Int }

    /// Windows grouped by (screen, first zone) in tracker order. A window spanning zones belongs to its first
    /// (lowest) one. Minimized windows are ignored; only groups with 2+ windows are returned, sorted by key.
    static func stacks(_ items: [Item]) -> [(key: StackKey, ids: [Int])] {
        var groups: [StackKey: [Int]] = [:]
        for item in items where !item.minimized {
            guard let zone = item.zones.min() else { continue }
            groups[StackKey(screenUUID: item.screenUUID, zone: zone), default: []].append(item.id)
        }
        return groups.filter { $0.value.count >= 2 }
            .map { (key: $0.key, ids: $0.value) }
            .sorted { ($0.key.screenUUID, $0.key.zone) < ($1.key.screenUUID, $1.key.zone) }
    }

    // MARK: Z-order

    /// One on-screen window from the window server list, front-to-back order. `bounds` in CG/AX space.
    struct CGEntry: Equatable { var pid: Int32; var bounds: CGRect; var layer: Int }

    /// Front-to-back rank for each item (lower = more in front), matched by pid + bounds within `tolerance`.
    /// Only layer-0 windows are candidates; an entry is used once; ties are resolved in item order.
    /// `frames` are the items' frames in the SAME space as the entries (CG/AX). Unmatched items get no rank.
    static func zRanks(items: [Item], frames: [CGRect], entries: [CGEntry], tolerance: CGFloat = 3) -> [Int: Int] {
        var used = Set<Int>()
        var ranks: [Int: Int] = [:]
        for (n, item) in items.enumerated() where n < frames.count {
            let f = frames[n]
            for (rank, e) in entries.enumerated() where !used.contains(rank) && e.layer == 0 && e.pid == item.pid {
                if close(e.bounds, f, tolerance) {
                    used.insert(rank)
                    ranks[item.id] = rank
                    break
                }
            }
        }
        return ranks
    }

    /// Ids ordered front-to-back; unmatched (no rank) last; ties and unmatched keep the given (tracker) order.
    static func sortedFrontToBack(_ ids: [Int], ranks: [Int: Int]) -> [Int] {
        let indexed = ids.enumerated().map { (pos: $0.offset, id: $0.element) }
        return indexed.sorted {
            let a = ranks[$0.id] ?? Int.max, b = ranks[$1.id] ?? Int.max
            return a != b ? a < b : $0.pos < $1.pos
        }.map(\.id)
    }

    private static func close(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> Bool {
        abs(a.minX - b.minX) <= t && abs(a.minY - b.minY) <= t && abs(a.width - b.width) <= t && abs(a.height - b.height) <= t
    }

    // MARK: Geometry

    /// Top strip of the window (the title bar region that triggers the tray).
    static func titleBarRect(of frame: CGRect) -> CGRect {
        let h = min(titleBarHeight, frame.height)
        return CGRect(x: frame.minX, y: frame.maxY - h, width: frame.width, height: h)
    }

    /// Badge: top-right, vertically centred in the title bar, inside the window.
    static func badgeRect(of frame: CGRect) -> CGRect {
        let bar = titleBarRect(of: frame)
        return CGRect(x: frame.maxX - badgeInset - badgeSize.width, y: bar.midY - badgeSize.height / 2,
                      width: badgeSize.width, height: badgeSize.height)
    }

    /// Where hovering opens the tray: the badge or the title bar.
    static func inTrigger(_ p: CGPoint, frame: CGRect) -> Bool {
        titleBarRect(of: frame).contains(p) || badgeRect(of: frame).contains(p)
    }

    /// Columns, rows and total tray size for `count` cards, wrapping so the tray fits `maxWidth`.
    static func trayLayout(count: Int, maxWidth: CGFloat) -> (columns: Int, rows: Int, size: CGSize) {
        let fit = Int(((maxWidth - 2 * trayPadding + cardGap) / (cardSize.width + cardGap)).rounded(.down))
        let columns = max(1, min(maxColumns, fit, max(count, 1)))
        let rows = max(1, Int((Double(count) / Double(columns)).rounded(.up)))
        let w = 2 * trayPadding + CGFloat(columns) * cardSize.width + CGFloat(columns - 1) * cardGap
        let h = trayPadding + trayHeaderHeight + CGFloat(rows) * cardSize.height + CGFloat(rows - 1) * cardGap + trayPadding
        return (columns, rows, CGSize(width: w, height: h))
    }

    /// Tray frame: centred under the front window's title bar; flips above the window when there is no room below;
    /// always clamped inside `visible` (the screen's visibleFrame).
    static func trayRect(size: CGSize, window: CGRect, visible: CGRect) -> CGRect {
        var x = window.midX - size.width / 2
        x = min(max(x, visible.minX), max(visible.minX, visible.maxX - size.width))
        let below = window.maxY - titleBarHeight - trayGapToWindow - size.height
        let above = window.maxY + trayGapToWindow
        var y = below
        if below < visible.minY {
            y = above + size.height <= visible.maxY ? above : below
        }
        y = min(max(y, visible.minY), max(visible.minY, visible.maxY - size.height))
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// Card rects (AppKit space, inside `tray`), row-major from the top-left below the header.
    static func cardRects(count: Int, columns: Int, tray: CGRect) -> [CGRect] {
        (0..<count).map { i in
            let col = i % columns, row = i / columns
            let x = tray.minX + trayPadding + CGFloat(col) * (cardSize.width + cardGap)
            let top = tray.maxY - trayPadding - trayHeaderHeight - CGFloat(row) * (cardSize.height + cardGap)
            return CGRect(x: x, y: top - cardSize.height, width: cardSize.width, height: cardSize.height)
        }
    }

    /// "ZONE 2 · 4 WINDOWS" (singular for one).
    static func headerTitle(zoneTitle: String, count: Int) -> String {
        "\(zoneTitle.uppercased()) · \(count) \(count == 1 ? "WINDOW" : "WINDOWS")"
    }

    // MARK: Hover state machine

    struct Hover {
        enum State: Equatable { case idle, pending(since: TimeInterval), open, closing(since: TimeInterval), dismissed }
        enum Action: Equatable { case open, close }

        static let openDelay: TimeInterval = 0.25
        static let closeGrace: TimeInterval = 0.3

        private(set) var state: State = .idle

        /// Advance with the pointer position and time. `suppressed` (drag in progress, editor open, feature off)
        /// closes immediately. Returns the action the UI must perform, if any.
        mutating func update(now: TimeInterval, inTrigger: Bool, inTray: Bool, suppressed: Bool) -> Action? {
            if suppressed {
                let wasShown = isShown
                state = .idle
                return wasShown ? .close : nil
            }
            switch state {
            case .idle:
                if inTrigger { state = .pending(since: now) }
            case .pending(let since):
                if !inTrigger { state = .idle } else if now - since >= Self.openDelay { state = .open; return .open }
            case .open:
                if !(inTrigger || inTray) { state = .closing(since: now) }
            case .closing(let since):
                if inTrigger || inTray { state = .open } else if now - since >= Self.closeGrace { state = .idle; return .close }
            case .dismissed:
                // Stay quiet until the pointer has left both regions, so Esc/click do not instantly reopen.
                if !inTrigger && !inTray { state = .idle }
            }
            return nil
        }

        /// Esc or a click: close now and do not reopen until the pointer leaves.
        mutating func dismiss() -> Action? {
            let wasShown = isShown
            state = .dismissed
            return wasShown ? .close : nil
        }

        var isShown: Bool {
            switch state {
            case .open, .closing: return true
            default: return false
            }
        }
        /// True while a timer must keep ticking (a delay is running).
        var needsTick: Bool {
            switch state {
            case .pending, .closing: return true
            default: return false
            }
        }
    }
}
