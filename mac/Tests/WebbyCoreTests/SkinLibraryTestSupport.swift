import Foundation
@testable import WebbyCore

/// Shared fixtures for the skins-library tests. All writes go to temporary directories.
enum SkinLibraryTestSupport {
    static func builtInFolder(_ id: String) -> URL {
        var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while url.path != "/" {
            let candidate = url.appendingPathComponent("mac/Resources/Skins/\(id)", isDirectory: true)
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("skin.json").path) {
                return candidate
            }
            url.deleteLastPathComponent()
        }
        return url
    }

    static func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WebbySkinLibraryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Copies a built-in skin folder to `destination` with a new id, as a staged user skin.
    static func stagedCopy(of builtIn: String, id: String, in directory: URL) throws -> URL {
        let destination = directory.appendingPathComponent("staged-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.copyItem(at: builtInFolder(builtIn), to: destination)
        try rewriteManifest(in: destination) { $0["id"] = id; $0["name"] = id }
        return destination
    }

    static func rewriteManifest(in folder: URL, _ change: (inout [String: Any]) -> Void) throws {
        let url = folder.appendingPathComponent("skin.json")
        var object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        change(&object)
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url)
    }

    static let builtInIDs = ["webby.clear", "webby.mono"]

    /// Loads a folder as an `InstalledSkin` with the header-only checker.
    static func installedSkin(folder: URL, origin: SkinOrigin) -> (skin: InstalledSkin?, diagnostics: [SkinDiagnostic]) {
        let loaded = SkinFolderLoader.load(folder: folder, origin: origin, availableBaseIDs: Set(builtInIDs))
        guard let manifest = loaded.manifest, let document = loaded.document else {
            return (nil, loaded.diagnostics)
        }
        let validation = SkinValidator.validate(
            document: document,
            assets: loaded.assetChecker,
            context: SkinValidationContext(isBuiltIn: origin == .builtIn, availableBaseIDs: Set(builtInIDs))
        )
        let skin = InstalledSkin(
            id: manifest.id,
            manifest: manifest,
            groups: validation.groups,
            availableImagePaths: Set(loaded.assetChecker.inventory().map(\.path)),
            isAccepted: loaded.isAccepted
        )
        return (skin, loaded.diagnostics)
    }

    static func builtInSkins() -> [InstalledSkin] {
        builtInIDs.compactMap { installedSkin(folder: builtInFolder($0), origin: .builtIn).skin }
    }
}

extension SkinLibraryTestSupport {
    /// A 1x1 PNG, enough for the header checker.
    static let tinyPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!

    /// A user-skin folder derived from webby.mono that declares a visible decoration.
    static func decoratedSkinFolder(id: String, in directory: URL) throws -> URL {
        let folder = try stagedCopy(of: "webby.mono", id: id, in: directory)
        let images = folder.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        try tinyPNG.write(to: images.appendingPathComponent("decoration.png"))
        try tinyPNG.write(to: images.appendingPathComponent("decoration@2x.png"))
        try rewriteManifest(in: folder) {
            $0["decoration"] = ["element": "decoration", "anchor": "topRight", "origin": "center"]
        }
        return folder
    }
}
