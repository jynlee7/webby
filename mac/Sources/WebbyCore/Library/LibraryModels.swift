import Foundation

public struct LibraryNote: Identifiable, Equatable, Sendable {
    public let note: Note

    public var id: UUID { note.id }
    public var isHidden: Bool { note.hidden }

    public init(note: Note) {
        self.note = note
    }
}

public enum LibraryEligibility {
    public static func isOrdinary(_ note: Note) -> Bool {
        note.trashedAt == nil
    }

    public static func isTrash(_ note: Note) -> Bool {
        note.trashedAt != nil
    }
}

extension WorkspaceKey {
    /// The name a person recognizes for this key.
    public var displayName: String {
        switch self {
        case .host(let name):
            return name
        case .app(let bundleID):
            return bundleID
        case .localFiles:
            return "Local files"
        case .tabsWithoutPage:
            return "Tabs without a page"
        }
    }
}

public struct LibraryTag: Hashable, Sendable {
    public let name: String
    public let searchKey: String

    public init(name: String, searchKey: String) {
        self.name = name
        self.searchKey = searchKey
    }
}
