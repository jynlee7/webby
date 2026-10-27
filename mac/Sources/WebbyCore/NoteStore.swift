import Foundation

public final class NoteStore {
    public static let currentVersion = 1

    public enum Mode: Equatable {
        case writable
        case readOnly(newerVersion: Int)
    }

    public enum StoreError: Error, LocalizedError, Equatable {
        case readOnly(newerVersion: Int)

        public var errorDescription: String? {
            switch self {
            case .readOnly(let newerVersion):
                return "This notes file was created by a newer version of Webby (format \(newerVersion)). Saving is disabled; update Webby to edit notes."
            }
        }
    }

    public let fileURL: URL
    public private(set) var notes: [Note]
    public private(set) var mode: Mode

    public static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("Webby", isDirectory: true)
            .appendingPathComponent("notes.json")
    }

    private struct VersionProbe: Decodable {
        let version: Int
    }

    private struct Envelope: Codable {
        let version: Int
        let notes: [Note]
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    public init(fileURL: URL = NoteStore.defaultFileURL, now: Date = Date()) throws {
        self.fileURL = fileURL
        self.notes = []
        self.mode = .writable

        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }

        // Read the bytes once so the version probe and full decode see the same file.
        let data = try Data(contentsOf: fileURL)

        let probe: VersionProbe
        do {
            probe = try Self.decoder.decode(VersionProbe.self, from: data)
        } catch {
            try moveAsideCorruptFile(now: now)
            return
        }

        if probe.version > Self.currentVersion {
            mode = .readOnly(newerVersion: probe.version)
            return
        }

        guard probe.version == Self.currentVersion else {
            try moveAsideCorruptFile(now: now)
            return
        }

        do {
            let envelope = try Self.decoder.decode(Envelope.self, from: data)
            notes = envelope.notes
        } catch {
            try moveAsideCorruptFile(now: now)
        }
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
        if case .readOnly(let newerVersion) = mode {
            throw StoreError.readOnly(newerVersion: newerVersion)
        }

        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try Self.encoder.encode(Envelope(version: Self.currentVersion, notes: notes))
        try data.write(to: fileURL, options: .atomic)
    }

    // Only a successful move leaves an empty writable store; a failed move propagates.
    private func moveAsideCorruptFile(now: Date) throws {
        let timestamp = Int(now.timeIntervalSince1970)
        let destination = fileURL
            .deletingLastPathComponent()
            .appendingPathComponent("notes.corrupt-\(timestamp).json")
        try FileManager.default.moveItem(at: fileURL, to: destination)
        notes = []
        mode = .writable
    }
}
