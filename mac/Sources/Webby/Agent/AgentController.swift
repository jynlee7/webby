import Foundation
import Observation
import OSLog
import WebbyAgent
import WebbyCore

/// What the agent reads from and writes to the notes. `NotesController` conforms.
@MainActor
protocol AgentNotesSource: AnyObject {
    var agentNotes: [Note] { get }
    var agentWorkspaces: [WorkspaceRecord] { get }
    @discardableResult func addLibraryObserver(_ observer: @escaping @MainActor () -> Void) -> UUID
    func createAgentNote(text: String, destination: LibraryDestination) -> UUID?
}

extension NotesController: AgentNotesSource {
    var agentNotes: [Note] { libraryNotes }
    var agentWorkspaces: [WorkspaceRecord] { libraryWorkspaces }

    func createAgentNote(text: String, destination: LibraryDestination) -> UUID? {
        guard let id = createLibraryNote(destination: destination) else { return nil }
        updateLibraryText(id: id, text: text)
        return id
    }
}

/// One question and its answer as the panel shows it.
struct AgentTurnView: Identifiable, Equatable {
    enum Status: Equatable {
        case streaming
        case complete
        case truncated
        case refused
        case failed(String)
    }

    let id: UUID
    let question: String
    let askedAt: String
    var answer: String
    var manifest: ContextManifest
    var citations: [CitationValidator.Citation]
    var usage: ClaudeUsage
    var status: Status
    var savedNoteID: UUID?

    var isRetryable: Bool {
        switch status {
        case .failed, .refused, .truncated: return true
        case .streaming, .complete: return false
        }
    }
}

/// A stored conversation, as the Empty Trash sheet lists it.
struct AgentConversationSummary: Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let updatedAt: String
}

struct AgentCitationChip: Identifiable, Equatable {
    var id: String { alias }
    let alias: String
    let noteID: UUID
    let snippet: String
    let mark: AgentCitationMark
    var canOpen: Bool { mark != .noteDeleted }
}

/// The agent panel's view model (plan §4d, §4e, Step 12b).
///
/// It assembles each turn with #24's `ContextAssembler`, runs it through
/// `ClaudeConversationRunner`, and streams text into the latest turn. A failure keeps
/// the question and the partial answer, and Retry asks again with fresh notes.
@MainActor @Observable
final class AgentController {
    struct Dependencies {
        var credentials: any CredentialProvider
        var makeTransport: @Sendable (String) -> any ClaudeTransport = { key in
            KeyedClaudeTransport(base: URLSessionClaudeTransport(), apiKey: key)
        }
        var currentContext: @MainActor () -> Context?
        var model: @MainActor () -> String = { AgentModelSetting.pinnedDefault }
        var queryRules: @MainActor () -> [QueryRule] = { QueryRules.builtIns }
        var now: @MainActor () -> Date = { Date() }
        var scopeTitle: @MainActor (Context) -> String = { AgentContextLabel.scopeLabel(for: $0) }
        /// Where conversations are stored (`conversations/<uuid>.json`), or nil to keep
        /// them in memory only.
        var conversations: ConversationStore?
        var debugLog: @MainActor (String) -> Void = { line in
            Logger(subsystem: Webby.bundleID, category: "agent").debug("\(line, privacy: .public)")
        }
    }

    /// Shown when the frontmost page is in another workspace than the conversation.
    struct ScopePrompt: Equatable {
        let question: String
        let conversationTitle: String
        let currentTitle: String
    }

    enum ScopeChoice {
        case newConversation
        case keepConversation
        case cancel
    }

    var draft = ""
    var scope: AgentScope = .workspace
    private(set) var turns: [AgentTurnView] = []
    private(set) var isRunning = false
    private(set) var activity: String?
    private(set) var needsKey = false
    private(set) var scopePrompt: ScopePrompt?
    private(set) var notesVersion = 0
    /// Set when a conversation couldn't be written. Answers still show.
    private(set) var storageProblem: String?

    @ObservationIgnored var openNote: @MainActor (UUID) -> Void = { _ in }
    @ObservationIgnored var openSettings: @MainActor () -> Void = {}

    @ObservationIgnored private let notes: AgentNotesSource
    @ObservationIgnored private let dependencies: Dependencies
    @ObservationIgnored private var conversation: AgentConversationState?
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var activeFingerprint: String?
    @ObservationIgnored private var invalidated = false
    @ObservationIgnored private var committedText = ""
    @ObservationIgnored private var roundText = ""
    /// Usage of finished requests in this turn, and of the request in flight.
    @ObservationIgnored private var completedUsage = ClaudeUsage.zero
    @ObservationIgnored private var roundUsage = ClaudeUsage.zero
    /// Replays the runner's `read_note` bookkeeping, so a failed turn keeps citations
    /// to notes the model read successfully.
    @ObservationIgnored private var readSession: AgentReadSession?
    @ObservationIgnored private var readAliases: Set<String> = []
    @ObservationIgnored private var document: ConversationDocument?
    @ObservationIgnored private var redactedNoteIDs: Set<UUID> = []
    @ObservationIgnored private var storageChain: Task<Void, Never>?
    @ObservationIgnored private var persistPending = false

    init(notes: AgentNotesSource, dependencies: Dependencies) {
        self.notes = notes
        self.dependencies = dependencies
        notes.addLibraryObserver { [weak self] in self?.notesChanged() }
    }

    // MARK: Header

    /// The conversation's fixed scope, or what a new question would use.
    var scopeTitle: String {
        if scope == .allNotes { return "All notes" }
        guard let context = conversation?.startContext ?? dependencies.currentContext() else {
            return "No app or page"
        }
        return dependencies.scopeTitle(context)
    }

    var hasConversation: Bool { !turns.isEmpty }

    /// Choosing another scope starts a new conversation, because scope is fixed per
    /// conversation (decision 6).
    func setScope(_ newScope: AgentScope) {
        guard newScope != scope, !isRunning else { return }
        scope = newScope
        resetConversation()
    }

    func newConversation() {
        guard !isRunning else { return }
        resetConversation()
    }

    private func resetConversation() {
        conversation = nil
        document = nil
        redactedNoteIDs = []
        turns = []
        scopePrompt = nil
    }

    // MARK: Asking

    func ask() {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isRunning else { return }
        guard let context = dependencies.currentContext() else {
            activity = "Switch to an app or page, then ask."
            return
        }
        if let conversation, conversation.scope != .allNotes, !turns.isEmpty {
            let snapshot = makeSnapshot()
            if snapshot.workspaceDestination(for: context)
                != snapshot.workspaceDestination(for: conversation.startContext) {
                scopePrompt = ScopePrompt(
                    question: question,
                    conversationTitle: dependencies.scopeTitle(conversation.startContext),
                    currentTitle: dependencies.scopeTitle(context)
                )
                return
            }
        }
        draft = ""
        start(question: question, context: context)
    }

    func resolveScopePrompt(_ choice: ScopeChoice) {
        guard let prompt = scopePrompt else { return }
        scopePrompt = nil
        guard let context = dependencies.currentContext() else { return }
        switch choice {
        case .cancel:
            return
        case .newConversation:
            resetConversation()
        case .keepConversation:
            break
        }
        draft = ""
        start(question: prompt.question, context: context)
    }

    /// Asks the latest failed, refused or truncated question again. The failed turn
    /// stays, with its partial answer, above the new one.
    func retry() {
        guard !isRunning, let last = turns.last, last.isRetryable else { return }
        let context = dependencies.currentContext() ?? conversation?.startContext
        guard let context else { return }
        start(question: last.question, context: context)
    }

    func cancel() {
        runTask?.cancel()
    }

    private func start(question: String, context: Context) {
        isRunning = true
        needsKey = false
        activity = "Thinking…"
        runTask = Task { [weak self] in
            await self?.run(question: question, context: context)
        }
    }

    private func run(question: String, context: Context) async {
        defer {
            isRunning = false
            activity = nil
            activeFingerprint = nil
            runTask = nil
        }
        let credential: CredentialValue?
        do {
            credential = try await dependencies.credentials.credential(for: .anthropicAPIKey)
        } catch {
            needsKey = true
            draft = question
            return
        }
        guard let credential, !credential.secret.isEmpty else {
            needsKey = true
            draft = question
            return
        }

        if conversation == nil {
            let configuration = AgentModelSetting.configuration(model: dependencies.model(), context: context)
            conversation = AgentConversationState(scope: scope, startContext: context, configuration: configuration)
            document = ConversationDocument(
                scope: scope,
                context: context,
                configuration: configuration,
                workspaces: notes.agentWorkspaces,
                createdAt: dependencies.now()
            )
        }
        guard let state = conversation else { return }
        let snapshot = makeSnapshot()
        let askedAt = dependencies.now()
        let assembled = ContextAssembler.assemble(
            snapshot: snapshot,
            context: context,
            conversation: state,
            now: askedAt,
            question: question
        )
        // Aliases sent to the provider stay bound to their notes for the conversation.
        conversation = assembled.conversation
        let userMessage = assembled.request.messages.last
        let turnID = UUID()
        turns.append(AgentTurnView(
            id: turnID,
            question: question,
            askedAt: AgentTimestamp.rfc3339(askedAt),
            answer: "",
            manifest: assembled.manifest,
            citations: [],
            usage: .zero,
            status: .streaming
        ))
        committedText = ""
        roundText = ""
        completedUsage = .zero
        roundUsage = .zero
        readSession = AgentReadSession(snapshot: assembled.turnSnapshot)
        readAliases = []
        invalidated = false
        activeFingerprint = assembled.turnSnapshot.authorizationFingerprint
        // The turn is on disk before anything is sent, so a crash still records it.
        persist()

        let prepared = PreparedTurn(assembled: assembled) { [weak self] fingerprint in
            await self?.authorizationIsCurrent(fingerprint) ?? false
        }
        let runner = ClaudeConversationRunner(transport: dependencies.makeTransport(credential.secret))
        do {
            let result = try await runner.run(prepared) { [weak self] event in
                await self?.receive(event, turnID: turnID)
            }
            finish(result, turnID: turnID, userMessage: userMessage)
        } catch {
            let message = invalidated ? AgentErrorMessage.notesChanged : AgentErrorMessage.text(for: error)
            fail(turnID: turnID, message: message, snapshot: assembled.turnSnapshot)
        }
    }

    private func receive(_ event: AgentEvent, turnID: UUID) {
        switch event {
        case .contentBlockStart(_, .toolUse):
            activity = "Reading a note…"
        case .contentBlockDelta(_, .text(let text)):
            activity = nil
            roundText += text
            updateAnswer(turnID: turnID)
            persistSoon()
        case .usage(let usage):
            roundUsage = usage
        case .completed(let completion):
            completedUsage = Self.adding(completedUsage, completion.usage)
            roundUsage = .zero
            // Text from a tool round is not the answer; a paused turn keeps its text.
            if completion.stopReason == .toolUse {
                recordReads(completion)
                roundText = ""
            } else if completion.stopReason == .pauseTurn {
                committedText = Self.joined(committedText, roundText)
                roundText = ""
            }
            updateAnswer(turnID: turnID)
        default:
            break
        }
    }

    private func updateAnswer(turnID: UUID) {
        guard let index = turns.firstIndex(where: { $0.id == turnID }) else { return }
        turns[index].answer = Self.joined(committedText, roundText)
    }

    private func finish(_ result: ClaudeTurnResult, turnID: UUID, userMessage: ClaudeRequest.Message?) {
        guard let index = turns.firstIndex(where: { $0.id == turnID }) else { return }
        turns[index].answer = result.answerText
        turns[index].citations = result.citations
        turns[index].usage = result.usage
        switch result.termination {
        case .completed: turns[index].status = .complete
        case .truncated: turns[index].status = .truncated
        case .refused: turns[index].status = .refused
        case .invalidated: turns[index].status = .failed(AgentErrorMessage.notesChanged)
        }
        if let userMessage, result.termination == .completed || result.termination == .truncated {
            conversation?.appendCompletedTurn(userMessage: userMessage, assistantText: result.answerText)
        }
        dependencies.debugLog(Self.usageLogLine(turns[index].usage))
        persist()
    }

    private func fail(turnID: UUID, message: String, snapshot: AgentTurnSnapshot) {
        guard let index = turns.firstIndex(where: { $0.id == turnID }) else { return }
        // The partial answer stays, with citations checked as the runner checks a
        // finished answer: against the aliases sent and the notes read successfully.
        let validation = CitationValidator.validate(
            answerText: turns[index].answer,
            snapshot: snapshot,
            sentAliases: Self.sentAliases(snapshot: snapshot, manifest: turns[index].manifest),
            readAliases: readAliases
        )
        turns[index].answer = validation.answerText
        turns[index].citations = validation.citations
        turns[index].usage = Self.adding(completedUsage, roundUsage)
        turns[index].status = .failed(message)
        dependencies.debugLog(Self.usageLogLine(turns[index].usage))
        persist()
    }

    /// Mirrors `ClaudeConversationRunner`: an alias counts as read when its
    /// `read_note` call returned the note rather than an error.
    private func recordReads(_ completion: ClaudeCompletion) {
        for block in completion.blocks {
            guard case let .toolUse(_, name, inputJSON) = block, name == "read_note",
                  case let .object(fields)? = try? ClaudeJSON.parse(inputJSON),
                  case let .string(alias)? = fields["alias"],
                  let result = readSession?.readNote(alias: alias),
                  !result.isError
            else { continue }
            readAliases.insert(alias)
        }
    }

    /// The aliases the request carried: packed notes plus omitted-manifest lines.
    private static func sentAliases(snapshot: AgentTurnSnapshot, manifest: ContextManifest) -> Set<String> {
        var sent = Set(snapshot.notesByAlias.compactMap { alias, note in
            note.status == .omitted ? nil : alias
        })
        for line in manifest.omittedLines {
            if let alias = line.split(separator: " ").first.map(String.init),
               snapshot.notesByAlias[alias] != nil {
                sent.insert(alias)
            }
        }
        return sent
    }

    private static func adding(_ lhs: ClaudeUsage, _ rhs: ClaudeUsage) -> ClaudeUsage {
        ClaudeUsage(
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            cacheCreationInputTokens: lhs.cacheCreationInputTokens + rhs.cacheCreationInputTokens,
            cacheReadInputTokens: lhs.cacheReadInputTokens + rhs.cacheReadInputTokens
        )
    }

    /// The debug line for a finished turn, from the usage the turn stores.
    static func usageLogLine(_ usage: ClaudeUsage) -> String {
        "agent turn usage: input_tokens=\(usage.inputTokens) output_tokens=\(usage.outputTokens) "
            + "cache_creation_input_tokens=\(usage.cacheCreationInputTokens) "
            + "cache_read_input_tokens=\(usage.cacheReadInputTokens)"
    }

    // MARK: Storage

    /// The stored form of the conversation: fixed configuration, aliases, and each
    /// turn's question, manifest, answer text, citations, usage and status. Never a
    /// key, a thinking block or a raw URL (#24's `ConversationDocument`).
    private func makeDocument() -> ConversationDocument? {
        guard var document, let conversation else { return nil }
        document.aliases = conversation.ledger
        document.turns = turns.map { turn in
            ConversationTurn(
                question: turn.question,
                askedAt: turn.askedAt,
                manifest: turn.manifest,
                answerText: turn.answer,
                citations: turn.citations,
                usage: turn.usage,
                status: Self.storedStatus(turn.status)
            )
        }
        if !redactedNoteIDs.isEmpty {
            document.redactedNoteIDs = (document.redactedNoteIDs ?? []).union(redactedNoteIDs)
        }
        return document
    }

    private static func storedStatus(_ status: AgentTurnView.Status) -> ConversationTurnStatus {
        switch status {
        case .streaming: return .failed(reason: "The answer had not finished.")
        case .complete: return .complete
        case .truncated: return .truncated
        case .refused: return .refused
        case .failed(let message): return .failed(reason: message)
        }
    }

    /// Runs storage work in order on one chain, so a later save never lands first.
    private func enqueue(_ work: @escaping @Sendable (ConversationStore) async throws -> Void) {
        guard let store = dependencies.conversations else { return }
        let previous = storageChain
        storageChain = Task { [weak self] in
            await previous?.value
            do {
                try await work(store)
            } catch {
                self?.storageProblem = "This conversation couldn't be saved: \(error.localizedDescription)"
            }
        }
    }

    private func persist() {
        guard let document = makeDocument() else { return }
        enqueue { try await $0.save(document) }
    }

    /// Streaming text is saved as it arrives, with at most one save waiting.
    private func persistSoon() {
        guard !persistPending, dependencies.conversations != nil else { return }
        persistPending = true
        enqueue { [weak self] store in
            guard let document = await self?.takePendingDocument() else { return }
            try await store.save(document)
        }
    }

    private func takePendingDocument() -> ConversationDocument? {
        persistPending = false
        return makeDocument()
    }

    /// Waits for queued storage work. Tests and quit use it.
    func waitForStorage() async {
        await storageChain?.value
    }

    /// Notes removed for good: stored conversations replace their manifest lines and
    /// citation snippets with "note deleted" (decision 7), and so does this panel.
    /// Answer text that may quote a note is not rewritten.
    func notesPurged(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        for id in ids { redactInMemory(id) }
        redactedNoteIDs.formUnion(ids)
        enqueue { store in
            for id in ids { try await store.redactNote(id) }
        }
    }

    /// The same replacement `ConversationStore.redactNote` makes on disk.
    private func redactInMemory(_ noteID: UUID) {
        var aliases = Set(conversation?.ledger.entries.filter { $0.noteID == noteID }.map(\.alias) ?? [])
        for index in turns.indices {
            var turn = turns[index]
            for entry in turn.manifest.entries where entry.noteID == noteID { aliases.insert(entry.alias) }
            let entries = turn.manifest.entries.map { entry -> ContextManifest.Entry in
                guard entry.noteID == noteID else { return entry }
                return ContextManifest.Entry(
                    alias: entry.alias, noteID: entry.noteID, status: entry.status, revision: entry.revision,
                    page: "note deleted", updated: entry.updated, summary: "note deleted", omittedCharacters: 0
                )
            }
            let omitted = turn.manifest.omittedLines.map { line in
                aliases.contains { line.hasPrefix($0 + " ") } ? "note deleted" : line
            }
            turn.manifest = ContextManifest(entries: entries, omittedLines: omitted, screen: turn.manifest.screen)
            turn.citations = turn.citations.map { citation in
                guard citation.noteID == noteID else { return citation }
                return CitationValidator.Citation(
                    alias: citation.alias, noteID: citation.noteID, revision: citation.revision,
                    status: .deleted, snippet: "note deleted"
                )
            }
            turns[index] = turn
        }
        conversation?.ledger.retire(noteID: noteID)
    }

    /// Removes conversations older than the retention window (decision 7).
    func purgeExpiredConversations(retentionDays: Int) {
        enqueue { _ = try await $0.purgeExpired(retentionDays: retentionDays) }
    }

    /// Stored conversations that sent, listed or cited any of `noteIDs`.
    func conversations(referencing noteIDs: Set<UUID>) async -> [AgentConversationSummary] {
        guard let store = dependencies.conversations, !noteIDs.isEmpty else { return [] }
        await storageChain?.value
        guard let ids = try? await store.conversationIDs() else { return [] }
        var result: [AgentConversationSummary] = []
        for id in ids {
            guard let document = await store.load(id), Self.references(document, noteIDs) else { continue }
            result.append(AgentConversationSummary(
                id: id,
                title: document.turns.first.map { Note.summaryLine(of: $0.question, limit: 60) ?? $0.question } ?? "Conversation",
                updatedAt: document.updatedAt
            ))
        }
        return result.sorted { $0.updatedAt > $1.updatedAt }
    }

    private static func references(_ document: ConversationDocument, _ noteIDs: Set<UUID>) -> Bool {
        document.aliases.entries.contains { noteIDs.contains($0.noteID) }
            || document.turns.contains { turn in
                turn.manifest.entries.contains { noteIDs.contains($0.noteID) }
                    || turn.citations.contains { noteIDs.contains($0.noteID) }
            }
    }

    /// Deletes stored conversations, for Empty Trash's "Also delete those
    /// conversations". The open conversation closes if it is one of them.
    func deleteConversations(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        if let current = document?.id, ids.contains(current) {
            runTask?.cancel()
            resetConversation()
        }
        enqueue { store in
            for id in ids { try await store.delete(id) }
        }
    }

    // MARK: Authorization

    private func makeSnapshot() -> AgentSnapshot {
        AgentSnapshot(
            notes: notes.agentNotes,
            workspaces: notes.agentWorkspaces,
            queryRules: dependencies.queryRules()
        )
    }

    private func currentFingerprint() -> String? {
        guard let conversation else { return nil }
        return makeSnapshot().authorizationFingerprint(
            scope: conversation.scope,
            context: conversation.startContext
        )
    }

    private func authorizationIsCurrent(_ fingerprint: String) -> Bool {
        !invalidated && currentFingerprint() == fingerprint
    }

    /// Trash, purge, exclusion, moves, edits and imports change the fingerprint and
    /// stop a running turn, so no stale note reaches the provider.
    private func notesChanged() {
        notesVersion += 1
        guard isRunning, let activeFingerprint, currentFingerprint() != activeFingerprint else { return }
        invalidated = true
        runTask?.cancel()
    }

    // MARK: Citations and saving

    func chips(for turn: AgentTurnView) -> [AgentCitationChip] {
        _ = notesVersion
        let live = Dictionary(uniqueKeysWithValues: notes.agentNotes.map { ($0.id, $0) })
        return turn.citations.map { citation in
            let mark = AgentCitationMark.classify(citation, live: live[citation.noteID])
            return AgentCitationChip(
                alias: citation.alias,
                noteID: citation.noteID,
                snippet: mark == .noteDeleted ? "note deleted" : (citation.snippet ?? citation.alias),
                mark: mark
            )
        }
    }

    func open(_ chip: AgentCitationChip) {
        guard chip.canOpen else { return }
        openNote(chip.noteID)
    }

    func canSave(_ turn: AgentTurnView) -> Bool {
        !isRunning && turn.savedNoteID == nil && !turn.answer.isEmpty && turn.status != .streaming
    }

    /// Creates a note with the question, the answer and its sources, in the
    /// conversation's workspace (the Inbox for All notes). Only by explicit action.
    @discardableResult
    func saveAsNote(_ turnID: UUID) -> UUID? {
        guard let index = turns.firstIndex(where: { $0.id == turnID }), canSave(turns[index]) else { return nil }
        let turn = turns[index]
        var text = "\(turn.question)\n\n\(turn.answer)"
        let sources = chips(for: turn).filter(\.canOpen)
        if !sources.isEmpty {
            text += "\n\nSources\n" + sources.map {
                "[\($0.alias)] \($0.snippet) \(NoteLink.url(for: $0.noteID))"
            }.joined(separator: "\n")
        }
        guard let id = notes.createAgentNote(text: text, destination: saveDestination()) else { return nil }
        turns[index].savedNoteID = id
        return id
    }

    private func saveDestination() -> LibraryDestination {
        guard let conversation, conversation.scope != .allNotes else { return .inbox }
        switch makeSnapshot().workspaceDestination(for: conversation.startContext) {
        case .inbox: return .inbox
        case .record(let id): return .record(id)
        case .implicit(let key): return .workspace(key)
        }
    }

    private static func joined(_ lhs: String, _ rhs: String) -> String {
        guard !lhs.isEmpty else { return rhs }
        guard !rhs.isEmpty else { return lhs }
        if lhs.last?.isWhitespace == true || rhs.first?.isWhitespace == true { return lhs + rhs }
        return lhs + " " + rhs
    }
}
