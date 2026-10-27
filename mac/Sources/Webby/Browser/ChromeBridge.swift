import Foundation
import OSLog
import WebbyCore

/// Connects Webby to the Chrome extension: registers the native-messaging host, listens on
/// the bridge socket and writes what arrives to the debug log. Nothing consumes the
/// messages yet; web notes arrive in Step 4b. To watch the log:
///
///     log stream --level debug --predicate 'subsystem == "com.webby.app" AND category == "bridge"'
@MainActor
final class ChromeBridge {
    private let logger = Logger(subsystem: Webby.bundleID, category: "bridge")
    private var server: BridgeServer?
    private var eventsTask: Task<Void, Never>?

    /// True when Webby runs from a translocated location and can't register the bridge.
    private(set) var needsMoveToApplications = false

    func start() {
        installHost()
        startServer()
    }

    func stop() {
        eventsTask?.cancel()
        server?.stop()
        server = nil
    }

    private func installHost() {
        guard let executable = Bundle.main.executableURL else { return }
        let bridge = executable.deletingLastPathComponent().appendingPathComponent(BridgeConstants.bridgeExecutableName)
        do {
            switch try NativeHostInstaller(bridgeExecutableURL: bridge).install() {
            case .installed(let url):
                logger.info("Registered the Chrome bridge at \(url.path, privacy: .public)")
            case .unchanged:
                logger.info("Chrome bridge registration is up to date")
            case .translocated:
                needsMoveToApplications = true
                logger.error("Webby is running from a translocated location; not registering the Chrome bridge")
            case .bridgeMissing:
                logger.error("No \(BridgeConstants.bridgeExecutableName, privacy: .public) next to Webby; not registering the Chrome bridge")
            case .chromeNotFound:
                logger.info("Chrome's support folder doesn't exist; not registering the Chrome bridge")
            }
        } catch {
            logger.error("Couldn't register the Chrome bridge: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func startServer() {
        let server = BridgeServer()
        do {
            try server.start()
        } catch {
            logger.error("Couldn't listen for the Chrome bridge: \(String(describing: error), privacy: .public)")
            return
        }
        self.server = server
        let events = server.events
        eventsTask = Task { [weak self] in
            for await event in events {
                self?.log(event)
            }
        }
    }

    private func log(_ event: BridgeEvent) {
        switch event {
        case .connected(let connection):
            logger.info("bridge \(connection) connected")
        case .disconnected(let connection, let profile):
            logger.info("bridge \(connection) disconnected (profile \(profile ?? "unknown", privacy: .public))")
        case .dropped(let connection, let reason):
            logger.error("bridge \(connection.map(String.init) ?? "-", privacy: .public) dropped: \(reason, privacy: .public)")
        case .message(let connection, let profile, let message):
            log(message, connection: connection, profile: profile)
        }
    }

    /// URLs and titles are logged as private: they show only while debugging.
    private func log(_ message: ExtensionMessage, connection: Int, profile: String) {
        let prefix = "bridge \(connection) [\(profile)]"
        switch message {
        case .hello(let hello):
            logger.info("\(prefix, privacy: .public) hello: extension \(hello.extVersion, privacy: .public), incognito allowed \(hello.incognitoAllowed)")
        case .inventory(let windows):
            let tabs = windows.reduce(0) { $0 + $1.tabs.count }
            logger.debug("\(prefix, privacy: .public) inventory: \(windows.count) windows, \(tabs) tabs")
        case .active(let windowId, let incognito, let tab):
            logger.debug("\(prefix, privacy: .public) active tab \(tab.id) in window \(windowId)\(incognito ? " (incognito)" : "", privacy: .public): \(tab.url, privacy: .private)")
        case .tabCreated(let tab):
            logger.debug("\(prefix, privacy: .public) tab \(tab.id) created in window \(tab.windowId), opener \(tab.openerTabId.map(String.init) ?? "none", privacy: .public)")
        case .tabUpdated(let tabId, let url, let title):
            logger.debug("\(prefix, privacy: .public) tab \(tabId) updated: \(url ?? "-", privacy: .private) \(title ?? "-", privacy: .private)")
        case .tabClosed(let tabId, let windowClosing):
            logger.debug("\(prefix, privacy: .public) tab \(tabId) closed\(windowClosing ? " with its window" : "", privacy: .public)")
        case .tabMoved(let tabId, let windowId, let index):
            logger.debug("\(prefix, privacy: .public) tab \(tabId) moved to window \(windowId) at \(index)")
        case .tabReplaced(let added, let removed):
            logger.debug("\(prefix, privacy: .public) tab \(removed) replaced by \(added)")
        }
    }
}
