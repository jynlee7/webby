import Foundation

/// Why a skins-folder operation was refused.
public enum SkinLibraryError: Error, Equatable, Sendable {
    /// The id does not follow the manifest id grammar, so it is not a safe folder name.
    case invalidID(String)
    /// The `webby.` prefix belongs to built-in skins.
    case reservedID(String)
    case manifestMissing
    case manifestUnreadable
    /// The staged `skin.json` declares a different id than the one being installed.
    case idMismatch(expected: String, found: String?)
    case notFound(String)
    case operationFailed(String)
}

/// One user skin folder found under the library root.
public struct SkinLibraryFolderEntry: Sendable, Equatable {
    public let id: String
    public let folder: URL
}

/// The result of "Duplicate to edit".
public struct DuplicatedSkin: Sendable, Equatable {
    public let id: String
    public let name: String
    public let folder: URL
}

/// The folder that holds user-installed skins, `<root>/<id>/skin.json`.
///
/// The app passes `Application Support/Webby/Skins`; tests pass a temporary
/// directory. Every path this type writes is a direct child of `root`.
public struct SkinLibraryFolder: Sendable, Equatable {
    public static let reservedPrefix = "webby."

    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// The folder an installed skin with `id` lives in. Does not touch the disk.
    public func folder(for id: String) -> URL {
        root.appendingPathComponent(id, isDirectory: true)
    }

    /// Installed user skin folders, sorted by id. Folders whose name is not a valid
    /// id, folders without a `skin.json`, and symbolic links are ignored.
    public func installed() -> [SkinLibraryFolderEntry] {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: root.path) else {
            return []
        }
        return names.sorted().compactMap { name in
            guard SkinValidator.isValidSkinID(name) else { return nil }
            let folder = self.folder(for: name)
            guard Self.isRealDirectory(folder),
                  fileManager.fileExists(atPath: folder.appendingPathComponent("skin.json").path)
            else { return nil }
            return SkinLibraryFolderEntry(id: name, folder: folder)
        }
    }

    /// Moves a validated staged folder to `<root>/<id>`, replacing a user skin with
    /// the same id in one step so the old skin is never missing without the new one
    /// in place. The staged folder is consumed.
    @discardableResult
    public func install(stagedFolder: URL, id: String) throws -> URL {
        try Self.checkInstallable(id)
        guard Self.isRealDirectory(stagedFolder) else { throw SkinLibraryError.manifestMissing }
        let declared = try Self.readManifestObject(in: stagedFolder)["id"] as? String
        guard declared == id else {
            throw SkinLibraryError.idMismatch(expected: id, found: declared)
        }

        let fileManager = FileManager.default
        let destination = folder(for: id)
        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: stagedFolder)
            } else {
                try fileManager.moveItem(at: stagedFolder, to: destination)
            }
        } catch {
            throw SkinLibraryError.operationFailed(error.localizedDescription)
        }
        return destination
    }

    /// Removes an installed user skin.
    public func remove(id: String) throws {
        try Self.checkInstallable(id)
        let destination = folder(for: id)
        guard Self.isRealDirectory(destination) else { throw SkinLibraryError.notFound(id) }
        do {
            try FileManager.default.removeItem(at: destination)
        } catch {
            throw SkinLibraryError.operationFailed(error.localizedDescription)
        }
    }

    /// Copies any skin folder (built-in or user) into the library under a new unique
    /// id derived from the source, changing only `id` and `name` in `skin.json`.
    ///
    /// `avoiding` lists ids that are taken elsewhere, such as the built-ins.
    public func duplicate(folder source: URL, avoiding taken: Set<String> = []) throws -> DuplicatedSkin {
        var object = try Self.readManifestObject(in: source)
        guard let sourceID = object["id"] as? String, SkinValidator.isValidSkinID(sourceID) else {
            throw SkinLibraryError.invalidID((object["id"] as? String) ?? "")
        }
        let sourceName = (object["name"] as? String) ?? sourceID

        let fileManager = FileManager.default
        let used = taken.union(installed().map(\.id))
        let baseID = Self.copyBaseID(for: sourceID)
        var number = 1
        var newID = baseID
        while used.contains(newID) || fileManager.fileExists(atPath: folder(for: newID).path) {
            number += 1
            newID = "\(baseID)-\(number)"
        }
        let newName = number == 1 ? "\(sourceName) Copy" : "\(sourceName) Copy \(number)"

        object["id"] = newID
        object["name"] = newName
        let manifest: Data
        do {
            manifest = try JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
        } catch {
            throw SkinLibraryError.manifestUnreadable
        }

        let scratch = root.appendingPathComponent(".duplicate-\(UUID().uuidString)", isDirectory: true)
        let destination = folder(for: newID)
        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            try fileManager.copyItem(at: source, to: scratch)
            try manifest.write(to: scratch.appendingPathComponent("skin.json"), options: .atomic)
            try fileManager.moveItem(at: scratch, to: destination)
        } catch {
            try? fileManager.removeItem(at: scratch)
            throw SkinLibraryError.operationFailed(error.localizedDescription)
        }
        return DuplicatedSkin(id: newID, name: newName, folder: destination)
    }

    // MARK: - Helpers

    /// `webby.mono` becomes `user.mono-copy`; other ids just gain `-copy`.
    private static func copyBaseID(for id: String) -> String {
        if id.lowercased().hasPrefix(reservedPrefix) {
            return "user." + id.dropFirst(reservedPrefix.count) + "-copy"
        }
        return id + "-copy"
    }

    private static func checkInstallable(_ id: String) throws {
        guard SkinValidator.isValidSkinID(id) else { throw SkinLibraryError.invalidID(id) }
        guard !id.lowercased().hasPrefix(reservedPrefix) else { throw SkinLibraryError.reservedID(id) }
    }

    private static func isRealDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private static func readManifestObject(in folder: URL) throws -> [String: Any] {
        let url = folder.appendingPathComponent("skin.json")
        guard FileManager.default.fileExists(atPath: url.path) else { throw SkinLibraryError.manifestMissing }
        guard let data = try? Data(contentsOf: url),
              data.count <= SkinFolderLoader.maximumManifestBytes,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { throw SkinLibraryError.manifestUnreadable }
        return object
    }
}
