import AppKit
import Foundation
import Testing
import WebbyCore
@testable import Webby

@MainActor
@Suite struct SkinAssetCacheTests {
    private let key = ResolvedImageKey(skinID: "io.example.skin", element: .noteBody, appearance: .light, scale: .one)

    private func makeSkinFolder() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("webby-assets-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("images", isDirectory: true),
            withIntermediateDirectories: true
        )
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: root.appendingPathComponent(key.relativeName))
        return root
    }

    @Test func lastGoodArtworkSurvivesABrokenEdit() throws {
        let root = try makeSkinFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = SkinAssetCache(folder: { _ in root })
        #expect(cache.image(for: key, availableScales: [.one]) != nil)

        cache.keepLastGood(skinID: key.skinID)
        try FileManager.default.removeItem(at: root.appendingPathComponent(key.relativeName))
        #expect(cache.image(for: key, availableScales: [.one]) != nil)

        cache.invalidate(skinID: key.skinID)
        #expect(cache.image(for: key, availableScales: [.one]) == nil)
    }

    @Test func anAcceptedSkinRereadsItsFiles() throws {
        let root = try makeSkinFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = SkinAssetCache(folder: { _ in root })
        #expect(cache.image(for: key, availableScales: [.one]) != nil)

        try FileManager.default.removeItem(at: root.appendingPathComponent(key.relativeName))
        #expect(cache.image(for: key, availableScales: [.one]) == nil)
    }
}
