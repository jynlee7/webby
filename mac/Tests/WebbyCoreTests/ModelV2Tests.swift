import Foundation
import Testing
@testable import WebbyCore

@Suite("Model v2")
struct ModelV2Tests {
    @Test func noteFullFieldRoundTrip() throws {
        let id = UUID(uuidString: "6B29FC40-CA47-1067-B31D-00DD010662DA")!
        let workspaceID = UUID(uuidString: "A1B2C3D4-E5F6-7890-ABCD-EF1234567890")!
        let createdAt = Date(timeIntervalSinceReferenceDate: 123_456.789)
        let updatedAt = createdAt.addingTimeInterval(90.5)
        let closedAt = createdAt.addingTimeInterval(-15.25)
        let pinnedAt = createdAt.addingTimeInterval(10.75)

        let note = Note(
            id: id,
            anchor: .web(
                page: PageURL(host: "example.com", path: "/docs", query: "a=1&b=2"),
                scope: .prefix(path: "/docs")
            ),
            tab: TabBinding(
                browser: "chrome",
                profile: "Default",
                session: "session-1",
                tabID: 12,
                windowID: 3,
                index: 4,
                lastURL: "https://example.com/docs?page=2",
                lastTitle: "Docs",
                closedAt: closedAt,
                pendingRestore: true
            ),
            workspaceOverride: workspaceID,
            text: "Line one\nLine two - café 🌍 日本語",
            revision: 7,
            source: NoteSource(url: "https://example.com/docs", title: "Docs"),
            frame: NoteFrame(x: -10.5, y: 20.25, width: 300.5, height: 200.25),
            placement: .screen,
            collapsed: true,
            hidden: true,
            pinnedAt: pinnedAt,
            trashedAt: updatedAt,
            excludedFromAgent: true,
            appearance: NoteAppearance(paletteIndex: 3, hideDecoration: true),
            createdAt: createdAt,
            updatedAt: updatedAt,
            ephemeral: false
        )

        let data = try JSONEncoder().encode(note)
        let decoded = try JSONDecoder().decode(Note.self, from: data)

        #expect(decoded == note)
        #expect(decoded.createdAt == createdAt)
        #expect(decoded.updatedAt == updatedAt)
    }

    @Test func inboxNoteHasNilAnchor() throws {
        let note = Note(
            text: "Inbox",
            frame: NoteFrame(x: 1, y: 2, width: 3, height: 4),
            placement: .window
        )

        #expect(note.anchor == nil)
        #expect(note.tab == nil)
        #expect(note.workspaceOverride == nil)
        #expect(note.revision == 1)
        #expect(note.ephemeral == false)

        let data = try JSONEncoder().encode(note)
        let decoded = try JSONDecoder().decode(Note.self, from: data)

        #expect(decoded == note)
        #expect(decoded.anchor == nil)
    }

    @Test func workspaceMetadataRoundTrip() throws {
        let id = UUID(uuidString: "C3D4E5F6-7890-ABCD-EF12-34567890ABCD")!
        let createdAt = Date(timeIntervalSinceReferenceDate: 123_456.789)
        let record = WorkspaceRecord(
            id: id,
            title: "Work",
            keys: [
                .host(name: "example.com"),
                .app(bundleID: "com.example.Notes"),
                .localFiles,
                .tabsWithoutPage,
            ],
            pinned: true,
            skinID: "paper",
            createdAt: createdAt
        )

        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(WorkspaceRecord.self, from: data)

        #expect(decoded == record)
        #expect(decoded.keys.count == 4)
        #expect(decoded.createdAt == createdAt)
    }

    @Test func ephemeralKeyIsOmittedAndResetsToFalse() throws {
        let note = Note(
            anchor: .app(bundleID: "com.example.Notes"),
            text: "Incognito",
            frame: NoteFrame(x: 0, y: 0, width: 100, height: 100),
            placement: .window,
            ephemeral: true
        )

        let data = try JSONEncoder().encode(note)
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(!json.contains("ephemeral"))

        let decoded = try JSONDecoder().decode(Note.self, from: data)
        #expect(decoded.ephemeral == false)

        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["ephemeral"] = true
        let injected = try JSONSerialization.data(withJSONObject: object)
        let decodedWithKey = try JSONDecoder().decode(Note.self, from: injected)
        #expect(decodedWithKey.ephemeral == false)
    }

    @Test func v1ShapeIsNotDecodedAsV2() {
        let data = Data(
            #"""
            {
              "id": "6B29FC40-CA47-1067-B31D-00DD010662DA",
              "anchor": {"app": {"bundleID": "com.example.Notes"}},
              "text": "legacy",
              "frame": {"x": 0, "y": 0, "width": 300, "height": 200},
              "placement": "window",
              "collapsed": false,
              "createdAt": 123456.789,
              "updatedAt": 123456.789
            }
            """#.utf8
        )

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Note.self, from: data)
        }
    }
}
