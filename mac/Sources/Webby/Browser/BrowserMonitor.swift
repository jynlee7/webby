import AppKit
import WebbyCore

/// Follows the focused Chrome window's page from the bridge stream. The replayable
/// state stays in WebbyCore's `BrowserSession`; the Accessibility frame it is checked
/// against comes from `ContextMonitor`, which owns every OS observation.
@MainActor
final class BrowserMonitor {
    private var session = BrowserSession()
    private let sessionIdentity: @MainActor () -> String?

    /// The query rules that decide page identity: the enabled rules plus every key a
    /// page anchor still uses. Read each time a context is built.
    var queryRules: @MainActor () -> [QueryRule] = { QueryRules.builtIns }

    /// Called after each bridge event is applied.
    var onChange: (@MainActor () -> Void)?

    init(sessionIdentity: @escaping @MainActor () -> String? = BrowserMonitor.runningChromeSession) {
        self.sessionIdentity = sessionIdentity
    }

    func receive(_ event: BridgeEvent) {
        // Establish the process identity before accepting its first hello.
        session.setIdentity(sessionIdentity())
        session.receive(event)
        onChange?()
    }

    /// The page context of Chrome's focused window. Unknown, ambiguous, private or
    /// unverified windows get Chrome's app context (see `BrowserSession.context`).
    func context(focusedFrame: CGRect?) -> Context {
        // A Chrome restart invalidates every tab ID even before the new bridge speaks.
        session.setIdentity(sessionIdentity())
        return session.context(focusedFrame: focusedFrame, queryRules: queryRules())
    }

    /// The running Chrome's `"<pid>@<launch date>"`, or nil when Chrome isn't running.
    static func runningChromeSession() -> String? {
        let session = OpenTabsFeed.runningChromeSession()
        return session == OpenTabsInventory.unknownSession ? nil : session
    }
}
