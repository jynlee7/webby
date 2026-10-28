import Foundation

public struct SkinCredit: Codable, Sendable, Equatable, Hashable {
    public let name: String
    public let role: String?

    public init(name: String, role: String? = nil) {
        self.name = name
        self.role = role
    }
}

/// The decoded `skin.json` contract. Missing groups and members stay absent.
public struct SkinManifest: Codable, Sendable, Equatable, Hashable {
    public let schema: String?
    public let formatVersion: Int
    public let id: String
    public let name: String
    public let author: String
    public let version: String
    public let description: String?
    public let license: String?
    public let basedOn: String?
    public let base: String?
    public let credits: [SkinCredit]?
    public let tags: [String]?
    public let appearances: [SkinAppearance]?
    public let palette: [SkinColor]?
    public let surface: SkinSurface?
    public let typography: SkinTypography?
    public let header: SkinHeader?
    public let collapsed: SkinCollapsed?
    public let decoration: SkinDecoration?
    public let icons: SkinIcons?
    public let resizeHandle: SkinResizeHandle?
    public let library: SkinLibrary?
    public let voiceOrb: SkinVoiceOrb?
    public let sounds: SkinSounds?
    public let highContrast: SkinHighContrast?

    private enum CodingKeys: String, CodingKey {
        case schema = "$schema"
        case formatVersion
        case id
        case name
        case author
        case version
        case description
        case license
        case basedOn
        case base
        case credits
        case tags
        case appearances
        case palette
        case surface
        case typography
        case header
        case collapsed
        case decoration
        case icons
        case resizeHandle
        case library
        case voiceOrb
        case sounds
        case highContrast
    }

    public init(
        schema: String? = nil,
        formatVersion: Int,
        id: String,
        name: String,
        author: String,
        version: String,
        description: String? = nil,
        license: String? = nil,
        basedOn: String? = nil,
        base: String? = nil,
        credits: [SkinCredit]? = nil,
        tags: [String]? = nil,
        appearances: [SkinAppearance]? = nil,
        palette: [SkinColor]? = nil,
        surface: SkinSurface? = nil,
        typography: SkinTypography? = nil,
        header: SkinHeader? = nil,
        collapsed: SkinCollapsed? = nil,
        decoration: SkinDecoration? = nil,
        icons: SkinIcons? = nil,
        resizeHandle: SkinResizeHandle? = nil,
        library: SkinLibrary? = nil,
        voiceOrb: SkinVoiceOrb? = nil,
        sounds: SkinSounds? = nil,
        highContrast: SkinHighContrast? = nil
    ) {
        self.schema = schema
        self.formatVersion = formatVersion
        self.id = id
        self.name = name
        self.author = author
        self.version = version
        self.description = description
        self.license = license
        self.basedOn = basedOn
        self.base = base
        self.credits = credits
        self.tags = tags
        self.appearances = appearances
        self.palette = palette
        self.surface = surface
        self.typography = typography
        self.header = header
        self.collapsed = collapsed
        self.decoration = decoration
        self.icons = icons
        self.resizeHandle = resizeHandle
        self.library = library
        self.voiceOrb = voiceOrb
        self.sounds = sounds
        self.highContrast = highContrast
    }
}
