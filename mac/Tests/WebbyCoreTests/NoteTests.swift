import Foundation
import Testing
@testable import WebbyCore

@Test func noteDefaults() {
    let note = Note(
        anchor: .app(bundleID: "com.example.Notes"),
        frame: NoteFrame(x: 10, y: 20, width: 300, height: 200),
        placement: .window
    )
    let other = Note(
        anchor: .app(bundleID: "com.example.Notes"),
        frame: NoteFrame(x: 10, y: 20, width: 300, height: 200),
        placement: .window
    )

    #expect(note.text == "")
    #expect(note.collapsed == false)
    #expect(note.updatedAt == note.createdAt)
    #expect(abs(note.createdAt.timeIntervalSinceNow) < 1)
    #expect(note.id != other.id)
}

@Test func notePreservesExplicitValues() {
    let id = UUID(uuidString: "6B29FC40-CA47-1067-B31D-00DD010662DA")!
    let createdAt = Date(timeIntervalSinceReferenceDate: 123_456.75)
    let updatedAt = createdAt.addingTimeInterval(90)
    let frame = NoteFrame(x: -10.5, y: 20.25, width: 300.5, height: 200.25)

    let note = Note(
        id: id,
        anchor: .app(bundleID: "com.example.Notes"),
        text: "Explicit",
        frame: frame,
        placement: .screen,
        collapsed: true,
        createdAt: createdAt,
        updatedAt: updatedAt
    )

    #expect(note.id == id)
    #expect(note.text == "Explicit")
    #expect(note.frame == frame)
    #expect(note.placement == .screen)
    #expect(note.collapsed)
    #expect(note.createdAt == createdAt)
    #expect(note.updatedAt == updatedAt)
}

@Test func noteCodableRoundTrip() throws {
    let createdAt = Date(timeIntervalSinceReferenceDate: 123_456.789)
    let notes = [
        Note(
            id: UUID(uuidString: "6B29FC40-CA47-1067-B31D-00DD010662DA")!,
            anchor: .app(bundleID: "com.example.Notes"),
            text: "",
            frame: NoteFrame(x: -10.5, y: 20.25, width: 300.5, height: 200.25),
            placement: .window,
            collapsed: false,
            createdAt: createdAt,
            updatedAt: createdAt.addingTimeInterval(30)
        ),
        Note(
            id: UUID(uuidString: "A1B2C3D4-E5F6-7890-ABCD-EF1234567890")!,
            anchor: .app(bundleID: "com.example.Notes"),
            text: "Line one\nLine two - café 🌍 日本語",
            frame: NoteFrame(x: 1.5, y: 2.25, width: 30.5, height: 20.25),
            placement: .screen,
            collapsed: true,
            createdAt: createdAt.addingTimeInterval(-60),
            updatedAt: createdAt
        ),
    ]

    let data = try JSONEncoder().encode(notes)
    let decoded = try JSONDecoder().decode([Note].self, from: data)

    #expect(decoded == notes)
}
