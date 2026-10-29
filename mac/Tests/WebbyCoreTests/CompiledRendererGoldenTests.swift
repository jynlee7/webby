import Foundation
import Testing
@testable import WebbyCore

private let goldenRecordID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
private let goldenQueryRules = [QueryRule(host: "example.com", key: "v")]

private func goldenUUID(_ suffix: String) -> UUID {
    UUID(uuidString: "00000000-0000-0000-0000-0000000000" + suffix)!
}

private func goldenDate(_ value: TimeInterval) -> Date {
    Date(timeIntervalSinceReferenceDate: value)
}

private func goldenNote(
    _ suffix: String,
    anchor: Anchor? = nil,
    tab: TabBinding? = nil,
    workspaceOverride: UUID? = nil,
    text: String,
    pinnedAt: TimeInterval? = nil,
    created: TimeInterval
) -> Note {
    Note(
        id: goldenUUID(suffix),
        anchor: anchor,
        tab: tab,
        workspaceOverride: workspaceOverride,
        text: text,
        frame: NoteFrame(),
        placement: .window,
        pinnedAt: pinnedAt.map(goldenDate),
        createdAt: goldenDate(created),
        updatedAt: goldenDate(created)
    )
}

private func goldenWeb(
    _ path: String,
    query: String? = nil,
    host: String = "example.com",
    scope: WebScope = .page
) -> Anchor {
    .web(page: PageURL(host: host, path: path, query: query), scope: scope)
}

private func mixedNotes() -> [Note] {
    [
        goldenNote(
            "01",
            workspaceOverride: goldenRecordID,
            text: "Standalone thought\nRemember to revisit the notes. #inbox",
            created: 0
        ),
        goldenNote(
            "02",
            anchor: goldenWeb("/tab", scope: .site),
            tab: TabBinding(
                browser: "chrome",
                profile: "Default",
                session: "session-1",
                tabID: 7,
                windowID: 1,
                index: 0,
                lastURL: "https://example.com/tab"
            ),
            text: "Tab note\nWhile reading the docs.",
            created: 86_400
        ),
        goldenNote(
            "03",
            anchor: goldenWeb("/", scope: .site),
            text: "Site wide\nUse Python for interviews. #lang",
            created: 172_800
        ),
        goldenNote(
            "04",
            anchor: goldenWeb("/problems", scope: .prefix(path: "/problems")),
            text: "Prefix note\nApplies to every problem. #algo",
            created: 259_200
        ),
        goldenNote(
            "05",
            anchor: goldenWeb("/problems/two-sum"),
            text: "Hash map approach\nStore each value's index. #lang #algo",
            pinnedAt: 999_999,
            created: 345_600
        ),
        goldenNote(
            "06",
            anchor: goldenWeb("/problems/two-sum", query: "v=2"),
            text: "Query variant\nSame path, different query.",
            created: 432_000
        ),
    ]
}

private func mixedWorkspaceDocument() -> CompiledDocument {
    CompiledDocument.workspace(
        destination: .record(goldenRecordID),
        notes: mixedNotes(),
        workspaces: [
            WorkspaceRecord(
                id: goldenRecordID,
                keys: [.host(name: "example.com")],
                createdAt: goldenDate(0)
            )
        ],
        queryRules: goldenQueryRules
    )
}

private func mixedPageDocument() -> CompiledDocument {
    CompiledDocument.page(
        PageURL(host: "example.com", path: "/problems/two-sum"),
        destination: .record(goldenRecordID),
        notes: mixedNotes(),
        workspaces: [
            WorkspaceRecord(
                id: goldenRecordID,
                keys: [.host(name: "example.com")],
                createdAt: goldenDate(0)
            )
        ],
        queryRules: goldenQueryRules
    )
}

private func maliciousDocument() -> CompiledDocument {
    let recordID = goldenUUID("A2")
    let notes = [
        goldenNote(
            "01",
            anchor: goldenWeb("/", host: "evil.example", scope: .site),
            text: """
            <script>alert('x')</script>
            <img src="https://remote.example/pixel.png"> and [link](https://remote.example) and `code`.
            # not a heading
            & < > " '
            """,
            created: 0
        ),
        goldenNote(
            "02",
            anchor: goldenWeb("/", host: "evil.example", scope: .site),
            text: """
            Remote <img src="https://remote.example/x.png"> image
            **bold** and [x](https://remote.example) and `tick`.
            A tag stays literal: #safe_tag
            """,
            created: 86_400
        ),
    ]

    return CompiledDocument.workspace(
        destination: .record(recordID),
        notes: notes,
        workspaces: [
            WorkspaceRecord(
                id: recordID,
                keys: [.host(name: "evil.example")],
                createdAt: goldenDate(0)
            )
        ]
    )
}

private func fixtureURL(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("fixtures/compiled")
        .appendingPathComponent(name)
}

private func fixtureData(_ name: String) throws -> Data {
    try Data(contentsOf: fixtureURL(name))
}

@Test func mixedWorkspaceMarkdownMatchesGolden() throws {
    let rendered = MarkdownRenderer.render(mixedWorkspaceDocument())
    let expected = try fixtureData("workspace.md")

    #expect(Data(rendered.utf8) == expected)
}

@Test func mixedWorkspaceHTMLMatchesGolden() throws {
    let rendered = HTMLRenderer.render(mixedWorkspaceDocument())
    let expected = try fixtureData("workspace.html")

    #expect(Data(rendered.utf8) == expected)
}

@Test func mixedPageMarkdownMatchesGolden() throws {
    let rendered = MarkdownRenderer.render(mixedPageDocument())
    let expected = try fixtureData("page.md")

    #expect(Data(rendered.utf8) == expected)
}

@Test func mixedPageHTMLMatchesGolden() throws {
    let rendered = HTMLRenderer.render(mixedPageDocument())
    let expected = try fixtureData("page.html")

    #expect(Data(rendered.utf8) == expected)
}

@Test func maliciousMarkdownMatchesGoldenAndStaysText() throws {
    let rendered = MarkdownRenderer.render(maliciousDocument())
    let expected = try fixtureData("malicious.md")

    #expect(Data(rendered.utf8) == expected)
    #expect(!rendered.contains("<script"))
    #expect(!rendered.contains("<img"))
    #expect(!rendered.contains("[link](https://"))
    #expect(rendered.contains("&lt;script&gt;"))
    #expect(rendered.contains("\\# not a heading"))
    #expect(rendered.contains("\\[link\\]\\(https://remote.example\\)"))
    #expect(rendered.contains("\\`code\\`"))
}

@Test func maliciousHTMLMatchesGoldenAndStaysText() throws {
    let rendered = HTMLRenderer.render(maliciousDocument())
    let expected = try fixtureData("malicious.html")

    #expect(Data(rendered.utf8) == expected)
    #expect(rendered.contains(
        "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; style-src 'unsafe-inline'\">"
    ))
    #expect(!rendered.contains("<script"))
    #expect(!rendered.contains("<img"))
    #expect(!rendered.contains("src=\"https://remote.example"))
    #expect(!rendered.contains("href=\"https://remote.example"))
    #expect(rendered.contains("&lt;script&gt;"))
    #expect(rendered.contains("&lt;img src=&quot;https://remote.example/pixel.png&quot;&gt;"))
}

@Test func renderersAreDeterministic() {
    let workspace = mixedWorkspaceDocument()
    let page = mixedPageDocument()
    let malicious = maliciousDocument()

    #expect(MarkdownRenderer.render(workspace) == MarkdownRenderer.render(workspace))
    #expect(HTMLRenderer.render(workspace) == HTMLRenderer.render(workspace))
    #expect(MarkdownRenderer.render(page) == MarkdownRenderer.render(page))
    #expect(HTMLRenderer.render(page) == HTMLRenderer.render(page))
    #expect(MarkdownRenderer.render(malicious) == MarkdownRenderer.render(malicious))
    #expect(HTMLRenderer.render(malicious) == HTMLRenderer.render(malicious))
}

@Test func markdownBodyCannotCreateListsRulesHeadingsOrCodeBlocks() {
    let note = CompiledNote(
        id: goldenUUID("F1"),
        title: "Plain text",
        body: "- item\n+ item\n1. item\n---\n===\n    indented",
        createdAt: goldenDate(0),
        isPinned: false,
        isHidden: false,
        isCollapsed: false,
        isExcludedFromAgent: false,
        tags: [],
        noteLink: CompiledLink(title: "Open note", url: NoteLink.url(for: goldenUUID("F1")).absoluteString),
        pageLink: nil
    )
    let document = CompiledDocument(
        scope: .workspace(.inbox),
        title: "Safety",
        sections: [CompiledSection(kind: .workspaceNotes, heading: "Notes", notes: [note])]
    )
    let rendered = MarkdownRenderer.render(document)

    #expect(rendered.contains("\\- item"))
    #expect(rendered.contains("\\+ item"))
    #expect(rendered.contains("1\\. item"))
    #expect(rendered.contains("\\---"))
    #expect(rendered.contains("\\==="))
    #expect(rendered.contains("&#32;&#32;&#32;&#32;indented"))
}

@Test func renderersIncludeNoteStateMarkersAndSafePageDestinations() {
    let id = goldenUUID("F2")
    let note = CompiledNote(
        id: id,
        title: "Stateful",
        body: "body",
        createdAt: goldenDate(0),
        isPinned: false,
        isHidden: true,
        isCollapsed: true,
        isExcludedFromAgent: true,
        tags: [],
        noteLink: CompiledLink(title: "Open note", url: NoteLink.url(for: id).absoluteString),
        pageLink: CompiledLink(title: "Open page", url: "https://example.com/a)b")
    )
    let document = CompiledDocument(
        scope: .workspace(.inbox),
        title: "States",
        sections: [CompiledSection(kind: .workspaceNotes, heading: "Notes", notes: [note])]
    )

    let markdown = MarkdownRenderer.render(document)
    let html = HTMLRenderer.render(document)
    #expect(markdown.contains("https://example.com/a%29b"))
    #expect(markdown.contains("hidden, collapsed, keep away from AI"))
    #expect(html.contains("hidden, collapsed, keep away from AI"))
}

@Test func renderersUseOnlyLineFeedEndings() {
    let markdown = MarkdownRenderer.render(mixedWorkspaceDocument())
    let html = HTMLRenderer.render(mixedWorkspaceDocument())

    #expect(!markdown.contains("\r"))
    #expect(!html.contains("\r"))
    #expect(markdown.hasSuffix("\n"))
    #expect(html.hasSuffix("\n"))
}
