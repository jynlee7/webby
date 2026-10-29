import AppKit
import SwiftUI
import WebbyCore

/// The resolved note look for both appearances, as `SkinStore` selects it for one note.
struct NoteThemes: Sendable, Equatable {
    var light: ResolvedTheme
    var dark: ResolvedTheme
    var effectiveSkinID: String
    /// Palette slots the effective skin offers; zero hides the Color menu.
    var paletteSlotCount: Int
    var hasDecoration: Bool
    /// The palette of the light look, for slot swatches.
    var palette: [RGBAColor]
    /// Bumped by every skin reload so artwork edited in place redraws even when the
    /// resolved values are equal.
    var revision: Int

    /// The skins shipped in the app bundle.
    static let builtInIDs = ["webby.clear", "webby.mono"]

    /// Without any skin folder the resolver still returns its terminal fallback, so a
    /// note always has a complete, readable look.
    static let fallback = NoteThemes(
        selection: SkinSelection(skins: [], availableBaseIDs: []).select(workspaceSkinID: nil, globalSkinID: nil)
    )

    func theme(for scheme: ColorScheme) -> ResolvedTheme {
        scheme == .dark ? dark : light
    }

    /// The taller of the two collapsed bars, so a bar never changes height when the
    /// system appearance does.
    var collapsedHeight: Double {
        max(light.collapsed.height, dark.collapsed.height)
    }

    init(selection: SkinSelectionResult, revision: Int = 0) {
        light = selection.light.theme
        dark = selection.dark.theme
        effectiveSkinID = selection.effectiveSkinID
        paletteSlotCount = selection.paletteSlotCount
        hasDecoration = selection.hasDecoration
        palette = selection.light.theme.palette
        self.revision = revision
    }

    /// The system's Reduce Transparency, Increase Contrast and Reduce Motion settings.
    @MainActor
    static var systemAccessibility: WebbyCore.AccessibilitySettings {
        let workspace = NSWorkspace.shared
        return WebbyCore.AccessibilitySettings(
            reduceTransparency: workspace.accessibilityDisplayShouldReduceTransparency,
            increaseContrast: workspace.accessibilityDisplayShouldIncreaseContrast,
            reduceMotion: workspace.accessibilityDisplayShouldReduceMotion
        )
    }

    static var bundledSkinsDirectory: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("Skins", isDirectory: true)
    }
}

// Hand-written rather than with SwiftUI's Entry macro, whose plugin ships only with Xcode (plan §5.4.8).
private struct WebbyThemeKey: EnvironmentKey {
    static let defaultValue: ResolvedTheme = NoteThemes.fallback.light
}

extension EnvironmentValues {
    var webbyTheme: ResolvedTheme {
        get { self[WebbyThemeKey.self] }
        set { self[WebbyThemeKey.self] = newValue }
    }
}

extension Color {
    init(_ color: RGBAColor) {
        self.init(.sRGB, red: color.r, green: color.g, blue: color.b, opacity: color.a)
    }
}

extension NSColor {
    convenience init(_ color: RGBAColor) {
        self.init(srgbRed: color.r, green: color.g, blue: color.b, alpha: color.a)
    }
}

extension ResolvedTypography {
    var nsFont: NSFont {
        let size = CGFloat(effectiveSize)
        if let family, let font = NSFont(name: family, size: size) {
            return font
        }
        return NSFont.systemFont(ofSize: size, weight: nsWeight)
    }

    var swiftUIFont: Font {
        if let family { return .custom(family, size: effectiveSize) }
        return .system(size: effectiveSize, weight: swiftUIWeight)
    }

    private var nsWeight: NSFont.Weight {
        guard case .known(let known) = weight else { return .regular }
        switch known {
        case .ultraLight: return .ultraLight
        case .thin: return .thin
        case .light: return .light
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        }
    }

    private var swiftUIWeight: Font.Weight {
        guard case .known(let known) = weight else { return .regular }
        switch known {
        case .ultraLight: return .ultraLight
        case .thin: return .thin
        case .light: return .light
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        }
    }
}

extension SkinMaterial {
    /// The system material behind the note, or nil for none (including when Reduce
    /// Transparency has turned it off).
    var visualEffectMaterial: NSVisualEffectView.Material? {
        guard case .known(let known) = self else { return nil }
        switch known {
        case .none: return nil
        case .titlebar: return .titlebar
        case .selection: return .selection
        case .menu: return .menu
        case .popover: return .popover
        case .sidebar: return .sidebar
        case .headerView: return .headerView
        case .sheet: return .sheet
        case .windowBackground: return .windowBackground
        case .hudWindow: return .hudWindow
        case .fullScreenUI: return .fullScreenUI
        case .toolTip: return .toolTip
        case .contentBackground: return .contentBackground
        case .underWindowBackground: return .underWindowBackground
        case .underPageBackground: return .underPageBackground
        }
    }
}

extension SkinVisibility {
    func isShown(hovering: Bool) -> Bool {
        switch self {
        case .known(.always): return true
        case .known(.hover): return hovering
        case .known(.never), .unknown: return false
        }
    }
}

/// The blur behind a note. `maskImage` rounds it, because a behind-window blur ignores
/// layer clipping, and the system shadow follows the same corners.
struct VisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let cornerRadius: Double

    func makeNSView(context: NSViewRepresentableContext<Self>) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        // Active even while another app is frontmost, so notes aren't dimmed.
        view.state = .active
        update(view)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: NSViewRepresentableContext<Self>) {
        update(view)
    }

    private func update(_ view: NSVisualEffectView) {
        view.material = material
        view.maskImage = NotePanel.roundedMask(radius: cornerRadius)
    }
}
