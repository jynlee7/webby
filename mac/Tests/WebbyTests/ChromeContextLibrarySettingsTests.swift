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

    /// Opening the Library makes Webby active, and Chrome then reports no focused
    /// window. The Library still offers the page Chrome showed, and only that page.
    @Test func attachToCurrentKeepsChromesPageWhileWebbyIsInFront() throws {
        var identity = "100@1"
        var webbyIsActive = false
        let browser = BrowserMonitor(sessionIdentity: { identity })
        let monitor = ContextMonitor(permission: AccessibilityPermission(), browser: browser)
        monitor.isWebbyActive = { webbyIsActive }
        monitor.app = ContextMonitor.FrontApp(bundleID: BrowserSession.bundleID, pid: 1, name: "Google Chrome")
        monitor.windowFrame = CGRect(x: 20, y: 40, width: 1000, height: 700)
        let subject = actions(bundleID: { monitor.app?.bundleID }, context: { monitor.attachContext })
        let profile = "p"
        func send(_ message: ExtensionMessage) {
            browser.receive(.message(connection: 1, profile: profile, message))
        }
        func inventory(focused: Bool, incognito: Bool = false, activeTab: Int = 1) {
            send(.inventory(windows: [BridgeWindow(
                id: 1, focused: focused, incognito: incognito,
                bounds: BridgeWindowBounds(left: 20, top: 40, width: 1000, height: 700),
                tabs: [
                    BridgeTab(id: 1, index: 0, active: activeTab == 1, url: "https://example.com/a/b", title: "A"),
                    BridgeTab(id: 2, index: 1, active: activeTab == 2, url: "https://example.com/c", title: "C"),
                ]
            )]))
        }
        let page = try #require(PageURL(string: "https://example.com/a/b", queryRules: QueryRules.builtIns))
        let pageScopes = ["This page", "/a/b and below", "/a and below", "Whole site", "This app"]

        send(.hello(BridgeHello(profile: profile, extVersion: "1", incognitoAllowed: true)))
        inventory(focused: true)
        #expect(subject.currentScopes().map(\.title) == pageScopes)

        webbyIsActive = true
        inventory(focused: false)
        #expect(subject.currentScopes().map(\.title) == pageScopes)
        var applied: [Anchor] = []
        #expect(subject.attachCurrentScope(titled: "Whole site") { applied.append($0) })
        #expect(applied == [.web(page: page, scope: .site)])

        // A tab that is no longer the window's active tab is never offered.
        inventory(focused: false, activeTab: 2)
        #expect(subject.currentScopes().map(\.title) == ["This app"])
        inventory(focused: false)
        #expect(subject.currentScopes().map(\.title) == pageScopes)

        // Nor is a page from before a Chrome restart.
        identity = "200@2"
        #expect(subject.currentScopes().map(\.title) == ["This app"])
        send(.hello(BridgeHello(profile: profile, extVersion: "1", incognitoAllowed: true)))
        inventory(focused: false)
        #expect(subject.currentScopes().map(\.title) == ["This app"])

        // A private window that was in front last leaves only the app.
        webbyIsActive = false
        inventory(focused: true)
        inventory(focused: true, incognito: true)
        webbyIsActive = true
        inventory(focused: false)
        #expect(subject.currentScopes().map(\.title) == ["This app"])

        // With Chrome itself in front, the live context decides.
        webbyIsActive = false
        inventory(focused: true)
        inventory(focused: false)
        #expect(subject.currentScopes().map(\.title) == ["This app"])
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
