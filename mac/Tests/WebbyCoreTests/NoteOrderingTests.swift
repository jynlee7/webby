import Foundation
import Testing
@testable import WebbyCore

private func uuid(_ suffix: String) -> UUID {
    UUID(uuidString: "00000000-0000-0000-0000-000000000" + suffix)!
}

private func date(_ value: TimeInterval) -> Date {
    Date(timeIntervalSinceReferenceDate: value)
}

private func orderingNote(
    _ suffix: String,
    created: TimeInterval = 0,
    updated: TimeInterval? = nil,
    pinned: TimeInterval? = nil,
    trashed: TimeInterval? = nil,
    closed: TimeInterval? = nil
) -> Note {
    let tab = closed.map {
        TabBinding(
            browser: "browser",
            profile: "profile",
            session: "session",
            tabID: 1,
            windowID: 1,
            index: 0,
            lastURL: "https://example.com",
            closedAt: date($0)
        )
    }
    return Note(
        id: uuid(suffix),
        tab: tab,
        text: suffix,
        frame: NoteFrame(),
        placement: .window,
        pinnedAt: pinned.map(date),
        trashedAt: trashed.map(date),
        createdAt: date(created),
        updatedAt: date(updated ?? created)
    )
}

private func ids(_ notes: [Note]) -> [String] {
    notes.map { $0.id.uuidString.suffix(3).lowercased() }
}

private func allOrders() -> [NoteOrder] {
    [
        .updatedDescending,
        .createdAscending,
        .pinnedDescending,
        .closedDescending,
        .trashedDescending,
        .pinnedThenCreatedAscending,
    ]
}

@Test func updatedDescendingUsesNewestFirstAndLowercaseUUIDTies() {
    let notes = [
        orderingNote("004", updated: 100),
        orderingNote("003", updated: 300),
        orderingNote("002", updated: 200),
        orderingNote("001", updated: 200),
    ]

    #expect(ids(NoteOrdering.sorted(notes, by: .updatedDescending)) == ["003", "001", "002", "004"])
}

@Test func createdAscendingUsesOldestFirstAndLowercaseUUIDTies() {
    let notes = [
        orderingNote("004", created: 400),
        orderingNote("003", created: 200),
        orderingNote("001", created: 200),
        orderingNote("002", created: 100),
    ]

    #expect(ids(NoteOrdering.sorted(notes, by: .createdAscending)) == ["002", "001", "003", "004"])
}

@Test func pinnedDescendingPutsPinnedNotesFirstAndNilLast() {
    let notes = [
        orderingNote("004", pinned: nil),
        orderingNote("003", pinned: 300),
        orderingNote("002", pinned: 100),
        orderingNote("001", pinned: 300),
    ]

    #expect(ids(NoteOrdering.sorted(notes, by: .pinnedDescending)) == ["001", "003", "002", "004"])
}

@Test func closedDescendingUsesClosedAtAndNilLast() {
    let notes = [
        orderingNote("005", closed: nil),
        orderingNote("004"),
        orderingNote("003", closed: 200),
        orderingNote("002", closed: 300),
        orderingNote("001", closed: 200),
    ]

    #expect(ids(NoteOrdering.sorted(notes, by: .closedDescending)) == ["002", "001", "003", "004", "005"])
}

@Test func trashedDescendingUsesTrashedAtAndNilLast() {
    let notes = [
        orderingNote("004", trashed: nil),
        orderingNote("003", trashed: 300),
        orderingNote("002", trashed: 100),
        orderingNote("001", trashed: 300),
    ]

    #expect(ids(NoteOrdering.sorted(notes, by: .trashedDescending)) == ["001", "003", "002", "004"])
}

@Test func pinnedThenCreatedOrdersPinnedByPinnedAtThenEverythingByCreatedAt() {
    let notes = [
        orderingNote("005", created: 500),
        orderingNote("004", created: 400),
        orderingNote("003", created: 300, pinned: 100),
        orderingNote("002", created: 200, pinned: 300),
        orderingNote("001", created: 100, pinned: 300),
    ]

    #expect(ids(NoteOrdering.sorted(notes, by: .pinnedThenCreatedAscending)) == [
        "001", "002", "003", "004", "005",
    ])
}

@Test func pinnedThenCreatedBreaksEqualPinnedAndCreatedTiesByUUID() {
    let notes = [
        orderingNote("003", created: 100, pinned: 300),
        orderingNote("001", created: 100, pinned: 300),
        orderingNote("002", created: 100),
    ]

    #expect(ids(NoteOrdering.sorted(notes, by: .pinnedThenCreatedAscending)) == ["001", "003", "002"])
}

@Test func allOrdersAreDeterministicForShuffledInput() {
    let notes = [
        orderingNote("001", created: 100, updated: 400, pinned: 100, trashed: 100, closed: 100),
        orderingNote("002", created: 200, updated: 400, pinned: nil, trashed: nil, closed: 200),
        orderingNote("003", created: 300, updated: 200, pinned: 300, trashed: 300, closed: nil),
        orderingNote("004", created: 400, updated: 100, pinned: 300, trashed: nil, closed: 400),
    ]
    let shuffles = [
        notes,
        notes.reversed(),
        [notes[2], notes[0], notes[3], notes[1]],
        [notes[1], notes[3], notes[0], notes[2]],
    ]

    for order in allOrders() {
        let expected = ids(NoteOrdering.sorted(notes, by: order))
        for shuffled in shuffles {
            #expect(ids(NoteOrdering.sorted(shuffled, by: order)) == expected)
        }
    }
}

@Test func allOrdersHandleEmptyAndSingleNoteInputs() {
    #expect(NoteOrdering.sorted([], by: .createdAscending).isEmpty)

    for order in allOrders() {
        let note = orderingNote("001", pinned: 100, trashed: 100, closed: 100)
        #expect(NoteOrdering.sorted([note], by: order).map(\.id) == [note.id])
    }
}

@Test func noteOrderCasesAreDistinct() {
    let notes = [
        orderingNote("001", created: 100, updated: 300, pinned: 100, trashed: 300, closed: 200),
        orderingNote("002", created: 200, updated: 200, pinned: 300, trashed: 200, closed: 100),
        orderingNote("003", created: 300, updated: 100, pinned: nil, trashed: nil, closed: nil),
    ]

    let results = allOrders().map { ids(NoteOrdering.sorted(notes, by: $0)) }

    #expect(results == [
        ["001", "002", "003"],
        ["001", "002", "003"],
        ["002", "001", "003"],
        ["001", "002", "003"],
        ["001", "002", "003"],
        ["002", "001", "003"],
    ])
}
