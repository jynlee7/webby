import Foundation
import Testing
@testable import WebbyCore

private let goldenV1 = #"""
{
  "version": 1,
  "notes": [
    {
      "id": "6B29FC40-CA47-1067-B31D-00DD010662DA",
      "anchor": { "app": { "bundleID": "com.apple.TextEdit" } },
      "text": "Line one\nLine two - café 🌍 日本語",
      "frame": { "x": -10.5, "y": 20.25, "width": 300.75, "height": 200.125 },
      "placement": "window",
      "collapsed": false,
      "createdAt": 123456.789,
      "updatedAt": 123486.789
    },
    {
      "id": "A1B2C3D4-E5F6-7890-ABCD-EF1234567890",
      "anchor": {
        "web": {
          "page": { "host": "youtube.com", "path": "/watch" },
          "scope": { "page": {} }
        }
      },
      "text": "Page note",
      "frame": { "x": 1, "y": 2, "width": 3, "height": 4 },
      "placement": "screen",
      "collapsed": true,
      "createdAt": 100,
      "updatedAt": 200
    },
    {
      "id": "B1B2C3D4-E5F6-7890-ABCD-EF1234567890",
      "anchor": {
        "web": {
          "page": { "host": " WWW.WWW.Double.Example.COM ", "path": "//news///tech/" },
          "scope": { "prefix": { "path": "/news/" } }
        }
      },
      "text": "Prefix note",
      "frame": { "x": 1.5, "y": 2.5, "width": 3.5, "height": 4.5 },
      "placement": "window",
      "collapsed": false,
      "createdAt": 123456.5,
      "updatedAt": 123456.75
    },
    {
      "id": "C1B2C3D4-E5F6-7890-ABCD-EF1234567890",
      "anchor": {
        "web": {
          "page": { "host": "docs.example.com", "path": "/guide" },
          "scope": { "site": {} }
        }
      },
      "text": "Site note",
      "frame": { "x": 5, "y": 6, "width": 7, "height": 8 },
      "placement": "screen",
      "collapsed": false,
      "createdAt": 300,
      "updatedAt": 400
    }
  ]
}
"""#

private func assertV1Defaults(_ note: Note) {
    #expect(note.revision == 1)
    #expect(note.tab == nil)
    #expect(note.workspaceOverride == nil)
    #expect(note.source == nil)
    #expect(note.hidden == false)
    #expect(note.pinnedAt == nil)
    #expect(note.trashedAt == nil)
    #expect(note.excludedFromAgent == false)
    #expect(note.appearance == nil)
    #expect(note.ephemeral == false)
}

private func makeV2Sample() -> (NotesDocument, Note, WorkspaceRecord) {
    let workspaceID = UUID(uuidString: "D1B2C3D4-E5F6-7890-ABCD-EF1234567890")!
    let noteID = UUID(uuidString: "E1B2C3D4-E5F6-7890-ABCD-EF1234567890")!
    let createdAt = Date(timeIntervalSinceReferenceDate: 123456.789)
    let updatedAt = createdAt.addingTimeInterval(42.5)

    let workspace = WorkspaceRecord(
        id: workspaceID,
        title: "Research",
        keys: [
            .host(name: "example.com"),
            .app(bundleID: "com.apple.TextEdit"),
            .localFiles,
            .tabsWithoutPage,
        ],
        pinned: true,
        skinID: "webby.clear",
        createdAt: createdAt
    )

    let note = Note(
        id: noteID,
        anchor: .web(
            page: PageURL(host: "example.com", path: "/docs", query: nil),
            scope: .prefix(path: "/docs")
        ),
        tab: TabBinding(
            browser: "chrome",
            profile: "Default",
            session: "session-1",
            tabID: 17,
            windowID: 3,
            index: 2,
            lastURL: "https://example.com/docs",
            lastTitle: "Docs 📚",
            closedAt: createdAt.addingTimeInterval(10),
            pendingRestore: true
        ),
        workspaceOverride: workspaceID,
        text: "Complete note - café 🌍 日本語",
        revision: 4,
        source: NoteSource(url: "https://example.com/docs", title: "Docs"),
        frame: NoteFrame(x: -10.5, y: 20.25, width: 300.75, height: 200.125),
        placement: .screen,
        collapsed: true,
        hidden: true,
        pinnedAt: createdAt.addingTimeInterval(20),
        trashedAt: createdAt.addingTimeInterval(30),
        excludedFromAgent: true,
        appearance: NoteAppearance(paletteIndex: 3, hideDecoration: true),
        createdAt: createdAt,
        updatedAt: updatedAt,
        ephemeral: false
    )

    return (NotesDocument(notes: [note], workspaces: [workspace]), note, workspace)
}

@Suite("NotesDocument codec")
struct MigrationTests {
    @Test func v1GoldenFixtureMapsEveryField() throws {
        let document = try NotesDocument.decode(Data(goldenV1.utf8), version: 1)

        #expect(document.workspaces.isEmpty)
        #expect(document.notes.count == 4)

        let appNote = document.notes[0]
        #expect(appNote.id == UUID(uuidString: "6B29FC40-CA47-1067-B31D-00DD010662DA"))
        #expect(appNote.anchor == .app(bundleID: "com.apple.TextEdit"))
        #expect(appNote.text == "Line one\nLine two - café 🌍 日本語")
        #expect(appNote.frame == NoteFrame(x: -10.5, y: 20.25, width: 300.75, height: 200.125))
        #expect(appNote.placement == .window)
        #expect(appNote.collapsed == false)
        #expect(appNote.createdAt == Date(timeIntervalSinceReferenceDate: 123456.789))
        #expect(appNote.updatedAt == Date(timeIntervalSinceReferenceDate: 123486.789))
        #expect(appNote.createdAt != appNote.updatedAt)
        assertV1Defaults(appNote)

        let pageNote = document.notes[1]
        #expect(pageNote.anchor == .web(
            page: PageURL(host: "youtube.com", path: "/watch", query: nil),
            scope: .page
        ))
        if case .web(let page, _) = pageNote.anchor {
            #expect(page.query == nil)
        } else {
            Issue.record("Expected a web anchor")
        }
        #expect(pageNote.collapsed == true)
        #expect(pageNote.placement == .screen)
        assertV1Defaults(pageNote)

        let prefixNote = document.notes[2]
        #expect(prefixNote.anchor == .web(
            page: PageURL(host: "www.www.double.example.com", path: "/news/tech", query: nil),
            scope: .prefix(path: "/news/")
        ))
        #expect(prefixNote.text == "Prefix note")
        #expect(prefixNote.frame == NoteFrame(x: 1.5, y: 2.5, width: 3.5, height: 4.5))
        assertV1Defaults(prefixNote)

        let siteNote = document.notes[3]
        #expect(siteNote.anchor == .web(
            page: PageURL(host: "docs.example.com", path: "/guide", query: nil),
            scope: .site
        ))
        assertV1Defaults(siteNote)
    }

    @Test func v2RoundTripKeepsNotesWorkspacesAndMetadata() throws {
        let (document, note, workspace) = makeV2Sample()

        let data = try NotesDocument.encode(document, version: 2)
        let decoded = try NotesDocument.decode(data, version: 2)

        #expect(decoded.notes == [note])
        #expect(decoded.workspaces == [workspace])
    }

    @Test func encodedDocumentHasOnlyVersionNotesAndWorkspacesAtRoot() throws {
        let (document, _, _) = makeV2Sample()

        let data = try NotesDocument.encode(document, version: 2)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(Set(object.keys) == ["version", "notes", "workspaces"])
        #expect(object["version"] as? Int == 2)
        #expect((object["notes"] as? [Any])?.count == 1)
        #expect((object["workspaces"] as? [Any])?.count == 1)
        #expect(object["content"] == nil)
    }

    @Test func ephemeralNotesAreLeftOutOfEncodedOutput() throws {
        let (_, keptNote, workspace) = makeV2Sample()
        let ephemeral = Note(
            id: UUID(uuidString: "F1B2C3D4-E5F6-7890-ABCD-EF1234567890")!,
            anchor: keptNote.anchor,
            tab: keptNote.tab,
            workspaceOverride: keptNote.workspaceOverride,
            text: "Temporary",
            revision: keptNote.revision,
            source: keptNote.source,
            frame: keptNote.frame,
            placement: keptNote.placement,
            collapsed: keptNote.collapsed,
            hidden: keptNote.hidden,
            pinnedAt: keptNote.pinnedAt,
            trashedAt: keptNote.trashedAt,
            excludedFromAgent: keptNote.excludedFromAgent,
            appearance: keptNote.appearance,
            createdAt: keptNote.createdAt,
            updatedAt: keptNote.updatedAt,
            ephemeral: true
        )

        let document = NotesDocument(notes: [keptNote, ephemeral], workspaces: [workspace])
        let data = try NotesDocument.encode(document, version: 2)
        let decoded = try NotesDocument.decode(data, version: 2)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let encodedNotes = try #require(object["notes"] as? [[String: Any]])

        #expect(encodedNotes.count == 1)
        #expect(encodedNotes[0]["id"] as? String == keptNote.id.uuidString)
        #expect(encodedNotes[0]["ephemeral"] == nil)
        #expect(decoded.notes.map(\.id) == [keptNote.id])
        #expect(decoded.workspaces == [workspace])
    }

    @Test func workspaceKeysMustBeNonEmptyAndUnique() {
        let empty = WorkspaceRecord(keys: [])
        #expect(throws: NotesDocumentError.self) {
            try NotesDocument.validateWorkspaces([empty])
        }

        let first = WorkspaceRecord(keys: [.host(name: "example.com"), .localFiles])
        let second = WorkspaceRecord(keys: [.host(name: "example.com")])
        #expect(throws: NotesDocumentError.self) {
            try NotesDocument.validateWorkspaces([first, second])
        }

        let duplicateInOne = WorkspaceRecord(keys: [.localFiles, .localFiles])
        #expect(throws: NotesDocumentError.self) {
            try NotesDocument.validateWorkspaces([duplicateInOne])
        }

        let sharedID = UUID(uuidString: "D1B2C3D4-E5F6-7890-ABCD-EF1234567890")!
        let repeatedID = WorkspaceRecord(id: sharedID, keys: [.localFiles])
        let sameID = WorkspaceRecord(id: sharedID, keys: [.tabsWithoutPage])
        #expect(throws: NotesDocumentError.self) {
            try NotesDocument.validateWorkspaces([repeatedID, sameID])
        }
    }

    @Test func unknownVersionsFailCodec() {
        #expect(throws: NotesDocumentError.self) {
            _ = try NotesDocument.decode(Data(goldenV1.utf8), version: 0)
        }
        #expect(throws: NotesDocumentError.self) {
            _ = try NotesDocument.decode(Data(goldenV1.utf8), version: 3)
        }
        #expect(throws: NotesDocumentError.self) {
            _ = try NotesDocument.encode(NotesDocument(), version: 1)
        }
        #expect(throws: NotesDocumentError.self) {
            _ = try NotesDocument.encode(NotesDocument(), version: 3)
        }
    }

    @Test func malformedDocumentsFailCodec() {
        let malformedVersion = #"{"version":"two","notes":[],"workspaces":[]}"#
        #expect(throws: DecodingError.self) {
            _ = try NotesDocument.decode(Data(malformedVersion.utf8), version: 2)
        }

        let missingWorkspaces = #"{"version":2,"notes":[]}"#
        #expect(throws: DecodingError.self) {
            _ = try NotesDocument.decode(Data(missingWorkspaces.utf8), version: 2)
        }

        let missingNotes = #"{"version":2,"workspaces":[]}"#
        #expect(throws: DecodingError.self) {
            _ = try NotesDocument.decode(Data(missingNotes.utf8), version: 2)
        }

        #expect(throws: (any Error).self) {
            _ = try NotesDocument.decode(Data(goldenV1.utf8), version: 2)
        }
        #expect(throws: (any Error).self) {
            _ = try NotesDocument.decode(Data(#"{"version":2,"notes":[],"workspaces":[]}"#.utf8), version: 1)
        }
    }
}
