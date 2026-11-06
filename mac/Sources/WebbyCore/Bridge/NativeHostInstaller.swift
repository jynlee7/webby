import Foundation

/// Registers the bridge with Chrome by writing its native-messaging host manifest, built in
/// code from `BridgeConstants`. It writes only into a Chrome support folder that already
/// exists, and nothing at all when Webby runs from an App Translocation mount, a temporary
/// path that disappears and would leave Chrome pointing at nothing, or from a location its
/// `RegistrationPolicy` doesn't approve. Before replacing a manifest it keeps one owner-only
/// copy at `com.webby.bridge.json.previous`, outside Chrome's `*.json` scan.
public struct NativeHostInstaller: Sendable {
    public enum Outcome: Equatable, Sendable {
        case installed(URL)
        /// The manifest on disk already matched; nothing was written.
        case unchanged(URL)
        /// Webby runs from a translocated location; the user must move it to Applications.
        case translocated
        /// There is no bridge executable next to the app.
        case bridgeMissing
        /// Chrome's support folder doesn't exist, so Chrome isn't set up for this user.
        case chromeNotFound
        /// Webby runs outside the policy's approved folders; nothing was written.
        case unstableLocation
        /// Webby runs from a translocated or unapproved location, and a working registration
        /// already exists; it was left untouched.
        case preservedExisting(URL)
    }

    /// What the manifest on disk says, without changing it.
    public enum Inspection: Equatable, Sendable {
        case missing
        /// It points at this installer's bridge, which exists.
        case current(URL)
        /// It points at a different bridge that exists.
        case stale(path: String)
        /// The bridge it points at is missing or not executable.
        case dangling(path: String)
        /// Unreadable, or not Webby's host name, origin and `stdio` type.
        case malformed
    }

    public let bridgeExecutableURL: URL
    public let chromeSupportDirectory: URL
    public let policy: RegistrationPolicy

    public init(
        bridgeExecutableURL: URL,
        chromeSupportDirectory: URL = BridgeConstants.chromeSupportDirectory,
        policy: RegistrationPolicy = .release()
    ) {
        self.bridgeExecutableURL = bridgeExecutableURL
        self.chromeSupportDirectory = chromeSupportDirectory
        self.policy = policy
    }

    /// The single backup of the manifest written before the last replacement.
    public var backupURL: URL {
        manifestURL.deletingLastPathComponent().appendingPathComponent("\(BridgeConstants.hostName).json.previous")
    }

    public var manifestURL: URL {
        chromeSupportDirectory
            .appendingPathComponent("NativeMessagingHosts", isDirectory: true)
            .appendingPathComponent("\(BridgeConstants.hostName).json")
    }

    public static func isTranslocated(_ url: URL) -> Bool {
        url.path.contains("/AppTranslocation/")
    }

    /// The host manifest Chrome reads. `bridgePath` must be absolute.
    public static func manifest(bridgePath: String) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(HostManifest(
            name: BridgeConstants.hostName,
            description: "Webby native messaging bridge",
            path: bridgePath,
            type: "stdio",
            allowedOrigins: [BridgeConstants.extensionOrigin]
        ))
    }

    public func inspect() -> Inspection {
        // attributesOfItem does not follow a final symlink, so a linked manifest is never read.
        guard let type = (try? FileManager.default.attributesOfItem(atPath: manifestURL.path))?[.type] as? FileAttributeType
        else { return .missing }
        guard type == .typeRegular,
              let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(HostManifest.self, from: data),
              manifest.name == BridgeConstants.hostName,
              manifest.type == "stdio",
              manifest.allowedOrigins == [BridgeConstants.extensionOrigin],
              manifest.path.hasPrefix("/")
        else { return .malformed }
        guard FileManager.default.isExecutableFile(atPath: manifest.path) else { return .dangling(path: manifest.path) }
        if manifest.path == bridgeExecutableURL.standardizedFileURL.path {
            return .current(manifestURL)
        }
        return .stale(path: manifest.path)
    }

    public func install() throws -> Outcome {
        let bridge = bridgeExecutableURL.standardizedFileURL
        let translocated = Self.isTranslocated(bridge)
        if translocated || !policy.allowsRegistration(forBridge: bridge) {
            // Never repoint Chrome from here; keep a registration that still works.
            switch inspect() {
            case .current, .stale:
                return .preservedExisting(manifestURL)
            case .missing, .dangling, .malformed:
                return translocated ? .translocated : .unstableLocation
            }
        }
        guard FileManager.default.isExecutableFile(atPath: bridge.path) else { return .bridgeMissing }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: chromeSupportDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return .chromeNotFound }

        let data = try Self.manifest(bridgePath: bridge.path)
        if (try? Data(contentsOf: manifestURL)) == data {
            return .unchanged(manifestURL)
        }
        // The parent is Chrome's existing folder, so this never creates Chrome's own folders.
        let hostsDirectory = manifestURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: hostsDirectory.path) {
            try FileManager.default.createDirectory(at: hostsDirectory, withIntermediateDirectories: false)
        }
        // Keep the manifest being replaced; if it can't be read or copied, change nothing.
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            let existing = try Data(contentsOf: manifestURL)
            try existing.write(to: backupURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupURL.path)
        }
        // An atomic write leaves the current manifest intact if it fails.
        try data.write(to: manifestURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: manifestURL.path)
        return .installed(manifestURL)
    }
}

private struct HostManifest: Codable {
    let name: String
    let description: String
    let path: String
    let type: String
    let allowedOrigins: [String]

    enum CodingKeys: String, CodingKey {
        case name, description, path, type
        case allowedOrigins = "allowed_origins"
    }
}
