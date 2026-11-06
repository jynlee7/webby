import AppKit
import SwiftUI
import Testing
import WebbyCore
@testable import Webby

@MainActor
@Suite struct NoteArtworkContrastTests {
    @Test(arguments: [false, true], [false, true])
    func artworkCannotCoverTitleBacking(collapsed: Bool, increaseContrast: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("webby-contrast-\(UUID())")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("images"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = try JSONDecoder().decode(SkinManifest.self, from: Data("""
        {
          "formatVersion": 1, "id": "io.example.contrast", "name": "Contrast", "author": "Tests", "version": "1.0.0",
          "appearances": ["light", "dark"],
          "surface": {
            "fill": {"light": "#FFFFFF", "dark": "#000000"},
            "text": {"color": {"light": "#000000", "dark": "#FFFFFF"}},
            "material": "none", "cornerRadius": 0,
            "image": {"element": "note-body", "insets": {"top": 1, "left": 1, "bottom": 1, "right": 1}}
          },
          "header": {"height": 32, "fill": "#00000000", "showsTitle": true},
          "collapsed": {"height": 32, "showsFirstLine": true}
        }
        """.utf8))
        let paths: Set<String> = ["images/note-body.png", "images/note-body~dark.png"]
        for (path, white) in [("images/note-body.png", false), ("images/note-body~dark.png", true)] {
            let rep = try #require(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ))
            let component: CGFloat = white ? 1 : 0
            let color = NSColor(deviceRed: component, green: component, blue: component, alpha: 1)
            for y in 0..<8 { for x in 0..<8 { rep.setColor(color, atX: x, y: y) } }
            try #require(rep.representation(using: .png, properties: [:])).write(to: root.appendingPathComponent(path))
        }
        let skin = InstalledSkin(id: manifest.id, manifest: manifest, availableImagePaths: paths)
        let selection = SkinSelection(skins: [skin], availableBaseIDs: [])
            .select(workspaceSkinID: nil, globalSkinID: skin.id,
                    accessibility: AccessibilitySettings(increaseContrast: increaseContrast))
        let themes = NoteThemes(selection: selection)
        let assets = SkinAssetCache(folder: { _ in root })
        for (mode, scheme) in [(AppearanceMode.light, ColorScheme.light), (.dark, .dark)] {
            let theme = selection.resolution(for: mode).theme
            #expect(theme.surface.image != nil)
            #expect(theme.header.fill.a == 0)
            #expect(theme.collapsed.fill.a == 0)
            let passes = ContrastReport.pairs(theme: theme, appearance: mode).allSatisfy { $0.passes }
            #expect(passes)
            let model = NoteModel(id: UUID(), text: "Visible title", collapsed: collapsed, isEditable: false, themes: themes)
            let renderer = ImageRenderer(content: NoteView(model: model)
                .environment(\.webbyTheme, theme)
                .environment(\.skinAssetCache, assets)
                .environment(\.colorScheme, scheme)
                .frame(width: 240, height: collapsed ? 32 : 120))
            renderer.scale = 1
            let artwork = try #require(theme.surface.image)
            #expect(assets.image(for: artwork.key, availableScales: artwork.availableScales) != nil)
            let bitmap = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
            // Sample the control row’s horizontal padding, away from glyphs and
            // the AppKit drag area (which ImageRenderer cannot draw).
            let pixel = try #require(bitmap.colorAt(x: 3, y: 16)?.usingColorSpace(.deviceRGB))
            let background = try RGBAColor(r: pixel.redComponent, g: pixel.greenComponent, b: pixel.blueComponent, a: pixel.alphaComponent)
            #expect(background.a == 1)
            let ratio = try Contrast.contrastRatio(foreground: theme.surface.text, background: background)
            #expect(ratio >= 4.5, "\(mode), collapsed=\(collapsed), increaseContrast=\(increaseContrast)")
        }
    }
}
