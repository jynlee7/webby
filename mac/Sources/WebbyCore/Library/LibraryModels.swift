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

public struct LibraryTag: Hashable, Sendable {
    public let name: String
    public let searchKey: String

    public init(name: String, searchKey: String) {
        self.name = name
        self.searchKey = searchKey
    }
}
