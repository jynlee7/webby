import Foundation

/// Registers the bridge with Chrome by writing its native-messaging host manifest, built in
/// code from `BridgeConstants`. It writes only into a Chrome support folder that already
/// exists, and nothing at all when Webby runs from an App Translocation mount, a temporary
/// path that disappears and would leave Chrome pointing at nothing.
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
    }

    public let bridgeExecutableURL: URL
    public let chromeSupportDirectory: URL

    public init(bridgeExecutableURL: URL, chromeSupportDirectory: URL = BridgeConstants.chromeSupportDirectory) {
        self.bridgeExecutableURL = bridgeExecutableURL
        self.chromeSupportDirectory = chromeSupportDirectory
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

    public func install() throws -> Outcome {
        let bridge = bridgeExecutableURL.standardizedFileURL
        guard !Self.isTranslocated(bridge) else { return .translocated }
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
        try data.write(to: manifestURL, options: .atomic)
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
