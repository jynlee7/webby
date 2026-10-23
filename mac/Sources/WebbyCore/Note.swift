import Foundation

/// A rectangle in top-left-origin coordinates (y grows downward), matching the
/// Accessibility API. See `Geometry` for conversion to AppKit coordinates.
public struct NoteFrame: Hashable, Codable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// What a note's `frame` is measured from.
public enum Placement: String, Codable, Sendable {
    /// Offset from the anchored app's focused window's top-left corner; the note follows the window.
    case window
    /// Absolute top-left-origin screen position; used when no window frame is available
    /// (e.g. Accessibility permission not granted).
    case screen
}

public struct Note: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var anchor: Anchor
    public var text: String
    public var frame: NoteFrame
    public var placement: Placement
    public var collapsed: Bool
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        anchor: Anchor,
        text: String = "",
        frame: NoteFrame,
        placement: Placement,
        collapsed: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.anchor = anchor
        self.text = text
        self.frame = frame
        self.placement = placement
        self.collapsed = collapsed
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }
}
