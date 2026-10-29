import Foundation
import WebbyCore

/// One skin folder in the catalog.
public struct SkinCatalogEntry: Sendable {
    public let skin: InstalledSkin
    public let folder: URL
    public let origin: SkinOrigin
    public let diagnostics: [SkinDiagnostic]
}

/// A folder that could not join the catalog, with the reason.
public struct SkippedSkinFolder: Error, Sendable {
    public let folder: URL
    public let origin: SkinOrigin
    public let diagnostics: [SkinDiagnostic]
}

/// Every built-in and user skin found on disk.
public struct SkinCatalog: Sendable {
    /// Built-ins first, then user skins, each group sorted by id.
    public let entries: [SkinCatalogEntry]
    public let skipped: [SkippedSkinFolder]
    /// The ids a skin may name as `base`: the built-ins.
    public let availableBaseIDs: Set<String>

    public var skins: [InstalledSkin] {
        entries.map(\.skin)
    }

    public func entry(id: String) -> SkinCatalogEntry? {
        entries.first { $0.skin.id == id }
    }

    /// Selection over this catalog, ready for the app's skin store.
    public var selection: SkinSelection {
        SkinSelection(skins: skins, availableBaseIDs: availableBaseIDs)
    }
}

/// Loads built-in and user skin folders through one loader and the real media
/// checks (plan "One loader").
public enum SkinCatalogLoader {
    /// `builtInDirectory` holds the bundled skin folders; nil outside an app bundle.
    public static func load(builtInDirectory: URL?, library: SkinLibraryFolder) -> SkinCatalog {
        var entries: [SkinCatalogEntry] = []
        var skipped: [SkippedSkinFolder] = []

        let builtInFolders = builtInDirectory.map(subfolders(of:)) ?? []
        // Built-in ids are the folder names; they are the only valid bases.
        let baseIDs = Set(builtInFolders.map(\.lastPathComponent))

        for folder in builtInFolders {
            switch loadFolder(folder, origin: .builtIn, baseIDs: baseIDs) {
            case .success(let entry): entries.append(entry)
            case .failure(let rejected): skipped.append(rejected)
            }
        }

        var seen = Set(entries.map(\.skin.id))
        for installed in library.installed() {
            switch loadFolder(installed.folder, origin: .installed, baseIDs: baseIDs) {
            case .success(let entry):
                if entry.skin.id != installed.id {
                    skipped.append(SkippedSkinFolder(
                        folder: installed.folder,
                        origin: .installed,
                        diagnostics: [fatal(
                            "id-folder-mismatch",
                            "Folder '\(installed.id)' contains skin '\(entry.skin.id)'; the folder name must match the id."
                        )]
                    ))
                } else if !seen.insert(entry.skin.id).inserted {
                    skipped.append(SkippedSkinFolder(
                        folder: installed.folder,
                        origin: .installed,
                        diagnostics: [fatal(
                            "duplicate-skin-id",
                            "Skin id '\(entry.skin.id)' is already used by another skin."
                        )]
                    ))
                } else {
                    entries.append(entry)
                }
            case .failure(let rejected):
                skipped.append(rejected)
            }
        }

        return SkinCatalog(entries: entries, skipped: skipped, availableBaseIDs: baseIDs)
    }

    /// Loads one folder. Used by the catalog and by hot reload of a single skin.
    /// A folder without a readable manifest fails; a folder with a manifest that
    /// validation rejected succeeds with `isAccepted == false`.
    public static func loadFolder(
        _ folder: URL,
        origin: SkinOrigin,
        baseIDs: Set<String>
    ) -> Result<SkinCatalogEntry, SkippedSkinFolder> {
        let loaded = SkinFolderLoader.load(folder: folder, origin: origin, availableBaseIDs: baseIDs)
        guard loaded.document != nil else {
            return .failure(SkippedSkinFolder(folder: folder, origin: origin, diagnostics: loaded.diagnostics))
        }

        let isBuiltIn = origin == .builtIn
        // Diagnostics that the folder pass found before validation (ignored files,
        // symlinks); the validator's own are regenerated against the real checker.
        let headerValidation = SkinValidator.validate(
            document: loaded.document!,
            assets: loaded.assetChecker,
            context: SkinValidationContext(isBuiltIn: isBuiltIn, availableBaseIDs: baseIDs)
        )
        let headerOnly = Set(headerValidation.diagnostics)
        let folderLevel = loaded.diagnostics.filter { !headerOnly.contains($0) }

        let validation = SkinArchiveStaging.validate(
            root: folder,
            paths: loaded.entries.map(\.path),
            warnings: folderLevel,
            availableBaseIDs: baseIDs,
            isBuiltIn: isBuiltIn
        )
        guard let manifest = validation.manifest else {
            return .failure(SkippedSkinFolder(folder: folder, origin: origin, diagnostics: validation.diagnostics))
        }
        let skin = InstalledSkin(
            id: manifest.id,
            manifest: manifest,
            groups: validation.groups,
            availableImagePaths: validation.availableImagePaths,
            isAccepted: validation.isAccepted
        )
        return .success(SkinCatalogEntry(
            skin: skin,
            folder: folder,
            origin: origin,
            diagnostics: validation.diagnostics
        ))
    }

    private static func subfolders(of directory: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.sorted().compactMap { name in
            let url = directory.appendingPathComponent(name, isDirectory: true)
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isDirectory == true, values?.isSymbolicLink != true,
                  FileManager.default.fileExists(atPath: url.appendingPathComponent("skin.json").path)
            else { return nil }
            return url
        }
    }

    private static func fatal(_ code: String, _ message: String) -> SkinDiagnostic {
        SkinDiagnostic(code: code, severity: .fatal, path: [], message: message)
    }
}
