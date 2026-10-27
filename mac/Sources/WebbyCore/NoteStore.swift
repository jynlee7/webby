import Foundation

/// The notes file.
///
/// `NoteStore` is not `Sendable`. Create and use it from the main actor.
public final class NoteStore {
    public static let currentVersion = VersionedJSONFile<[Note]>.currentVersion

    public enum Mode: Equatable {
        case writable
        case readOnly(FileLoadProblem)
    }

    public enum StoreError: Error, LocalizedError, Equatable {
        case readOnly(FileLoadProblem)

        public var errorDescription: String? {
            switch self {
            case .readOnly(.newerVersion(let found, let supported)):
                return "This notes file was created by a newer version of Webby (format \(found), supported \(supported)). Saving is disabled; update Webby to edit notes."
            case .readOnly(.unreadable(let reason)):
                return "This notes file could not be read, so saving is disabled: \(reason)"
            }
        }
    }

    public let fileURL: URL
    public private(set) var notes: [Note]

    public var mode: Mode {
        switch file.mode {
        case .writable:
            return .writable
        case .readOnly(let problem):
            return .readOnly(problem)
        }
    }

    public var outcome: FileLoadOutcome {
        file.outcome
    }

    public static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("Webby", isDirectory: true)
            .appendingPathComponent("notes.json")
    }

    private var file: VersionedJSONFile<[Note]>

    public init(fileURL: URL = NoteStore.defaultFileURL, now: Date = Date()) {
        let file = VersionedJSONFile<[Note]>(
            fileURL: fileURL,
            defaultContent: [],
            contentKey: "notes",
            now: { now }
        )
        self.fileURL = fileURL
        self.notes = file.content
        self.file = file
    }

    public func note(id: UUID) -> Note? {
        notes.first { $0.id == id }
    }

    public func notes(matching context: Context) -> [Note] {
        notes.filter { $0.anchor.matches(context) }
    }

    public func add(_ note: Note) {
        notes.append(note)
    }

    @discardableResult
    public func update(id: UUID, now: Date = Date(), _ change: (inout Note) -> Void) -> Bool {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return false }
        change(&notes[index])
        notes[index].updatedAt = now
        return true
    }

    @discardableResult
    public func remove(id: UUID) -> Bool {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return false }
        notes.remove(at: index)
        return true
    }

    public func save() throws {
        file.updateContent(notes)
        do {
            try file.save()
        } catch let error as VersionedJSONFile<[Note]>.SaveError {
            switch error {
            case .readOnly(let problem):
                throw StoreError.readOnly(problem)
            }
        }
    }
}
