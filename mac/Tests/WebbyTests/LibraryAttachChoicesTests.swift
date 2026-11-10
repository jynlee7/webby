import Foundation
import SwiftUI
import Testing
@testable import Webby
import WebbyCore

private struct NoApps: LibraryAppAvailabilityChecking, LibraryAppActivating {
    func isInstalled(bundleID: String) -> Bool { false }
    func isRunning(bundleID: String) -> Bool { false }
    func activate(bundleID: String) -> Bool { false }
}

private struct NoOverlay: LibraryOverlayPresenting {
    func showAtAnchor(noteID: UUID) -> Bool { false }
}

/// Set by an observation's change handler, which may not capture a local variable.
private final class RenderFlag: @unchecked Sendable {
    var stale = false
}

@MainActor
@Suite struct LibraryAttachChoicesTests {
    /// A note already on show keeps its rendered menu until something it reads changes.
    /// Opening or clicking the Library makes Webby active, which must render the menu
    /// again, so it offers the page now in front instead of only "This app".
    @Test func attachChoicesRenderAgainWhenWebbyBecomesActive() throws {
        let chrome = BrowserSession.bundleID
        let page = try #require(PageURL(string: "https://example.com/a/b", queryRules: QueryRules.builtIns))
        var context = Context(appBundleID: chrome)
        let center = NotificationCenter()
        let choices = LibraryAttachChoices(
            actions: LibraryAnchorActions(
                appAvailability: NoApps(),
                appActivation: NoApps(),
                pageOpening: UnavailableLibraryPageOpening(),
                overlayPresentation: NoOverlay(),
                currentApp: LiveLibraryCurrentAppProvider(
                    currentBundleID: { chrome },
                    currentContext: { context }
                )
            ),
            center: center
        )
        let rendered = RenderFlag()
        func render() -> [String] {
            withObservationTracking {
                choices.scopes.map(\.title)
            } onChange: {
                rendered.stale = true
            }
        }

        #expect(render() == ["This app"])
        // The front page isn't observable, so this alone leaves the menu as rendered.
        context = Context(appBundleID: chrome, page: page)
        #expect(!rendered.stale)

        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(rendered.stale)
        #expect(render() == ["This page", "/a/b and below", "/a and below", "Whole site", "This app"])
    }
}
