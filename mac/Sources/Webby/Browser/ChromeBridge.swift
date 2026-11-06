import Foundation
import OSLog
import WebbyCore

/// Connects Webby to the Chrome extension: registers the native-messaging host, listens on
/// the bridge socket, installs the bundled extension and delivers ordered events on the
/// main actor. To watch the log:
///
///     log stream --level debug --predicate 'subsystem == "io.github.jynlee7.webby" AND category == "bridge"'
@MainActor
final class ChromeBridge {
    private let logger = Logger(subsystem: Webby.bundleID, category: "bridge")
    private var server: BridgeServer?
    private var eventsTask: Task<Void, Never>?

    /// Subscribers called on the main actor, in the order added, after each event is logged.
    private let handlers = BridgeEventHandlers()

    /// True when Webby runs from a translocated or unapproved location and can't register the bridge.
    private(set) var needsMoveToApplications = false

    /// What the last launch did with the native host manifest, for the Chrome settings.
    private(set) var hostRegistration: NativeHostInstaller.Outcome?

    /// What the last launch did with the bundled extension, for the Chrome settings.
    private(set) var extensionInstall: BundledExtensionInstaller.Outcome?

    /// Adds a subscriber for every later bridge event. Handlers run in the order added.
    @discardableResult
    func addEventHandler(_ handler: @escaping @MainActor (BridgeEvent) -> Void) -> BridgeEventHandlers.Token {
        handlers.add(handler)
    }

    func removeEventHandler(_ token: BridgeEventHandlers.Token) {
        handlers.remove(token)
    }

    func start() {
        installExtension()
        installHost()
        startServer()
    }

    func stop() {
        eventsTask?.cancel()
        server?.stop()
        server = nil
    }

    private var extensionInstaller: BundledExtensionInstaller? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        return BundledExtensionInstaller(
            bundleDirectory: resources.appendingPathComponent("Extension", isDirectory: true)
        )
    }

    private var hostInstaller: NativeHostInstaller? {
        guard let executable = Bundle.main.executableURL else { return nil }
        let bridge = executable.deletingLastPathComponent().appendingPathComponent(BridgeConstants.bridgeExecutableName)
        // Release builds register only from Applications; a staged development build may
        // register from anywhere that isn't translocated.
        let policy = RegistrationPolicy.forApp(infoDictionary: Bundle.main.infoDictionary)
        return NativeHostInstaller(bridgeExecutableURL: bridge, policy: policy)
    }

    /// Copies the bundled extension to Application Support. A failure is logged and never
    /// blocks notes or the bridge.
    private func installExtension() {
        guard let installer = extensionInstaller else { return }
        let outcome = installer.install()
        extensionInstall = outcome
        log(extensionOutcome: outcome)
    }

    /// Replaces an installed extension folder that can't be read, then records the result.
    @discardableResult
    func repairExtension() -> BundledExtensionInstaller.Outcome? {
        guard let installer = extensionInstaller else { return nil }
        let outcome = installer.repairInvalidInstallation()
        extensionInstall = outcome
        log(extensionOutcome: outcome)
        return outcome
    }

    private func installHost() {
        guard let installer = hostInstaller else { return }
        do {
            let outcome = try installer.install()
            hostRegistration = outcome
            log(hostOutcome: outcome)
        } catch {
            logger.error("Couldn't register the Chrome bridge: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Writes the host manifest again with the same policy as launch, then records the result.
    @discardableResult
    func reRegisterHost() -> NativeHostInstaller.Outcome? {
        guard let installer = hostInstaller else { return nil }
        do {
            let outcome = try installer.install()
            hostRegistration = outcome
            log(hostOutcome: outcome)
            return outcome
        } catch {
            logger.error("Couldn't register the Chrome bridge: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// The version of the app's bundled payload, independent of what is installed.
    func bundledExtensionVersion() -> ExtensionVersion? {
        extensionInstaller?.bundledVersion()
    }

    /// What the host manifest on disk says, without changing it.
    func inspectHost() -> NativeHostInstaller.Inspection {
        hostInstaller?.inspect() ?? .missing
    }

    /// The version of the extension folder Chrome loads, read from its manifest.
    func installedExtensionVersion() -> ExtensionVersion? {
        guard let installer = extensionInstaller else { return nil }
        let manifest = installer.installDirectory.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifest),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let string = object["version"] as? String
        else { return nil }
        return ExtensionVersion(string)
    }

    private func log(extensionOutcome outcome: BundledExtensionInstaller.Outcome) {
        switch outcome {
        case .bundleMissing:
            logger.info("No bundled Chrome extension; not installing it")
        case .bundleInvalid:
            logger.error("The bundled Chrome extension is incomplete; not installing it")
        case .installed(_, let version):
            logger.info("Installed Chrome extension \(version.description, privacy: .public)")
        case .unchanged(_, let version):
            logger.info("Chrome extension \(version.description, privacy: .public) is up to date")
        case .installedNewer(_, let version):
            logger.info("Kept the newer installed Chrome extension \(version.description, privacy: .public)")
        case .installationInvalid:
            logger.error("The installed Chrome extension folder is invalid; kept it for repair")
        case .conflict:
            logger.info("The Chrome extension folder changed during install; will retry next launch")
        case .failed(let message):
            logger.error("Couldn't install the Chrome extension: \(message, privacy: .public)")
        }
    }

    private func log(hostOutcome outcome: NativeHostInstaller.Outcome) {
        switch outcome {
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
        case .unstableLocation:
            needsMoveToApplications = true
            logger.error("Webby is not in Applications; not registering the Chrome bridge")
        case .preservedExisting:
            needsMoveToApplications = true
            logger.error("Webby is not in Applications; kept the existing Chrome bridge registration")
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
                self?.handlers.deliver(event)
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
