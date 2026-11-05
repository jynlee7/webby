import AppKit
import WebbyCore

/// Keeps the open Chrome tabs current from bridge events and tells the Library when
/// they change. Events with no effect on the inventory do not notify.
@MainActor
final class OpenTabsFeed {
    private var reducer = OpenTabsInventory()
    private(set) var inventory = LibraryInventory()
    private let sessionIdentity: @MainActor () -> String

    /// Called after the inventory changes. The Library is the only observer.
    var onChange: (() -> Void)?

    init(sessionIdentity: @escaping @MainActor () -> String = OpenTabsFeed.runningChromeSession) {
        self.sessionIdentity = sessionIdentity
    }

    func receive(_ event: BridgeEvent) {
        reducer.setSession(sessionIdentity())
        reducer.receive(event)
        let updated = reducer.inventory
        guard updated != inventory else { return }
        inventory = updated
        onChange?()
    }

    /// The running Chrome's process ID and launch time, which identifies one run of the
    /// browser. Tab IDs are only unique within a run.
    static func runningChromeSession() -> String {
        let chrome = NSRunningApplication
            .runningApplications(withBundleIdentifier: OpenTabsInventory.bundleID).first
        guard let chrome, let launched = chrome.launchDate else {
            return OpenTabsInventory.unknownSession
        }
        return "\(chrome.processIdentifier)@\(launched.timeIntervalSince1970)"
    }
}
