import AppKit
import WebbyCore

/// Whether an app anchor can be resolved on this Mac.
enum LibraryAppAvailabilityState: Equatable, Sendable {
    case missing
    case installed
    case running
}

@MainActor
protocol LibraryAppAvailabilityChecking {
    func isInstalled(bundleID: String) -> Bool
    func isRunning(bundleID: String) -> Bool
}

@MainActor
protocol LibraryAppActivating {
    /// Returns false when the app is missing or the running app refused activation.
    func activate(bundleID: String) -> Bool
}

@MainActor
protocol LibraryPageOpening {
    /// Chrome focus/open arrives with the browser bridge (#11).
    func open(page: PageURL, scope: WebScope) -> Bool
}

@MainActor
protocol LibraryOverlayPresenting {
    /// Shows an existing Mac-anchored note through `NotesController`, not a browser.
    func showAtAnchor(noteID: UUID) -> Bool
}

@MainActor
protocol LibraryCurrentAppProviding {
    /// The app to attach to. This provider must never return Webby itself.
    func currentBundleID() -> String?
}

/// The action surface the Library uses for app and page anchors.
///
/// Web opening is deliberately unavailable until #11 supplies bridge inventory and
/// context. Nothing here logs note text or raw URLs, and the mutation closure runs
/// exactly once per successful attach.
@MainActor
struct LibraryAnchorActions {
    static let webUnavailableExplanation =
        "Reopening web pages and attaching to the current page wait for browser support (#11)."

    let appAvailability: any LibraryAppAvailabilityChecking
    let appActivation: any LibraryAppActivating
    let pageOpening: any LibraryPageOpening
    let overlayPresentation: any LibraryOverlayPresenting
    let currentApp: any LibraryCurrentAppProviding

    func appState(bundleID: String) -> LibraryAppAvailabilityState {
        if appAvailability.isRunning(bundleID: bundleID) { return .running }
        if appAvailability.isInstalled(bundleID: bundleID) { return .installed }
        return .missing
    }

    @discardableResult
    func reopenApp(bundleID: String) -> Bool {
        appActivation.activate(bundleID: bundleID)
    }

    /// Always false in #13; the disabled controls explain why.
    var webOpeningAvailable: Bool { false }

    @discardableResult
    func openWeb(page: PageURL, scope: WebScope) -> Bool {
        _ = page
        _ = scope
        return false
    }

    /// The current app anchor, or nil when the provider reports Webby or no app.
    func currentExternalAppAnchor() -> Anchor? {
        guard let raw = currentApp.currentBundleID() else { return nil }
        let bundleID = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundleID.isEmpty, bundleID != WebbyCore.Webby.bundleID else { return nil }
        return .app(bundleID: bundleID)
    }

    /// Calls `apply` once when there is a usable external app, or not at all.
    @discardableResult
    func attachCurrentAppAnchor(_ apply: (Anchor) -> Void) -> Bool {
        guard let anchor = currentExternalAppAnchor() else { return false }
        apply(anchor)
        return true
    }

    @discardableResult
    func showAtAnchor(noteID: UUID) -> Bool {
        overlayPresentation.showAtAnchor(noteID: noteID)
    }
}

// MARK: - Live services

@MainActor
struct WorkspaceLibraryAppAvailability: LibraryAppAvailabilityChecking {
    func isInstalled(bundleID: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    func isRunning(bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }
}

@MainActor
struct WorkspaceLibraryAppActivation: LibraryAppActivating {
    func activate(bundleID: String) -> Bool {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            return running.activate(options: [])
        }

        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return false
        }
        // Launching is asynchronous. Returning true means the launch request was
        // accepted, not that the app has finished opening.
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in }
        return true
    }
}

/// #13 can edit persisted web anchors but cannot focus or open a browser page.
@MainActor
struct UnavailableLibraryPageOpening: LibraryPageOpening {
    func open(page: PageURL, scope: WebScope) -> Bool {
        _ = page
        _ = scope
        return false
    }
}

@MainActor
final class NotesControllerLibraryOverlayPresenter: LibraryOverlayPresenting {
    private let controller: NotesController

    init(controller: NotesController) {
        self.controller = controller
    }

    func showAtAnchor(noteID: UUID) -> Bool {
        guard let note = controller.libraryNotes.first(where: { $0.id == noteID }),
              note.trashedAt == nil,
              let anchor = note.anchor,
              case .app = anchor
        else { return false }

        controller.show(noteID)
        return true
    }
}

/// Wraps the app context source and keeps Webby from attaching to itself.
@MainActor
final class LiveLibraryCurrentAppProvider: LibraryCurrentAppProviding {
    private let provider: @MainActor () -> String?

    init(currentBundleID: @escaping @MainActor () -> String?) {
        provider = currentBundleID
    }

    func currentBundleID() -> String? {
        provider()
    }
}
