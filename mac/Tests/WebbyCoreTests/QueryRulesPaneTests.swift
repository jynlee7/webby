import Foundation
import Testing
@testable import WebbyCore

private let paneNow = Date(timeIntervalSince1970: 1_800_000_000)

private func paneNote(_ anchor: Anchor?, trashed: Bool = false) -> Note {
    Note(
        anchor: anchor,
        text: "n",
        frame: NoteFrame(),
        placement: .screen,
        trashedAt: trashed ? paneNow : nil,
        createdAt: paneNow,
        updatedAt: paneNow
    )
}

private func video(_ id: String, trashed: Bool = false) throws -> Note {
    let page = try #require(PageURL(string: "https://www.youtube.com/watch?v=\(id)&t=5"))
    return paneNote(.web(page: page, scope: .page), trashed: trashed)
}

private let ytRule = QueryRule(host: "youtube.com", key: "v")

@Suite("QueryRulesPane")
struct QueryRulesPaneTests {
    @Test func defaultRowsAreTheBuiltInsWithNoStatus() {
        let pane = QueryRulesPane(settings: .default, notes: [])
        #expect(pane.rows.map { "\($0.host) \($0.key)" } == ["news.ycombinator.com id", "youtube.com v"])
        #expect(pane.rows.allSatisfy { $0.isBuiltIn && $0.isEnabled && $0.status == nil })
    }

    @Test func removingABuiltInKeepsItInEffectWhileNotesUseIt() throws {
        let a = try video("A")
        let b = try video("B")
        let settings = QueryRulesPane.removing(host: "youtube.com", key: "v", from: .default)
        #expect(settings.removedBuiltInQueryRules == [ytRule])

        let pane = QueryRulesPane(settings: settings, notes: [a, b])
        let row = try #require(pane.rows.first { $0.host == "youtube.com" })
        #expect(!row.isEnabled && row.isBuiltIn)
        #expect(row.usageCount == 2)
        #expect(row.status == "Still used by 2 notes")

        // Each note still matches only its own video through the effective rules.
        let rules = QueryRules.effective(rules: settings.enabledQueryRules, anchors: [a, b].compactMap(\.anchor))
        #expect(rules.contains(ytRule))
        let pageA = try #require(PageURL(string: "https://youtube.com/watch?v=A", queryRules: rules))
        let pageB = try #require(PageURL(string: "https://youtube.com/watch?v=B", queryRules: rules))
        let anchorA = try #require(a.anchor)
        #expect(anchorA.matches(Context(appBundleID: "x", page: pageA)))
        #expect(!anchorA.matches(Context(appBundleID: "x", page: pageB)))
    }

    @Test func singularStatusForOneNote() throws {
        let settings = QueryRulesPane.removing(host: "youtube.com", key: "v", from: .default)
        let pane = QueryRulesPane(settings: settings, notes: [try video("A")])
        #expect(pane.rows.first { $0.host == "youtube.com" }?.status == "Still used by 1 note")
    }

    @Test func convertDropsTheKeyAndStopsItBeingSignificant() throws {
        let a = try video("A")
        let b = try video("B")
        let settings = QueryRulesPane.removing(host: "youtube.com", key: "v", from: .default)
        let pane = QueryRulesPane(settings: settings, notes: [a, b])

        let plan = try #require(pane.convertPlan(host: "youtube.com", key: "v"))
        #expect(Set(plan.rewrites.map(\.noteID)) == [a.id, b.id])
        #expect(plan.confirmationMessage.contains("share one page"))
        for rewrite in plan.rewrites {
            #expect(rewrite.anchor == .web(page: PageURL(host: "youtube.com", path: "/watch"), scope: .page))
        }

        // Apply to a real store to check the revision bump.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("webby-pane-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NoteStore(fileURL: directory.appendingPathComponent("notes.json"))
        #expect(store.add(a) && store.add(b))
        for rewrite in plan.rewrites {
            #expect(store.updateContent(id: rewrite.noteID, change: .anchor(rewrite.anchor)))
        }
        let converted = try [a, b].map { try #require(store.note(id: $0.id)) }
        #expect(converted.allSatisfy { $0.revision == a.revision + 1 })

        let after = QueryRulesPane(settings: settings, notes: converted)
        #expect(after.rows.allSatisfy { $0.host != "youtube.com" })
        let rules = QueryRules.effective(rules: settings.enabledQueryRules, anchors: converted.compactMap(\.anchor))
        #expect(!rules.contains(ytRule))
        let anchor = try #require(converted[0].anchor)
        for id in ["A", "B", "C"] {
            let page = try #require(PageURL(string: "https://youtube.com/watch?v=\(id)", queryRules: rules))
            #expect(anchor.matches(Context(appBundleID: "x", page: page)))
        }
    }

    @Test func convertKeepsOtherSignificantKeys() throws {
        let rule = QueryRule(host: "example.com", key: "a")
        let settings = Settings(queryRules: [QueryRule(host: "example.com", key: "b"), rule])
        let page = PageURL(host: "example.com", path: "/p", query: "a=1&b=2")
        let note = paneNote(.web(page: page, scope: .page))
        let pane = QueryRulesPane(settings: QueryRulesPane.removing(host: "example.com", key: "a", from: settings), notes: [note])
        let plan = try #require(pane.convertPlan(host: "example.com", key: "a"))
        #expect(plan.rewrites.first?.anchor == .web(page: PageURL(host: "example.com", path: "/p", query: "b=2"), scope: .page))
    }

    @Test func removingAnUnusedRuleJustDropsIt() {
        let settings = Settings(queryRules: [QueryRule(host: "example.com", key: "q")])
        let updated = QueryRulesPane.removing(host: "example.com", key: "q", from: settings)
        #expect(updated.queryRules.isEmpty && updated.removedBuiltInQueryRules.isEmpty)
        let pane = QueryRulesPane(settings: updated, notes: [])
        #expect(!pane.rows.contains { $0.host == "example.com" })
        #expect(pane.convertPlan(host: "example.com", key: "q") == nil)
    }

    @Test func trashedAndNonPageNotesDoNotCount() throws {
        let settings = QueryRulesPane.removing(host: "youtube.com", key: "v", from: .default)
        let page = try #require(PageURL(string: "https://youtube.com/watch?v=Z"))
        let notes = [
            try video("A", trashed: true),
            paneNote(.web(page: page, scope: .site)),
            paneNote(.web(page: page, scope: .prefix(path: "/watch"))),
            paneNote(.app(bundleID: "x")),
            paneNote(nil),
        ]
        let pane = QueryRulesPane(settings: settings, notes: notes)
        #expect(!pane.rows.contains { $0.host == "youtube.com" })
    }

    @Test func addingNormalizesAndValidates() throws {
        let added = try QueryRulesPane.adding(host: "  WWW.Example.com ", key: " q ", to: .default)
        #expect(added.queryRules == [QueryRule(host: "example.com", key: "q")])
        #expect(added.enabledQueryRules.contains(QueryRule(host: "example.com", key: "q")))

        #expect(throws: QueryRulesPane.RuleError.emptyHost) { try QueryRulesPane.adding(host: " ", key: "q", to: .default) }
        #expect(throws: QueryRulesPane.RuleError.emptyHost) { try QueryRulesPane.adding(host: "www.", key: "q", to: .default) }
        #expect(throws: QueryRulesPane.RuleError.emptyKey) { try QueryRulesPane.adding(host: "a.com", key: " ", to: .default) }
        #expect(throws: QueryRulesPane.RuleError.invalidHost) { try QueryRulesPane.adding(host: "https://a.com/x", key: "q", to: .default) }
        #expect(throws: QueryRulesPane.RuleError.invalidKey) { try QueryRulesPane.adding(host: "a.com", key: "a=b", to: .default) }
        #expect(throws: QueryRulesPane.RuleError.duplicate) { try QueryRulesPane.adding(host: "example.com", key: "q", to: added) }
        #expect(throws: QueryRulesPane.RuleError.duplicate) { try QueryRulesPane.adding(host: "youtube.com", key: "v", to: .default) }
    }

    @Test func addingARemovedBuiltInRestoresItInsteadOfDuplicating() throws {
        let removed = QueryRulesPane.removing(host: "youtube.com", key: "v", from: .default)
        let restored = try QueryRulesPane.adding(host: "www.youtube.com", key: "v", to: removed)
        #expect(restored.removedBuiltInQueryRules.isEmpty)
        #expect(restored.queryRules.isEmpty)
        #expect(restored.enabledQueryRules == QueryRules.builtIns)
    }

    @Test func addingARuleLeavesQueryLessAnchorsMatchingEveryValue() throws {
        let settings = try QueryRulesPane.adding(host: "example.com", key: "q", to: .default)
        let anchor = Anchor.web(page: PageURL(host: "example.com", path: "/p"), scope: .page)
        let rules = QueryRules.effective(rules: settings.enabledQueryRules, anchors: [anchor])
        for url in ["https://example.com/p", "https://example.com/p?q=1", "https://example.com/p?q=2"] {
            let page = try #require(PageURL(string: url, queryRules: rules))
            #expect(anchor.matches(Context(appBundleID: "x", page: page)))
        }
    }
}
