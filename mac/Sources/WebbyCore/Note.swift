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

public struct NoteSource: Hashable, Codable, Sendable {
    public var url: String?
    public var title: String?

    public init(url: String? = nil, title: String? = nil) {
        self.url = url
        self.title = title
    }
}

public struct NoteAppearance: Hashable, Codable, Sendable {
    public var paletteIndex: Int?
    public var hideDecoration: Bool

    public init(paletteIndex: Int? = nil, hideDecoration: Bool = false) {
        self.paletteIndex = paletteIndex
        self.hideDecoration = hideDecoration
    }
}

public struct Note: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var anchor: Anchor?
    public var tab: TabBinding?
    public var workspaceOverride: UUID?
    public var text: String
    public var revision: Int
    public var source: NoteSource?
    public var frame: NoteFrame
    public var placement: Placement
    public var collapsed: Bool
    public var hidden: Bool
    public var pinnedAt: Date?
    public var trashedAt: Date?
    public var excludedFromAgent: Bool
    public var appearance: NoteAppearance?
    public let createdAt: Date
    public var updatedAt: Date
    public var ephemeral: Bool = false

    public init(
        id: UUID = UUID(),
        anchor: Anchor? = nil,
        tab: TabBinding? = nil,
        workspaceOverride: UUID? = nil,
        text: String = "",
        revision: Int = 1,
        source: NoteSource? = nil,
        frame: NoteFrame,
        placement: Placement,
        collapsed: Bool = false,
        hidden: Bool = false,
        pinnedAt: Date? = nil,
        trashedAt: Date? = nil,
        excludedFromAgent: Bool = false,
        appearance: NoteAppearance? = nil,
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        ephemeral: Bool = false
    ) {
        self.id = id
        self.anchor = anchor
        self.tab = tab
        self.workspaceOverride = workspaceOverride
        self.text = text
        self.revision = revision
        self.source = source
        self.frame = frame
        self.placement = placement
        self.collapsed = collapsed
        self.hidden = hidden
        self.pinnedAt = pinnedAt
        self.trashedAt = trashedAt
        self.excludedFromAgent = excludedFromAgent
        self.appearance = appearance
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.ephemeral = ephemeral
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case anchor
        case tab
        case workspaceOverride
        case text
        case revision
        case source
        case frame
        case placement
        case collapsed
        case hidden
        case pinnedAt
        case trashedAt
        case excludedFromAgent
        case appearance
        case createdAt
        case updatedAt
    }
}

extension Note {
    /// The first non-blank line of the text, trimmed and cut to `limit` characters
    /// with an ellipsis. `nil` for a note with no visible text.
    public func summaryLine(limit: Int = 40) -> String? {
        let line = text.split(whereSeparator: \.isNewline)
            .lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        guard let line else { return nil }
        guard line.count > limit, limit > 1 else { return line }
        return line.prefix(limit - 1).trimmingCharacters(in: .whitespaces) + "…"
    }
}
