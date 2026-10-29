import Foundation

/// A token that is either one value for both appearances or separate light and dark values.
public enum AppearanceValue<T: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
    case bare(T)
    case paired(light: T, dark: T)

    private enum Keys: String, CodingKey {
        case light
        case dark
    }

    public init(_ value: T) {
        self = .bare(value)
    }

    public init(light: T, dark: T) {
        self = .paired(light: light, dark: dark)
    }

    public init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if let value = try? single.decode(T.self) {
            self = .bare(value)
            return
        }

        let container = try decoder.container(keyedBy: Keys.self)
        self = .paired(
            light: try container.decode(T.self, forKey: .light),
            dark: try container.decode(T.self, forKey: .dark)
        )
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .bare(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .paired(let light, let dark):
            var container = encoder.container(keyedBy: Keys.self)
            try container.encode(light, forKey: .light)
            try container.encode(dark, forKey: .dark)
        }
    }

    /// The light appearance value.
    public var light: T {
        switch self {
        case .bare(let value):
            return value
        case .paired(let light, _):
            return light
        }
    }

    /// The dark appearance value.
    public var dark: T {
        switch self {
        case .bare(let value):
            return value
        case .paired(_, let dark):
            return dark
        }
    }

    /// Returns a value in the same appearance shape.
    public func map<U: Codable & Sendable & Equatable>(_ transform: (T) throws -> U) rethrows -> AppearanceValue<U> {
        switch self {
        case .bare(let value):
            return .bare(try transform(value))
        case .paired(let light, let dark):
            return .paired(light: try transform(light), dark: try transform(dark))
        }
    }
}

extension AppearanceValue: Hashable where T: Hashable {}

/// A color token. Hex parsing belongs to the validator and resolver, not to this model.
public typealias SkinColor = AppearanceValue<String>

/// A material token that keeps an unrecognized value instead of failing the manifest.
public enum SkinMaterial: Codable, Sendable, Equatable, Hashable {
    public enum Known: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
        case none
        case titlebar
        case selection
        case menu
        case popover
        case sidebar
        case headerView
        case sheet
        case windowBackground
        case hudWindow
        case fullScreenUI
        case toolTip
        case contentBackground
        case underWindowBackground
        case underPageBackground
    }

    case known(Known)
    case unknown(String)

    public init(rawValue: String) {
        if let known = Known(rawValue: rawValue) {
            self = .known(known)
        } else {
            self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .known(let value):
            return value.rawValue
        case .unknown(let value):
            return value
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A shadow token that keeps an unrecognized value.
public enum SkinShadow: Codable, Sendable, Equatable, Hashable {
    public enum Known: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
        case system
        case none
        case soft
    }

    case known(Known)
    case unknown(String)

    public init(rawValue: String) {
        if let known = Known(rawValue: rawValue) {
            self = .known(known)
        } else {
            self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .known(let value):
            return value.rawValue
        case .unknown(let value):
            return value
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// An image fill mode that keeps an unrecognized value.
public enum SkinImageMode: Codable, Sendable, Equatable, Hashable {
    public enum Known: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
        case stretch
        case tile
    }

    case known(Known)
    case unknown(String)

    public init(rawValue: String) {
        if let known = Known(rawValue: rawValue) {
            self = .known(known)
        } else {
            self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .known(let value):
            return value.rawValue
        case .unknown(let value):
            return value
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A font weight token that keeps an unrecognized value.
public enum SkinFontWeight: Codable, Sendable, Equatable, Hashable {
    public enum Known: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
        case ultraLight
        case thin
        case light
        case regular
        case medium
        case semibold
        case bold
        case heavy
        case black
    }

    case known(Known)
    case unknown(String)

    public init(rawValue: String) {
        if let known = Known(rawValue: rawValue) {
            self = .known(known)
        } else {
            self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .known(let value):
            return value.rawValue
        case .unknown(let value):
            return value
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A nine-position anchor or origin token that keeps an unrecognized value.
public enum SkinAlignment: Codable, Sendable, Equatable, Hashable {
    public enum Known: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
        case topLeft
        case topCenter
        case topRight
        case centerLeft
        case center
        case centerRight
        case bottomLeft
        case bottomCenter
        case bottomRight
    }

    case known(Known)
    case unknown(String)

    public init(rawValue: String) {
        if let known = Known(rawValue: rawValue) {
            self = .known(known)
        } else {
            self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .known(let value):
            return value.rawValue
        case .unknown(let value):
            return value
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A resize-handle visibility token that keeps an unrecognized value.
public enum SkinVisibility: Codable, Sendable, Equatable, Hashable {
    public enum Known: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
        case always
        case hover
        case never
    }

    case known(Known)
    case unknown(String)

    public init(rawValue: String) {
        if let known = Known(rawValue: rawValue) {
            self = .known(known)
        } else {
            self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .known(let value):
            return value.rawValue
        case .unknown(let value):
            return value
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A library card style token that keeps an unrecognized value.
public enum SkinCardStyle: Codable, Sendable, Equatable, Hashable {
    public enum Known: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
        case note
        case uniform
    }

    case known(Known)
    case unknown(String)

    public init(rawValue: String) {
        if let known = Known(rawValue: rawValue) {
            self = .known(known)
        } else {
            self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .known(let value):
            return value.rawValue
        case .unknown(let value):
            return value
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A sound event token that keeps an unrecognized value.
public enum SkinSoundEvent: Codable, Sendable, Equatable, Hashable {
    public enum Known: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
        case noteCreate = "note-create"
        case noteSave = "note-save"
        case noteDelete = "note-delete"
        case noteCollapse = "note-collapse"
        case voiceStart = "voice-start"
        case voiceStop = "voice-stop"
        case voiceError = "voice-error"
    }

    case known(Known)
    case unknown(String)

    public init(rawValue: String) {
        if let known = Known(rawValue: rawValue) {
            self = .known(known)
        } else {
            self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .known(let value):
            return value.rawValue
        case .unknown(let value):
            return value
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// An orb state token that keeps an unrecognized value.
public enum SkinOrbState: Codable, Sendable, Equatable, Hashable {
    public enum Known: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
        case idle
        case listening
        case thinking
        case speaking
        case error
    }

    case known(Known)
    case unknown(String)

    public init(rawValue: String) {
        if let known = Known(rawValue: rawValue) {
            self = .known(known)
        } else {
            self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .known(let value):
            return value.rawValue
        case .unknown(let value):
            return value
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public typealias SoundEventValue = SkinSoundEvent

/// A light or dark appearance.
public enum SkinAppearance: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    case light
    case dark
}

/// An image scale variant.
public enum SkinScale: Int, Codable, Sendable, Equatable, Hashable, CaseIterable {
    case one = 1
    case two = 2
}

/// A four-sided point or pixel inset.
public struct SkinInsets: Codable, Sendable, Equatable, Hashable {
    public let top: Double?
    public let left: Double?
    public let bottom: Double?
    public let right: Double?

    public init(top: Double? = nil, left: Double? = nil, bottom: Double? = nil, right: Double? = nil) {
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
    }
}

public struct SkinBorder: Codable, Sendable, Equatable, Hashable {
    public let width: Double?
    public let color: SkinColor?

    public init(width: Double? = nil, color: SkinColor? = nil) {
        self.width = width
        self.color = color
    }
}

public struct SkinSurfaceImage: Codable, Sendable, Equatable, Hashable {
    public let element: String?
    public let insets: SkinInsets?
    public let mode: SkinImageMode?
    public let tintWithPalette: Bool?

    public init(
        element: String? = nil,
        insets: SkinInsets? = nil,
        mode: SkinImageMode? = nil,
        tintWithPalette: Bool? = nil
    ) {
        self.element = element
        self.insets = insets
        self.mode = mode
        self.tintWithPalette = tintWithPalette
    }
}

public struct SkinSurfaceText: Codable, Sendable, Equatable, Hashable {
    public let color: SkinColor?

    public init(color: SkinColor? = nil) {
        self.color = color
    }
}

public struct SkinSurface: Codable, Sendable, Equatable, Hashable {
    public let fill: SkinColor?
    public let material: AppearanceValue<SkinMaterial>?
    public let image: SkinSurfaceImage?
    public let cornerRadius: Double?
    public let border: SkinBorder?
    public let shadow: SkinShadow?
    public let padding: SkinInsets?
    public let text: SkinSurfaceText?
    public let placeholderColor: SkinColor?
    public let selection: SkinColor?
    public let caret: SkinColor?

    public init(
        fill: SkinColor? = nil,
        material: AppearanceValue<SkinMaterial>? = nil,
        image: SkinSurfaceImage? = nil,
        cornerRadius: Double? = nil,
        border: SkinBorder? = nil,
        shadow: SkinShadow? = nil,
        padding: SkinInsets? = nil,
        text: SkinSurfaceText? = nil,
        placeholderColor: SkinColor? = nil,
        selection: SkinColor? = nil,
        caret: SkinColor? = nil
    ) {
        self.fill = fill
        self.material = material
        self.image = image
        self.cornerRadius = cornerRadius
        self.border = border
        self.shadow = shadow
        self.padding = padding
        self.text = text
        self.placeholderColor = placeholderColor
        self.selection = selection
        self.caret = caret
    }
}

public struct SkinFont: Codable, Sendable, Equatable, Hashable {
    public let family: String?

    public init(family: String? = nil) {
        self.family = family
    }
}

public struct SkinTypography: Codable, Sendable, Equatable, Hashable {
    public let font: SkinFont?
    public let size: Double?
    public let weight: SkinFontWeight?
    public let lineSpacing: Double?

    public init(
        font: SkinFont? = nil,
        size: Double? = nil,
        weight: SkinFontWeight? = nil,
        lineSpacing: Double? = nil
    ) {
        self.font = font
        self.size = size
        self.weight = weight
        self.lineSpacing = lineSpacing
    }
}

public struct SkinHeader: Codable, Sendable, Equatable, Hashable {
    public let height: Double?
    public let fill: SkinColor?
    public let showsTitle: Bool?

    public init(height: Double? = nil, fill: SkinColor? = nil, showsTitle: Bool? = nil) {
        self.height = height
        self.fill = fill
        self.showsTitle = showsTitle
    }
}

public struct SkinCollapsed: Codable, Sendable, Equatable, Hashable {
    public let height: Double?
    public let showsFirstLine: Bool?

    public init(height: Double? = nil, showsFirstLine: Bool? = nil) {
        self.height = height
        self.showsFirstLine = showsFirstLine
    }
}

public struct SkinOffset: Codable, Sendable, Equatable, Hashable {
    public let x: Double?
    public let y: Double?

    public init(x: Double? = nil, y: Double? = nil) {
        self.x = x
        self.y = y
    }
}

public struct SkinDecoration: Codable, Sendable, Equatable, Hashable {
    public let element: String?
    public let anchor: SkinAlignment?
    public let origin: SkinAlignment?
    public let offset: SkinOffset?
    public let rotation: Double?
    public let hidden: Bool?

    public init(
        element: String? = nil,
        anchor: SkinAlignment? = nil,
        origin: SkinAlignment? = nil,
        offset: SkinOffset? = nil,
        rotation: Double? = nil,
        hidden: Bool? = nil
    ) {
        self.element = element
        self.anchor = anchor
        self.origin = origin
        self.offset = offset
        self.rotation = rotation
        self.hidden = hidden
    }
}

public struct SkinIcons: Codable, Sendable, Equatable, Hashable {
    public let tint: SkinColor?
    public let template: Bool?

    public init(tint: SkinColor? = nil, template: Bool? = nil) {
        self.tint = tint
        self.template = template
    }
}

public struct SkinResizeHandle: Codable, Sendable, Equatable, Hashable {
    public let visibility: SkinVisibility?
    public let tint: SkinColor?

    public init(visibility: SkinVisibility? = nil, tint: SkinColor? = nil) {
        self.visibility = visibility
        self.tint = tint
    }
}

public struct SkinLibrary: Codable, Sendable, Equatable, Hashable {
    public let accent: SkinColor?
    public let sidebarMaterial: SkinMaterial?
    public let cardStyle: SkinCardStyle?
    public let background: SkinColor?

    public init(
        accent: SkinColor? = nil,
        sidebarMaterial: SkinMaterial? = nil,
        cardStyle: SkinCardStyle? = nil,
        background: SkinColor? = nil
    ) {
        self.accent = accent
        self.sidebarMaterial = sidebarMaterial
        self.cardStyle = cardStyle
        self.background = background
    }
}

public struct SkinOrbAnimation: Codable, Sendable, Equatable, Hashable {
    public let frames: Int?
    public let fps: Double?
    public let loop: Bool?
    public let audioReactive: Double?
    public let tint: SkinColor?

    public init(
        frames: Int? = nil,
        fps: Double? = nil,
        loop: Bool? = nil,
        audioReactive: Double? = nil,
        tint: SkinColor? = nil
    ) {
        self.frames = frames
        self.fps = fps
        self.loop = loop
        self.audioReactive = audioReactive
        self.tint = tint
    }
}

/// The per-state orb animations. Unknown state keys are preserved in `animations`.
public struct SkinOrbStates: Codable, Sendable, Equatable, Hashable {
    public var animations: [SkinOrbState: SkinOrbAnimation]

    public init(animations: [SkinOrbState: SkinOrbAnimation] = [:]) {
        self.animations = animations
    }

    public init(
        idle: SkinOrbAnimation? = nil,
        listening: SkinOrbAnimation? = nil,
        thinking: SkinOrbAnimation? = nil,
        speaking: SkinOrbAnimation? = nil,
        error: SkinOrbAnimation? = nil
    ) {
        var animations: [SkinOrbState: SkinOrbAnimation] = [:]
        animations[.known(.idle)] = idle
        animations[.known(.listening)] = listening
        animations[.known(.thinking)] = thinking
        animations[.known(.speaking)] = speaking
        animations[.known(.error)] = error
        self.animations = animations
    }

    public subscript(state: SkinOrbState) -> SkinOrbAnimation? {
        get { animations[state] }
        set { animations[state] = newValue }
    }

    public var idle: SkinOrbAnimation? {
        get { self[.known(.idle)] }
        set { self[.known(.idle)] = newValue }
    }

    public var listening: SkinOrbAnimation? {
        get { self[.known(.listening)] }
        set { self[.known(.listening)] = newValue }
    }

    public var thinking: SkinOrbAnimation? {
        get { self[.known(.thinking)] }
        set { self[.known(.thinking)] = newValue }
    }

    public var speaking: SkinOrbAnimation? {
        get { self[.known(.speaking)] }
        set { self[.known(.speaking)] = newValue }
    }

    public var error: SkinOrbAnimation? {
        get { self[.known(.error)] }
        set { self[.known(.error)] = newValue }
    }

    private struct DynamicKey: CodingKey {
        let stringValue: String
        let intValue: Int?

        init?(stringValue: String) {
            self.stringValue = stringValue
            self.intValue = nil
        }

        init?(intValue: Int) {
            self.stringValue = String(intValue)
            self.intValue = intValue
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        var animations: [SkinOrbState: SkinOrbAnimation] = [:]
        for key in container.allKeys {
            animations[SkinOrbState(rawValue: key.stringValue)] =
                try container.decode(SkinOrbAnimation.self, forKey: key)
        }
        self.animations = animations
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicKey.self)
        for (state, animation) in animations.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            let key = DynamicKey(stringValue: state.rawValue)!
            try container.encode(animation, forKey: key)
        }
    }
}

public struct SkinVoiceOrb: Codable, Sendable, Equatable, Hashable {
    public let states: SkinOrbStates?

    public init(states: SkinOrbStates? = nil) {
        self.states = states
    }
}

public struct SkinSounds: Codable, Sendable, Equatable, Hashable {
    public let volume: Double?
    public let mute: [SkinSoundEvent]?

    public init(volume: Double? = nil, mute: [SkinSoundEvent]? = nil) {
        self.volume = volume
        self.mute = mute
    }
}

/// High-contrast overrides for the two surface tokens that carry text contrast.
public struct SkinHighContrast: Codable, Sendable, Equatable, Hashable {
    public let surfaceFill: SkinColor?
    public let surfaceTextColor: SkinColor?

    private enum CodingKeys: String, CodingKey {
        case surfaceFill = "surface.fill"
        case surfaceTextColor = "surface.text.color"
    }

    public init(surfaceFill: SkinColor? = nil, surfaceTextColor: SkinColor? = nil) {
        self.surfaceFill = surfaceFill
        self.surfaceTextColor = surfaceTextColor
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.surfaceFill = try container.decodeIfPresent(SkinColor.self, forKey: .surfaceFill)
        self.surfaceTextColor = try container.decodeIfPresent(SkinColor.self, forKey: .surfaceTextColor)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(surfaceFill, forKey: .surfaceFill)
        try container.encodeIfPresent(surfaceTextColor, forKey: .surfaceTextColor)
    }
}
