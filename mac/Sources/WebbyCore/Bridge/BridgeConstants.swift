import Foundation

/// Identifiers and limits shared by the app, the native-messaging bridge and the extension.
/// `scripts/check-extension.sh` checks that `extensionID`, `hostName` and `protocolVersion`
/// agree with `extension/manifest.json`, `extension/protocol.js` and
/// `extension/native-host.template.json`, so keep each on its own `static let` line.
public enum BridgeConstants {
    /// Native-messaging host name the extension connects to.
    public static let hostName = "com.webby.bridge"
    /// Chrome extension ID derived from the pinned `key` in `extension/manifest.json`.
    public static let extensionID = "ccehhpjcbcabmlalclppmdomonfdcbcl"
    /// Version of the extension protocol (plan.md §5.1.7), sent in `hello.v`.
    public static let protocolVersion = 1

    /// Origin Chrome passes to the bridge as its first argument.
    public static var extensionOrigin: String { "chrome-extension://\(extensionID)/" }

    /// Name of the bridge executable inside `Webby.app/Contents/MacOS`.
    public static let bridgeExecutableName = "webby-bridge"

    /// Largest message Chrome sends to a native host (64 MiB). Also the limit for the
    /// bridge → app socket, which carries the same messages.
    public static let maxMessageFromChrome = 64 * 1024 * 1024
    /// Largest message a native host may send to Chrome (1 MB). Also the limit for the
    /// app → bridge socket, whose commands are forwarded to Chrome unchanged.
    public static let maxMessageToChrome = 1024 * 1024

    /// `~/Library/Application Support/Webby`.
    public static var supportDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("Webby", isDirectory: true)
    }

    /// The socket the app listens on and the bridge connects to.
    public static var defaultSocketURL: URL {
        supportDirectory.appendingPathComponent("bridge.sock")
    }

    /// Chrome's per-user support folder. Webby registers its host here only if it exists.
    public static var chromeSupportDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("Google/Chrome", isDirectory: true)
    }

    /// Whether the bridge was launched by Chrome for the Webby extension.
    /// Chrome passes the caller's origin as the first argument.
    public static func isAllowedCaller(_ arguments: [String]) -> Bool {
        arguments.count > 1 && arguments[1] == extensionOrigin
    }

    private static var applicationSupportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
    }
}
