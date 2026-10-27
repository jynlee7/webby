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
    let installer = NativeHostInstaller(bridgeExecutableURL: bridge, chromeSupportDirectory: chrome)

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
    let first = NativeHostInstaller(bridgeExecutableURL: try makeBridge(in: root), chromeSupportDirectory: chrome)

    #expect(try first.install() == .installed(first.manifestURL))
    #expect(try first.install() == .unchanged(first.manifestURL))

    let moved = try makeBridge(in: root, appPath: "Users/someone/Applications/Webby.app")
    let second = NativeHostInstaller(bridgeExecutableURL: moved, chromeSupportDirectory: chrome)
    #expect(try second.install() == .installed(second.manifestURL))
    #expect(try jsonObject(Data(contentsOf: second.manifestURL))["path"] as? String == moved.path)
}

@Test func missingChromeFolderCreatesNothing() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let bridge = try makeBridge(in: root)
    let google = root.appendingPathComponent("Library/Application Support/Google", isDirectory: true)
    let chrome = google.appendingPathComponent("Chrome", isDirectory: true)

    #expect(try NativeHostInstaller(bridgeExecutableURL: bridge, chromeSupportDirectory: chrome).install() == .chromeNotFound)
    #expect(!FileManager.default.fileExists(atPath: google.path))
}

@Test func aFileWhereChromesFolderShouldBeIsNotAChromeFolder() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let bridge = try makeBridge(in: root)
    let chrome = root.appendingPathComponent("Chrome")
    try Data().write(to: chrome)

    #expect(try NativeHostInstaller(bridgeExecutableURL: bridge, chromeSupportDirectory: chrome).install() == .chromeNotFound)
}

@Test func translocatedAppInstallsNothing() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let bridge = try makeBridge(in: root, appPath: "private/var/folders/xy/T/AppTranslocation/1A2B3C/d/Webby.app")
    let chrome = try makeChromeFolder(in: root)
    let installer = NativeHostInstaller(bridgeExecutableURL: bridge, chromeSupportDirectory: chrome)

    #expect(NativeHostInstaller.isTranslocated(bridge))
    #expect(try installer.install() == .translocated)
    #expect(!FileManager.default.fileExists(atPath: chrome.appendingPathComponent("NativeMessagingHosts").path))
}

@Test func missingBridgeInstallsNothing() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let chrome = try makeChromeFolder(in: root)
    let bridge = root.appendingPathComponent("Webby.app/Contents/MacOS/webby-bridge")

    #expect(try NativeHostInstaller(bridgeExecutableURL: bridge, chromeSupportDirectory: chrome).install() == .bridgeMissing)
    #expect(!FileManager.default.fileExists(atPath: chrome.appendingPathComponent("NativeMessagingHosts").path))
}

@Test func onlyAppTranslocationPathsCountAsTranslocated() {
    #expect(NativeHostInstaller.isTranslocated(URL(fileURLWithPath: "/private/var/folders/ab/cd/T/AppTranslocation/E5F6/d/Webby.app")))
    #expect(!NativeHostInstaller.isTranslocated(URL(fileURLWithPath: "/Applications/Webby.app/Contents/MacOS/webby-bridge")))
    #expect(!NativeHostInstaller.isTranslocated(URL(fileURLWithPath: "/Users/me/Downloads/Webby.app/Contents/MacOS/webby-bridge")))
}
