import Foundation
import Testing
@testable import Webby
import WebbyAgent
import WebbyCore

// MARK: Scripted client

private func sse(_ name: String, _ object: [String: Any]) -> String {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return "event: \(name)\ndata: \(String(decoding: data, as: UTF8.self))\n\n"
}

private func messageStart(cacheRead: Int = 0) -> String {
    sse("message_start", ["type": "message_start", "message": [
        "id": "msg_synthetic", "model": "synthetic-model",
        "usage": ["input_tokens": 12, "output_tokens": 0, "cache_read_input_tokens": cacheRead, "cache_creation_input_tokens": 0],
    ]])
}

private func textStart(_ index: Int) -> String {
    sse("content_block_start", ["type": "content_block_start", "index": index, "content_block": ["type": "text", "text": ""]])
}

private func textDelta(_ index: Int, _ text: String) -> String {
    sse("content_block_delta", ["type": "content_block_delta", "index": index, "delta": ["type": "text_delta", "text": text]])
}

private func blockStop(_ index: Int) -> String {
    sse("content_block_stop", ["type": "content_block_stop", "index": index])
}

private func messageEnd(_ stop: String = "end_turn") -> String {
    sse("message_delta", ["type": "message_delta", "delta": ["stop_reason": stop, "stop_sequence": NSNull()], "usage": ["output_tokens": 5]])
        + sse("message_stop", ["type": "message_stop"])
}

private func toolUse(_ index: Int, id: String, alias: String) -> String {
    sse("content_block_start", ["type": "content_block_start", "index": index, "content_block": ["type": "tool_use", "id": id, "name": "read_note", "input": [:]]])
        + sse("content_block_delta", ["type": "content_block_delta", "index": index, "delta": ["type": "input_json_delta", "partial_json": "{\"alias\":\"\(alias)\"}"]])
        + blockStop(index)
}

private func answer(_ text: String, cacheRead: Int = 0) -> [ScriptedTransport.Step] {
    [.send(messageStart(cacheRead: cacheRead) + textStart(0) + textDelta(0, text) + blockStop(0) + messageEnd())]
}

/// Plays one script per request and records every request it receives.
private final class ScriptedTransport: ClaudeTransport, @unchecked Sendable {
    enum Step {
        case send(String)
        case fail(ClaudeTransportError)
        case wait(Gate)
    }

    final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var opened = false
        private var waiter: CheckedContinuation<Void, Never>?
        private var reached = false
        private var reachedWaiters: [CheckedContinuation<Void, Never>] = []

        private func locked<T>(_ body: () -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body()
        }

        func open() {
            let waiting: CheckedContinuation<Void, Never>? = locked {
                opened = true
                defer { waiter = nil }
                return waiter
            }
            waiting?.resume()
        }

        func wait() async {
            let toResume: [CheckedContinuation<Void, Never>] = locked {
                reached = true
                defer { reachedWaiters = [] }
                return reachedWaiters
            }
            toResume.forEach { $0.resume() }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let now: Bool = locked {
                    if opened { return true }
                    waiter = continuation
                    return false
                }
                if now { continuation.resume() }
            }
        }

        func untilReached() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let now: Bool = locked {
                    if reached { return true }
                    reachedWaiters.append(continuation)
                    return false
                }
                if now { continuation.resume() }
            }
        }
    }

    private let lock = NSLock()
    private var scripts: [[Step]]
    private var captured: [PreparedRequest] = []

    init(_ scripts: [[Step]]) {
        self.scripts = scripts
    }

    var requests: [PreparedRequest] {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    func stream(_ request: PreparedRequest) -> AsyncThrowingStream<Data, Error> {
        lock.lock()
        captured.append(request)
        let script = scripts.isEmpty ? [] : scripts.removeFirst()
        lock.unlock()
        return AsyncThrowingStream { continuation in
            let task = Task {
                for step in script {
                    switch step {
                    case .send(let text):
                        continuation.yield(Data(text.utf8))
                    case .fail(let error):
                        continuation.finish(throwing: error)
                        return
                    case .wait(let gate):
                        await gate.wait()
                        if Task.isCancelled {
                            continuation.finish(throwing: ClaudeTransportError.cancelled)
                            return
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private struct StubCredentials: CredentialProvider {
    let key: String?
    func credential(for kind: CredentialKind) async throws -> CredentialValue? {
        key.map { CredentialValue(secret: $0) }
    }
}

@MainActor
private final class FakeNotes: AgentNotesSource {
    var notes: [Note]
    var workspaces: [WorkspaceRecord] = []
    var created: [(text: String, destination: LibraryDestination)] = []
    private var observers: [@MainActor () -> Void] = []

    init(_ notes: [Note]) { self.notes = notes }

    var agentNotes: [Note] { notes }
    var agentWorkspaces: [WorkspaceRecord] { workspaces }

    func addLibraryObserver(_ observer: @escaping @MainActor () -> Void) -> UUID {
        observers.append(observer)
        return UUID()
    }

    func createAgentNote(text: String, destination: LibraryDestination) -> UUID? {
        created.append((text, destination))
        return UUID()
    }

    func mutate(_ change: (inout [Note]) -> Void) {
        change(&notes)
        observers.forEach { $0() }
    }
}

// MARK: Fixtures

private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
private let leetcode = Context(appBundleID: "com.google.Chrome", page: PageURL(host: "leetcode.com", path: "/problems/two-sum"))
private let github = Context(appBundleID: "com.google.Chrome", page: PageURL(host: "github.com", path: "/jynlee7"))

private func uuid(_ n: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
}

private func webNote(_ n: Int, _ text: String, host: String = "leetcode.com", path: String = "/problems/two-sum", excluded: Bool = false) -> Note {
    Note(
        id: uuid(n),
        anchor: .web(page: PageURL(host: host, path: path), scope: .page),
        text: text,
        frame: NoteFrame(),
        placement: .screen,
        excludedFromAgent: excluded,
        createdAt: fixedNow,
        updatedAt: fixedNow
    )
}

@MainActor
private final class Harness {
    let notes: FakeNotes
    let transport: ScriptedTransport
    var context: Context = leetcode
    var logs: [String] = []
    var opened: [UUID] = []
    private(set) var controller: AgentController!

    init(notes: [Note], scripts: [[ScriptedTransport.Step]], key: String? = "sk-test-synthetic", store: ConversationStore? = nil) {
        self.notes = FakeNotes(notes)
        self.transport = ScriptedTransport(scripts)
        let transport = self.transport
        controller = AgentController(
            notes: self.notes,
            dependencies: AgentController.Dependencies(
                credentials: StubCredentials(key: key),
                makeTransport: { KeyedClaudeTransport(base: transport, apiKey: $0) },
                currentContext: { [unowned self] in self.context },
                model: { "synthetic-model" },
                queryRules: { [] },
                now: { fixedNow },
                conversations: store,
                debugLog: { [unowned self] in self.logs.append($0) }
            )
        )
        controller.openNote = { [unowned self] in self.opened.append($0) }
    }

    func ask(_ question: String) async {
        controller.draft = question
        controller.ask()
        await settle()
    }

    func settle() async {
        for _ in 0..<2_000 where controller.isRunning {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    func requestBody(_ index: Int) -> String {
        String(decoding: transport.requests[index].body, as: UTF8.self)
    }
}

// MARK: Tests

@MainActor
@Suite struct AgentControllerTests {
    @Test func streamsAnAnswerWithChipsThatOpenTheCitedNote() async throws {
        let decision = webNote(1, "Two-sum: use a hash map, one pass")
        let other = webNote(2, "Read the editorial later", path: "/problems/three-sum")
        let harness = Harness(notes: [decision, other], scripts: [answer("You chose a one-pass hash map [N1].")])

        await harness.ask("What did I decide about two-sum?")

        let turn = try #require(harness.controller.turns.first)
        #expect(turn.question == "What did I decide about two-sum?")
        #expect(turn.answer == "You chose a one-pass hash map [N1].")
        #expect(turn.status == .complete)
        let chips = harness.controller.chips(for: turn)
        #expect(chips.map(\.alias) == ["N1"])
        #expect(chips.first?.noteID == decision.id)
        #expect(chips.first?.mark == .current)
        harness.controller.open(try #require(chips.first))
        #expect(harness.opened == [decision.id])
        #expect(harness.controller.scopeTitle == "leetcode.com")

        let request = try #require(harness.transport.requests.first)
        #expect(request.headers.contains { $0.name == "x-api-key" && $0.value == "sk-test-synthetic" })
        #expect(harness.requestBody(0).contains("\"model\":\"synthetic-model\""))
    }

    @Test func excludedNotesNeverReachWhatTheAgentSaw() async throws {
        let open = webNote(1, "Two-sum: hash map")
        let secret = webNote(2, "SENTINEL private reflection", excluded: true)
        let harness = Harness(notes: [open, secret], scripts: [answer("Hash map [N1].")])

        await harness.ask("What did I decide?")

        let turn = try #require(harness.controller.turns.first)
        #expect(turn.manifest.entries.map(\.noteID) == [open.id])
        #expect(!turn.manifest.entries.contains { $0.summary.contains("SENTINEL") })
        #expect(!harness.requestBody(0).contains("SENTINEL"))
    }

    @Test func aNetworkFailureKeepsTheQuestionAndPartialAnswerAndRetryWorks() async throws {
        let note = webNote(1, "Two-sum: hash map")
        let harness = Harness(notes: [note], scripts: [
            [.send(messageStart() + textStart(0) + textDelta(0, "You decided on a hash")), .fail(.network)],
            answer("You decided on a hash map [N1]."),
        ])

        await harness.ask("What did I decide about two-sum?")

        let failed = try #require(harness.controller.turns.first)
        #expect(failed.question == "What did I decide about two-sum?")
        #expect(failed.answer == "You decided on a hash")
        guard case .failed(let message) = failed.status else {
            Issue.record("Expected a failed turn, got \(failed.status)")
            return
        }
        #expect(message.contains("connection"))
        #expect(failed.isRetryable)

        harness.controller.retry()
        await harness.settle()

        #expect(harness.controller.turns.count == 2)
        #expect(harness.controller.turns[0].answer == "You decided on a hash")
        #expect(harness.controller.turns[1].question == failed.question)
        #expect(harness.controller.turns[1].answer == "You decided on a hash map [N1].")
        #expect(harness.controller.turns[1].status == .complete)
        // A failed turn is not part of the history the follow-up resends.
        #expect(!harness.requestBody(1).contains("You decided on a hash\""))
    }

    @Test func aFollowUpResendsHistoryAndLogsStoredCacheReads() async throws {
        let note = webNote(1, "Two-sum: hash map")
        let harness = Harness(notes: [note], scripts: [
            answer("A hash map [N1]."),
            answer("Yes, one pass [N1].", cacheRead: 2_048),
        ])

        await harness.ask("What did I decide?")
        await harness.ask("Was it one pass?")

        #expect(harness.controller.turns.count == 2)
        #expect(harness.controller.turns[1].usage.cacheReadInputTokens == 2_048)
        #expect(harness.requestBody(1).contains("A hash map [N1]."))
        #expect(harness.logs.last == AgentController.usageLogLine(harness.controller.turns[1].usage))
        #expect(harness.logs.last?.contains("cache_read_input_tokens=2048") == true)
    }

    @Test func withoutAKeyThePanelAsksForOneAndSendsNothing() async throws {
        let harness = Harness(notes: [webNote(1, "Two-sum")], scripts: [], key: nil)

        await harness.ask("What did I decide?")

        #expect(harness.controller.needsKey)
        #expect(harness.controller.draft == "What did I decide?")
        #expect(harness.controller.turns.isEmpty)
        #expect(harness.transport.requests.isEmpty)
    }

    @Test func askingFromAnotherWorkspacePromptsBeforeMixingScopes() async throws {
        let harness = Harness(
            notes: [webNote(1, "Two-sum"), webNote(2, "Repo notes", host: "github.com", path: "/jynlee7")],
            scripts: [answer("Hash map [N1]."), answer("Repo answer [N1].")]
        )
        await harness.ask("What did I decide?")

        harness.context = github
        harness.controller.draft = "What about my repo?"
        harness.controller.ask()

        let prompt = try #require(harness.controller.scopePrompt)
        #expect(prompt.conversationTitle == "leetcode.com")
        #expect(prompt.currentTitle == "github.com")
        #expect(harness.transport.requests.count == 1)

        harness.controller.resolveScopePrompt(.newConversation)
        await harness.settle()

        #expect(harness.controller.turns.map(\.question) == ["What about my repo?"])
        #expect(harness.controller.scopeTitle == "github.com")
        #expect(harness.requestBody(1).contains("Repo notes"))
        #expect(!harness.requestBody(1).contains("Two-sum"))
    }

    @Test func chipsMarkEditedExcludedAndDeletedNotes() async throws {
        let edited = webNote(1, "First")
        let excluded = webNote(2, "Second")
        let deleted = webNote(3, "Third")
        let harness = Harness(notes: [edited, excluded, deleted], scripts: [answer("See [N1], [N2] and [N3].")])
        await harness.ask("Summarize")

        harness.notes.mutate { notes in
            notes[0].text = "First, edited"
            notes[0].revision += 1
            notes[1].excludedFromAgent = true
            notes.remove(at: 2)
        }

        let turn = try #require(harness.controller.turns.first)
        let marks = Dictionary(uniqueKeysWithValues: harness.controller.chips(for: turn).map { ($0.noteID, $0) })
        #expect(marks[edited.id]?.mark == .editedSince)
        #expect(marks[excluded.id]?.mark == .nowExcluded)
        #expect(marks[deleted.id]?.mark == .noteDeleted)
        #expect(marks[deleted.id]?.snippet == "note deleted")
        #expect(marks[deleted.id]?.canOpen == false)
        #expect(AgentCitationMark.editedSince.label == "edited since")
        #expect(AgentCitationMark.noteDeleted.label == "note deleted")
        #expect(AgentCitationMark.nowExcluded.label == "now excluded")
    }

    @Test func trashingAScopedNoteStopsARunningTurnAndKeepsThePartialAnswer() async throws {
        let gate = ScriptedTransport.Gate()
        let harness = Harness(notes: [webNote(1, "Two-sum"), webNote(2, "Other")], scripts: [
            [.send(messageStart() + textStart(0) + textDelta(0, "Partial")), .wait(gate), .send(blockStop(0) + messageEnd())],
        ])
        harness.controller.draft = "What did I decide?"
        harness.controller.ask()
        await gate.untilReached()
        for _ in 0..<500 where harness.controller.turns.first?.answer != "Partial" {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }

        harness.notes.mutate { $0[1].trashedAt = fixedNow }
        gate.open()
        await harness.settle()

        let turn = try #require(harness.controller.turns.first)
        #expect(turn.answer == "Partial")
        #expect(turn.status == .failed(AgentErrorMessage.notesChanged))
        #expect(turn.isRetryable)
    }

    @Test func saveAsNoteWritesTheAnswerAndSourcesIntoTheWorkspace() async throws {
        let note = webNote(1, "Two-sum: hash map")
        let harness = Harness(notes: [note], scripts: [answer("A hash map [N1].")])
        await harness.ask("What did I decide?")

        let turn = try #require(harness.controller.turns.first)
        #expect(harness.controller.saveAsNote(turn.id) != nil)

        let created = try #require(harness.notes.created.first)
        #expect(created.text.hasPrefix("What did I decide?\n\nA hash map [N1]."))
        #expect(created.text.contains("webby://note/\(note.id.uuidString.lowercased())"))
        #expect(created.destination == .workspace(.host(name: "leetcode.com")))
        #expect(harness.controller.turns.first?.savedNoteID != nil)
        #expect(harness.controller.saveAsNote(turn.id) == nil)
    }

    @Test func aFailedTurnKeepsCitationsToReadAndListedNotesAndItsTokenUse() async throws {
        // Enough long notes that the last ones are past both the notes budget and the
        // 50-line omitted manifest, so N80 reaches the model only through read_note.
        let notes = (1...80).map { webNote($0, "Note \($0). " + String(repeating: "Detail sentence here. ", count: 190)) }
        let harness = Harness(notes: notes, scripts: [
            [.send(messageStart() + toolUse(0, id: "toolu_1", alias: "N80") + messageEnd("tool_use"))],
            [.send(messageStart() + textStart(0) + textDelta(0, "Per [N80] and [N60], and not [N99]")), .fail(.network)],
        ])

        await harness.ask("What did I write?")

        let turn = try #require(harness.controller.turns.first)
        let manifestAliases = Set(turn.manifest.entries.map(\.alias))
        #expect(!turn.manifest.omittedLines.contains { $0.hasPrefix("N80 ") })
        #expect(manifestAliases.contains("N60"))
        #expect(turn.answer == "Per [N80] and [N60], and not ")
        #expect(turn.citations.map(\.alias) == ["N80", "N60"])
        #expect(turn.usage.inputTokens == 24)
        #expect(turn.usage.outputTokens == 5)
        #expect(harness.logs.last == AgentController.usageLogLine(turn.usage))
    }

    @Test func aNoteLongerThanTheCapIsReadInFullAndTheTurnCompletes() async throws {
        let tail = "TAIL-SENTINEL decided on a one-pass hash map."
        let long = webNote(1, String(repeating: "Earlier exploration of two-sum. ", count: 200) + tail)
        let harness = Harness(notes: [long], scripts: [
            [.send(messageStart() + toolUse(0, id: "toolu_long", alias: "N1") + messageEnd("tool_use"))],
            answer("You settled on a one-pass hash map [N1]."),
        ])

        await harness.ask("What did I finally decide about two-sum?")

        let turn = try #require(harness.controller.turns.first)
        #expect(turn.manifest.entries.first?.status == .truncated)
        #expect(!harness.requestBody(0).contains("TAIL-SENTINEL"))
        #expect(harness.transport.requests.count == 2)
        #expect(harness.requestBody(1).contains("TAIL-SENTINEL"))
        #expect(harness.requestBody(1).contains("\"tool_use_id\":\"toolu_long\""))
        #expect(turn.status == .complete)
        #expect(turn.answer == "You settled on a one-pass hash map [N1].")
        #expect(turn.citations.map(\.alias) == ["N1"])
    }

    @Test func shortcutsCanNeverBeSavedTwiceOnEitherPath() {
        let agent = KeyCombo.defaultAgent
        #expect(SettingsWindowController.shortcutConflict(agent, forAgent: true, other: agent)?.contains("already creates a note") == true)
        #expect(SettingsWindowController.shortcutConflict(agent, forAgent: false, other: agent)?.contains("already opens the agent panel") == true)
        #expect(SettingsWindowController.shortcutConflict(agent, forAgent: true, other: .defaultNewNote) == nil)
    }

    @Test func theModelDefaultComesFromTheAgentModulesPinnedConfiguration() {
        #expect(AgentModelSetting.resolve("") == ClaudeConfiguration.pendingLiveDocVerification.model)
        #expect(AgentModelSetting.resolve("  custom-model  ") == "custom-model")
        #expect(WebbyCore.Settings.default.agentModel.isEmpty)
        #expect(AgentModelSetting.problem(with: "bad model") != nil)
        #expect(AgentModelSetting.problem(with: "claude-x-1") == nil)
    }
}

@MainActor
@Suite struct AgentShortcutTests {
    @Test func theAgentShortcutDefaultsToControlOptionA() {
        #expect(KeyCombo.defaultAgent.storageString == "ctrl+opt+a")
        #expect(KeyCombo("ctrl+opt+a") == KeyCombo.defaultAgent)
        #expect(SettingsWindowController.agentShortcut(from: .default) == .defaultAgent)
        var settings = WebbyCore.Settings.default
        settings.agentHotkey = "a"
        #expect(SettingsWindowController.agentShortcut(from: settings) == .defaultAgent)
        settings.agentHotkey = "cmd+shift+k"
        #expect(SettingsWindowController.agentShortcut(from: settings).storageString == "shift+cmd+k" || SettingsWindowController.agentShortcut(from: settings) == KeyCombo("cmd+shift+k"))
    }

    @Test func registrationFailuresReadAsFailuresInSettings() {
        let combo = KeyCombo.defaultAgent
        let taken = Hotkeys.Status.failed(combo, OSStatus(-9878))
        #expect(taken.isFailure)
        #expect(taken.agentMessage.contains("already used"))
        #expect(Hotkeys.Status.registered(combo).agentMessage == "\(combo.displayString) opens the agent panel.")
    }
}

// MARK: Stored conversations

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    var now: Date {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}

private func temporaryConversations(clock: TestClock = TestClock(fixedNow)) throws -> (ConversationStore, URL) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("WebbyAgentConversations-\(UUID().uuidString)", isDirectory: true)
    return (ConversationStore(directory: directory, clock: { clock.now }), directory)
}

@MainActor
@Suite struct AgentConversationStorageTests {
    @Test func turnsAreStoredWithoutTheKeyOrExcludedNotes() async throws {
        let (store, directory) = try temporaryConversations()
        defer { try? FileManager.default.removeItem(at: directory) }
        let harness = Harness(
            notes: [webNote(1, "Two-sum: hash map"), webNote(2, "SENTINEL secret", excluded: true)],
            scripts: [answer("A hash map [N1].")],
            store: store
        )

        await harness.ask("What did I decide?")
        await harness.controller.waitForStorage()

        let ids = try await store.conversationIDs()
        #expect(ids.count == 1)
        let firstID = try #require(ids.first)
        let document = try #require(await store.load(firstID))
        #expect(document.turns.map(\.question) == ["What did I decide?"])
        #expect(document.turns.first?.answerText == "A hash map [N1].")
        #expect(document.turns.first?.status == .complete)
        #expect(document.turns.first?.citations.map(\.alias) == ["N1"])
        #expect(document.aliases.alias(for: uuid(1)) == "N1")
        let bytes = String(decoding: try Data(contentsOf: store.fileURL(for: document.id)), as: UTF8.self)
        #expect(!bytes.contains("sk-test-synthetic"))
        #expect(!bytes.contains("SENTINEL"))
        #expect(!bytes.contains("https://"))
    }

    @Test func aFailedTurnIsStoredWithItsPartialAnswer() async throws {
        let (store, directory) = try temporaryConversations()
        defer { try? FileManager.default.removeItem(at: directory) }
        let harness = Harness(
            notes: [webNote(1, "Two-sum")],
            scripts: [[.send(messageStart() + textStart(0) + textDelta(0, "Partial")), .fail(.network)]],
            store: store
        )

        await harness.ask("What did I decide?")
        await harness.controller.waitForStorage()

        let storedIDs = try await store.conversationIDs()
        let id = try #require(storedIDs.first)
        let turn = try #require(await store.load(id)?.turns.first)
        #expect(turn.answerText == "Partial")
        guard case .failed(let reason) = turn.status else {
            Issue.record("Expected a failed stored turn")
            return
        }
        #expect(reason.contains("connection"))
    }

    @Test func purgedNotesBecomeNoteDeletedInThePanelAndOnDisk() async throws {
        let (store, directory) = try temporaryConversations()
        defer { try? FileManager.default.removeItem(at: directory) }
        let purged = webNote(1, "Two-sum: hash map")
        let harness = Harness(notes: [purged, webNote(2, "Other")], scripts: [answer("A hash map [N1].")], store: store)
        await harness.ask("What did I decide?")
        await harness.controller.waitForStorage()

        harness.notes.mutate { $0.removeAll { $0.id == purged.id } }
        harness.controller.notesPurged([purged.id])
        await harness.controller.waitForStorage()

        let turn = try #require(harness.controller.turns.first)
        #expect(turn.manifest.entries.first { $0.noteID == purged.id }?.summary == "note deleted")
        #expect(harness.controller.chips(for: turn).first?.snippet == "note deleted")
        #expect(harness.controller.chips(for: turn).first?.mark == .noteDeleted)

        let storedIDs = try await store.conversationIDs()
        let id = try #require(storedIDs.first)
        let document = try #require(await store.load(id))
        #expect(document.redactedNoteIDs?.contains(purged.id) == true)
        #expect(document.turns.first?.citations.first?.status == .deleted)
        #expect(document.turns.first?.citations.first?.snippet == "note deleted")
        let bytes = String(decoding: try Data(contentsOf: store.fileURL(for: id)), as: UTF8.self)
        #expect(!bytes.contains("Two-sum: hash map"))
    }

    @Test func emptyTrashFindsAndCanDeleteTheConversationsThatUsedANote() async throws {
        let (store, directory) = try temporaryConversations()
        defer { try? FileManager.default.removeItem(at: directory) }
        let used = webNote(1, "Two-sum")
        let unused = webNote(9, "Elsewhere", host: "example.com", path: "/")
        let harness = Harness(notes: [used, unused], scripts: [answer("Hash map [N1].")], store: store)
        await harness.ask("What did I decide about two-sum?")

        #expect(await harness.controller.conversations(referencing: [unused.id]).isEmpty)
        let affected = await harness.controller.conversations(referencing: [used.id])
        #expect(affected.map(\.title) == ["What did I decide about two-sum?"])

        harness.controller.deleteConversations(affected.map(\.id))
        await harness.controller.waitForStorage()

        #expect(harness.controller.turns.isEmpty)
        #expect(try await store.conversationIDs().isEmpty)
    }

    @Test func conversationsPastTheRetentionWindowArePurged() async throws {
        let clock = TestClock(fixedNow)
        let (store, directory) = try temporaryConversations(clock: clock)
        defer { try? FileManager.default.removeItem(at: directory) }
        let harness = Harness(notes: [webNote(1, "Two-sum")], scripts: [answer("Hash map [N1].")], store: store)
        await harness.ask("What did I decide?")
        await harness.controller.waitForStorage()

        harness.controller.purgeExpiredConversations(retentionDays: 30)
        await harness.controller.waitForStorage()
        #expect(try await store.conversationIDs().count == 1)

        clock.now = fixedNow.addingTimeInterval(31 * 86_400)
        harness.controller.purgeExpiredConversations(retentionDays: 30)
        await harness.controller.waitForStorage()
        #expect(try await store.conversationIDs().isEmpty)
    }

    @Test func notesControllerReportsNotesItPurgesFromTrash() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WebbyAgentPurge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NoteStore(fileURL: directory.appendingPathComponent("notes.json"))
        let trashed = Note(text: "old", frame: NoteFrame(), placement: .screen, trashedAt: fixedNow, createdAt: fixedNow)
        let kept = Note(text: "kept", frame: NoteFrame(), placement: .screen, trashedAt: fixedNow, createdAt: fixedNow)
        #expect(store.add(trashed))
        #expect(store.add(kept))
        let permission = AccessibilityPermission()
        let controller = NotesController(
            store: store,
            monitor: ContextMonitor(permission: permission),
            permission: permission,
            themes: .fallback,
            now: { fixedNow }
        )
        var reported: [[UUID]] = []
        controller.onNotesPurged = { reported.append($0) }

        #expect(controller.emptyTrash(ids: [trashed.id]) == 1)
        #expect(reported == [[trashed.id]])
        #expect(controller.emptyTrash(ids: [trashed.id]) == 0)
        #expect(reported.count == 1)
    }
}

@MainActor
@Suite struct EmptyTrashConversationTests {
    private func makeModel() throws -> (LibraryModel, NoteStore, Note, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WebbyEmptyTrash-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = NoteStore(fileURL: directory.appendingPathComponent("notes.json"))
        let trashed = Note(text: "used by the agent", frame: NoteFrame(), placement: .screen, trashedAt: fixedNow, createdAt: fixedNow)
        _ = store.add(trashed)
        let permission = AccessibilityPermission()
        let controller = NotesController(
            store: store, monitor: ContextMonitor(permission: permission),
            permission: permission, themes: .fallback, now: { fixedNow }
        )
        return (LibraryModel(controller: controller, clock: { fixedNow }), store, trashed, directory)
    }

    @Test func theDialogListsAffectedConversationsAndKeepsThemByDefault() async throws {
        let (model, store, trashed, directory) = try makeModel()
        defer { try? FileManager.default.removeItem(at: directory) }
        let summary = AgentConversationSummary(id: uuid(42), title: "What did I decide?", updatedAt: "2027-01-15T08:00:00Z")
        var asked: [Set<UUID>] = []
        var deleted: [[UUID]] = []
        model.conversationImpact = { ids in
            asked.append(ids)
            return [summary]
        }
        model.deleteConversations = { deleted.append($0) }

        model.requestEmptyTrash()
        await model.waitForConversationImpact()
        #expect(asked == [[trashed.id]])
        #expect(model.emptyTrashConversations == [summary])
        #expect(model.alsoDeleteConversations == false)

        model.confirmEmptyTrash()
        #expect(store.note(id: trashed.id) == nil)
        #expect(deleted.isEmpty)
        #expect(model.emptyTrashConversations.isEmpty)
    }

    @Test func turningOnAlsoDeleteRemovesThoseConversations() async throws {
        let (model, _, _, directory) = try makeModel()
        defer { try? FileManager.default.removeItem(at: directory) }
        let summary = AgentConversationSummary(id: uuid(7), title: "Q", updatedAt: "2027-01-15T08:00:00Z")
        var deleted: [[UUID]] = []
        model.conversationImpact = { _ in [summary] }
        model.deleteConversations = { deleted.append($0) }

        model.requestEmptyTrash()
        await model.waitForConversationImpact()
        model.alsoDeleteConversations = true
        model.cancelEmptyTrash()
        #expect(model.alsoDeleteConversations == false)

        model.requestEmptyTrash()
        await model.waitForConversationImpact()
        #expect(model.alsoDeleteConversations == false)
        model.alsoDeleteConversations = true
        model.confirmEmptyTrash()
        #expect(deleted == [[summary.id]])
    }
}
