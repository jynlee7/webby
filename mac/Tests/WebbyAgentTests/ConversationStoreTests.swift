import Foundation
import Testing
import WebbyCore
@testable import WebbyAgent

private func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("WebbyConversationTests-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func storedDocument(
    id: UUID = UUID(),
    createdAt: Date = Date(timeIntervalSince1970: 1_800_000_000),
    noteID: UUID = agentUUID(1)
) -> ConversationDocument {
    var ledger = AgentAliasLedger()
    _ = ledger.assign(noteID: noteID, revision: 1)
    let asked = AgentTimestamp.rfc3339(createdAt)
    let manifest = ContextManifest(
        entries: [ContextManifest.Entry(
            alias: "N1",
            noteID: noteID,
            status: .included,
            revision: 1,
            page: "example.com/a/b",
            updated: "2026-10-20",
            summary: "secret summary"
        )],
        omittedLines: ["N1 · secret summary · example.com/a/b · 2026-10-20"],
        screen: .notCaptured
    )
    let turn = ConversationTurn(
        question: "Question",
        askedAt: asked,
        manifest: manifest,
        answerText: "I wrote secret [N1]",
        citations: [CitationValidator.Citation(
            alias: "N1",
            noteID: noteID,
            revision: 1,
            snippet: "secret snippet"
        )],
        usage: ClaudeUsage(inputTokens: 10, outputTokens: 2, cacheReadInputTokens: 1),
        status: .complete
    )
    return ConversationDocument(
        id: id,
        scope: .allNotes,
        startLabel: "example.com",
        configuration: StoredConversationConfiguration(
            model: "synthetic-model",
            apiVersion: "synthetic-version",
            effort: "medium",
            maxOutputTokens: 4_096,
            notesBudget: 8_000,
            tieringLabel: "example.com"
        ),
        aliases: ledger,
        createdAt: asked,
        updatedAt: asked,
        turns: [turn]
    )
}

@Test func citationValidationRemovesUnknownAliasesAndClassifiesLiveNotes() {
    let context = agentContext()
    let turn = ContextAssembler.assemble(
        snapshot: AgentSnapshot(notes: [
            agentNote(id: 1, text: "one", revision: 2),
            agentNote(id: 2, text: "two"),
        ]),
        context: context,
        conversation: agentConversation(scope: .allNotes, context: context),
        now: Date(timeIntervalSince1970: 1_800_000_000),
        question: "q"
    )
    let live = [
        agentUUID(1): agentNote(id: 1, text: "changed", revision: 3),
        agentUUID(2): agentNote(id: 2, text: "two", trashed: true),
    ]

    let validation = CitationValidator.validate(
        answerText: "A [N1] B [N99] C [N2] and [N1] again",
        snapshot: turn.turnSnapshot,
        sentAliases: ["N1", "N2"],
        liveNotes: live
    )

    #expect(!validation.answerText.contains("N99"))
    #expect(validation.answerText.contains("[N1]"))
    #expect(validation.answerText.contains("[N2]"))
    #expect(validation.citations.map(\.alias) == ["N1", "N2"])
    #expect(validation.citations[0].status == .edited)
    #expect(validation.citations[1].status == .deleted)
    #expect(validation.citations[0].revision == 2)
}

@Test func citationValidationMarksExcludedAndRemovesRetiredAliases() {
    let context = agentContext()
    let turn = ContextAssembler.assemble(
        snapshot: AgentSnapshot(notes: [agentNote(id: 1, text: "one")]),
        context: context,
        conversation: agentConversation(scope: .allNotes, context: context),
        now: Date(timeIntervalSince1970: 1_800_000_000),
        question: "q"
    )
    let excluded = CitationValidator.validate(
        answerText: "[N1]",
        snapshot: turn.turnSnapshot,
        liveNotes: [agentUUID(1): agentNote(id: 1, text: "one", excluded: true)]
    )
    #expect(excluded.citations.first?.status == .excluded)

    let snapshot = AgentTurnSnapshot(
        notesByAlias: turn.turnSnapshot.notesByAlias,
        orderedAliases: ["N1"],
        retiredAliases: ["N2"],
        authorizationFingerprint: "fingerprint"
    )
    let retired = CitationValidator.validate(
        answerText: "Keep [N1], drop [N2]",
        snapshot: snapshot
    )
    #expect(retired.answerText == "Keep [N1], drop ")
    #expect(retired.citations.map(\.alias) == ["N1"])
}

@Test func citationValidationIsDeterministic() {
    let context = agentContext()
    let turn = ContextAssembler.assemble(
        snapshot: AgentSnapshot(notes: [agentNote(id: 1, text: "one")]),
        context: context,
        conversation: agentConversation(scope: .allNotes, context: context),
        now: Date(timeIntervalSince1970: 1_800_000_000),
        question: "q"
    )
    let first = CitationValidator.validate(answerText: "[N1] [N1]", snapshot: turn.turnSnapshot)
    let second = CitationValidator.validate(answerText: "[N1] [N1]", snapshot: turn.turnSnapshot)
    #expect(first == second)
    #expect(first.citations.count == 1)
}

@Test func conversationRoundTripAndOwnerOnlyPermissions() async throws {
    let directory = temporaryDirectory()
    let store = ConversationStore(directory: directory)
    let document = storedDocument()

    let saved = try await store.save(document)
    let loadedOptional = await store.load(document.id)
    let loaded = try #require(loadedOptional)

    #expect(loaded.id == document.id)
    #expect(loaded.scope == .allNotes)
    #expect(loaded.turns == document.turns)
    #expect(!saved.updatedAt.isEmpty)
    #expect(!String(decoding: try Data(contentsOf: store.fileURL(for: document.id)), as: UTF8.self)
        .contains("thinking"))

    let directoryMode = try FileManager.default
        .attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
    let fileMode = try FileManager.default
        .attributesOfItem(atPath: store.fileURL(for: document.id).path)[.posixPermissions] as? NSNumber
    #expect(directoryMode?.intValue == 0o700)
    #expect(fileMode?.intValue == 0o600)
}

@Test func conversationSymlinkIsRejectedWithoutTouchingItsTarget() async throws {
    let directory = temporaryDirectory()
    let store = ConversationStore(directory: directory)
    let id = UUID()
    let outside = directory.deletingLastPathComponent()
        .appendingPathComponent("WebbyOutside-\(UUID().uuidString).json")
    try Data("outside".utf8).write(to: outside)
    try FileManager.default.createSymbolicLink(
        at: store.fileURL(for: id),
        withDestinationURL: outside
    )

    do {
        _ = try await store.save(storedDocument(id: id))
        Issue.record("Expected unsafe path")
    } catch let error as ConversationStoreError {
        #expect(error == .unsafePath)
    }
    #expect(try Data(contentsOf: outside) == Data("outside".utf8))
    let opened = await store.open(id)
    #expect(opened.isReadOnly)
}

@Test func conversationNewerVersionIsReadOnly() async throws {
    let directory = temporaryDirectory()
    let store = ConversationStore(directory: directory)
    let id = UUID()
    try Data(#"{"version":99,"content":{}}"#.utf8).write(to: store.fileURL(for: id))

    let open = await store.open(id)
    #expect(open.isReadOnly)
    #expect(open.mode == .readOnly(.newerVersion(found: 99, supported: 1)))

    do {
        _ = try await store.save(storedDocument(id: id))
        Issue.record("Expected a read-only save failure")
    } catch let error as ConversationStoreError {
        #expect(error == .readOnly(.newerVersion(found: 99, supported: 1)))
    }
}

private final class RetentionClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ date: Date) {
        lock.lock()
        value = date
        lock.unlock()
    }
}

@Test func conversationRetentionPurgesOnlyExpiredFiles() async throws {
    let directory = temporaryDirectory()
    let clock = RetentionClock(Date(timeIntervalSince1970: 1_700_000_000))
    let store = ConversationStore(directory: directory, clock: { clock.now() })
    let old = storedDocument(createdAt: clock.now())
    let fresh = storedDocument(createdAt: clock.now())
    _ = try await store.save(old)

    clock.set(Date(timeIntervalSince1970: 1_800_000_000))
    _ = try await store.save(fresh)

    let removed = try await store.purgeExpired(
        retentionDays: 30,
        now: Date(timeIntervalSince1970: 1_800_000_000)
    )
    #expect(removed == [old.id])
    let oldOptional = await store.load(old.id)
    let freshOptional = await store.load(fresh.id)
    #expect(oldOptional == nil)
    #expect(freshOptional != nil)
}

@Test func conversationRedactionRetiresAliasesAndKeepsAnswerText() async throws {
    let directory = temporaryDirectory()
    let store = ConversationStore(directory: directory)
    let document = storedDocument()
    _ = try await store.save(document)

    let changed = try await store.redactNote(agentUUID(1))
    #expect(changed == 1)

    let loadedOptional = await store.load(document.id)
    let loaded = try #require(loadedOptional)
    let turn = loaded.turns[0]
    #expect(turn.manifest.entries[0].summary == "note deleted")
    #expect(turn.manifest.entries[0].page == "note deleted")
    #expect(turn.manifest.omittedLines == ["note deleted"])
    #expect(turn.citations[0].snippet == "note deleted")
    #expect(turn.citations[0].status == .deleted)
    #expect(turn.answerText == "I wrote secret [N1]")
    #expect(loaded.aliases.entries[0].retired)
}

private final class BlockingWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let started = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private var writes = 0

    func write(_ data: Data, to url: URL) throws {
        lock.lock()
        writes += 1
        let current = writes
        lock.unlock()
        if current == 1 {
            started.signal()
            release.wait()
        }
        try data.write(to: url, options: .atomic)
    }

    func waitForFirstWrite() -> Bool {
        switch started.wait(timeout: .now() + 5) {
        case .success:
            return true
        case .timedOut:
            return false
        }
    }

    func allowFirstWriteToFinish() {
        release.signal()
    }

    func writeCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return writes
    }
}

@Test func pendingWriteIsSerializedBeforeTheNextWrite() async throws {
    let directory = temporaryDirectory()
    let writer = BlockingWriter()
    let store = ConversationStore(
        directory: directory,
        atomicWrite: { data, url in try writer.write(data, to: url) }
    )
    let first = storedDocument()
    let second = storedDocument()

    let firstSave = Task { try await store.save(first) }
    #expect(writer.waitForFirstWrite())
    let secondSave = Task { try await store.save(second) }
    try await Task.sleep(nanoseconds: 50_000_000)
    #expect(writer.writeCount() == 1)

    writer.allowFirstWriteToFinish()
    _ = try await firstSave.value
    _ = try await secondSave.value
    #expect(writer.writeCount() == 2)
    let firstLoaded = await store.load(first.id)
    let secondLoaded = await store.load(second.id)
    #expect(firstLoaded != nil)
    #expect(secondLoaded != nil)
}

private struct InjectedWriteFailure: Error {}

@Test func injectedWriteFailureLeavesNoConversationFile() async throws {
    let directory = temporaryDirectory()
    let store = ConversationStore(
        directory: directory,
        atomicWrite: { _, _ in throw InjectedWriteFailure() }
    )
    let document = storedDocument()

    do {
        _ = try await store.save(document)
        Issue.record("Expected an injected write failure")
    } catch let error as ConversationStoreError {
        guard case .writeFailed = error else {
            Issue.record("Unexpected error: \(error)")
            return
        }
    }
    #expect(!FileManager.default.fileExists(atPath: store.fileURL(for: document.id).path))
}
