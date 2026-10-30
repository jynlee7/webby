import Foundation
import Testing
import WebbyCore
@testable import WebbyAgent

@Test func firstTurnUsesTiersThenPinnedUpdatedAndUUIDTies() {
    let context = agentContext()
    let page = PageURL(host: "example.com", path: "/a/b")
    let notes = [
        agentNote(
            id: 1,
            anchor: .web(page: page, scope: .page),
            updated: 100
        ),
        agentNote(
            id: 2,
            tab: agentTab(),
            sourceURL: "https://example.com/a/b",
            updated: 200
        ),
        agentNote(
            id: 3,
            anchor: .web(
                page: PageURL(host: "example.com", path: "/a/b"),
                scope: .prefix(path: "/a/b")
            ),
            updated: 900
        ),
        agentNote(
            id: 4,
            anchor: .web(
                page: PageURL(host: "example.com", path: "/a"),
                scope: .prefix(path: "/a")
            ),
            updated: 800
        ),
        agentNote(
            id: 5,
            anchor: .web(
                page: PageURL(host: "example.com", path: "/elsewhere"),
                scope: .site
            ),
            updated: 700
        ),
        agentNote(
            id: 6,
            tab: agentTab(tabID: 99),
            sourceURL: "https://example.com/a/b/c",
            updated: 600
        ),
        agentNote(
            id: 7,
            tab: agentTab(tabID: 100),
            sourceURL: "https://example.com/a/d",
            updated: 500
        ),
    ]
    let turn = ContextAssembler.assemble(
        snapshot: AgentSnapshot(notes: notes),
        context: context,
        conversation: agentConversation(context: context),
        now: Date(timeIntervalSince1970: 1_800_000_000),
        question: "What did I decide?"
    )

    #expect(turn.turnSnapshot.orderedAliases == ["N1", "N2", "N3", "N4", "N5", "N6", "N7"])
    let aliases = aliasesByNoteID(turn)
    #expect(aliases[agentUUID(2)] == "N1") // same tab
    #expect(aliases[agentUUID(1)] == "N2") // exact page
    #expect(aliases[agentUUID(3)] == "N3") // deepest prefix
    #expect(aliases[agentUUID(4)] == "N4") // shallower prefix
    #expect(aliases[agentUUID(5)] == "N5") // site
    #expect(aliases[agentUUID(6)] == "N6") // shared path segments
    #expect(aliases[agentUUID(7)] == "N7")
}

@Test func firstTurnMergesExplicitWorkspaceAppFileAndSignificantQuery() throws {
    let querySecret = "significant-query-sentinel"
    let fileSecret = "file-path-sentinel"
    let page = PageURL(host: "example.com", path: "/a/b", query: "token=\(querySecret)")
    let context = agentContext(page: page)
    let workspaceID = agentUUID(90)
    let workspace = WorkspaceRecord(
        id: workspaceID,
        title: "Merged",
        keys: [
            .host(name: "example.com"),
            .app(bundleID: "com.example.app"),
            .localFiles,
        ]
    )
    let notes = [
        agentNote(
            id: 1,
            anchor: .app(bundleID: "com.example.app"),
            updated: 100
        ),
        agentNote(
            id: 2,
            anchor: .web(
                page: PageURL(host: "file", path: "/Users/secret/\(fileSecret).txt"),
                scope: .page
            ),
            workspaceOverride: workspaceID,
            updated: 300
        ),
        agentNote(
            id: 3,
            anchor: .web(page: page, scope: .page),
            updated: 200
        ),
        agentNote(
            id: 4,
            workspaceOverride: workspaceID,
            updated: 100
        ),
    ]
    let turn = ContextAssembler.assemble(
        snapshot: AgentSnapshot(notes: notes, workspaces: [workspace]),
        context: context,
        conversation: agentConversation(context: context),
        now: Date(timeIntervalSince1970: 1_800_000_000),
        question: "Question"
    )

    let aliases = aliasesByNoteID(turn)
    #expect(aliases[agentUUID(3)] == "N1")
    #expect(aliases[agentUUID(1)] == "N2")
    #expect(aliases[agentUUID(2)] == "N3")
    #expect(aliases[agentUUID(4)] == "N4")
    #expect(turn.manifest.entries.first { $0.noteID == agentUUID(2) }?.page == "Local file")

    let body = try requestString(turn.request)
    #expect(!body.contains(querySecret))
    #expect(!body.contains(fileSecret))
}

@Test func aliasesStayStableAcrossEditsAddsRemovalsAndReloads() throws {
    let context = agentContext()
    let first = AgentSnapshot(notes: [
        agentNote(id: 1, text: "one", updated: 200),
        agentNote(id: 2, text: "two", updated: 100),
    ])
    let turn1 = ContextAssembler.assemble(
        snapshot: first,
        context: context,
        conversation: agentConversation(scope: .allNotes, context: context),
        now: Date(timeIntervalSince1970: 1_800_000_000),
        question: "first"
    )
    #expect(aliasesByNoteID(turn1)[agentUUID(1)] == "N1")
    #expect(aliasesByNoteID(turn1)[agentUUID(2)] == "N2")

    let edited = AgentSnapshot(notes: [
        agentNote(id: 1, text: "one edited", revision: 2, updated: 300),
        agentNote(id: 2, text: "two", updated: 100, trashed: true),
        agentNote(id: 3, text: "three", updated: 50),
    ])
    let turn2 = ContextAssembler.assemble(
        snapshot: edited,
        context: context,
        conversation: turn1.conversation,
        now: Date(timeIntervalSince1970: 1_800_000_060),
        question: "second"
    )
    let aliases2 = aliasesByNoteID(turn2)
    #expect(aliases2[agentUUID(1)] == "N1")
    #expect(aliases2[agentUUID(3)] == "N3")
    #expect(turn2.turnSnapshot.retiredAliases.contains("N2"))
    #expect(turn2.turnSnapshot.notesByAlias["N1"]?.note.text == "one edited")

    let data = try JSONEncoder().encode(turn2.ledger)
    let reloaded = try JSONDecoder().decode(AgentAliasLedger.self, from: data)
    #expect(reloaded == turn2.ledger)

    let returned = AgentSnapshot(notes: [
        agentNote(id: 1, text: "one edited", revision: 2, updated: 300),
        agentNote(id: 2, text: "two returns", revision: 2, updated: 400),
        agentNote(id: 3, text: "three", updated: 50),
    ])
    let turn3 = ContextAssembler.assemble(
        snapshot: returned,
        context: context,
        conversation: turn2.conversation,
        now: Date(timeIntervalSince1970: 1_800_000_120),
        question: "third"
    )
    let aliases3 = aliasesByNoteID(turn3)
    #expect(aliases3[agentUUID(1)] == "N1")
    #expect(aliases3[agentUUID(3)] == "N3")
    #expect(aliases3[agentUUID(2)] == "N4")
    #expect(turn3.turnSnapshot.readNote(alias: "N2").failure == .retiredAlias)
    #expect(turn3.turnSnapshot.readNote(alias: "N4").content == "two returns")
    #expect(turn3.turnSnapshot.readNote(alias: "N99").failure == .unknownAlias)
}

@Test func perTurnReadCapIsFiveSuccessfulReads() {
    let context = agentContext()
    let turn = ContextAssembler.assemble(
        snapshot: AgentSnapshot(notes: [agentNote(id: 1, text: "full note")]),
        context: context,
        conversation: agentConversation(scope: .allNotes, context: context),
        now: Date(timeIntervalSince1970: 1_800_000_000),
        question: "question"
    )
    var session = AgentReadSession(snapshot: turn.turnSnapshot)
    for _ in 0..<5 {
        #expect(session.readNote(alias: "N1").content == "full note")
    }
    #expect(session.readsUsed == 5)
    #expect(session.readNote(alias: "N1").failure == .readLimitReached)
    #expect(turn.turnSnapshot.readNote(alias: "N1", readsUsed: 5).failure == .readLimitReached)
}

@Test func oneNoteIsTruncatedAtASentenceBoundaryWithAnExplicitMarker() {
    let sentence = "This is a sentence with enough words to matter. "
    let longText = String(repeating: sentence, count: 400)
    let turn = ContextAssembler.assemble(
        snapshot: AgentSnapshot(notes: [agentNote(id: 1, text: longText)]),
        context: agentContext(),
        conversation: agentConversation(scope: .allNotes),
        now: Date(timeIntervalSince1970: 1_800_000_000),
        question: "question"
    )

    #expect(turn.manifest.truncated.count == 1)
    #expect(turn.manifest.truncated[0].omittedCharacters > 0)
    let notesBlock = turn.request.system[1].text
    #expect(notesBlock.contains("[truncated:"))
    #expect(notesBlock.contains("read_note(\"N1\")"))
    let truncation = TokenEstimator.truncate(
        longText,
        maxCharacters: TokenEstimator.maxCharacters(forTokens: TokenEstimator.maxNoteTokens),
        alias: "N1"
    )
    #expect(truncation.isTruncated)
    #expect(truncation.text.last == ".")
    #expect(truncation.text.count + (truncation.marker?.count ?? 0)
        <= TokenEstimator.maxCharacters(forTokens: TokenEstimator.maxNoteTokens))
}

@Test func truncationFallsBackToAUnicodeCharacterBoundary() {
    let text = String(repeating: "😀", count: 5_000)
    let truncation = TokenEstimator.truncate(text, maxCharacters: 100, alias: "N1")

    #expect(truncation.isTruncated)
    #expect(truncation.text.count + (truncation.marker?.count ?? 0) <= 100)
    #expect(!truncation.text.contains("\u{FFFD}"))
}

@Test func packingStopsAtFirstNonfitAndCapsOmittedManifestAtFiftyLines() {
    let context = agentContext()
    let twoNotes = [
        agentNote(id: 1, text: "short first", updated: 200),
        agentNote(id: 2, text: "short second", updated: 100),
    ]
    let turn = ContextAssembler.assemble(
        snapshot: AgentSnapshot(notes: twoNotes),
        context: context,
        conversation: agentConversation(
            scope: .allNotes,
            context: context,
            configuration: agentConfiguration(context: context, notesBudget: 84)
        ),
        now: Date(timeIntervalSince1970: 1_800_000_000),
        question: "question"
    )
    #expect(turn.manifest.included.count == 1)
    #expect(turn.manifest.omitted.count == 1)

    let many = (1...55).map { agentNote(id: $0, text: "note \($0)", updated: 100) }
    let manyTurn = ContextAssembler.assemble(
        snapshot: AgentSnapshot(notes: many),
        context: context,
        conversation: agentConversation(
            scope: .allNotes,
            context: context,
            configuration: agentConfiguration(context: context, notesBudget: 2_000)
        ),
        now: Date(timeIntervalSince1970: 1_800_000_000),
        question: "question"
    )
    #expect(manyTurn.manifest.entries.count == 55)
    #expect(manyTurn.manifest.omittedLines.count <= ContextManifest.maxOmittedLines)
    let capped = ContextManifest(
        entries: [],
        omittedLines: Array(repeating: "line", count: 60)
    )
    #expect(capped.omittedLines.count == ContextManifest.maxOmittedLines)
}

@Test func packingIsDeterministicForTheSameInputs() {
    let context = agentContext()
    let snapshot = AgentSnapshot(notes: [
        agentNote(id: 1, text: "one", updated: 200),
        agentNote(id: 2, text: "two", updated: 100),
    ])
    let conversation = agentConversation(scope: .allNotes, context: context)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let first = ContextAssembler.assemble(
        snapshot: snapshot,
        context: context,
        conversation: conversation,
        now: now,
        question: "question"
    )
    let second = ContextAssembler.assemble(
        snapshot: snapshot,
        context: context,
        conversation: conversation,
        now: now,
        question: "question"
    )

    #expect(first.request.body == second.request.body)
    #expect(first.manifest == second.manifest)
    #expect(first.turnSnapshot == second.turnSnapshot)
}
