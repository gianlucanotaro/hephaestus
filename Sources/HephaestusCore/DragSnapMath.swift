import CoreGraphics

/// Pure decision logic for `DragSnapController`, kept free of AX/AppKit so it can be unit-tested.
enum DragSnapMath {
    /// Distance (pt) the window origin must travel before the drag counts as a move.
    static let moveThreshold: CGFloat = 3
    /// Width/height change (pt) above which the drag counts as a resize.
    static let resizeThreshold: CGFloat = 2
    /// Number of drag events without a window move after which we stop polling AX.
    static let maxChecksWithoutMove = 40

    /// What an extra (non-left) mouse button press does while a window drag is in progress.
    enum ButtonAction: Equatable {
        /// Toggle multi-zone spanning.
        case multiZone
        /// Toggle zone activation (only meaningful in `.button` activation mode).
        case activation
        case none
    }

    /// Compares the window frame at mouse-down with its current frame.
    /// - Returns: `moved` when the origin travelled more than `moveThreshold`, `resized` when
    ///   width or height changed by more than `resizeThreshold`.
    static func classify(start: CGRect, now: CGRect) -> (moved: Bool, resized: Bool) {
        let moved = hypot(now.minX - start.minX, now.minY - start.minY) > moveThreshold
        let resized = abs(now.width - start.width) > resizeThreshold
            || abs(now.height - start.height) > resizeThreshold
        return (moved, resized)
    }

    /// Whether to stop polling the window for this drag: it was resized, or it never moved
    /// within `maxChecksWithoutMove` checks.
    static func shouldGiveUp(resized: Bool, checksWithoutMove: Int) -> Bool {
        resized || checksWithoutMove > maxChecksWithoutMove
    }

    /// Extra-button rule: in `.button` activation mode, ANY extra button (button 2 included) toggles
    /// activation. In the other modes, button 2 (middle) toggles multi-zone spanning and other buttons do nothing.
    static func toggle(buttonNumber: Int, activation: DragActivation) -> ButtonAction {
        if activation == .button { return .activation }
        return buttonNumber == 2 ? .multiZone : .none
    }
}
