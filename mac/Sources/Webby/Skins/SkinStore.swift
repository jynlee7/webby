import AppKit
import Foundation
import OSLog
import WebbyCore
import WebbySkinArchive

/// One row for the skin list in Settings.
struct SkinRow: Identifiable, Equatable {
    let id: String
    let name: String
    let author: String
    let origin: SkinOrigin
    let folder: URL
    /// Whether the folder on disk loads cleanly. A rejected skin that is still in use
    /// shows `usingLastGood`.
    let isAccepted: Bool
    /// The previous good load is in use because the folder now fails validation.
    let usingLastGood: Bool
    let diagnostics: [SkinDiagnostic]

    var isUserSkin: Bool { origin == .installed }
}

enum SkinStoreError: Error, LocalizedError, Equatable {
    case notAccepted
    case unknownSkin(String)
    case builtIn(String)

    var errorDescription: String? {
        switch self {
        case .notAccepted: "This skin has problems and can't be installed."
        case .unknownSkin(let id): "There is no skin named \(id)."
        case .builtIn(let id): "\(id) is built in and can't be changed."
        }
    }
}

/// The skins Webby can show: built-ins plus the folders in Application Support, and the
/// choice of which one each note uses (workspace, then global, then `webby.clear`).
///
/// Loads and edits flow one way: a change to the library, the global skin, a workspace,
/// a note's appearance or the system accessibility settings clears the resolved themes
/// and calls `onThemesChanged`, and the notes controller re-reads each open note.
@MainActor
@Observable
final class SkinStore {
    private struct Held {
        var skin: InstalledSkin?
        var name: String
        var author: String
        var folder: URL
        var origin: SkinOrigin
        var isAccepted: Bool
        var usingLastGood: Bool
        var diagnostics: [SkinDiagnostic]
    }

    private struct ThemeKey: Hashable {
        let workspaceSkinID: String?
        let paletteIndex: Int?
        let hideDecoration: Bool
    }

    /// The skins in the list, built-ins first.
    private(set) var rows: [SkinRow] = []
    private(set) var globalSkinID: String?
    /// A quiet explanation for the UI when the chosen skin can't be used, else nil.
    private(set) var notice: String?
    /// Bumped by each applied reload.
    private(set) var revision = 0

    @ObservationIgnored var onThemesChanged: (@MainActor () -> Void)?
    /// Called after a workspace record changed, so the owner can save notes.
    @ObservationIgnored var onNotesMutated: (@MainActor () -> Void)?
    @ObservationIgnored var assetCache: SkinAssetCache?

    @ObservationIgnored private let library: SkinLibraryFolder
    @ObservationIgnored private let builtInDirectory: URL?
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let noteStore: NoteStore
    @ObservationIgnored private let logger = Logger(subsystem: Webby.bundleID, category: "skins")
    @ObservationIgnored private var held: [String: Held] = [:]
    @ObservationIgnored private var order: [String] = []
    @ObservationIgnored private var baseIDs: Set<String> = []
    @ObservationIgnored private var selection = SkinSelection(skins: [], availableBaseIDs: [])
    @ObservationIgnored private var accessibility = NoteThemes.systemAccessibility
    @ObservationIgnored private var cache: [ThemeKey: NoteThemes] = [:]
    @ObservationIgnored private var reloadGeneration = 0
    @ObservationIgnored private var debouncer: AutosaveDebouncer!
    @ObservationIgnored private var watcher: SkinWatcher!

    /// Loads the catalog synchronously so the first layout already has its skins.
    init(userRoot: URL, builtInDirectory: URL?, settings: SettingsStore, noteStore: NoteStore) {
        library = SkinLibraryFolder(root: userRoot)
        self.builtInDirectory = builtInDirectory
        self.settings = settings
        self.noteStore = noteStore
        globalSkinID = settings.settings.globalSkinID
        apply(SkinCatalogLoader.load(builtInDirectory: builtInDirectory, library: library), notify: false)
        debouncer = SkinReload.makeDebouncer { [weak self] in self?.scheduleReload() }
        watcher = SkinWatcher(root: userRoot) { [weak self] in self?.debouncer.schedule() }
        watcher.startIfPossible()
    }

    func stop() {
        debouncer.cancel()
        watcher.stop()
    }

    // MARK: Themes

    /// The look for `note`: its workspace skin, else the global skin, else `webby.clear`,
    /// with its own palette slot and decoration choice and the system accessibility
    /// settings applied.
    func themes(for note: Note) -> NoteThemes {
        let record = WorkspaceResolver.resolve(note, workspaces: noteStore.workspaces)
        var workspaceSkinID: String?
        if case .record(let id) = record {
            workspaceSkinID = noteStore.workspaces.first { $0.id == id }?.skinID
        }
        return themes(workspaceSkinID: workspaceSkinID, appearance: note.appearance)
    }

    func themes(workspaceSkinID: String? = nil, appearance: NoteAppearance? = nil) -> NoteThemes {
        let key = ThemeKey(
            workspaceSkinID: workspaceSkinID,
            paletteIndex: appearance?.paletteIndex,
            hideDecoration: appearance?.hideDecoration ?? false
        )
        if let cached = cache[key] { return cached }
        let result = selection.select(
            workspaceSkinID: workspaceSkinID,
            globalSkinID: globalSkinID,
            noteAppearance: appearance,
            accessibility: accessibility
        )
        let themes = NoteThemes(selection: result, revision: revision)
        cache[key] = themes
        return themes
    }

    /// The skin folder for an installed skin ID, for `SkinAssetCache`.
    func folder(for skinID: String) -> URL? {
        held[skinID]?.folder
    }

    var assetFolderProvider: SkinAssetCache.FolderProvider {
        { [weak self] id in
            MainActor.assumeIsolated { self?.folder(for: id) }
        }
    }

    func accessibilityChanged() {
        let current = NoteThemes.systemAccessibility
        guard current != accessibility else { return }
        accessibility = current
        themesChanged()
    }

    // MARK: Selection

    func setGlobalSkinID(_ id: String?) throws {
        guard id != globalSkinID else { return }
        var updated = settings.settings
        updated.globalSkinID = id
        try settings.replace(updated)
        globalSkinID = id
        updateNotice()
        themesChanged()
    }

    /// Sets or clears a workspace's skin. Throws when notes are read-only or the
    /// workspace doesn't exist.
    func setWorkspaceSkin(_ id: String?, workspaceID: UUID) throws {
        var records = noteStore.workspaces
        guard let index = records.firstIndex(where: { $0.id == workspaceID }) else { return }
        guard records[index].skinID != id else { return }
        records[index].skinID = id
        try noteStore.replaceWorkspaces(records)
        onNotesMutated?()
        themesChanged()
    }

    // MARK: Library operations

    /// Unpacks `url` into staging without touching the library. Runs off the main actor.
    func stageArchive(at url: URL) async throws -> StagedSkinPreview {
        let near = library.root.deletingLastPathComponent()
        let bases = baseIDs
        return try await Task.detached(priority: .userInitiated) {
            try FileManager.default.createDirectory(at: near, withIntermediateDirectories: true)
            return try SkinArchiveImporter.stage(archiveAt: url, stagingNear: near, availableBaseIDs: bases)
        }.value
    }

    /// Installs a staged skin, replacing one with the same id, and shows it live when
    /// it is the selected skin.
    func install(_ preview: StagedSkinPreview) throws {
        guard preview.isAccepted, let id = preview.manifest?.id else { throw SkinStoreError.notAccepted }
        try library.install(stagedFolder: preview.root, id: id)
        libraryChanged()
    }

    func discard(_ preview: StagedSkinPreview) {
        do {
            try preview.discard()
        } catch {
            logger.error("Could not remove staged skin: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Copies a skin into the library under a new id, returning that id.
    func duplicate(skinID: String) throws -> String {
        guard let source = held[skinID] else { throw SkinStoreError.unknownSkin(skinID) }
        let copy = try library.duplicate(folder: source.folder, avoiding: Set(held.keys))
        libraryChanged()
        return copy.id
    }

    func exportArchive(skinID: String, to destination: URL) throws {
        guard let source = held[skinID] else { throw SkinStoreError.unknownSkin(skinID) }
        try SkinArchiveExporter.export(folder: source.folder, to: destination, availableBaseIDs: baseIDs)
    }

    /// Deletes an installed skin. Notes that used it fall back to the next choice.
    func remove(skinID: String) throws {
        guard let source = held[skinID] else { throw SkinStoreError.unknownSkin(skinID) }
        guard source.origin == .installed else { throw SkinStoreError.builtIn(skinID) }
        try library.remove(id: skinID)
        libraryChanged()
    }

    /// The user skins folder, created if needed so Reveal in Finder has something to open.
    var skinsFolderURL: URL {
        get throws {
            try FileManager.default.createDirectory(at: library.root, withIntermediateDirectories: true)
            watcher.startIfPossible()
            return library.root
        }
    }

    private func libraryChanged() {
        watcher.startIfPossible()
        scheduleReload()
    }

    // MARK: Reload

    func scheduleReload() {
        Task { await reload() }
    }

    /// Loads the folders off the main actor, then swaps the result in. A newer request
    /// supersedes an older one that is still loading.
    func reload() async {
        reloadGeneration += 1
        let generation = reloadGeneration
        let builtIn = builtInDirectory
        let library = library
        let catalog = await Task.detached(priority: .userInitiated) {
            SkinCatalogLoader.load(builtInDirectory: builtIn, library: library)
        }.value
        guard generation == reloadGeneration else { return }
        apply(catalog, notify: true)
    }

    private func apply(_ catalog: SkinCatalog, notify: Bool) {
        var next: [String: Held] = [:]
        var order: [String] = []

        for entry in catalog.entries {
            let id = entry.skin.id
            var item = Held(
                skin: entry.skin,
                name: entry.skin.manifest.name,
                author: entry.skin.manifest.author,
                folder: entry.folder,
                origin: entry.origin,
                isAccepted: entry.skin.isAccepted,
                usingLastGood: false,
                diagnostics: entry.diagnostics
            )
            if entry.origin == .installed, let previous = held[id], previous.origin == .installed {
                let outcome = SkinReload.keepLastGood(previous: previous.skin, fresh: entry.skin, diagnostics: entry.diagnostics)
                item.skin = outcome.skin
                item.usingLastGood = !outcome.usedNewLoad && outcome.skin != nil
                if item.usingLastGood { item.name = previous.name; item.author = previous.author }
            }
            next[id] = item
            order.append(id)
        }

        for rejected in catalog.skipped {
            // A skipped folder is named by its id, so a previously good skin of that name
            // keeps its look while the edit is broken.
            let id = rejected.folder.lastPathComponent
            guard next[id] == nil else { continue }
            let previous = rejected.origin == .installed ? held[id] : nil
            let kept = previous.flatMap { $0.origin == .installed ? $0.skin : nil }
            let outcome = SkinReload.keepLastGood(previous: kept, fresh: nil, diagnostics: rejected.diagnostics)
            next[id] = Held(
                skin: outcome.skin,
                name: previous?.name ?? id,
                author: previous?.author ?? "",
                folder: rejected.folder,
                origin: rejected.origin,
                isAccepted: false,
                usingLastGood: outcome.skin != nil,
                diagnostics: rejected.diagnostics
            )
            order.append(id)
        }

        // Anything user-made that existed before or exists now may have new files.
        for (id, item) in held.merging(next, uniquingKeysWith: { $1 }) where item.origin == .installed {
            assetCache?.invalidate(skinID: id)
        }

        held = next
        self.order = order
        baseIDs = catalog.availableBaseIDs
        selection = SkinSelection(skins: next.values.compactMap(\.skin), availableBaseIDs: baseIDs)
        rows = order.compactMap { id in
            next[id].map {
                SkinRow(
                    id: id, name: $0.name, author: $0.author, origin: $0.origin, folder: $0.folder,
                    isAccepted: $0.isAccepted, usingLastGood: $0.usingLastGood, diagnostics: $0.diagnostics
                )
            }
        }
        revision += 1
        updateNotice()
        if notify { themesChanged() } else { cache.removeAll() }
    }

    /// Records why the chosen global skin isn't the one showing.
    private func updateNotice() {
        guard let id = globalSkinID else { notice = nil; return }
        let effective = selection.select(workspaceSkinID: nil, globalSkinID: id).effectiveSkinID
        if effective == id {
            notice = nil
        } else if held[id] == nil {
            notice = "The skin “\(id)” isn't installed, so notes use the default look."
        } else {
            notice = "The skin “\(held[id]?.name ?? id)” has problems, so notes use the default look."
        }
    }

    private func themesChanged() {
        cache.removeAll()
        onThemesChanged?()
    }
}
