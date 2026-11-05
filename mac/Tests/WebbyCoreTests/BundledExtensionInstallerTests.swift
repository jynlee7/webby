import Foundation
import Testing
@testable import WebbyCore

@Suite struct BundledExtensionInstallerTests {
    private let root: URL
    private let bundle: URL
    private let support: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WebbyBundledExtensionInstallerTests-\(UUID().uuidString)", isDirectory: true)
        bundle = root.appendingPathComponent("Webby.app/Contents/Resources/Extension", isDirectory: true)
        support = root.appendingPathComponent("Support/Webby", isDirectory: true)
        try writePayload(at: bundle, version: "0.2.0")
    }

    private func writePayload(at folder: URL, version: String, extra: String? = nil) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"manifest_version":3,"name":"Webby","version":"\#(version)"}"#.utf8)
            .write(to: folder.appendingPathComponent("manifest.json"))
        try Data("// background \(version)\n".utf8).write(to: folder.appendingPathComponent("background.js"))
        try Data("// protocol \(version)\n".utf8).write(to: folder.appendingPathComponent("protocol.js"))
        if let extra {
            try Data().write(to: folder.appendingPathComponent(extra))
        }
    }

    private func installer(_ operations: BundledExtensionInstaller.Operations = .fileManager) -> BundledExtensionInstaller {
        BundledExtensionInstaller(bundleDirectory: bundle, supportDirectory: support, operations: operations)
    }

    private var installed: URL { support.appendingPathComponent("Extension", isDirectory: true) }

    private func installedVersion() throws -> String? {
        let data = try Data(contentsOf: installed.appendingPathComponent("manifest.json"))
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["version"] as? String
    }

    private func entries(_ folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    private func cleanUp() { try? FileManager.default.removeItem(at: root) }

    private static func version(_ string: String) -> ExtensionVersion { ExtensionVersion(string)! }

    // MARK: - Versions

    @Test func versionsCompareNumericallyWithZeroPadding() {
        #expect(Self.version("0.9") < Self.version("0.10"))
        #expect(Self.version("1.0") == Self.version("1.0.0"))
        #expect(Self.version("1.2.3.4") > Self.version("1.2.3"))
        #expect(Self.version("65535") > Self.version("9.9.9.9"))
        #expect(Self.version("0.1.0").description == "0.1.0")
    }

    @Test(arguments: ["", "1.", ".1", "1..2", "-1", "+1", "1a", "1.2.3.4.5", "65536", " 1", "١"])
    func malformedVersionsAreRejected(_ string: String) {
        #expect(ExtensionVersion(string) == nil)
    }

    // MARK: - Install rules

    @Test func freshInstallCopiesExactlyThePayload() throws {
        defer { cleanUp() }
        #expect(installer().install() == .installed(installed, Self.version("0.2.0")))
        #expect(try entries(installed) == BundledExtensionInstaller.payloadFiles)
        #expect(try entries(support) == ["Extension"])
        let mode = try FileManager.default.attributesOfItem(atPath: installed.appendingPathComponent("background.js").path)[.posixPermissions] as? Int
        #expect(mode == 0o644)
        for name in BundledExtensionInstaller.payloadFiles {
            #expect(try Data(contentsOf: installed.appendingPathComponent(name)) == Data(contentsOf: bundle.appendingPathComponent(name)))
        }
    }

    @Test func equalVersionIsANoOp() throws {
        defer { cleanUp() }
        _ = installer().install()
        let manifest = installed.appendingPathComponent("manifest.json")
        let before = try FileManager.default.attributesOfItem(atPath: manifest.path)[.modificationDate] as? Date
        try Data("// edited locally\n".utf8).write(to: installed.appendingPathComponent("background.js"))
        let edited = try Data(contentsOf: installed.appendingPathComponent("background.js"))

        #expect(installer().install() == .unchanged(installed, Self.version("0.2.0")))
        #expect(try FileManager.default.attributesOfItem(atPath: manifest.path)[.modificationDate] as? Date == before)
        #expect(try Data(contentsOf: installed.appendingPathComponent("background.js")) == edited)
    }

    @Test func olderInstallationIsReplacedAndNothingIsLeftBehind() throws {
        defer { cleanUp() }
        try writePayload(at: installed, version: "0.1.0")
        #expect(installer().install() == .installed(installed, Self.version("0.2.0")))
        #expect(try installedVersion() == "0.2.0")
        #expect(try entries(support) == ["Extension"])
    }

    @Test func newerInstallationIsNeverDowngraded() throws {
        defer { cleanUp() }
        try writePayload(at: installed, version: "0.10.0")
        #expect(installer().install() == .installedNewer(installed, Self.version("0.10.0")))
        #expect(try installedVersion() == "0.10.0")
    }

    @Test func invalidInstallationIsPreservedUntilRepaired() throws {
        defer { cleanUp() }
        try writePayload(at: installed, version: "0.1.0", extra: "notes.txt")

        #expect(installer().install() == .installationInvalid(installed))
        #expect(try entries(installed).contains("notes.txt"))

        #expect(installer().repairInvalidInstallation() == .installed(installed, Self.version("0.2.0")))
        #expect(try entries(installed) == BundledExtensionInstaller.payloadFiles)
        let recovered = support.appendingPathComponent("Extension-invalid")
        #expect(try entries(recovered).contains("notes.txt"))
        #expect(try FileManager.default.attributesOfItem(atPath: recovered.path)[.posixPermissions] as? Int == 0o700)
    }

    @Test func incompleteOrMalformedInstallationsAreInvalid() throws {
        defer { cleanUp() }
        try writePayload(at: installed, version: "0.1.0")
        try FileManager.default.removeItem(at: installed.appendingPathComponent("protocol.js"))
        #expect(installer().install() == .installationInvalid(installed))

        try writePayload(at: installed, version: "not a version")
        #expect(installer().install() == .installationInvalid(installed))
    }

    @Test func symlinkedInstallFolderIsRefusedAndItsTargetUntouched() throws {
        defer { cleanUp() }
        let elsewhere = root.appendingPathComponent("Elsewhere", isDirectory: true)
        try writePayload(at: elsewhere, version: "0.1.0")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: installed, withDestinationURL: elsewhere)

        #expect(installer().install() == .installationInvalid(installed))
        #expect(try String(decoding: Data(contentsOf: elsewhere.appendingPathComponent("background.js")), as: UTF8.self) == "// background 0.1.0\n")
    }

    @Test func missingOrInvalidBundlesWriteNothing() throws {
        defer { cleanUp() }
        let missing = BundledExtensionInstaller(
            bundleDirectory: root.appendingPathComponent("Nowhere"), supportDirectory: support
        )
        #expect(missing.install() == .bundleMissing)

        try Data().write(to: bundle.appendingPathComponent("package.json"))
        #expect(installer().install() == .bundleInvalid)
        try FileManager.default.removeItem(at: bundle.appendingPathComponent("package.json"))

        let protocolFile = bundle.appendingPathComponent("protocol.js")
        try FileManager.default.removeItem(at: protocolFile)
        try FileManager.default.createSymbolicLink(at: protocolFile, withDestinationURL: bundle.appendingPathComponent("background.js"))
        #expect(installer().install() == .bundleInvalid)

        try writePayload(at: bundle, version: "1.0.0.0.0")
        try FileManager.default.removeItem(at: protocolFile)
        try Data("// protocol\n".utf8).write(to: protocolFile)
        #expect(installer().install() == .bundleInvalid)
        #expect(!FileManager.default.fileExists(atPath: installed.path))
    }

    // MARK: - Recovery

    @Test func interruptedCopyKeepsThePreviousInstallation() throws {
        defer { cleanUp() }
        try writePayload(at: installed, version: "0.1.0")
        var operations = BundledExtensionInstaller.Operations.fileManager
        operations.copyItem = { from, to in
            if from.lastPathComponent == "protocol.js" { throw CocoaError(.fileWriteOutOfSpace) }
            try FileManager.default.copyItem(at: from, to: to)
        }

        guard case .failed = installer(operations).install() else {
            Issue.record("expected a failure")
            return
        }
        #expect(try installedVersion() == "0.1.0")
        #expect(try entries(support) == ["Extension"])
    }

    @Test func interruptedSwapRestoresThePreviousInstallation() throws {
        defer { cleanUp() }
        try writePayload(at: installed, version: "0.1.0")
        var operations = BundledExtensionInstaller.Operations.fileManager
        operations.moveItem = { from, to in
            if from.lastPathComponent == ".Extension-staging" { throw CocoaError(.fileWriteUnknown) }
            try FileManager.default.moveItem(at: from, to: to)
        }

        guard case .failed = installer(operations).install() else {
            Issue.record("expected a failure")
            return
        }
        #expect(try installedVersion() == "0.1.0")
        #expect(try entries(support) == ["Extension"])
    }

    @Test func crashMidSwapIsRecoveredFromThePreviousFolder() throws {
        defer { cleanUp() }
        try writePayload(at: support.appendingPathComponent(".Extension-previous"), version: "0.2.0")
        try writePayload(at: support.appendingPathComponent(".Extension-staging"), version: "0.2.0", extra: "partial")

        #expect(installer().install() == .unchanged(installed, Self.version("0.2.0")))
        #expect(try entries(installed) == BundledExtensionInstaller.payloadFiles)
    }

    @Test func staleStagingIsReplaced() throws {
        defer { cleanUp() }
        try writePayload(at: support.appendingPathComponent(".Extension-staging"), version: "9.9.9", extra: "partial")
        #expect(installer().install() == .installed(installed, Self.version("0.2.0")))
        #expect(try entries(support) == ["Extension"])
    }

    @Test func anotherLaunchInstallingMeanwhileIsAConflict() throws {
        defer { cleanUp() }
        let installedFolder = installed
        var operations = BundledExtensionInstaller.Operations.fileManager
        operations.copyItem = { from, to in
            try FileManager.default.copyItem(at: from, to: to)
            if from.lastPathComponent == "protocol.js", !FileManager.default.fileExists(atPath: installedFolder.path) {
                // Simulate a concurrent launch that installs a newer copy mid-staging.
                try FileManager.default.createDirectory(at: installedFolder, withIntermediateDirectories: true)
                for name in BundledExtensionInstaller.payloadFiles {
                    try FileManager.default.copyItem(at: from.deletingLastPathComponent().appendingPathComponent(name),
                                                     to: installedFolder.appendingPathComponent(name))
                }
                try Data(#"{"version":"0.3.0"}"#.utf8).write(to: installedFolder.appendingPathComponent("manifest.json"))
            }
        }

        #expect(installer(operations).install() == .conflict(installed))
        #expect(try installedVersion() == "0.3.0")
        #expect(try entries(support) == ["Extension"])
    }

    @Test func theBundleIsNeverModified() throws {
        defer { cleanUp() }
        let before = try BundledExtensionInstaller.payloadFiles.map { try Data(contentsOf: bundle.appendingPathComponent($0)) }
        try writePayload(at: installed, version: "0.1.0")
        _ = installer().install()
        _ = installer().repairInvalidInstallation()
        let after = try BundledExtensionInstaller.payloadFiles.map { try Data(contentsOf: bundle.appendingPathComponent($0)) }
        #expect(before == after)
        #expect(try entries(bundle) == BundledExtensionInstaller.payloadFiles)
    }
}
