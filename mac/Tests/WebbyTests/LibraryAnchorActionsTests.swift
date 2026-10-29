import Foundation
import Testing
@testable import Webby
import WebbyCore

@MainActor
private final class FakeAppAvailability: LibraryAppAvailabilityChecking {
    var installed: Set<String> = []
    var running: Set<String> = []

    func isInstalled(bundleID: String) -> Bool {
        installed.contains(bundleID)
    }

    func isRunning(bundleID: String) -> Bool {
        running.contains(bundleID)
    }
}

@MainActor
private final class FakeAppActivation: LibraryAppActivating {
    var result = true
    var calls: [String] = []

    func activate(bundleID: String) -> Bool {
        calls.append(bundleID)
        return result
    }
}

@MainActor
private final class FakePageOpening: LibraryPageOpening {
    var result = false
    var calls: [(page: PageURL, scope: WebScope)] = []

    func open(page: PageURL, scope: WebScope) -> Bool {
        calls.append((page, scope))
        return result
    }
}

@MainActor
private final class FakeOverlayPresentation: LibraryOverlayPresenting {
    var result = true
    var shown: [UUID] = []

    func showAtAnchor(noteID: UUID) -> Bool {
        shown.append(noteID)
        return result
    }
}

@MainActor
private final class FakeCurrentApp: LibraryCurrentAppProviding {
    var bundleID: String?

    func currentBundleID() -> String? {
        bundleID
    }
}

@MainActor
private struct Fakes {
    let availability = FakeAppAvailability()
    let activation = FakeAppActivation()
    let pageOpening = FakePageOpening()
    let overlay = FakeOverlayPresentation()
    let currentApp = FakeCurrentApp()

    func actions() -> LibraryAnchorActions {
        LibraryAnchorActions(
            appAvailability: availability,
            appActivation: activation,
            pageOpening: pageOpening,
            overlayPresentation: overlay,
            currentApp: currentApp
        )
    }
}

@MainActor
@Suite struct LibraryAnchorActionsTests {
    @Test func appStateDistinguishesMissingInstalledAndRunningApps() {
        let fakes = Fakes()
        fakes.availability.installed = ["com.example.Installed", "com.example.Running"]
        fakes.availability.running = ["com.example.Running"]
        let actions = fakes.actions()

        #expect(actions.appState(bundleID: "com.example.Missing") == .missing)
        #expect(actions.appState(bundleID: "com.example.Installed") == .installed)
        #expect(actions.appState(bundleID: "com.example.Running") == .running)
    }

    @Test func reopenDelegatesAndReportsActivationFailure() {
        let fakes = Fakes()
        let actions = fakes.actions()

        fakes.activation.result = false
        #expect(actions.reopenApp(bundleID: "com.example.App") == false)
        #expect(fakes.activation.calls == ["com.example.App"])

        fakes.activation.result = true
        #expect(actions.reopenApp(bundleID: "com.example.App") == true)
        #expect(fakes.activation.calls == ["com.example.App", "com.example.App"])
    }

    @Test func webOpeningStaysUnavailableUntilBrowserSupport() throws {
        let fakes = Fakes()
        let actions = fakes.actions()
        let page = PageURL(host: "example.com", path: "/docs")

        #expect(actions.webOpeningAvailable == false)
        #expect(actions.openWeb(page: page, scope: .page) == false)
        #expect(fakes.pageOpening.calls.isEmpty)
        #expect(LibraryAnchorActions.webUnavailableExplanation.contains("#11"))
    }

    @Test func attachCurrentAppExcludesWebbyAndMutatesExactlyOnce() {
        let fakes = Fakes()
        let actions = fakes.actions()
        var anchors: [Anchor] = []

        fakes.currentApp.bundleID = WebbyCore.Webby.bundleID
        #expect(actions.attachCurrentAppAnchor { anchors.append($0) } == false)
        #expect(anchors.isEmpty)

        fakes.currentApp.bundleID = "  "
        #expect(actions.attachCurrentAppAnchor { anchors.append($0) } == false)
        #expect(anchors.isEmpty)

        fakes.currentApp.bundleID = " com.example.External "
        #expect(actions.attachCurrentAppAnchor { anchors.append($0) } == true)
        #expect(anchors == [.app(bundleID: "com.example.External")])

        #expect(actions.attachCurrentAppAnchor { anchors.append($0) } == true)
        #expect(anchors.count == 2)
        #expect(actions.currentExternalAppAnchor() == .app(bundleID: "com.example.External"))
    }

    @Test func showAtAnchorDelegatesWithoutMutatingTheStore() {
        let fakes = Fakes()
        let actions = fakes.actions()
        let id = UUID()

        fakes.overlay.result = true
        #expect(actions.showAtAnchor(noteID: id) == true)
        #expect(fakes.overlay.shown == [id])

        fakes.overlay.result = false
        #expect(actions.showAtAnchor(noteID: id) == false)
        #expect(fakes.overlay.shown == [id, id])
    }
}
