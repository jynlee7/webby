import Foundation
import Testing
@testable import WebbyCore

private let importTransactionDate = Date(timeIntervalSinceReferenceDate: 700_000_000.123)
private let importTransactionStamp = BackupFileNaming.timestamp(from: importTransactionDate)

private struct InjectedImportWriteError: Error, Equatable {}

private struct GateContent: Codable, Equatable, Sendable {
    var value: String
}

private func makeTempDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("WebbyImportTransactionTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func removeTempDirectory(_ directory: URL) {
    try? FileManager.default.removeItem(at: directory)
}

private func makeNote(
    id: UUID = UUID(),
    text: String = "note",
    workspaceOverride: UUID? = nil
) -> Note {
    Note(
        id: id,
        workspaceOverride: workspaceOverride,
        text: text,
        frame: NoteFrame(x: 10, y: 20, width: 300, height: 200),
        placement: .window,
        createdAt: importTransactionDate,
        updatedAt: importTransactionDate
    )
}

private func makeWorkspace(_ keys: [WorkspaceKey], id: UUID = UUID()) -> WorkspaceRecord {
    WorkspaceRecord(id: id, keys: keys, createdAt: importTransactionDate)
}

private func fileNames(in directory: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
}

private func preImportBackups(in directory: URL) -> [String] {
    fileNames(in: directory).filter { $0.hasPrefix("notes.pre-import-") }
}

private func fileMode(_ url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
}

private func emptyDocumentData() throws -> Data {
    try NotesDocument.encode(NotesDocument(), version: NoteStore.currentVersion)
}

private final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    func set() {
        lock.lock()
        storage = true
        lock.unlock()
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class WriteObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var sawBackup = false
    private var backupBytes: Data?

    func record(_ data: Data, at destination: URL) {
        lock.lock()
        defer { lock.unlock() }
        let directory = destination.deletingLastPathComponent()
        guard let name = fileNames(in: directory).first(where: { $0.hasPrefix("notes.pre-import-") }) else {
            return
        }
        sawBackup = true
        backupBytes = try? Data(contentsOf: directory.appendingPathComponent(name))
    }

    var observation: (sawBackup: Bool, bytes: Data?) {
        lock.lock()
        defer { lock.unlock() }
        return (sawBackup, backupBytes)
    }
}

@Suite struct ImportTransactionTests {
    @Test func saveGateRejectsAStaleExpectedGenerationBeforePreparing() async throws {
        let root = try makeTempDirectory()
        defer { removeTempDirectory(root) }
        let url = root.appendingPathComponent("notes.json")
        let gate = SaveGate(
            file: VersionedJSONFile(fileURL: url, defaultContent: GateContent(value: "default")),
            committedGeneration: 7
        )
        let recorder = WriteObserver()

        let prepared = AtomicFlag()
        do {
            _ = try await gate.commitPrepared(
                .init(generation: 8, content: GateContent(value: "new")),
                expectedGeneration: 6
            ) {
                prepared.set()
                return nil
            }
            Issue.record("Expected a stale prepared commit to fail")
        } catch let error as SaveFailure {
            #expect(error == .staleGeneration(expected: 6, committed: 7))
        }

        #expect(!prepared.value)
        #expect(gate.generation == 7)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(recorder.observation.sawBackup == false)
    }

    @Test func staleCommittedGenerationThrowsAndWritesNothing() async throws {
        let root = try makeTempDirectory()
        defer { removeTempDirectory(root) }
        let url = root.appendingPathComponent("notes.json")
        let store = NoteStore(
            fileURL: url,
            backupDate: { importTransactionDate },
            backupSuffix: { _ in "stale" }
        )
        let existing = makeNote(text: "existing")
        #expect(store.add(existing))
        try store.save()

        let request = store.prepareImport(
            ImportPlan(notesToAdd: [makeNote(text: "imported")], workspacesToAdd: [], workspaceUpdates: [])
        )

        // Advance the committed generation past the one the request captured.
        #expect(store.add(makeNote(text: "competing")))
        try store.save()
        let before = try Data(contentsOf: url)

        do {
            _ = try await request.commit()
            Issue.record("Expected the stale import to fail")
        } catch let error as NoteStore.StoreError {
            #expect(error == .staleImportGeneration(
                expected: request.expectedCommittedGeneration,
                found: store.committedGeneration
            ))
        }

        #expect(try Data(contentsOf: url) == before)
        #expect(preImportBackups(in: root).isEmpty)
        #expect(store.notes.contains(where: { $0.text == "competing" }))
        #expect(!store.notes.contains(where: { $0.text == "imported" }))
    }

    @Test func aMutationAfterPrepareAbortsBeforeTheBackupOrCandidateWrite() async throws {
        let root = try makeTempDirectory()
        defer { removeTempDirectory(root) }
        let url = root.appendingPathComponent("notes.json")
        let store = NoteStore(
            fileURL: url,
            backupDate: { importTransactionDate },
            backupSuffix: { _ in "interleaved" }
        )
        let existing = makeNote(text: "existing")
        #expect(store.add(existing))
        try store.save()

        let request = store.prepareImport(
            ImportPlan(notesToAdd: [makeNote(text: "imported")], workspacesToAdd: [], workspaceUpdates: [])
        )
        let competing = makeNote(text: "competing")
        #expect(store.add(competing))
        let before = try Data(contentsOf: url)

        do {
            _ = try await request.commit()
            Issue.record("Expected an interleaved mutation to abort the import")
        } catch let error as NoteStore.StoreError {
            #expect(error == .staleImportGeneration(
                expected: request.expectedCommittedGeneration,
                found: store.mutationGeneration
            ))
        }

        #expect(try Data(contentsOf: url) == before)
        #expect(preImportBackups(in: root).isEmpty)
        #expect(store.notes.contains(where: { $0.id == competing.id }))
        #expect(!store.notes.contains(where: { $0.text == "imported" }))
    }

    @Test func backupHoldsThePreImportBytesWithOwnerOnlyPermissions() async throws {
        let root = try makeTempDirectory()
        defer { removeTempDirectory(root) }
        let url = root.appendingPathComponent("notes.json")
        let store = NoteStore(
            fileURL: url,
            backupDate: { importTransactionDate },
            backupSuffix: { _ in "owner" }
        )
        #expect(store.add(makeNote(text: "existing")))
        try store.save()
        let before = try Data(contentsOf: url)

        let request = store.prepareImport(
            ImportPlan(notesToAdd: [makeNote(text: "imported")], workspacesToAdd: [], workspaceUpdates: [])
        )
        let receipt = try await request.commit()

        let backup = try #require(receipt.backupURL)
        #expect(try Data(contentsOf: backup) == before)
        #expect(try fileMode(backup) == 0o600)
        #expect(try Data(contentsOf: url) != before)
    }

    @Test func aCollidingBackupNameUsesTheNextSuffix() async throws {
        let root = try makeTempDirectory()
        defer { removeTempDirectory(root) }
        let url = root.appendingPathComponent("notes.json")
        let collision = root.appendingPathComponent("notes.pre-import-\(importTransactionStamp)-first.json")
        let sentinel = Data("existing backup sentinel".utf8)
        try sentinel.write(to: collision)

        let store = NoteStore(
            fileURL: url,
            backupDate: { importTransactionDate },
            backupSuffix: { attempt in attempt == 0 ? "first" : "second" }
        )
        #expect(store.add(makeNote(text: "existing")))
        try store.save()

        let request = store.prepareImport(
            ImportPlan(notesToAdd: [makeNote(text: "imported")], workspacesToAdd: [], workspaceUpdates: [])
        )
        let receipt = try await request.commit()

        let backup = try #require(receipt.backupURL)
        #expect(backup.lastPathComponent == "notes.pre-import-\(importTransactionStamp)-second.json")
        #expect(try Data(contentsOf: collision) == sentinel)
        #expect(try Data(contentsOf: backup) != sentinel)
    }

    @Test func theBackupExistsBeforeTheCandidateWriteStarts() async throws {
        let root = try makeTempDirectory()
        defer { removeTempDirectory(root) }
        let url = root.appendingPathComponent("notes.json")
        let observer = WriteObserver()
        let store = NoteStore(
            fileURL: url,
            backupDate: { importTransactionDate },
            backupSuffix: { _ in "observed" },
            atomicWrite: { data, destination in
                observer.record(data, at: destination)
                try data.write(to: destination, options: .atomic)
            }
        )
        #expect(store.add(makeNote(text: "existing")))
        try store.save()
        let before = try Data(contentsOf: url)

        let request = store.prepareImport(
            ImportPlan(notesToAdd: [makeNote(text: "imported")], workspacesToAdd: [], workspaceUpdates: [])
        )
        _ = try await request.commit()

        let observation = observer.observation
        #expect(observation.sawBackup)
        #expect(observation.bytes == before)
    }

    @Test func aMissingNotesFileStillGetsAnEmptyStateBackup() async throws {
        let root = try makeTempDirectory()
        defer { removeTempDirectory(root) }
        let url = root.appendingPathComponent("notes.json")
        let store = NoteStore(
            fileURL: url,
            backupDate: { importTransactionDate },
            backupSuffix: { _ in "empty" }
        )
        #expect(!FileManager.default.fileExists(atPath: url.path))

        let request = store.prepareImport(
            ImportPlan(notesToAdd: [makeNote(text: "first")], workspacesToAdd: [], workspaceUpdates: [])
        )
        let receipt = try await request.commit()

        let backup = try #require(receipt.backupURL)
        #expect(try Data(contentsOf: backup) == emptyDocumentData())
        #expect(try fileMode(backup) == 0o600)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(NoteStore(fileURL: url).notes.map(\.text) == ["first"])
    }

    @Test func anInjectedCandidateWriteFailureKeepsFileMemoryAndBackup() async throws {
        let root = try makeTempDirectory()
        defer { removeTempDirectory(root) }
        let url = root.appendingPathComponent("notes.json")
        let store = NoteStore(
            fileURL: url,
            backupDate: { importTransactionDate },
            backupSuffix: { _ in "failed" },
            atomicWrite: { data, destination in
                let directory = destination.deletingLastPathComponent()
                if fileNames(in: directory).contains(where: { $0.hasPrefix("notes.pre-import-") }) {
                    throw InjectedImportWriteError()
                }
                try data.write(to: destination, options: .atomic)
            }
        )
        #expect(store.add(makeNote(text: "existing")))
        try store.save()
        let beforeNotes = store.notes
        let beforeMutation = store.mutationGeneration
        let beforeCommitted = store.committedGeneration
        let beforeFile = try Data(contentsOf: url)

        let request = store.prepareImport(
            ImportPlan(notesToAdd: [makeNote(text: "imported")], workspacesToAdd: [], workspaceUpdates: [])
        )
        do {
            _ = try await request.commit()
            Issue.record("Expected the injected candidate write to fail")
        } catch let error as InjectedImportWriteError {
            #expect(error == InjectedImportWriteError())
        }

        #expect(store.notes == beforeNotes)
        #expect(store.mutationGeneration == beforeMutation)
        #expect(store.committedGeneration == beforeCommitted)
        #expect(try Data(contentsOf: url) == beforeFile)
        #expect(preImportBackups(in: root).count == 1)
    }

    @Test func aReadOnlyStoreRefusesTheImportWithoutCreatingAFileOrBackup() async throws {
        let root = try makeTempDirectory()
        defer { removeTempDirectory(root) }
        let url = root.appendingPathComponent("notes.json")
        let original = Data(#"{"version":99,"future":"schema"}"#.utf8)
        try original.write(to: url)
        let store = NoteStore(
            fileURL: url,
            backupDate: { importTransactionDate },
            backupSuffix: { _ in "readonly" }
        )

        let request = store.prepareImport(
            ImportPlan(notesToAdd: [makeNote(text: "imported")], workspacesToAdd: [], workspaceUpdates: [])
        )
        do {
            _ = try await request.commit()
            Issue.record("Expected a read-only store to refuse the import")
        } catch let error as NoteStore.StoreError {
            #expect(error == .readOnly(.newerVersion(found: 99, supported: NoteStore.currentVersion)))
        }

        #expect(try Data(contentsOf: url) == original)
        #expect(fileNames(in: root) == ["notes.json"])
    }

    @Test func aSuccessfulImportMergesThePlanAndPublishesTheNewGeneration() async throws {
        let root = try makeTempDirectory()
        defer { removeTempDirectory(root) }
        let url = root.appendingPathComponent("notes.json")
        let store = NoteStore(
            fileURL: url,
            backupDate: { importTransactionDate },
            backupSuffix: { _ in "success" }
        )
        let existingWorkspace = makeWorkspace([.host(name: "existing.example")])
        try store.replaceWorkspaces([existingWorkspace])
        let existing = makeNote(text: "existing", workspaceOverride: existingWorkspace.id)
        #expect(store.add(existing))
        try store.save()

        let updatedWorkspace = makeWorkspace(
            [.host(name: "existing.example"), .host(name: "added.example")],
            id: existingWorkspace.id
        )
        let addedWorkspace = makeWorkspace([.host(name: "new.example")])
        let added = makeNote(text: "imported")
        let plan = ImportPlan(
            notesToAdd: [added],
            workspacesToAdd: [addedWorkspace],
            workspaceUpdates: [updatedWorkspace]
        )

        let request = store.prepareImport(plan)
        let receipt = try await request.commit()
        #expect(store.publishImport(receipt))

        #expect(store.notes.first == existing)
        #expect(store.notes.map(\.id) == [existing.id, added.id])
        #expect(store.workspaces == [updatedWorkspace, addedWorkspace])
        #expect(store.mutationGeneration == receipt.generation)
        #expect(store.committedGeneration == receipt.generation)
        #expect(!store.hasUnsavedChanges)

        let saveRequest = store.saveRequest()
        #expect(saveRequest.generation == receipt.generation)
        #expect(!saveRequest.isUnsaved)

        let reloaded = NoteStore(fileURL: url)
        #expect(reloaded.notes == store.notes)
        #expect(reloaded.workspaces == store.workspaces)
    }

    @Test func committingTheSameRequestTwiceNeverReportsSuccess() async throws {
        let root = try makeTempDirectory()
        defer { removeTempDirectory(root) }
        let url = root.appendingPathComponent("notes.json")
        let store = NoteStore(
            fileURL: url,
            backupDate: { importTransactionDate },
            backupSuffix: { _ in "repeat" }
        )
        #expect(store.add(makeNote(text: "existing")))
        try store.save()

        let request = store.prepareImport(
            ImportPlan(notesToAdd: [makeNote(text: "imported")], workspacesToAdd: [], workspaceUpdates: [])
        )
        _ = try await request.commit()
        let afterFirst = try Data(contentsOf: url)
        let backups = preImportBackups(in: root)

        do {
            _ = try await request.commit()
            Issue.record("Expected a repeated commit to be rejected")
        } catch let error as NoteStore.StoreError {
            #expect(error == .staleImportGeneration(
                expected: request.expectedCommittedGeneration,
                found: store.committedGeneration
            ))
        }

        #expect(try Data(contentsOf: url) == afterFirst)
        #expect(preImportBackups(in: root) == backups)
    }

    @Test func publishImportRejectsMismatchedGenerations() async throws {
        let root = try makeTempDirectory()
        defer { removeTempDirectory(root) }
        let url = root.appendingPathComponent("notes.json")
        let store = NoteStore(
            fileURL: url,
            backupDate: { importTransactionDate },
            backupSuffix: { attempt in "publish\(attempt)" }
        )
        let existing = makeNote(text: "existing")
        #expect(store.add(existing))
        try store.save()

        let first = store.prepareImport(
            ImportPlan(notesToAdd: [makeNote(text: "first")], workspacesToAdd: [], workspaceUpdates: [])
        )
        let firstReceipt = try await first.commit()

        let second = store.prepareImport(
            ImportPlan(notesToAdd: [makeNote(text: "second")], workspacesToAdd: [], workspaceUpdates: [])
        )
        let secondReceipt = try await second.commit()

        // The base mutation still matches, but the committed generation moved on.
        #expect(!store.publishImport(firstReceipt))
        #expect(store.publishImport(secondReceipt))
        #expect(store.mutationGeneration == secondReceipt.generation)

        // A later mutation makes the base generation stale even when the receipt's
        // generation matches the gate.
        let third = store.prepareImport(
            ImportPlan(notesToAdd: [makeNote(text: "third")], workspacesToAdd: [], workspaceUpdates: [])
        )
        let thirdReceipt = try await third.commit()
        let competing = makeNote(text: "competing")
        #expect(store.add(competing))
        #expect(!store.publishImport(thirdReceipt))
        #expect(store.notes.contains(where: { $0.id == competing.id }))
        #expect(!store.notes.contains(where: { $0.text == "third" }))
    }
}
