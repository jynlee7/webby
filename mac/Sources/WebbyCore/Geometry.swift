import CoreGraphics

/// Coordinate conversions between the two systems macOS uses:
///
/// - **Top-left** (Accessibility API, `NoteFrame`): origin at the top-left of the
///   primary screen, y grows downward.
/// - **AppKit** (`NSWindow.frame`, `NSScreen.frame`): origin at the bottom-left of the
///   primary screen, y grows upward.
///
/// Both share the same x axis. Other screens can sit at negative coordinates in either system.
public enum Geometry {
    /// Converts a top-left-origin rect to AppKit coordinates.
    /// `primaryScreenHeight` is the height of the screen whose AppKit frame origin is (0, 0).
    public static func appKitRect(fromTopLeft r: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: primaryScreenHeight - r.minY - r.height, width: r.width, height: r.height)
    }

    /// Converts an AppKit rect to top-left-origin coordinates. The conversion is its own inverse.
    public static func topLeftRect(fromAppKit r: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: primaryScreenHeight - r.minY - r.height, width: r.width, height: r.height)
    }

    /// Absolute top-left-origin rect for a note, given the window it's anchored to
    /// (`nil` when no window frame is known, in which case `.window` notes fall back to
    /// treating their offset as absolute).
    public static func absoluteFrame(for note: Note, window: CGRect?) -> CGRect {
        let f = note.frame
        let origin: CGPoint
        switch (note.placement, window) {
        case let (.window, window?):
            origin = CGPoint(x: window.minX + f.x, y: window.minY + f.y)
        default:
            origin = CGPoint(x: f.x, y: f.y)
        }
        return CGRect(origin: origin, size: CGSize(width: f.width, height: f.height))
    }

    /// The stored frame for a note placed at `absolute` (top-left coordinates).
    /// Inverse of `absoluteFrame(for:window:)`.
    public static func storedFrame(absolute: CGRect, placement: Placement, window: CGRect?) -> NoteFrame {
        switch (placement, window) {
        case let (.window, window?):
            return NoteFrame(x: absolute.minX - window.minX, y: absolute.minY - window.minY,
                             width: absolute.width, height: absolute.height)
        default:
            return NoteFrame(x: absolute.minX, y: absolute.minY, width: absolute.width, height: absolute.height)
        }
    }
}
