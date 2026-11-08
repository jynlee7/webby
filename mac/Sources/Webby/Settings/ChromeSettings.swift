import SwiftUI
import WebbyCore

/// What the Chrome pane shows: the installed extension, the native host registration and
/// the Chrome profiles currently connected. Inputs are injected so the model can be tested
/// without a bundle, a Chrome install or AppKit.
@MainActor @Observable
final class ChromeSettingsModel {
    enum ExtensionState: Equatable {
        case missing
        case upToDate(String)
        case newerInstalled(String)
        case invalid
        case failed(String)
        case unknown
    }

    struct ProfileRow: Identifiable, Equatable {
        let connection: Int
        let profile: String
        let reportedVersion: String?
        let reloadState: ExtensionReloadState

        var id: Int { connection }
    }

    var extensionFolder: URL
    var expectedExtensionID: String
    var bundledVersionText: String
    var installedVersionText: String
    var extensionState: ExtensionState = .unknown
    var registration: NativeHostInstaller.Inspection = .missing
    var profiles: [ProfileRow] = []
    var reloadState: ExtensionReloadState = .unknown
    var problemText: String?
    /// Why the last Re-register left Chrome without a working registration, else nil.
    var registrationProblem: String?
    /// Incognito access across connected profiles (moved here from General).
    var incognitoText = "Not connected"
    /// Set after Copy Path, so the pane can confirm the copy.
    var copied = false

    @ObservationIgnored var copyPath: @MainActor () -> Void = {}
    @ObservationIgnored var revealFolder: @MainActor () -> Void = {}
    @ObservationIgnored var repairExtension: @MainActor () -> Void = {}
    @ObservationIgnored var reRegisterHost: @MainActor () -> Void = {}

    private var status = BridgeStatus()
    private let folder: @MainActor () -> URL
    private let bundledVersion: @MainActor () -> ExtensionVersion?
    private let installedVersion: @MainActor () -> ExtensionVersion?
    private let extensionOutcome: @MainActor () -> BundledExtensionInstaller.Outcome?
    private let hostInspection: @MainActor () -> NativeHostInstaller.Inspection
    private let incognitoAccess: @MainActor () -> [String: Bool]

    init(
        extensionFolder folderProvider: @escaping @MainActor () -> URL = { BridgeConstants.extensionDirectory },
        bundledVersion: @escaping @MainActor () -> ExtensionVersion? = { nil },
        installedVersion: @escaping @MainActor () -> ExtensionVersion? = { nil },
        extensionOutcome: @escaping @MainActor () -> BundledExtensionInstaller.Outcome? = { nil },
        hostInspection: @escaping @MainActor () -> NativeHostInstaller.Inspection = { .missing },
        incognitoAccess: @escaping @MainActor () -> [String: Bool] = { [:] }
    ) {
        self.folder = folderProvider
        self.bundledVersion = bundledVersion
        self.installedVersion = installedVersion
        self.extensionOutcome = extensionOutcome
        self.hostInspection = hostInspection
        self.incognitoAccess = incognitoAccess
        extensionFolder = folderProvider()
        expectedExtensionID = BridgeConstants.extensionID
        bundledVersionText = ""
        installedVersionText = ""
        refresh()
    }

    /// Folds a live bridge event into the connected-profile list without re-reading the
    /// installed files.
    func receive(_ event: BridgeEvent) {
        status.receive(event)
        recomputeProfiles()
    }

    /// Re-reads every injected input. Live connection status is kept.
    func refresh() {
        extensionFolder = folder()
        let bundled = bundledVersion()
        let installed = installedVersion()
        bundledVersionText = bundled?.description ?? "Not bundled"
        installedVersionText = installed?.description ?? "Not installed"
        extensionState = Self.extensionState(outcome: extensionOutcome())
        registration = hostInspection()
        if case .current = registration { registrationProblem = nil }
        problemText = Self.problemText(for: extensionState)
        recomputeProfiles()
    }

    /// Records what Re-register did. A refusal or a failed write is explained inline,
    /// because the registration row alone looks unchanged after pressing the button.
    func reRegistered(_ result: Result<NativeHostInstaller.Outcome, any Error>) {
        switch result {
        case .success(let outcome):
            registrationProblem = Self.registrationProblem(for: outcome)
        case .failure(let error):
            registrationProblem = "Couldn't write Chrome's registration file: \(error.localizedDescription)"
        }
    }

    static func registrationProblem(for outcome: NativeHostInstaller.Outcome) -> String? {
        switch outcome {
        case .installed, .unchanged:
            return nil
        case .translocated, .unstableLocation, .preservedExisting:
            return "Webby registers with Chrome only from the Applications folder. Quit Webby, move it to Applications, and open it again."
        case .chromeNotFound:
            return "Chrome isn't set up for this Mac user yet. Open Chrome once, then press Re-register again."
        case .bridgeMissing:
            return "This copy of Webby is missing its Chrome bridge. Download Webby again."
        }
    }

    /// Copies the folder path, then records that it happened.
    func copyExtensionPath() {
        copyPath()
        copied = true
    }

    var extensionStateText: String {
        switch extensionState {
        case .missing: return "Not installed"
        case .upToDate(let version): return "Installed \(version)"
        case .newerInstalled(let version): return "Newer version \(version) installed"
        case .invalid: return "The installed folder is invalid"
        case .failed(let message): return message
        case .unknown: return "Unknown"
        }
    }

    var registrationText: String {
        switch registration {
        case .missing: return "Not registered"
        case .current: return "Registered with this copy of Webby"
        case .stale(let path): return "Points at another copy of Webby: \(path)"
        case .dangling(let path): return "Points at a bridge that is missing: \(path)"
        case .malformed: return "The registration file is unreadable"
        }
    }

    /// The install state line, shown only when it adds to the Installed and Bundled rows.
    var extensionStateNote: String? {
        if case .upToDate = extensionState { return nil }
        return extensionStateText
    }

    /// What to do when a connected profile runs an older or unknown extension. Chrome
    /// refuses programmatic chrome:// links, so this is an instruction, not a button.
    var reloadGuidance: String? {
        guard profiles.contains(where: { $0.reloadState != .current }) else { return nil }
        return "In chrome://extensions, press Reload on Webby in each profile that isn't Current."
    }

    /// Repair replaces an installed folder that can't be read.
    var needsRepair: Bool {
        extensionState == .invalid
    }

    /// Re-register writes a manifest that is missing or points somewhere else.
    var needsReRegister: Bool {
        switch registration {
        case .missing, .stale, .dangling, .malformed: return true
        case .current: return false
        }
    }

    static func reloadText(_ state: ExtensionReloadState) -> String {
        switch state {
        case .current: return "Current"
        case .reloadNeeded: return "Reload needed"
        case .unknown: return "Unknown"
        }
    }

    static func extensionState(outcome: BundledExtensionInstaller.Outcome?) -> ExtensionState {
        guard let outcome else { return .unknown }
        switch outcome {
        case .bundleMissing:
            return .missing
        case .bundleInvalid, .installationInvalid:
            return .invalid
        case .installed(_, let version), .unchanged(_, let version):
            return .upToDate(version.description)
        case .installedNewer(_, let version):
            return .newerInstalled(version.description)
        case .conflict:
            return .failed("The extension folder changed during install. It will retry next launch.")
        case .failed(let message):
            return .failed(message)
        }
    }

    private static func problemText(for state: ExtensionState) -> String? {
        switch state {
        case .invalid:
            return "The installed extension folder is invalid. Repair replaces it with the bundled copy."
        case .failed(let message):
            return message
        case .missing, .upToDate, .newerInstalled, .unknown:
            return nil
        }
    }

    /// "Allowed", "Not allowed", "Differs by profile", or nil when no profile is connected.
    static func incognitoSummary(_ access: [String: Bool]) -> String? {
        let values = Set(access.values)
        guard let only = values.first else { return nil }
        guard values.count == 1 else { return "Differs by profile" }
        return only ? "Allowed" : "Not allowed"
    }

    private func recomputeProfiles() {
        incognitoText = Self.incognitoSummary(incognitoAccess()) ?? "Not connected"
        let bundled = bundledVersion()
        profiles = status.connections.map { connection in
            ProfileRow(
                connection: connection.connection,
                profile: connection.profile,
                reportedVersion: connection.extensionVersion,
                reloadState: Self.reloadState(for: connection, bundled: bundled)
            )
        }
        reloadState = status.reloadState(bundledVersion: bundled)
    }

    private static func reloadState(
        for connection: BridgeConnectionStatus,
        bundled: ExtensionVersion?
    ) -> ExtensionReloadState {
        guard let bundled,
              connection.hasHello,
              let reported = connection.extensionVersion,
              let version = ExtensionVersion(reported)
        else { return .unknown }
        guard version < bundled else { return .current }
        return .reloadNeeded(reported: reported, bundled: bundled.description)
    }
}

struct ChromeSettingsView: View {
    let model: ChromeSettingsModel

    var body: some View {
        Form {
            Section("Extension folder") {
                Text(model.extensionFolder.path)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Copy Path") { model.copyExtensionPath() }
                    Button("Reveal in Finder") { model.revealFolder() }
                    if model.copied {
                        Text("Copied")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Installed", value: model.installedVersionText)
                LabeledContent("Bundled", value: model.bundledVersionText)
                if let note = model.extensionStateNote {
                    Text(note)
                        .font(.callout)
                        .foregroundStyle(model.problemText == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                }
            }

            Section("Set up") {
                Text("Webby installs its Chrome extension here. Chrome loads it from this folder, so it survives restarts.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("1. Move Webby to Applications and open it from there.")
                Text("2. Open chrome://extensions in Chrome.")
                Text("3. Turn on Developer mode.")
                Text("4. Choose Load unpacked and select the folder above.")
                LabeledContent("Expected extension ID") {
                    Text(model.expectedExtensionID)
                        .textSelection(.enabled)
                }
            }

            Section("Connected profiles") {
                if model.profiles.isEmpty {
                    Text("No Chrome profile is connected.")
                        .foregroundStyle(.secondary)
                } else {
                    if let guidance = model.reloadGuidance {
                        Text(guidance)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(model.profiles) { row in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.profile)
                                if let version = row.reportedVersion {
                                    Text("Version \(version)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Text(ChromeSettingsModel.reloadText(row.reloadState))
                                .foregroundStyle(row.reloadState == .current ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                        }
                    }
                }
                LabeledContent("Extension in Incognito", value: model.incognitoText)
                Text("Incognito windows show only notes for Chrome itself. Web notes never appear there.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Troubleshooting") {
                LabeledContent("Bridge registration", value: model.registrationText)
                if model.needsRepair {
                    Button("Repair Extension") { model.repairExtension() }
                }
                if model.needsReRegister {
                    Button("Re-register Bridge") { model.reRegisterHost() }
                }
                if let problem = model.registrationProblem {
                    Text(problem)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let problem = model.problemText {
                    Text(problem)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}
