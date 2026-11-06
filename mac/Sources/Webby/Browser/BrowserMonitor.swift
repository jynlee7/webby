import AppKit
import WebbyCore

/// Follows the focused Chrome window's page from the bridge stream. The replayable
/// state stays in WebbyCore's `BrowserSession`; the Accessibility frame it is checked
/// against comes from `ContextMonitor`, which owns every OS observation.
@MainActor
final class BrowserMonitor {
    private var session = BrowserSession()
    private var incognito: [String: (connection: Int, allowed: Bool)] = [:]
    private let sessionIdentity: @MainActor () -> String?

    /// The query rules that decide page identity: the enabled rules plus every key a
    /// page anchor still uses. Read each time a context is built.
    var queryRules: @MainActor () -> [QueryRule] = { QueryRules.builtIns }

    /// Called after each bridge event is applied.
    var onChange: (@MainActor () -> Void)?

    init(sessionIdentity: @escaping @MainActor () -> String? = BrowserMonitor.runningChromeSession) {
        self.sessionIdentity = sessionIdentity
    }

    /// Whether each connected Chrome profile allows the extension in Incognito, from
    /// its latest `hello`. Keyed by profile key.
    var incognitoAccess: [String: Bool] { incognito.mapValues(\.allowed) }

    func receive(_ event: BridgeEvent) {
        // Establish the process identity before accepting its first hello.
        session.setIdentity(sessionIdentity())
        session.receive(event)
        switch event {
        case .message(let connection, let profile, .hello(let hello)):
            incognito[profile] = (connection, hello.incognitoAllowed)
        case .disconnected(let connection, let profile?):
            if incognito[profile]?.connection == connection { incognito[profile] = nil }
        case .disconnected(let connection, nil), .dropped(let connection?, _):
            incognito = incognito.filter { $0.value.connection != connection }
        default:
            break
        }
        onChange?()
    }

    /// The page context of Chrome's focused window. Unknown, ambiguous, private or
    /// unverified windows get Chrome's app context (see `BrowserSession.context`).
    func context(focusedFrame: CGRect?) -> Context {
        // A Chrome restart invalidates every tab ID even before the new bridge speaks.
        session.setIdentity(sessionIdentity())
        return session.context(focusedFrame: focusedFrame, queryRules: queryRules())
    }

    /// The bridge's last report for a live, non-incognito tab of the running Chrome.
    func tab(_ ref: TabRef) -> BridgeTab? {
        session.setIdentity(sessionIdentity())
        return session.tab(ref)
    }

    /// The running Chrome's `"<pid>@<launch date>"`, or nil when Chrome isn't running.
    static func runningChromeSession() -> String? {
        let session = OpenTabsFeed.runningChromeSession()
        return session == OpenTabsInventory.unknownSession ? nil : session
    }
}
