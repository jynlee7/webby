import Foundation
import Testing
@testable import WebbyCore

private func makeTempDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("WebbyNativeHostInstallerTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

/// A stand-in bridge executable inside an app bundle under `root`.
private func makeBridge(in root: URL, appPath: String = "Applications/Webby.app") throws -> URL {
    let bridge = root.appendingPathComponent("\(appPath)/Contents/MacOS/webby-bridge")
    try FileManager.default.createDirectory(at: bridge.deletingLastPathComponent(), withIntermediateDirectories: true)
    #expect(FileManager.default.createFile(atPath: bridge.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755]))
    return bridge
}

private func makeChromeFolder(in root: URL) throws -> URL {
    let chrome = root.appendingPathComponent("Library/Application Support/Google/Chrome", isDirectory: true)
    try FileManager.default.createDirectory(at: chrome, withIntermediateDirectories: true)
    return chrome
}

@Test func manifestNamesTheBridgeAndAllowsOnlyTheWebbyExtension() throws {
    let data = try NativeHostInstaller.manifest(bridgePath: "/Applications/Webby.app/Contents/MacOS/webby-bridge")
    let json = try jsonObject(data)

    #expect(json["name"] as? String == BridgeConstants.hostName)
    #expect(json["path"] as? String == "/Applications/Webby.app/Contents/MacOS/webby-bridge")
    #expect(json["type"] as? String == "stdio")
    #expect(json["allowed_origins"] as? [String] == ["chrome-extension://ccehhpjcbcabmlalclppmdomonfdcbcl/"])
    #expect(json["description"] is String)
    #expect(json.count == 5)
    #expect(!String(decoding: data, as: UTF8.self).contains(#"\/"#))
}

@Test func installsTheManifestIntoAnExistingChromeFolder() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let bridge = try makeBridge(in: root)
    let chrome = try makeChromeFolder(in: root)
    let installer = NativeHostInstaller(bridgeExecutableURL: bridge, chromeSupportDirectory: chrome, policy: .development)

    #expect(installer.manifestURL == chrome.appendingPathComponent("NativeMessagingHosts/com.webby.bridge.json"))
    #expect(try installer.install() == .installed(installer.manifestURL))

    let json = try jsonObject(Data(contentsOf: installer.manifestURL))
    #expect(json["path"] as? String == bridge.path)
    #expect(json["allowed_origins"] as? [String] == [BridgeConstants.extensionOrigin])
}

@Test func reinstallingIsANoOpUntilTheBridgeMoves() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let chrome = try makeChromeFolder(in: root)
    let first = NativeHostInstaller(bridgeExecutableURL: try makeBridge(in: root), chromeSupportDirectory: chrome, policy: .development)

    #expect(try first.install() == .installed(first.manifestURL))
    #expect(try first.install() == .unchanged(first.manifestURL))

    let moved = try makeBridge(in: root, appPath: "Users/someone/Applications/Webby.app")
    let second = NativeHostInstaller(bridgeExecutableURL: moved, chromeSupportDirectory: chrome, policy: .development)
    #expect(try second.install() == .installed(second.manifestURL))
    #expect(try jsonObject(Data(contentsOf: second.manifestURL))["path"] as? String == moved.path)
}

@Test func missingChromeFolderCreatesNothing() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let bridge = try makeBridge(in: root)
    let google = root.appendingPathComponent("Library/Application Support/Google", isDirectory: true)
    let chrome = google.appendingPathComponent("Chrome", isDirectory: true)

    #expect(try NativeHostInstaller(bridgeExecutableURL: bridge, chromeSupportDirectory: chrome, policy: .development).install() == .chromeNotFound)
    #expect(!FileManager.default.fileExists(atPath: google.path))
}

@Test func aFileWhereChromesFolderShouldBeIsNotAChromeFolder() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let bridge = try makeBridge(in: root)
    let chrome = root.appendingPathComponent("Chrome")
    try Data().write(to: chrome)

    #expect(try NativeHostInstaller(bridgeExecutableURL: bridge, chromeSupportDirectory: chrome, policy: .development).install() == .chromeNotFound)
}

@Test func translocatedAppInstallsNothing() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let bridge = try makeBridge(in: root, appPath: "private/var/folders/xy/T/AppTranslocation/1A2B3C/d/Webby.app")
    let chrome = try makeChromeFolder(in: root)
    let installer = NativeHostInstaller(bridgeExecutableURL: bridge, chromeSupportDirectory: chrome, policy: .development)

    #expect(NativeHostInstaller.isTranslocated(bridge))
    #expect(try installer.install() == .translocated)
    #expect(!FileManager.default.fileExists(atPath: chrome.appendingPathComponent("NativeMessagingHosts").path))
}

@Test func missingBridgeInstallsNothing() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let chrome = try makeChromeFolder(in: root)
    let bridge = root.appendingPathComponent("Webby.app/Contents/MacOS/webby-bridge")

    #expect(try NativeHostInstaller(bridgeExecutableURL: bridge, chromeSupportDirectory: chrome, policy: .development).install() == .bridgeMissing)
    #expect(!FileManager.default.fileExists(atPath: chrome.appendingPathComponent("NativeMessagingHosts").path))
}

@Test func onlyAppTranslocationPathsCountAsTranslocated() {
    #expect(NativeHostInstaller.isTranslocated(URL(fileURLWithPath: "/private/var/folders/ab/cd/T/AppTranslocation/E5F6/d/Webby.app")))
    #expect(!NativeHostInstaller.isTranslocated(URL(fileURLWithPath: "/Applications/Webby.app/Contents/MacOS/webby-bridge")))
    #expect(!NativeHostInstaller.isTranslocated(URL(fileURLWithPath: "/Users/me/Downloads/Webby.app/Contents/MacOS/webby-bridge")))
}

// MARK: - Registration policy and recovery

private func releasePolicy(_ root: URL) -> RegistrationPolicy {
    RegistrationPolicy(allowedRoots: [
        root.appendingPathComponent("Applications", isDirectory: true),
        root.appendingPathComponent("Users/me/Applications", isDirectory: true),
    ])
}

@Test func releasePolicyAllowsOnlyApplicationsFolders() {
    let home = URL(fileURLWithPath: "/Users/me", isDirectory: true)
    let policy = RegistrationPolicy.release(home: home)
    func allows(_ app: String) -> Bool {
        policy.allowsRegistration(forBridge: URL(fileURLWithPath: "\(app)/Contents/MacOS/webby-bridge"))
    }

    #expect(allows("/Applications/Webby.app"))
    #expect(allows("/applications/Webby.app"))
    #expect(allows("/Applications/Utilities/Webby.app"))
    #expect(allows("/Users/me/Applications/Webby.app"))
    #expect(!allows("/Applications2/Webby.app"))
    #expect(!allows("/Users/me/Downloads/Webby.app"))
    #expect(!allows("/Volumes/Webby/Webby.app"))
    #expect(!allows("/Users/me/Library/Developer/Xcode/DerivedData/Webby/Build/Products/Release/Webby.app"))
    #expect(!allows("/Applications/../Users/me/Downloads/Webby.app"))
    #expect(!allows("/private/var/folders/ab/T/AppTranslocation/E5F6/d/Webby.app"))
    #expect(RegistrationPolicy.appBundle(forBridge: URL(fileURLWithPath: "/Applications/Webby.app/Contents/MacOS/webby-bridge")).path == "/Applications/Webby.app")
}

@Test func developmentPolicyAllowsAnyNonTranslocatedPath() {
    #expect(RegistrationPolicy.development.allowsRegistration(forBridge: URL(fileURLWithPath: "/Users/me/src/webby/dist/Webby.app/Contents/MacOS/webby-bridge")))
    #expect(!RegistrationPolicy.development.allowsRegistration(forBridge: URL(fileURLWithPath: "/private/var/folders/ab/T/AppTranslocation/E5F6/d/Webby.app/Contents/MacOS/webby-bridge")))
}

@Test func onlyTheStagedDevelopmentKeySelectsTheDevelopmentPolicy() {
    let home = URL(fileURLWithPath: "/Users/me", isDirectory: true)
    #expect(RegistrationPolicy.forApp(infoDictionary: ["WebbyDevelopmentBuild": true], home: home) == .development)
    #expect(RegistrationPolicy.forApp(infoDictionary: ["WebbyDevelopmentBuild": false], home: home) == .release(home: home))
    #expect(RegistrationPolicy.forApp(infoDictionary: ["WebbyDevelopmentBuild": "true"], home: home) == .release(home: home))
    #expect(RegistrationPolicy.forApp(infoDictionary: [:], home: home) == .release(home: home))
    #expect(RegistrationPolicy.forApp(infoDictionary: nil, home: home) == .release(home: home))
}

@Test func unstableLaunchPreservesAWorkingRegistrationByteForByte() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let chrome = try makeChromeFolder(in: root)
    let approved = NativeHostInstaller(bridgeExecutableURL: try makeBridge(in: root), chromeSupportDirectory: chrome, policy: releasePolicy(root))
    #expect(try approved.install() == .installed(approved.manifestURL))
    let before = try Data(contentsOf: approved.manifestURL)

    let downloads = NativeHostInstaller(bridgeExecutableURL: try makeBridge(in: root, appPath: "Users/me/Downloads/Webby.app"), chromeSupportDirectory: chrome, policy: releasePolicy(root))
    #expect(try downloads.install() == .preservedExisting(downloads.manifestURL))
    let translocated = NativeHostInstaller(bridgeExecutableURL: try makeBridge(in: root, appPath: "private/var/folders/T/AppTranslocation/1A/d/Webby.app"), chromeSupportDirectory: chrome, policy: releasePolicy(root))
    #expect(try translocated.install() == .preservedExisting(translocated.manifestURL))

    #expect(try Data(contentsOf: approved.manifestURL) == before)
    #expect(!FileManager.default.fileExists(atPath: approved.backupURL.path))
}

@Test func unstableLaunchWithADanglingManifestWritesNothing() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let chrome = try makeChromeFolder(in: root)
    let hosts = chrome.appendingPathComponent("NativeMessagingHosts", isDirectory: true)
    try FileManager.default.createDirectory(at: hosts, withIntermediateDirectories: true)
    let dangling = try NativeHostInstaller.manifest(bridgePath: root.appendingPathComponent("Applications/Gone.app/Contents/MacOS/webby-bridge").path)
    try dangling.write(to: hosts.appendingPathComponent("com.webby.bridge.json"))

    let installer = NativeHostInstaller(bridgeExecutableURL: try makeBridge(in: root, appPath: "Volumes/Image/Webby.app"), chromeSupportDirectory: chrome, policy: releasePolicy(root))
    #expect(try installer.install() == .unstableLocation)
    #expect(try Data(contentsOf: installer.manifestURL) == dangling)
    #expect(try FileManager.default.contentsOfDirectory(atPath: hosts.path) == ["com.webby.bridge.json"])
}

@Test func unstableLaunchWithoutARegistrationInstallsNothing() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let chrome = try makeChromeFolder(in: root)
    let installer = NativeHostInstaller(bridgeExecutableURL: try makeBridge(in: root, appPath: "Users/me/Downloads/Webby.app"), chromeSupportDirectory: chrome, policy: releasePolicy(root))

    #expect(try installer.install() == .unstableLocation)
    #expect(!FileManager.default.fileExists(atPath: chrome.appendingPathComponent("NativeMessagingHosts").path))
}

@Test(arguments: ["stale", "dangling", "malformed"])
func approvedLaunchBacksUpAndRewritesABrokenManifest(_ state: String) throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let chrome = try makeChromeFolder(in: root)
    let hosts = chrome.appendingPathComponent("NativeMessagingHosts", isDirectory: true)
    try FileManager.default.createDirectory(at: hosts, withIntermediateDirectories: true)
    let old: Data
    switch state {
    case "stale":
        old = try NativeHostInstaller.manifest(bridgePath: try makeBridge(in: root, appPath: "Applications/Old/Webby.app").path)
    case "dangling":
        old = try NativeHostInstaller.manifest(bridgePath: root.appendingPathComponent("Applications/Gone.app/Contents/MacOS/webby-bridge").path)
    default:
        old = Data("not json".utf8)
    }
    let installer = NativeHostInstaller(bridgeExecutableURL: try makeBridge(in: root), chromeSupportDirectory: chrome, policy: releasePolicy(root))
    try old.write(to: installer.manifestURL)

    #expect(try installer.install() == .installed(installer.manifestURL))
    #expect(try Data(contentsOf: installer.backupURL) == old)
    #expect(try FileManager.default.attributesOfItem(atPath: installer.backupURL.path)[.posixPermissions] as? Int == 0o600)
    #expect(installer.inspect() == .current(installer.manifestURL))
}

@Test func unchangedInstallWritesNoBackup() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let chrome = try makeChromeFolder(in: root)
    let installer = NativeHostInstaller(bridgeExecutableURL: try makeBridge(in: root), chromeSupportDirectory: chrome, policy: releasePolicy(root))

    #expect(try installer.install() == .installed(installer.manifestURL))
    #expect(try installer.install() == .unchanged(installer.manifestURL))
    #expect(!FileManager.default.fileExists(atPath: installer.backupURL.path))
}

@Test func failedBackupLeavesTheManifestUntouched() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let chrome = try makeChromeFolder(in: root)
    let installer = NativeHostInstaller(bridgeExecutableURL: try makeBridge(in: root), chromeSupportDirectory: chrome, policy: releasePolicy(root))
    try FileManager.default.createDirectory(at: installer.manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let old = Data("not json".utf8)
    try old.write(to: installer.manifestURL)
    // A folder where the backup goes makes the backup write fail.
    try FileManager.default.createDirectory(at: installer.backupURL.appendingPathComponent("blocker"), withIntermediateDirectories: true)

    #expect(throws: (any Error).self) { try installer.install() }
    #expect(try Data(contentsOf: installer.manifestURL) == old)
}

@Test func inspectReportsEachState() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let chrome = try makeChromeFolder(in: root)
    let installer = NativeHostInstaller(bridgeExecutableURL: try makeBridge(in: root), chromeSupportDirectory: chrome, policy: releasePolicy(root))
    #expect(installer.inspect() == .missing)

    _ = try installer.install()
    #expect(installer.inspect() == .current(installer.manifestURL))

    let other = try makeBridge(in: root, appPath: "Users/me/Applications/Webby.app")
    try NativeHostInstaller.manifest(bridgePath: other.path).write(to: installer.manifestURL)
    #expect(installer.inspect() == .stale(path: other.path))

    try FileManager.default.removeItem(at: other)
    #expect(installer.inspect() == .dangling(path: other.path))

    let foreign = try JSONSerialization.data(withJSONObject: [
        "name": "com.example.host", "path": installer.bridgeExecutableURL.path, "type": "stdio",
        "allowed_origins": [BridgeConstants.extensionOrigin], "description": "x",
    ])
    try foreign.write(to: installer.manifestURL)
    #expect(installer.inspect() == .malformed)
}

@Test func unreadableManifestIsNeverReplacedWithoutABackup() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let chrome = try makeChromeFolder(in: root)
    let installer = NativeHostInstaller(bridgeExecutableURL: try makeBridge(in: root), chromeSupportDirectory: chrome, policy: releasePolicy(root))
    try FileManager.default.createDirectory(at: installer.manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("old".utf8).write(to: installer.manifestURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: installer.manifestURL.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: installer.manifestURL.path) }

    #expect(throws: (any Error).self) { try installer.install() }
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: installer.manifestURL.path)
    #expect(try Data(contentsOf: installer.manifestURL) == Data("old".utf8))
    #expect(!FileManager.default.fileExists(atPath: installer.backupURL.path))
}
