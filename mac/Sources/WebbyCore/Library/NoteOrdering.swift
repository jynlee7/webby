import Foundation

public enum NoteOrder: Sendable {
    case updatedDescending
    case createdAscending
    case pinnedDescending
    case closedDescending
    case trashedDescending
    case pinnedThenCreatedAscending
}

public enum NoteOrdering {
    public static func sorted(_ notes: [Note], by order: NoteOrder) -> [Note] {
        notes.sorted { lhs, rhs in
            switch order {
            case .updatedDescending:
                return compare(lhs.updatedAt, rhs.updatedAt, descending: true, lhs: lhs, rhs: rhs)
            case .createdAscending:
                return compare(lhs.createdAt, rhs.createdAt, descending: false, lhs: lhs, rhs: rhs)
            case .pinnedDescending:
                return compare(lhs.pinnedAt, rhs.pinnedAt, descending: true, lhs: lhs, rhs: rhs)
            case .closedDescending:
                return compare(lhs.tab?.closedAt, rhs.tab?.closedAt, descending: true, lhs: lhs, rhs: rhs)
            case .trashedDescending:
                return compare(lhs.trashedAt, rhs.trashedAt, descending: true, lhs: lhs, rhs: rhs)
            case .pinnedThenCreatedAscending:
                if (lhs.pinnedAt == nil) != (rhs.pinnedAt == nil) {
                    return lhs.pinnedAt != nil
                }
                if let lhsPinned = lhs.pinnedAt, let rhsPinned = rhs.pinnedAt, lhsPinned != rhsPinned {
                    return lhsPinned > rhsPinned
                }
                return compare(lhs.createdAt, rhs.createdAt, descending: false, lhs: lhs, rhs: rhs)
            }
        }
    }

    private static func compare(
        _ lhsDate: Date?,
        _ rhsDate: Date?,
        descending: Bool,
        lhs: Note,
        rhs: Note
    ) -> Bool {
        switch (lhsDate, rhsDate) {
        case let (lhsDate?, rhsDate?):
            if lhsDate != rhsDate {
                return descending ? lhsDate > rhsDate : lhsDate < rhsDate
            }
        case (nil, .some):
            return false
        case (.some, nil):
            return true
        case (nil, nil):
            break
        }
        return lhs.id.uuidString.lowercased() < rhs.id.uuidString.lowercased()
    }

    private static func compare(
        _ lhsDate: Date,
        _ rhsDate: Date,
        descending: Bool,
        lhs: Note,
        rhs: Note
    ) -> Bool {
        if lhsDate != rhsDate {
            return descending ? lhsDate > rhsDate : lhsDate < rhsDate
        }
        return lhs.id.uuidString.lowercased() < rhs.id.uuidString.lowercased()
    }
}
