import Foundation

/// Owns the in-memory list of notes and persists it to a single JSON file.
///
/// Not thread-safe: use from one actor (the app uses it on the main actor).
/// Saving is explicit; the app debounces calls to `save()` after edits.
public final class NoteStore {
    public static let currentVersion = 1

    public let fileURL: URL
    public private(set) var notes: [Note]

    /// Default location: ~/Library/Application Support/Webby/notes.json
    public static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Webby", isDirectory: true).appendingPathComponent("notes.json")
    }

    /// Loads notes from `fileURL`. A missing file means "no notes yet".
    ///
    /// A file that exists but can't be decoded is moved aside to
    /// `notes.corrupt-<timestamp>.json` instead of being overwritten by the next save,
    /// so a bug or a hand-edit never silently destroys notes.
    public init(fileURL: URL = NoteStore.defaultFileURL, now: Date = Date()) throws {
        self.fileURL = fileURL
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else {
            notes = []
            return
        }
        let data = try Data(contentsOf: fileURL)
        do {
            notes = try NoteStore.decoder.decode(StoreFile.self, from: data).notes
        } catch {
            let stamp = Int(now.timeIntervalSince1970)
            let aside = fileURL.deletingLastPathComponent().appendingPathComponent("notes.corrupt-\(stamp).json")
            try fm.moveItem(at: fileURL, to: aside)
            notes = []
        }
    }

    // MARK: Queries

    public func note(id: UUID) -> Note? {
        notes.first { $0.id == id }
    }

    public func notes(matching context: Context) -> [Note] {
        notes.filter { $0.anchor.matches(context) }
    }

    // MARK: Mutations

    public func add(_ note: Note) {
        notes.append(note)
    }

    /// Applies `change` to the note with `id` and bumps its `updatedAt`. Returns false if no such note.
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

    // MARK: Persistence

    /// Writes all notes atomically (temp file + rename), creating the directory if needed.
    public func save() throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try NoteStore.encoder.encode(StoreFile(version: NoteStore.currentVersion, notes: notes))
        try data.write(to: fileURL, options: [.atomic])
    }

    private struct StoreFile: Codable {
        var version: Int
        var notes: [Note]
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
