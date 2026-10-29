import Foundation
import Testing
@testable import Webby
import WebbyCore

private let copyLinkNow = Date(timeIntervalSince1970: 1_800_000_000)

private func makeCopyNote(text: String = "note", trashedAt: Date? = nil, ephemeral: Bool = false) -> Note {
    Note(
        text: text,
        frame: NoteFrame(),
        placement: .screen,
        trashedAt: trashedAt,
        createdAt: copyLinkNow,
        updatedAt: copyLinkNow,
        ephemeral: ephemeral
    )
}

@MainActor
@Suite struct LibraryNoteLinkTests {
    @Test func copyLinkStringIsTheStrictWebbyNoteLink() {
        let note = makeCopyNote()
        let string = LibraryNoteLink.urlString(for: note)

        #expect(string == "webby://note/\(note.id.uuidString)")
        #expect(NoteLink.parse(string) == note.id)
        #expect(LibraryNoteLink.canCopy(note))
    }

    @Test func trashedNotesKeepTheirStableCopyLink() {
        let note = makeCopyNote(trashedAt: copyLinkNow)
        let string = LibraryNoteLink.urlString(for: note)

        #expect(LibraryNoteLink.canCopy(note))
        #expect(NoteLink.parse(string) == note.id)
    }

    @Test func ephemeralNotesAreNeverCopied() {
        let note = makeCopyNote(ephemeral: true)

        #expect(LibraryNoteLink.canCopy(note) == false)
    }
}
