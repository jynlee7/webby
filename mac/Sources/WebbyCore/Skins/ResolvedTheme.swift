import Foundation

/// The logical identity of one image asset after appearance and scale resolution.
public struct ResolvedImageKey: Sendable, Equatable, Hashable {
    public let skinID: String
    public let element: SkinImageElement
    public let appearance: SkinAppearance
    public let scale: SkinScale

    public init(
        skinID: String,
        element: SkinImageElement,
        appearance: SkinAppearance,
        scale: SkinScale
    ) {
        self.skinID = skinID
        self.element = element
        self.appearance = appearance
        self.scale = scale
    }

    /// The package-relative image name. This is a logical name, not a path on disk.
    public var relativeName: String {
        var name = element.rawValue
        if appearance == .dark {
            name += "~dark"
        }
        if scale == .two {
            name += "@2x"
        }
        return "images/\(name).png"
    }
}

/// An image key together with the scale variants the package actually provides.
public struct ResolvedImage: Sendable, Equatable, Hashable {
    public let key: ResolvedImageKey
    public let availableScales: Set<SkinScale>

    public init(key: ResolvedImageKey, availableScales: Set<SkinScale> = []) {
        self.key = key
        self.availableScales = availableScales.isEmpty ? [key.scale] : availableScales
    }
}

/// A nine-slice surface image reference.
public struct ResolvedSurfaceImage: Sendable, Equatable, Hashable {
    public let key: ResolvedImageKey
    public let availableScales: Set<SkinScale>
    public let insets: SkinInsets
    public let mode: SkinImageMode
    public let tintWithPalette: Bool

    public init(
        key: ResolvedImageKey,
        availableScales: Set<SkinScale> = [],
        insets: SkinInsets = SkinInsets(),
        mode: SkinImageMode = .known(.stretch),
        tintWithPalette: Bool = false
    ) {
        self.key = key
        self.availableScales = availableScales.isEmpty ? [key.scale] : availableScales
        self.insets = insets
        self.mode = mode
        self.tintWithPalette = tintWithPalette
    }
}

public struct ResolvedBorder: Sendable, Equatable, Hashable {
    public let width: Double
    public let color: RGBAColor

    public init(width: Double = 0, color: RGBAColor = .clear) {
        self.width = width
        self.color = color
    }
}

/// An opaque backing the renderer paints above surface artwork and below body text.
///
/// Two values exist because the page behind a translucent note is unknown: the
/// surface was checked composited over both black and white. Rendering one backing
/// for both would overstate the guarantee.
public struct ResolvedContrastBacking: Sendable, Equatable, Hashable {
    public let overBlack: RGBAColor
    public let overWhite: RGBAColor

    public init(overBlack: RGBAColor, overWhite: RGBAColor) {
        self.overBlack = overBlack
        self.overWhite = overWhite
    }

    public static let white = ResolvedContrastBacking(overBlack: .white, overWhite: .white)
}

public struct ResolvedSurface: Sendable, Equatable, Hashable {
    public let fill: RGBAColor
    public let contrastBacking: ResolvedContrastBacking
    public let material: SkinMaterial
    public let image: ResolvedSurfaceImage?
    public let cornerRadius: Double
    public let border: ResolvedBorder
    public let shadow: SkinShadow
    public let padding: SkinInsets
    public let text: RGBAColor
    public let placeholder: RGBAColor
    public let selection: RGBAColor
    public let caret: RGBAColor

    public init(
        fill: RGBAColor,
        contrastBacking: ResolvedContrastBacking,
        material: SkinMaterial = .known(.none),
        image: ResolvedSurfaceImage? = nil,
        cornerRadius: Double = 0,
        border: ResolvedBorder = ResolvedBorder(),
        shadow: SkinShadow = .known(.none),
        padding: SkinInsets = SkinInsets(),
        text: RGBAColor = .black,
        placeholder: RGBAColor = .black,
        selection: RGBAColor = .clear,
        caret: RGBAColor = .black
    ) {
        self.fill = fill
        self.contrastBacking = contrastBacking
        self.material = material
        self.image = image
        self.cornerRadius = cornerRadius
        self.border = border
        self.shadow = shadow
        self.padding = padding
        self.text = text
        self.placeholder = placeholder
        self.selection = selection
        self.caret = caret
    }
}

public struct ResolvedTypography: Sendable, Equatable, Hashable {
    public let family: String?
    public let effectiveSize: Double
    public let weight: SkinFontWeight
    public let lineSpacing: Double

    public init(
        family: String? = nil,
        effectiveSize: Double,
        weight: SkinFontWeight = .known(.regular),
        lineSpacing: Double = 0
    ) {
        self.family = family
        self.effectiveSize = effectiveSize
        self.weight = weight
        self.lineSpacing = lineSpacing
    }
}

public struct ResolvedHeader: Sendable, Equatable, Hashable {
    public let height: Double
    public let fill: RGBAColor
    public let showsTitle: Bool
    public let image: ResolvedImage?

    public init(
        height: Double,
        fill: RGBAColor,
        showsTitle: Bool,
        image: ResolvedImage? = nil
    ) {
        self.height = height
        self.fill = fill
        self.showsTitle = showsTitle
        self.image = image
    }
}

public struct ResolvedCollapsed: Sendable, Equatable, Hashable {
    public let height: Double
    public let fill: RGBAColor
    public let showsFirstLine: Bool
    public let image: ResolvedImage?

    public init(
        height: Double,
        fill: RGBAColor,
        showsFirstLine: Bool,
        image: ResolvedImage? = nil
    ) {
        self.height = height
        self.fill = fill
        self.showsFirstLine = showsFirstLine
        self.image = image
    }
}

public struct ResolvedOffset: Sendable, Equatable, Hashable {
    public let x: Double
    public let y: Double

    public init(x: Double = 0, y: Double = 0) {
        self.x = x
        self.y = y
    }
}

public struct ResolvedDecoration: Sendable, Equatable, Hashable {
    public let image: ResolvedImage?
    public let anchor: SkinAlignment
    public let origin: SkinAlignment
    public let offset: ResolvedOffset
    public let rotation: Double
    public let hidden: Bool

    public init(
        image: ResolvedImage? = nil,
        anchor: SkinAlignment = .known(.topCenter),
        origin: SkinAlignment = .known(.center),
        offset: ResolvedOffset = ResolvedOffset(),
        rotation: Double = 0,
        hidden: Bool = false
    ) {
        self.image = image
        self.anchor = anchor
        self.origin = origin
        self.offset = offset
        self.rotation = rotation
        self.hidden = hidden
    }
}

public struct ResolvedIcons: Sendable, Equatable, Hashable {
    public let collapse: ResolvedImage?
    public let expand: ResolvedImage?
    public let close: ResolvedImage?
    public let more: ResolvedImage?
    public let template: Bool
    public let tint: RGBAColor

    public init(
        collapse: ResolvedImage? = nil,
        expand: ResolvedImage? = nil,
        close: ResolvedImage? = nil,
        more: ResolvedImage? = nil,
        template: Bool = false,
        tint: RGBAColor
    ) {
        self.collapse = collapse
        self.expand = expand
        self.close = close
        self.more = more
        self.template = template
        self.tint = tint
    }
}

public struct ResolvedResizeHandle: Sendable, Equatable, Hashable {
    public let visibility: SkinVisibility
    public let tint: RGBAColor
    public let image: ResolvedImage?

    public init(
        visibility: SkinVisibility = .known(.hover),
        tint: RGBAColor,
        image: ResolvedImage? = nil
    ) {
        self.visibility = visibility
        self.tint = tint
        self.image = image
    }
}

public struct ResolvedLibrary: Sendable, Equatable, Hashable {
    public let accent: RGBAColor
    public let sidebarMaterial: SkinMaterial
    public let cardStyle: SkinCardStyle
    public let background: RGBAColor

    public init(
        accent: RGBAColor,
        sidebarMaterial: SkinMaterial = .known(.none),
        cardStyle: SkinCardStyle = .known(.note),
        background: RGBAColor
    ) {
        self.accent = accent
        self.sidebarMaterial = sidebarMaterial
        self.cardStyle = cardStyle
        self.background = background
    }
}

/// The logical identity of one orb frame after appearance and scale resolution.
public struct ResolvedOrbFrameKey: Sendable, Equatable, Hashable {
    public let skinID: String
    public let state: SkinOrbState.Known
    public let frame: Int
    public let appearance: SkinAppearance
    public let scale: SkinScale

    public init(
        skinID: String,
        state: SkinOrbState.Known,
        frame: Int,
        appearance: SkinAppearance,
        scale: SkinScale
    ) {
        self.skinID = skinID
        self.state = state
        self.frame = frame
        self.appearance = appearance
        self.scale = scale
    }

    /// The package-relative image name. This is a logical name, not a path on disk.
    public var relativeName: String {
        var name = "orb-\(state.rawValue)-\(frame)"
        if appearance == .dark {
            name += "~dark"
        }
        if scale == .two {
            name += "@2x"
        }
        return "images/\(name).png"
    }
}

public struct ResolvedOrbAnimation: Sendable, Equatable, Hashable {
    public let state: SkinOrbState.Known
    public let frameKeys: [ResolvedOrbFrameKey]
    public let fps: Double
    public let loop: Bool
    public let audioReactive: Double
    public let tint: RGBAColor

    public init(
        state: SkinOrbState.Known,
        frameKeys: [ResolvedOrbFrameKey],
        fps: Double = 0,
        loop: Bool = false,
        audioReactive: Double = 0,
        tint: RGBAColor = .clear
    ) {
        self.state = state
        self.frameKeys = frameKeys
        self.fps = fps
        self.loop = loop
        self.audioReactive = audioReactive
        self.tint = tint
    }
}

/// The logical identity of one sound asset.
public struct ResolvedSoundKey: Sendable, Equatable, Hashable {
    public let skinID: String
    public let event: SkinSoundEvent

    public init(skinID: String, event: SkinSoundEvent) {
        self.skinID = skinID
        self.event = event
    }

    /// The package-relative sound stem. The checker chooses the file extension.
    public var relativeStem: String {
        "sounds/\(event.rawValue)"
    }
}

public struct ResolvedSounds: Sendable, Equatable, Hashable {
    public let byEvent: [SkinSoundEvent: ResolvedSoundKey]
    public let volume: Double
    public let muted: Set<SkinSoundEvent>

    public init(
        byEvent: [SkinSoundEvent: ResolvedSoundKey] = [:],
        volume: Double = 1,
        muted: Set<SkinSoundEvent> = []
    ) {
        self.byEvent = byEvent
        self.volume = volume
        self.muted = muted
    }
}

public struct ResolvedAccessibility: Sendable, Equatable, Hashable {
    public let reduceTransparency: Bool
    public let increaseContrast: Bool
    public let reduceMotion: Bool
    public let textScale: Double

    public init(
        reduceTransparency: Bool = false,
        increaseContrast: Bool = false,
        reduceMotion: Bool = false,
        textScale: Double = 1
    ) {
        self.reduceTransparency = reduceTransparency
        self.increaseContrast = increaseContrast
        self.reduceMotion = reduceMotion
        self.textScale = textScale
    }
}

public struct ResolvedHighContrast: Sendable, Equatable, Hashable {
    public let surfaceFill: RGBAColor?
    public let surfaceTextColor: RGBAColor?

    public init(
        surfaceFill: RGBAColor? = nil,
        surfaceTextColor: RGBAColor? = nil
    ) {
        self.surfaceFill = surfaceFill
        self.surfaceTextColor = surfaceTextColor
    }
}

/// A complete, value-only note theme. It contains asset keys, never images or audio.
public struct ResolvedTheme: Sendable, Equatable, Hashable {
    public let skinID: String
    public let baseID: String
    public let surface: ResolvedSurface
    public let typography: ResolvedTypography
    public let header: ResolvedHeader
    public let collapsed: ResolvedCollapsed
    public let decoration: ResolvedDecoration
    public let icons: ResolvedIcons
    public let resizeHandle: ResolvedResizeHandle
    public let palette: [RGBAColor]
    public let selectedIndex: Int?
    public let library: ResolvedLibrary
    public let orb: [SkinOrbState.Known: ResolvedOrbAnimation]
    public let sounds: ResolvedSounds
    public let accessibility: ResolvedAccessibility
    public let provenance: [SkinGroup: String]
    public let highContrast: ResolvedHighContrast

    public init(
        skinID: String,
        baseID: String,
        surface: ResolvedSurface,
        typography: ResolvedTypography,
        header: ResolvedHeader,
        collapsed: ResolvedCollapsed,
        decoration: ResolvedDecoration = ResolvedDecoration(),
        icons: ResolvedIcons,
        resizeHandle: ResolvedResizeHandle,
        palette: [RGBAColor] = [],
        selectedIndex: Int? = nil,
        library: ResolvedLibrary,
        orb: [SkinOrbState.Known: ResolvedOrbAnimation] = [:],
        sounds: ResolvedSounds = ResolvedSounds(),
        accessibility: ResolvedAccessibility = ResolvedAccessibility(),
        provenance: [SkinGroup: String] = [:],
        highContrast: ResolvedHighContrast = ResolvedHighContrast()
    ) {
        self.skinID = skinID
        self.baseID = baseID
        self.surface = surface
        self.typography = typography
        self.header = header
        self.collapsed = collapsed
        self.decoration = decoration
        self.icons = icons
        self.resizeHandle = resizeHandle
        self.palette = palette
        self.selectedIndex = selectedIndex
        self.library = library
        self.orb = orb
        self.sounds = sounds
        self.accessibility = accessibility
        self.provenance = provenance
        self.highContrast = highContrast
    }

    /// Returns a copy with selected resolved values replaced.
    public func replacing(
        surface: ResolvedSurface? = nil,
        typography: ResolvedTypography? = nil,
        palette: [RGBAColor]? = nil,
        orb: [SkinOrbState.Known: ResolvedOrbAnimation]? = nil,
        accessibility: ResolvedAccessibility? = nil
    ) -> ResolvedTheme {
        ResolvedTheme(
            skinID: skinID,
            baseID: baseID,
            surface: surface ?? self.surface,
            typography: typography ?? self.typography,
            header: header,
            collapsed: collapsed,
            decoration: decoration,
            icons: icons,
            resizeHandle: resizeHandle,
            palette: palette ?? self.palette,
            selectedIndex: selectedIndex,
            library: library,
            orb: orb ?? self.orb,
            sounds: sounds,
            accessibility: accessibility ?? self.accessibility,
            provenance: provenance,
            highContrast: highContrast
        )
    }
}
