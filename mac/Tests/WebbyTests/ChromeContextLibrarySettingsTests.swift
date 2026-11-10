import Foundation
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

@MainActor
private func actions(bundleID: @escaping @MainActor () -> String?, context: @escaping @MainActor () -> Context?) -> LibraryAnchorActions {
    LibraryAnchorActions(
        appAvailability: NoApps(),
        appActivation: NoApps(),
        pageOpening: UnavailableLibraryPageOpening(),
        overlayPresentation: NoOverlay(),
        currentApp: LiveLibraryCurrentAppProvider(currentBundleID: bundleID, currentContext: context)
    )
}

@MainActor
@Suite struct ChromeContextLibrarySettingsTests {
    @Test func attachToCurrentOffersPageScopesAndRereadsTheContext() throws {
        let first = try #require(PageURL(string: "https://example.com/docs/intro", queryRules: QueryRules.builtIns))
        let second = try #require(PageURL(string: "https://other.example/a", queryRules: QueryRules.builtIns))
        var page: PageURL? = first
        let chrome = BrowserSession.bundleID
        let subject = actions(bundleID: { chrome }, context: { Context(appBundleID: chrome, page: page) })
        #expect(subject.currentScopes().map(\.title) == ["This page", "/docs/intro and below", "/docs and below", "Whole site", "This app"])

        var applied: [Anchor] = []
        #expect(subject.attachCurrentScope(titled: "/docs and below") { applied.append($0) })
        #expect(applied == [.web(page: first, scope: .prefix(path: "/docs"))])

        // A menu built for the first page never attaches to it after the page changed.
        page = second
        #expect(!subject.attachCurrentScope(titled: "/docs and below") { applied.append($0) })
        #expect(subject.attachCurrentScope(titled: "Whole site") { applied.append($0) })
        #expect(applied.last == .web(page: second, scope: .site))
        #expect(applied.count == 2)
    }

    @Test func attachToCurrentFallsBackToTheAppAndRefusesWebby() {
        let other = actions(bundleID: { "com.example.app" }, context: { Context(appBundleID: "com.example.app") })
        #expect(other.currentScopes().map(\.anchor) == [.app(bundleID: "com.example.app")])
        // A context for another app than the provider's is ignored.
        let mismatched = actions(bundleID: { "com.example.app" }, context: { Context(appBundleID: "com.example.stale") })
        #expect(mismatched.currentScopes().map(\.anchor) == [.app(bundleID: "com.example.app")])
        let webby = actions(bundleID: { WebbyCore.Webby.bundleID }, context: { nil })
        #expect(webby.currentScopes().isEmpty)
        #expect(!webby.attachCurrentScope(titled: "This app") { _ in Issue.record("must not attach") })
    }

    @Test func incognitoAccessFollowsEachProfilesLatestHello() {
        let browser = BrowserMonitor(sessionIdentity: { "100@1" })
        func hello(_ connection: Int, _ profile: String, _ allowed: Bool) {
            browser.receive(.message(connection: connection, profile: profile,
                                     .hello(BridgeHello(profile: profile, extVersion: "1", incognitoAllowed: allowed))))
        }
        #expect(ChromeSettingsModel.incognitoSummary(browser.incognitoAccess) == nil)
        hello(1, "a", false)
        #expect(ChromeSettingsModel.incognitoSummary(browser.incognitoAccess) == "Not allowed")
        hello(2, "b", true)
        #expect(ChromeSettingsModel.incognitoSummary(browser.incognitoAccess) == "Differs by profile")
        // A late disconnect from an older bridge keeps its replacement's answer.
        hello(3, "a", true)
        browser.receive(.disconnected(connection: 1, profile: "a"))
        #expect(browser.incognitoAccess == ["a": true, "b": true])
        #expect(ChromeSettingsModel.incognitoSummary(browser.incognitoAccess) == "Allowed")
        browser.receive(.dropped(connection: 2, reason: "test"))
        browser.receive(.disconnected(connection: 3, profile: "a"))
        #expect(browser.incognitoAccess.isEmpty)
    }
}
