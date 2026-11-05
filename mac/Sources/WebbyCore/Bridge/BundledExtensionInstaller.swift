import Foundation

/// Copies the extension bundled in `Webby.app/Contents/Resources/Extension` to
/// `~/Library/Application Support/Webby/Extension`, the folder the user points Chrome's
/// Load unpacked at. It installs only when that folder is absent or holds an older version,
/// never downgrades a newer copy, and never overwrites or deletes an installation it can't
/// read: that one is reported, and `repairInvalidInstallation()` moves it aside first.
///
/// Replacement is recoverable: the new copy is staged in `.Extension-staging`, the old folder
/// moves to `.Extension-previous`, the staged folder moves into place, and only then is the
/// previous copy deleted. Any failure restores the previous folder, and a launch that finds
/// only `.Extension-previous` (a crash mid-swap) moves it back first. Both folders are
/// injected; this type never reads `Bundle.main` and never writes into the app bundle.
public struct BundledExtensionInstaller: Sendable {
    /// The exact payload, in sorted order (scripts/package-extension.sh stages the same).
    public static let payloadFiles = ["background.js", "manifest.json", "protocol.js"]

    public enum Outcome: Equatable, Sendable {
        /// No bundled extension (for example a `swift run` build).
        case bundleMissing
        /// The bundled folder isn't exactly the valid payload; nothing was written.
        case bundleInvalid
        case installed(URL, ExtensionVersion)
        /// The installed copy already has the bundled version; nothing was written.
        case unchanged(URL, ExtensionVersion)
        /// The installed copy is newer than the bundle and was kept.
        case installedNewer(URL, ExtensionVersion)
        /// The installed folder is unreadable, incomplete, has extra entries or is a symlink.
        /// It was kept; `repairInvalidInstallation()` replaces it.
        case installationInvalid(URL)
        /// The installed folder changed while this launch staged its copy; nothing was replaced.
        case conflict(URL)
        /// An unexpected filesystem failure; the previous installation, if any, is intact.
        case failed(String)
    }

    /// Filesystem calls, injectable so tests can fail a chosen step.
    public struct Operations: Sendable {
        public var createDirectory: @Sendable (URL) throws -> Void
        public var copyItem: @Sendable (_ from: URL, _ to: URL) throws -> Void
        public var moveItem: @Sendable (_ from: URL, _ to: URL) throws -> Void
        public var removeItem: @Sendable (URL) throws -> Void
        public var readData: @Sendable (URL) throws -> Data

        public init(
            createDirectory: @escaping @Sendable (URL) throws -> Void,
            copyItem: @escaping @Sendable (URL, URL) throws -> Void,
            moveItem: @escaping @Sendable (URL, URL) throws -> Void,
            removeItem: @escaping @Sendable (URL) throws -> Void,
            readData: @escaping @Sendable (URL) throws -> Data
        ) {
            self.createDirectory = createDirectory
            self.copyItem = copyItem
            self.moveItem = moveItem
            self.removeItem = removeItem
            self.readData = readData
        }

        public static let fileManager = Operations(
            createDirectory: { try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true) },
            copyItem: { try FileManager.default.copyItem(at: $0, to: $1) },
            moveItem: { try FileManager.default.moveItem(at: $0, to: $1) },
            removeItem: { try FileManager.default.removeItem(at: $0) },
            readData: { try Data(contentsOf: $0) }
        )
    }

    public let bundleDirectory: URL
    public let supportDirectory: URL
    public let installDirectory: URL
    private let operations: Operations

    public init(
        bundleDirectory: URL,
        supportDirectory: URL = BridgeConstants.supportDirectory,
        operations: Operations = .fileManager
    ) {
        self.bundleDirectory = bundleDirectory
        self.supportDirectory = supportDirectory
        self.installDirectory = supportDirectory.appendingPathComponent("Extension", isDirectory: true)
        self.operations = operations
    }

    var stagingDirectory: URL { supportDirectory.appendingPathComponent(".Extension-staging", isDirectory: true) }
    var previousDirectory: URL { supportDirectory.appendingPathComponent(".Extension-previous", isDirectory: true) }
    /// Where `repairInvalidInstallation()` keeps the folder it replaced (one copy, owner-only).
    public var invalidDirectory: URL { supportDirectory.appendingPathComponent("Extension-invalid", isDirectory: true) }

    private struct Payload: Equatable {
        let version: ExtensionVersion
        let files: [String: Data]
    }

    private enum Installed: Equatable {
        case missing
        case invalid
        case valid(Payload)
    }

    public func install() -> Outcome {
        do {
            guard try supportDirectoryIsSafe() else {
                return .failed("The Webby support folder is not a real folder")
            }
            try recoverInterruptedSwap()
            guard exists(bundleDirectory) else { return .bundleMissing }
            guard let bundle = readPayload(at: bundleDirectory) else { return .bundleInvalid }

            let installed = readInstalled()
            switch installed {
            case .invalid:
                return .installationInvalid(installDirectory)
            case .valid(let current) where current.version > bundle.version:
                return .installedNewer(installDirectory, current.version)
            case .valid(let current) where current.version == bundle.version:
                return .unchanged(installDirectory, current.version)
            case .valid, .missing:
                return try replace(with: bundle, expecting: installed)
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Moves an invalid installation to `Extension-invalid` (replacing an earlier recovery
    /// copy) and installs the bundled payload. Nothing is deleted except that older recovery
    /// copy; if the move fails, the invalid folder stays where it was.
    public func repairInvalidInstallation() -> Outcome {
        do {
            guard try supportDirectoryIsSafe() else {
                return .failed("The Webby support folder is not a real folder")
            }
            guard readInstalled() == .invalid else { return install() }
            guard exists(bundleDirectory) else { return .bundleMissing }
            guard readPayload(at: bundleDirectory) != nil else { return .bundleInvalid }
            if exists(invalidDirectory) {
                try operations.removeItem(invalidDirectory)
            }
            try operations.moveItem(installDirectory, invalidDirectory)
            if isRealDirectory(invalidDirectory) {
                try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: invalidDirectory.path)
            }
            return install()
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: - Steps

    private func supportDirectoryIsSafe() throws -> Bool {
        if !exists(supportDirectory) {
            try operations.createDirectory(supportDirectory)
        }
        return isRealDirectory(supportDirectory)
    }

    /// A crash between the two renames leaves only `.Extension-previous`; put it back.
    private func recoverInterruptedSwap() throws {
        if !exists(installDirectory), exists(previousDirectory) {
            try operations.moveItem(previousDirectory, installDirectory)
        }
    }

    private func replace(with bundle: Payload, expecting installed: Installed) throws -> Outcome {
        if exists(stagingDirectory) {
            try operations.removeItem(stagingDirectory)
        }
        do {
            try operations.createDirectory(stagingDirectory)
            try setPermissions(0o755, stagingDirectory)
            for name in Self.payloadFiles {
                let staged = stagingDirectory.appendingPathComponent(name)
                try operations.copyItem(bundleDirectory.appendingPathComponent(name), staged)
                try setPermissions(0o644, staged)
            }
            guard readPayload(at: stagingDirectory) == bundle else {
                throw InstallerError("The staged extension does not match the bundled copy")
            }
        } catch {
            try? operations.removeItem(stagingDirectory)
            throw error
        }

        // Another launch may have installed meanwhile; never overwrite its work.
        guard readInstalled() == installed else {
            try? operations.removeItem(stagingDirectory)
            return .conflict(installDirectory)
        }

        let hadInstallation = exists(installDirectory)
        if hadInstallation {
            if exists(previousDirectory) {
                try operations.removeItem(previousDirectory)
            }
            do {
                try operations.moveItem(installDirectory, previousDirectory)
            } catch {
                try? operations.removeItem(stagingDirectory)
                throw error
            }
        }
        do {
            try operations.moveItem(stagingDirectory, installDirectory)
        } catch {
            if hadInstallation, !exists(installDirectory) {
                try? operations.moveItem(previousDirectory, installDirectory)
            }
            try? operations.removeItem(stagingDirectory)
            throw error
        }
        if exists(previousDirectory) {
            try? operations.removeItem(previousDirectory)
        }
        return .installed(installDirectory, bundle.version)
    }

    // MARK: - Reading

    private func readInstalled() -> Installed {
        if isSymbolicLink(installDirectory) { return .invalid }
        guard exists(installDirectory) else { return .missing }
        guard let payload = readPayload(at: installDirectory) else { return .invalid }
        return .valid(payload)
    }

    /// The folder's payload if it is a real folder holding exactly the three regular files
    /// with a manifest whose version parses.
    private func readPayload(at directory: URL) -> Payload? {
        guard isRealDirectory(directory),
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path),
              names.sorted() == Self.payloadFiles
        else { return nil }
        var files: [String: Data] = [:]
        for name in Self.payloadFiles {
            let file = directory.appendingPathComponent(name)
            guard fileType(file) == .typeRegular, let data = try? operations.readData(file) else { return nil }
            files[name] = data
        }
        guard let manifest = files["manifest.json"],
              let object = try? JSONSerialization.jsonObject(with: manifest) as? [String: Any],
              let string = object["version"] as? String,
              let version = ExtensionVersion(string)
        else { return nil }
        return Payload(version: version, files: files)
    }

    private func fileType(_ url: URL) -> FileAttributeType? {
        // attributesOfItem does not follow a final symlink.
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
    }

    private func isSymbolicLink(_ url: URL) -> Bool { fileType(url) == .typeSymbolicLink }
    private func isRealDirectory(_ url: URL) -> Bool { fileType(url) == .typeDirectory }
    private func exists(_ url: URL) -> Bool { fileType(url) != nil }

    private func setPermissions(_ mode: Int, _ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }
}

private struct InstallerError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
