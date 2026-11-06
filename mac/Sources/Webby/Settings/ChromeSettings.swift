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

    init(
        extensionFolder: @escaping @MainActor () -> URL = { BridgeConstants.extensionDirectory },
        bundledVersion: @escaping @MainActor () -> ExtensionVersion? = { nil },
        installedVersion: @escaping @MainActor () -> ExtensionVersion? = { nil },
        extensionOutcome: @escaping @MainActor () -> BundledExtensionInstaller.Outcome? = { nil },
        hostInspection: @escaping @MainActor () -> NativeHostInstaller.Inspection = { .missing }
    ) {
        self.folder = extensionFolder
        self.bundledVersion = bundledVersion
        self.installedVersion = installedVersion
        self.extensionOutcome = extensionOutcome
        self.hostInspection = hostInspection
        extensionFolder = extensionFolder()
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
        problemText = Self.problemText(for: extensionState)
        recomputeProfiles()
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

    private func recomputeProfiles() {
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
                Text(model.extensionStateText)
                    .font(.callout)
                    .foregroundStyle(model.problemText == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
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
            }

            Section("Troubleshooting") {
                LabeledContent("Bridge registration", value: model.registrationText)
                if model.needsRepair {
                    Button("Repair Extension") { model.repairExtension() }
                }
                if model.needsReRegister {
                    Button("Re-register Bridge") { model.reRegisterHost() }
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
