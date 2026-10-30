import Foundation
import WebbyCore
@testable import WebbyAgent

func agentUUID(_ number: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))!
}

func agentNote(
    id: Int,
    text: String = "note text",
    anchor: Anchor? = nil,
    tab: TabBinding? = nil,
    workspaceOverride: UUID? = nil,
    sourceURL: String? = nil,
    revision: Int = 1,
    updated: TimeInterval = 1_700_000_000,
    pinnedAt: Date? = nil,
    trashed: Bool = false,
    excluded: Bool = false,
    ephemeral: Bool = false
) -> Note {
    let date = Date(timeIntervalSince1970: updated)
    return Note(
        id: agentUUID(id),
        anchor: anchor,
        tab: tab,
        workspaceOverride: workspaceOverride,
        text: text,
        revision: revision,
        source: sourceURL.map { NoteSource(url: $0) },
        frame: NoteFrame(),
        placement: .screen,
        pinnedAt: pinnedAt,
        trashedAt: trashed ? date : nil,
        excludedFromAgent: excluded,
        createdAt: date,
        updatedAt: date,
        ephemeral: ephemeral
    )
}

func agentTab(
    tabID: Int = 7,
    windowID: Int = 1,
    lastURL: String = "https://example.com/"
) -> TabBinding {
    TabBinding(
        browser: "chrome",
        profile: "default",
        session: "session",
        tabID: tabID,
        windowID: windowID,
        index: 0,
        lastURL: lastURL
    )
}

func agentTabRef(tabID: Int = 7, windowID: Int = 1) -> TabRef {
    TabRef(
        browser: "chrome",
        profile: "default",
        session: "session",
        tabID: tabID,
        windowID: windowID
    )
}

func agentContext(
    page: PageURL? = PageURL(host: "example.com", path: "/a/b"),
    appBundleID: String = "com.google.Chrome",
    tab: TabRef? = TabRef(
        browser: "chrome",
        profile: "default",
        session: "session",
        tabID: 7,
        windowID: 1
    )
) -> Context {
    Context(appBundleID: appBundleID, page: page, tab: tab)
}

func agentConfiguration(
    context: Context = agentContext(),
    model: String = "synthetic-model",
    apiVersion: String = "synthetic-version",
    effort: ClaudeConfiguration.Effort = .medium,
    maxOutputTokens: Int = 4_096,
    notesBudget: Int = 8_000
) -> ClaudeConfiguration {
    ClaudeConfiguration(
        model: model,
        apiVersion: apiVersion,
        effort: effort,
        maxOutputTokens: maxOutputTokens,
        notesBudget: notesBudget,
        tieringContext: context
    )
}

func agentConversation(
    scope: AgentScope = .currentPage,
    context: Context = agentContext(),
    configuration: ClaudeConfiguration? = nil,
    ledger: AgentAliasLedger = AgentAliasLedger(),
    history: [ClaudeRequest.Message] = [],
    pendingQuestion: String? = nil
) -> AgentConversationState {
    AgentConversationState(
        scope: scope,
        startContext: context,
        configuration: configuration ?? agentConfiguration(context: context),
        ledger: ledger,
        history: history,
        pendingQuestion: pendingQuestion
    )
}

func aliasesByNoteID(_ turn: AgentAssembledTurn) -> [UUID: String] {
    Dictionary(uniqueKeysWithValues: turn.turnSnapshot.notesByAlias.values.map {
        ($0.note.id, $0.alias)
    })
}

func requestObject(_ request: ClaudeRequest) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: request.body) as! [String: Any]
}

func requestString(_ request: ClaudeRequest) throws -> String {
    String(decoding: request.body, as: UTF8.self)
}
