import Foundation

/// Where an app may register its bridge with Chrome. A release registers only from
/// `/Applications` or `~/Applications`, so a copy run from Downloads, a mounted image or an
/// external volume never repoints Chrome at a path that may disappear. A development build
/// (staged with `WebbyDevelopmentBuild`, which release artifacts reject) may register from
/// any path that is not an App Translocation mount.
public struct RegistrationPolicy: Equatable, Sendable {
    /// Approved parent folders, or `nil` for any non-translocated path.
    public let allowedRoots: [URL]?

    public init(allowedRoots: [URL]?) {
        self.allowedRoots = allowedRoots?.map(\.standardizedFileURL)
    }

    public static func release(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> RegistrationPolicy {
        RegistrationPolicy(allowedRoots: [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            home.appendingPathComponent("Applications", isDirectory: true),
        ])
    }

    public static let development = RegistrationPolicy(allowedRoots: nil)

    /// The policy a running app uses: development only when its `Info.plist` says so.
    public static func forApp(infoDictionary: [String: Any]?, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> RegistrationPolicy {
        (infoDictionary?["WebbyDevelopmentBuild"] as? Bool) == true ? .development : .release(home: home)
    }

    /// `…/Webby.app/Contents/MacOS/webby-bridge` → `…/Webby.app`.
    public static func appBundle(forBridge bridge: URL) -> URL {
        bridge.standardizedFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// Whether the app owning `bridge` may register. Containment is checked on whole path
    /// components, case-insensitively, so `/Applications2` is not inside `/Applications`.
    public func allowsRegistration(forBridge bridge: URL) -> Bool {
        let app = Self.appBundle(forBridge: bridge)
        guard !NativeHostInstaller.isTranslocated(app) else { return false }
        guard let allowedRoots else { return true }
        let appComponents = app.pathComponents.map { $0.lowercased() }
        return allowedRoots.contains { root in
            let rootComponents = root.pathComponents.map { $0.lowercased() }
            return appComponents.count > rootComponents.count
                && Array(appComponents.prefix(rootComponents.count)) == rootComponents
        }
    }
}
