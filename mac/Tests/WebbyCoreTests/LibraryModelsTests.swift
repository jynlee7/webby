import Foundation
import Testing
@testable import WebbyCore

private let libraryDate = Date(timeIntervalSinceReferenceDate: 500_000)

private func libraryNote(
    id: UUID = UUID(),
    text: String = "note",
    hidden: Bool = false,
    trashedAt: Date? = nil,
    ephemeral: Bool = false,
    createdAt: Date = libraryDate,
    updatedAt: Date = libraryDate
) -> Note {
    Note(
        id: id,
        text: text,
        frame: NoteFrame(),
        placement: .window,
        hidden: hidden,
        trashedAt: trashedAt,
        createdAt: createdAt,
        updatedAt: updatedAt,
        ephemeral: ephemeral
    )
}

@Test func libraryNoteExposesItsNoteIdentityAndHiddenMarker() {
    let id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let note = libraryNote(id: id, text: "body", hidden: true)
    let item = LibraryNote(note: note)

    #expect(item.id == id)
    #expect(item.note == note)
    #expect(item.isHidden)
}

@Test func libraryNoteIsNotHiddenForAnOrdinaryNote() {
    #expect(!LibraryNote(note: libraryNote()).isHidden)
}

@Test func ordinaryEligibilityIncludesUntrashedEphemeralNotes() {
    let ordinary = libraryNote()
    let ephemeral = libraryNote(ephemeral: true)

    #expect(LibraryEligibility.isOrdinary(ordinary))
    #expect(!LibraryEligibility.isTrash(ordinary))
    #expect(LibraryEligibility.isOrdinary(ephemeral))
    #expect(!LibraryEligibility.isTrash(ephemeral))
}

@Test func trashEligibilityIncludesTrashedEphemeralNotes() {
    let trashed = libraryNote(trashedAt: libraryDate)
    let trashedEphemeral = libraryNote(trashedAt: libraryDate, ephemeral: true)

    #expect(!LibraryEligibility.isOrdinary(trashed))
    #expect(LibraryEligibility.isTrash(trashed))
    #expect(!LibraryEligibility.isOrdinary(trashedEphemeral))
    #expect(LibraryEligibility.isTrash(trashedEphemeral))
}

@Test func libraryTagStoresDisplayNameAndSearchKey() {
    let tag = LibraryTag(name: "Café", searchKey: "cafe")

    #expect(tag.name == "Café")
    #expect(tag.searchKey == "cafe")
    #expect(tag != LibraryTag(name: "Cafe", searchKey: "cafe"))
}
