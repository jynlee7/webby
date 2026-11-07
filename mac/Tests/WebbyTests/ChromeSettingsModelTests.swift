import Foundation
import Testing
@testable import Webby
import WebbyCore

private let chromeFolder = URL(fileURLWithPath: "/tmp/Webby/Extension", isDirectory: true)
private let chromeManifest = URL(fileURLWithPath: "/tmp/Chrome/NativeMessagingHosts/com.webby.bridge.json")

private func version(_ string: String) -> ExtensionVersion {
    ExtensionVersion(string)!
}

private func helloEvent(_ connection: Int, profile: String, version: String) -> BridgeEvent {
    .message(
        connection: connection,
        profile: profile,
        .hello(BridgeHello(profile: profile, extVersion: version, incognitoAllowed: false))
    )
}

@MainActor
private func makeModel(
    bundled: ExtensionVersion? = version("1.2.0"),
    installed: ExtensionVersion? = nil,
    outcome: BundledExtensionInstaller.Outcome? = nil,
    inspection: NativeHostInstaller.Inspection = .missing
) -> ChromeSettingsModel {
    ChromeSettingsModel(
        extensionFolder: { chromeFolder },
        bundledVersion: { bundled },
        installedVersion: { installed },
        extensionOutcome: { outcome },
        hostInspection: { inspection }
    )
}

@MainActor
@Suite struct ChromeSettingsModelTests {
    @Test func profileComesFromHello() {
        let model = makeModel()
        model.receive(.connected(connection: 1))
        model.receive(helloEvent(1, profile: "profile-a", version: "1.2.0"))

        #expect(model.profiles.count == 1)
        #expect(model.profiles[0].connection == 1)
        #expect(model.profiles[0].profile == "profile-a")
        #expect(model.profiles[0].reportedVersion == "1.2.0")
        #expect(model.profiles[0].reloadState == .current)
        #expect(model.reloadState == .current)
    }

    @Test func olderVersionNeedsReload() {
        let model = makeModel(bundled: version("1.2.0"))
        model.receive(.connected(connection: 1))
        model.receive(helloEvent(1, profile: "profile-a", version: "1.1.0"))

        #expect(model.profiles[0].reloadState == .reloadNeeded(reported: "1.1.0", bundled: "1.2.0"))
        #expect(model.reloadState == .reloadNeeded(reported: "1.1.0", bundled: "1.2.0"))
    }

    @Test func malformedOrMissingHelloIsUnknown() {
        let model = makeModel()
        model.receive(.connected(connection: 1))
        model.receive(helloEvent(1, profile: "profile-a", version: "not-a-version"))
        model.receive(.connected(connection: 2))

        #expect(model.profiles.count == 2)
        #expect(model.profiles[0].reloadState == .unknown)
        #expect(model.profiles[1].reloadState == .unknown)
        #expect(model.reloadState == .unknown)
    }

    @Test func disconnectRemovesOnlyItsRow() {
        let model = makeModel()
        model.receive(.connected(connection: 1))
        model.receive(helloEvent(1, profile: "profile-a", version: "1.2.0"))
        model.receive(.connected(connection: 2))
        model.receive(helloEvent(2, profile: "profile-b", version: "1.2.0"))

        model.receive(.disconnected(connection: 1, profile: "profile-a"))

        #expect(model.profiles.count == 1)
        #expect(model.profiles[0].connection == 2)
        #expect(model.profiles[0].profile == "profile-b")
    }

    @Test func extensionStateMapsEveryOutcome() {
        let cases: [(BundledExtensionInstaller.Outcome, ChromeSettingsModel.ExtensionState)] = [
            (.bundleMissing, .missing),
            (.bundleInvalid, .invalid),
            (.installed(chromeFolder, version("1.2.0")), .upToDate("1.2.0")),
            (.unchanged(chromeFolder, version("1.2.0")), .upToDate("1.2.0")),
            (.installedNewer(chromeFolder, version("1.3.0")), .newerInstalled("1.3.0")),
            (.installationInvalid(chromeFolder), .invalid),
            (.conflict(chromeFolder), .failed("The extension folder changed during install. It will retry next launch.")),
            (.failed("disk full"), .failed("disk full")),
        ]

        for (outcome, expected) in cases {
            let model = makeModel(outcome: outcome)
            #expect(model.extensionState == expected)
        }
    }

    @Test func registrationTextMapsEveryInspection() {
        let cases: [(NativeHostInstaller.Inspection, String)] = [
            (.missing, "Not registered"),
            (.current(chromeManifest), "Registered with this copy of Webby"),
            (.stale(path: "/Applications/Other.app/webby-bridge"), "Points at another copy of Webby: /Applications/Other.app/webby-bridge"),
            (.dangling(path: "/missing/webby-bridge"), "Points at a bridge that is missing: /missing/webby-bridge"),
            (.malformed, "The registration file is unreadable"),
        ]

        for (inspection, expected) in cases {
            let model = makeModel(inspection: inspection)
            #expect(model.registrationText == expected)
            #expect(model.needsReRegister == (inspection != .current(chromeManifest)))
        }
    }

    @Test func copyFlagAndInjectedActionsFire() {
        let model = makeModel()
        var copied = false
        var revealed = false
        var repaired = false
        var registered = false
        model.copyPath = { copied = true }
        model.revealFolder = { revealed = true }
        model.repairExtension = { repaired = true }
        model.reRegisterHost = { registered = true }

        model.copyExtensionPath()
        model.revealFolder()
        model.repairExtension()
        model.reRegisterHost()

        #expect(copied)
        #expect(model.copied)
        #expect(revealed)
        #expect(repaired)
        #expect(registered)
    }

    @Test func refreshPicksUpChangedInputs() {
        var installed: ExtensionVersion? = version("1.0.0")
        var outcome: BundledExtensionInstaller.Outcome? = .unchanged(chromeFolder, version("1.0.0"))
        var inspection: NativeHostInstaller.Inspection = .missing
        let model = ChromeSettingsModel(
            extensionFolder: { chromeFolder },
            bundledVersion: { version("1.2.0") },
            installedVersion: { installed },
            extensionOutcome: { outcome },
            hostInspection: { inspection }
        )

        #expect(model.installedVersionText == "1.0.0")
        #expect(model.extensionState == .upToDate("1.0.0"))
        #expect(model.registrationText == "Not registered")

        installed = version("1.2.0")
        outcome = .installed(chromeFolder, version("1.2.0"))
        inspection = .current(chromeManifest)
        model.refresh()

        #expect(model.installedVersionText == "1.2.0")
        #expect(model.extensionState == .upToDate("1.2.0"))
        #expect(model.registrationText == "Registered with this copy of Webby")
        #expect(model.needsReRegister == false)
    }

    @Test func reloadGuidanceAppearsOnlyWhileAProfileIsBehind() {
        let model = makeModel(outcome: .unchanged(chromeFolder, version("1.2.0")))
        #expect(model.reloadGuidance == nil)
        #expect(model.extensionStateNote == nil)

        model.receive(.connected(connection: 1))
        model.receive(helloEvent(1, profile: "Default", version: "1.1.0"))
        #expect(model.reloadGuidance?.contains("Reload") == true)

        model.receive(helloEvent(1, profile: "Default", version: "1.2.0"))
        #expect(model.reloadGuidance == nil)

        let invalid = makeModel(outcome: .installationInvalid(chromeFolder))
        #expect(invalid.extensionStateNote == "The installed folder is invalid")
    }

    @Test func incognitoAccessIsShownInTheChromePane() {
        var access: [String: Bool] = [:]
        let model = ChromeSettingsModel(
            extensionFolder: { chromeFolder },
            incognitoAccess: { access }
        )
        #expect(model.incognitoText == "Not connected")

        // The browser monitor runs before the pane for each event, so the pane reads the
        // access that event just produced.
        access = ["Default": false]
        model.receive(helloEvent(1, profile: "Default", version: "1.2.0"))
        #expect(model.incognitoText == "Not allowed")

        access["Work"] = true
        model.refresh()
        #expect(model.incognitoText == "Differs by profile")
    }

    @Test func noConnectionsIsSafe() {
        let model = makeModel()
        model.receive(.disconnected(connection: 1, profile: nil))
        model.receive(.dropped(connection: nil, reason: "nothing to drop"))
        model.refresh()

        #expect(model.profiles.isEmpty)
        #expect(model.reloadState == .unknown)
    }
}
