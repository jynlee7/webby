import CoreGraphics

/// Converts note frames between the coordinate systems macOS uses.
///
/// Top-left coordinates (Accessibility API, `NoteFrame`) put the origin at the top-left of the
/// primary screen with y growing downward. AppKit coordinates (`NSWindow.frame`) put the origin
/// at the bottom-left with y growing upward. Both share the same x axis.
public enum Geometry {
    /// Converts a top-left-origin rect to AppKit coordinates.
    /// - Parameter primaryScreenHeight: Height of the screen whose AppKit origin is (0, 0).
    public static func appKitRect(fromTopLeft rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(
            x: rect.minX,
            y: primaryScreenHeight - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    /// Converts an AppKit rect to top-left-origin coordinates. Inverse of `appKitRect(fromTopLeft:primaryScreenHeight:)`.
    public static func topLeftRect(fromAppKit rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(
            x: rect.minX,
            y: primaryScreenHeight - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    /// Returns where a note appears on screen, in top-left coordinates.
    ///
    /// A `.window` note is stored as an offset from its window's top-left corner, so it follows the
    /// window. With no known window, or for `.screen` notes, the stored frame is already absolute.
    /// `window` must use the same top-left coordinate space as the stored note frame.
    public static func absoluteFrame(for note: Note, window: CGRect?) -> CGRect {
        let origin = windowOrigin(for: note.placement, window: window)
        return CGRect(
            x: CGFloat(note.frame.x) + origin.x,
            y: CGFloat(note.frame.y) + origin.y,
            width: CGFloat(note.frame.width),
            height: CGFloat(note.frame.height)
        )
    }

    /// Returns the frame to store for a note shown at `absolute`. Inverse of `absoluteFrame(for:window:)`.
    /// `absolute` and `window` use top-left coordinates.
    public static func storedFrame(absolute: CGRect, placement: Placement, window: CGRect?) -> NoteFrame {
        let origin = windowOrigin(for: placement, window: window)
        return NoteFrame(
            x: Double(absolute.minX - origin.x),
            y: Double(absolute.minY - origin.y),
            width: Double(absolute.width),
            height: Double(absolute.height)
        )
    }

    /// The offset stored frames are relative to: the window's origin for a `.window` note with a
    /// known window, otherwise zero.
    private static func windowOrigin(for placement: Placement, window: CGRect?) -> CGPoint {
        guard placement == .window, let window else { return .zero }
        return CGPoint(x: window.minX, y: window.minY)
    }
}
