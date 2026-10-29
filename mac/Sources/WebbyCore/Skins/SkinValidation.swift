import Foundation

/// Inputs that come from the installation context rather than `skin.json`.
public struct SkinValidationContext: Sendable, Equatable, Hashable {
    public let isBuiltIn: Bool
    public let availableBaseIDs: Set<String>

    public init(isBuiltIn: Bool = false, availableBaseIDs: Set<String> = ["webby.clear"]) {
        self.isBuiltIn = isBuiltIn
        self.availableBaseIDs = availableBaseIDs
    }
}

/// The fallback state of one element group after validation.
public enum SkinGroupStatus: String, Sendable, Equatable, Hashable, CaseIterable {
    case absent
    case usable
    case invalid
}

/// The element groups that fall back as a unit.
public enum SkinGroup: String, Sendable, Equatable, Hashable, CaseIterable {
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
}

/// The complete validation outcome for one loaded manifest.
public struct SkinValidationResult: Sendable, Equatable {
    public let document: SkinManifestDocument
    public let manifest: SkinManifest?
    public let isAccepted: Bool
    public let diagnostics: [SkinDiagnostic]
    public let groups: [SkinGroup: SkinGroupStatus]

    public init(
        document: SkinManifestDocument,
        manifest: SkinManifest?,
        isAccepted: Bool,
        diagnostics: [SkinDiagnostic],
        groups: [SkinGroup: SkinGroupStatus]
    ) {
        self.document = document
        self.manifest = manifest
        self.isAccepted = isAccepted
        self.diagnostics = diagnostics
        self.groups = groups
    }
}

/// One archive entry that survived entry-name validation.
public struct SkinAssetRecord: Sendable, Equatable, Hashable {
    public let path: String
    public let bytes: Int

    public init(path: String, bytes: Int) {
        self.path = path
        self.bytes = bytes
    }
}

/// The checker's answer for one expected asset path.
public enum AssetCheck<Value: Sendable & Equatable>: Sendable, Equatable {
    case missing
    case available(Value)
    case invalid(code: String)

    public var value: Value? {
        guard case .available(let value) = self else {
            return nil
        }
        return value
    }
}

/// Decoded image facts that the validator needs from the archive lane.
public struct ImageAssetMetadata: Sendable, Equatable, Hashable {
    public let path: String
    public let bytes: Int
    public let png: PNGHeader

    public init(path: String, bytes: Int, png: PNGHeader) {
        self.path = path
        self.bytes = bytes
        self.png = png
    }
}

/// Decoded sound facts that the validator needs from the archive lane.
public struct SoundAssetMetadata: Sendable, Equatable, Hashable {
    public let path: String
    public let bytes: Int
    public let isPCM: Bool
    public let duration: Double

    public init(path: String, bytes: Int, isPCM: Bool, duration: Double) {
        self.path = path
        self.bytes = bytes
        self.isPCM = isPCM
        self.duration = duration
    }
}

/// The asset surface a skin package must provide to `SkinValidator`.
public protocol SkinAssetChecking {
    func inventory() -> [SkinAssetRecord]
    func image(_ path: String) -> AssetCheck<ImageAssetMetadata>
    func sound(_ path: String) -> AssetCheck<SoundAssetMetadata>
}
