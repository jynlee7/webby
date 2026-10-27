import Foundation

public struct NoteFrame: Hashable, Codable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double = 0, y: Double = 0, width: Double = 0, height: Double = 0) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public enum Placement: String, Codable, Sendable {
    case window
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
        createdAt: Date = Date(),
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.anchor = anchor
        self.text = text
        self.frame = frame
        self.placement = placement
        self.collapsed = collapsed
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }
}
