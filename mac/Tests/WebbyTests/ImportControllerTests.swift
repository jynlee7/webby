import Foundation
import Testing
@testable import Webby
import WebbyCore

private let importControllerDate = Date(timeIntervalSinceReferenceDate: 700_000_000.123)

private struct InjectedControllerWriteError: Error, LocalizedError, Equatable {
    var errorDescription: String? { "injected controller write failure" }
}

private func makeTempDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("WebbyImportControllerTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func removeTempDirectory(_ directory: URL) {
    try? FileManager.default.removeItem(at: directory)
}

private func makeNote(text: String = "note") -> Note {
    Note(
        text: text,
        frame: NoteFrame(x: 10, y: 20, width: 300, height: 200),
        placement: .window,
        createdAt: importControllerDate,
        updatedAt: importControllerDate
    )
}

private func makeWorkspace(_ keys: [WorkspaceKey]) -> WorkspaceRecord {
    WorkspaceRecord(keys: keys, createdAt: importControllerDate)
}

private func fileNames(in directory: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
}

private func preImportBackups(in directory: URL) -> [String] {
    fileNames(in: directory).filter { $0.hasPrefix("notes.pre-import-") }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class SequenceRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    func append(_ event: String) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    func reset() {
        lock.lock()
        events.removeAll()
        lock.unlock()
    }

    var snapshot: [String] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

private final class AsyncSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var signaled = false
    private var waiter: CheckedContinuation<Void, Never>?

    func signal() {
        lock.lock()
        guard !signaled else {
            lock.unlock()
            return
        }
        signaled = true
        let waiter = waiter
        self.waiter = nil
        lock.unlock()
        waiter?.resume()
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if signaled {
                lock.unlock()
                continuation.resume()
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }
}

private final class BlockingGate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)

    func wait() {
        semaphore.wait()
    }

    func signal() {
        semaphore.signal()
    }
}

@MainActor
private func makeController(_ store: NoteStore) -> NotesController {
    let permission = AccessibilityPermission()
    let monitor = ContextMonitor(permission: permission)
    return NotesController(
        store: store,
        monitor: monitor,
        permission: permission,
        themes: .fallback,
        now: { importControllerDate }
    )
}

@MainActor
@Suite struct ImportControllerTests {
    @Test func importNotesRefusesAReadOnlyStoreWithoutMutatingIt() async throws {
        let directory = try makeTempDirectory()
        defer { removeTempDirectory(directory) }
        let url = directory.appendingPathComponent("notes.json")
        let original = Data(#"{"version":99,"future":"schema"}"#.utf8)
        try original.write(to: url)
        let store = NoteStore(fileURL: url)
        let controller = makeController(store)
        let plan = ImportPlan(
            notesToAdd: [makeNote(text: "imported")],
            workspacesToAdd: [],
            workspaceUpdates: []
        )

        do {
            _ = try await controller.importNotes(plan)
            Issue.record("Expected a read-only store to refuse the import")
        } catch let error as NoteStore.StoreError {
            #expect(error == .readOnly(.newerVersion(found: 99, supported: NoteStore.currentVersion)))
        }

        let expectedMessage = NoteStore.StoreError
            .readOnly(.newerVersion(found: 99, supported: NoteStore.currentVersion))
            .localizedDescription
        #expect(controller.importState == .failed(expectedMessage))
        #expect(store.mutationGeneration == 0)
        #expect(store.notes.isEmpty)
        #expect(try Data(contentsOf: url) == original)
        #expect(fileNames(in: directory) == ["notes.json"])
    }

    @Test func importNotesCommitsTheLibraryDraftOnceBeforeTheBarrierFlush() async throws {
        let directory = try makeTempDirectory()
        defer { removeTempDirectory(directory) }
        let url = directory.appendingPathComponent("notes.json")
        let recorder = SequenceRecorder()
        let store = NoteStore(
            fileURL: url,
            backupDate: { importControllerDate },
            backupSuffix: { _ in "hook" },
            atomicWrite: { data, destination in
                recorder.append("write")
                try data.write(to: destination, options: .atomic)
            }
        )
        let existing = makeNote(text: "saved")
        #expect(store.add(existing))
        try store.save()
        recorder.reset()

        let controller = makeController(store)
        let hookCount = Counter()
        controller.commitLibraryDrafts = {
            hookCount.increment()
            recorder.append("hook")
            _ = store.updateContent(id: existing.id, change: .text("from-hook"), now: importControllerDate)
        }
        let plan = ImportPlan(
            notesToAdd: [makeNote(text: "imported")],
            workspacesToAdd: [],
            workspaceUpdates: []
        )

        _ = try await controller.importNotes(plan)

        #expect(hookCount.count == 1)
        #expect(recorder.snapshot.first == "hook")
        #expect(store.note(id: existing.id)?.text == "from-hook")
        #expect(NoteStore(fileURL: url).note(id: existing.id)?.text == "from-hook")
    }

    @Test func aSuccessfulImportPublishesStateAndRefreshesCallbacks() async throws {
        let directory = try makeTempDirectory()
        defer { removeTempDirectory(directory) }
        let url = directory.appendingPathComponent("notes.json")
        let store = NoteStore(
            fileURL: url,
            backupDate: { importControllerDate },
            backupSuffix: { _ in "success" }
        )
        let existing = makeNote(text: "existing")
        #expect(store.add(existing))
        try store.save()

        let controller = makeController(store)
        let libraryChanges = Counter()
        let statusChanges = Counter()
        controller.onLibraryChange = { libraryChanges.increment() }
        controller.onStatusChange = { statusChanges.increment() }

        let addedWorkspace = makeWorkspace([.host(name: "new.example")])
        let added = makeNote(text: "imported")
        let plan = ImportPlan(
            notesToAdd: [added],
            workspacesToAdd: [addedWorkspace],
            workspaceUpdates: []
        )

        let summary = try await controller.importNotes(plan)

        #expect(summary == plan.summary)
        #expect(store.notes.map(\.id) == [existing.id, added.id])
        #expect(store.workspaces == [addedWorkspace])
        #expect(libraryChanges.count == 1)
        #expect(statusChanges.count == 1)

        guard case let .succeeded(result) = controller.importState else {
            Issue.record("Expected a succeeded import state")
            return
        }
        #expect(result.summary == plan.summary)
        #expect(result.generation == store.committedGeneration)
        #expect(result.backupURL != nil)
        #expect(!store.hasUnsavedChanges)
        #expect(!controller.quit.hasPendingChanges)
        #expect(store.saveRequest().generation == result.generation)
        #expect(!store.saveRequest().isUnsaved)
    }

    @Test func aFailedImportReportsTheErrorAndLeavesStoreAndFileUnchanged() async throws {
        let directory = try makeTempDirectory()
        defer { removeTempDirectory(directory) }
        let url = directory.appendingPathComponent("notes.json")
        let store = NoteStore(
            fileURL: url,
            backupDate: { importControllerDate },
            backupSuffix: { _ in "failed" },
            atomicWrite: { data, destination in
                let directory = destination.deletingLastPathComponent()
                if fileNames(in: directory).contains(where: { $0.hasPrefix("notes.pre-import-") }) {
                    throw InjectedControllerWriteError()
                }
                try data.write(to: destination, options: .atomic)
            }
        )
        let existing = makeNote(text: "existing")
        #expect(store.add(existing))
        try store.save()

        let beforeNotes = store.notes
        let beforeGeneration = store.mutationGeneration
        let beforeFile = try Data(contentsOf: url)
        let controller = makeController(store)
        let libraryChanges = Counter()
        controller.onLibraryChange = { libraryChanges.increment() }

        let plan = ImportPlan(
            notesToAdd: [makeNote(text: "imported")],
            workspacesToAdd: [],
            workspaceUpdates: []
        )
        do {
            _ = try await controller.importNotes(plan)
            Issue.record("Expected the injected candidate write to fail")
        } catch let error as InjectedControllerWriteError {
            #expect(error == InjectedControllerWriteError())
        }

        #expect(controller.importState == .failed("injected controller write failure"))
        #expect(store.notes == beforeNotes)
        #expect(store.mutationGeneration == beforeGeneration)
        #expect(try Data(contentsOf: url) == beforeFile)
        #expect(preImportBackups(in: directory).count == 1)
        #expect(libraryChanges.count == 0)
    }

    @Test func competingLibraryMutationsAreRejectedWhileAnImportIsInFlight() async throws {
        let directory = try makeTempDirectory()
        defer { removeTempDirectory(directory) }
        let url = directory.appendingPathComponent("notes.json")
        let candidateStarted = AsyncSignal()
        let releaseCandidate = BlockingGate()
        let store = NoteStore(
            fileURL: url,
            backupDate: { importControllerDate },
            backupSuffix: { _ in "competing" },
            atomicWrite: { data, destination in
                let directory = destination.deletingLastPathComponent()
                if fileNames(in: directory).contains(where: { $0.hasPrefix("notes.pre-import-") }) {
                    candidateStarted.signal()
                    releaseCandidate.wait()
                }
                try data.write(to: destination, options: .atomic)
            }
        )
        let existing = makeNote(text: "existing")
        #expect(store.add(existing))
        try store.save()

        let controller = makeController(store)
        let added = makeNote(text: "imported")
        let plan = ImportPlan(notesToAdd: [added], workspacesToAdd: [], workspaceUpdates: [])
        let task = Task { try await controller.importNotes(plan) }

        await candidateStarted.wait()
        let generationBefore = store.mutationGeneration

        #expect(controller.createLibraryNote(destination: .inbox) == nil)
        controller.updateLibraryText(id: existing.id, text: "blocked")
        #expect(store.note(id: existing.id)?.text == "existing")
        #expect(store.mutationGeneration == generationBefore)

        releaseCandidate.signal()
        let summary = try await task.value

        #expect(summary == plan.summary)
        #expect(store.notes.contains(where: { $0.id == added.id }))
        #expect(store.note(id: existing.id)?.text == "existing")
    }

    @Test func overlaysAreFrozenDuringAnImportAndTheLayoutReplaysAfterIt() async throws {
        let directory = try makeTempDirectory()
        defer { removeTempDirectory(directory) }
        let url = directory.appendingPathComponent("notes.json")
        let candidateStarted = AsyncSignal()
        let releaseCandidate = BlockingGate()
        let store = NoteStore(
            fileURL: url,
            backupDate: { importControllerDate },
            backupSuffix: { _ in "freeze" },
            atomicWrite: { data, destination in
                let directory = destination.deletingLastPathComponent()
                if fileNames(in: directory).contains(where: { $0.hasPrefix("notes.pre-import-") }) {
                    candidateStarted.signal()
                    releaseCandidate.wait()
                }
                try data.write(to: destination, options: .atomic)
            }
        )
        let bundleID = "com.example.app"
        var existing = makeNote(text: "existing")
        existing.anchor = .app(bundleID: bundleID)
        #expect(store.add(existing))
        try store.save()

        let permission = AccessibilityPermission()
        let monitor = ContextMonitor(permission: permission)
        monitor.app = ContextMonitor.FrontApp(bundleID: bundleID, pid: 1, name: "Example")
        let controller = NotesController(
            store: store,
            monitor: monitor,
            permission: permission,
            themes: .fallback,
            now: { importControllerDate }
        )
        controller.layout()
        let overlay = controller.overlayController(for: existing)
        #expect(overlay.model.isEditable)

        var imported = makeNote(text: "imported")
        imported.anchor = .app(bundleID: bundleID)
        var importingAtRefresh: [Bool] = []
        controller.onLibraryChange = { importingAtRefresh.append(controller.isImporting) }
        controller.onStatusChange = { importingAtRefresh.append(controller.isImporting) }
        let plan = ImportPlan(notesToAdd: [imported], workspacesToAdd: [], workspaceUpdates: [])
        let task = Task { try await controller.importNotes(plan) }

        await candidateStarted.wait()
        #expect(controller.isImporting)
        #expect(!overlay.model.isEditable)

        releaseCandidate.signal()
        _ = try await task.value

        #expect(importingAtRefresh == [false, false])
        #expect(overlay.model.isEditable)
        #expect(controller.windows[imported.id] != nil)
        #expect(controller.windows[existing.id] != nil)
        controller.windows.values.forEach { $0.close() }
    }
}
