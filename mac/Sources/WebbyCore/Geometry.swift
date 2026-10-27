import CoreGraphics

public enum Geometry {
    public static func appKitRect(fromTopLeft rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(
            x: rect.minX,
            y: primaryScreenHeight - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    public static func topLeftRect(fromAppKit rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(
            x: rect.minX,
            y: primaryScreenHeight - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    public static func absoluteFrame(for note: Note, window: CGRect?) -> CGRect {
        let origin = windowOrigin(for: note.placement, window: window)
        return CGRect(
            x: CGFloat(note.frame.x) + origin.x,
            y: CGFloat(note.frame.y) + origin.y,
            width: CGFloat(note.frame.width),
            height: CGFloat(note.frame.height)
        )
    }

    public static func storedFrame(absolute: CGRect, placement: Placement, window: CGRect?) -> NoteFrame {
        let origin = windowOrigin(for: placement, window: window)
        return NoteFrame(
            x: Double(absolute.minX - origin.x),
            y: Double(absolute.minY - origin.y),
            width: Double(absolute.width),
            height: Double(absolute.height)
        )
    }

    private static func windowOrigin(for placement: Placement, window: CGRect?) -> CGPoint {
        guard placement == .window, let window else { return .zero }
        return CGPoint(x: window.minX, y: window.minY)
    }
}
