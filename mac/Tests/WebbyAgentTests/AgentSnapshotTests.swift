import Foundation
import Testing
import WebbyCore
@testable import WebbyAgent

@Test func snapshotExcludesTrashExcludedAndEphemeralNotes() {
    let notes = [
        agentNote(id: 1),
        agentNote(id: 2, trashed: true),
        agentNote(id: 3, excluded: true),
        agentNote(id: 4, ephemeral: true),
    ]
    let snapshot = AgentSnapshot(notes: notes)

    #expect(snapshot.notes.map(\.id) == [agentUUID(1)])
}

@Test func inboxIsIncludedOnlyForExplicitAllNotesScope() {
    let inbox = agentNote(id: 1, text: "inbox")
    let page = agentNote(
        id: 2,
        anchor: .web(
            page: PageURL(host: "example.com", path: "/a/b"),
            scope: .page
        )
    )
    let snapshot = AgentSnapshot(notes: [inbox, page])
    let context = agentContext()

    #expect(snapshot.notes(for: .currentPage, context: context).map(\.id) == [agentUUID(2)])
    #expect(snapshot.notes(for: .workspace, context: context).map(\.id) == [agentUUID(2)])
    #expect(Set(snapshot.notes(for: .allNotes, context: context).map(\.id))
        == Set([agentUUID(1), agentUUID(2)]))
}

@Test func snapshotComputesEffectiveQueryRulesFromConfiguredAndAnchorRules() {
    let page = PageURL(host: "example.com", path: "/p", query: "id=secret")
    let note = agentNote(id: 1, anchor: .web(page: page, scope: .page))
    let snapshot = AgentSnapshot(
        notes: [note],
        queryRules: [QueryRule(host: "other.test", key: "q")]
    )

    #expect(snapshot.effectiveQueryRules.contains(QueryRule(host: "example.com", key: "id")))
    #expect(snapshot.effectiveQueryRules.contains(QueryRule(host: "other.test", key: "q")))
    #expect(snapshot.queryRules == snapshot.effectiveQueryRules)
}

@Test func contextLabelRemovesQueryAndFilePaths() {
    let querySecret = "query-sentinel"
    let fileSecret = "file-sentinel"
    let web = PageURL(host: "example.com", path: "/a/b", query: "token=\(querySecret)")
    let file = PageURL(host: "file", path: "/Users/secret/\(fileSecret).txt")

    #expect(AgentContextLabel.page(web) == "example.com/a/b")
    #expect(!AgentContextLabel.page(web).contains(querySecret))
    #expect(AgentContextLabel.page(file) == "Local file")
    #expect(!AgentContextLabel.page(file).contains(fileSecret))
    #expect(AgentContextLabel.label(for: Context(appBundleID: "com.example.app", page: file))
        == "Local file")
    #expect(AgentContextLabel.label(for: Context(appBundleID: "com.example.app", tab: agentTabRef()))
        == "Browser tab without page")
}

@Test func contextLabelUsesAppDisplayNameOrBundleID() {
    let bundle = "com.example.notes"
    let workspace = WorkspaceRecord(
        id: agentUUID(90),
        title: "Reading",
        keys: [.app(bundleID: bundle)]
    )

    #expect(AgentContextLabel.label(
        for: Context(appBundleID: bundle, page: nil, tab: nil),
        workspaces: [workspace]
    ) == "Reading")
    #expect(AgentContextLabel.label(
        for: Context(appBundleID: bundle, page: nil, tab: nil)
    ) == bundle)
}
