import Foundation

/// A fixed image element from the skin package.
public enum SkinImageElement: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    case noteBody = "note-body"
    case noteHeader = "note-header"
    case noteCollapsed = "note-collapsed"
    case decoration
    case iconCollapse = "icon-collapse"
    case iconExpand = "icon-expand"
    case iconClose = "icon-close"
    case iconMore = "icon-more"
    case resizeHandle = "resize-handle"
    case libraryEmpty = "library-empty"
}

public typealias ImageElement = SkinImageElement
public typealias OrbState = SkinOrbState.Known

/// The identity of an expected skin asset and its filename variant.
public enum SkinAsset: Codable, Sendable, Equatable, Hashable {
    public typealias Element = SkinImageElement
    public typealias OrbState = SkinOrbState.Known
    public typealias Appearance = SkinAppearance
    public typealias Scale = SkinScale

    public enum Kind: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
        case image
        case orb
        case sound
    }

    case image(element: Element, appearance: Appearance?, scale: Scale)
    case orb(state: SkinOrbState.Known, frame: Int?, appearance: Appearance?, scale: Scale)
    case sound(event: SkinSoundEvent)

    public var kind: Kind {
        switch self {
        case .image:
            return .image
        case .orb:
            return .orb
        case .sound:
            return .sound
        }
    }

    public var element: Element? {
        guard case .image(let element, _, _) = self else {
            return nil
        }
        return element
    }

    public var orbState: SkinOrbState.Known? {
        guard case .orb(let state, _, _, _) = self else {
            return nil
        }
        return state
    }

    public var soundEvent: SkinSoundEvent? {
        guard case .sound(let event) = self else {
            return nil
        }
        return event
    }

    public var appearance: Appearance? {
        switch self {
        case .image(_, let appearance, _):
            return appearance
        case .orb(_, _, let appearance, _):
            return appearance
        case .sound:
            return nil
        }
    }

    public var scale: Scale? {
        switch self {
        case .image(_, _, let scale):
            return scale
        case .orb(_, _, _, let scale):
            return scale
        case .sound:
            return nil
        }
    }

    public var frame: Int? {
        guard case .orb(_, let frame, _, _) = self else {
            return nil
        }
        return frame
    }

    /// The element or event name without appearance, scale or extension suffixes.
    public var fileStem: String {
        switch self {
        case .image(let element, let appearance, let scale):
            return element.rawValue + appearanceSuffix(appearance) + scaleSuffix(scale)
        case .orb(let state, let frame, let appearance, let scale):
            return Self.orbKey(state: state, frame: frame)
                + appearanceSuffix(appearance)
                + scaleSuffix(scale)
        case .sound(let event):
            return event.rawValue
        }
    }

    /// The package-relative path for an image asset. Sound extensions are chosen by the checker.
    public var relativePath: String? {
        switch self {
        case .image, .orb:
            return "images/\(fileStem).png"
        case .sound:
            return nil
        }
    }

    public static func orbKey(state: SkinOrbState.Known, frame: Int?) -> String {
        if let frame {
            return "orb-\(state.rawValue)-\(frame)"
        }
        return "orb-\(state.rawValue)"
    }

    public static func orbKey(_ state: SkinOrbState.Known, frame: Int) -> String {
        orbKey(state: state, frame: Optional(frame))
    }

    public static func orbImageKey(state: SkinOrbState.Known, frame: Int?) -> String {
        orbKey(state: state, frame: frame)
    }

    private func appearanceSuffix(_ appearance: Appearance?) -> String {
        appearance == .dark ? "~dark" : ""
    }

    private func scaleSuffix(_ scale: Scale) -> String {
        scale == .two ? "@2x" : ""
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case element
        case orbState
        case frame
        case appearance
        case scale
        case event
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .image:
            self = .image(
                element: try container.decode(Element.self, forKey: .element),
                appearance: try container.decodeIfPresent(Appearance.self, forKey: .appearance),
                scale: try container.decode(Scale.self, forKey: .scale)
            )
        case .orb:
            self = .orb(
                state: try container.decode(OrbState.self, forKey: .orbState),
                frame: try container.decodeIfPresent(Int.self, forKey: .frame),
                appearance: try container.decodeIfPresent(Appearance.self, forKey: .appearance),
                scale: try container.decode(Scale.self, forKey: .scale)
            )
        case .sound:
            self = .sound(event: try container.decode(SkinSoundEvent.self, forKey: .event))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        switch self {
        case .image(let element, let appearance, let scale):
            try container.encode(element, forKey: .element)
            try container.encodeIfPresent(appearance, forKey: .appearance)
            try container.encode(scale, forKey: .scale)
        case .orb(let state, let frame, let appearance, let scale):
            try container.encode(state, forKey: .orbState)
            try container.encodeIfPresent(frame, forKey: .frame)
            try container.encodeIfPresent(appearance, forKey: .appearance)
            try container.encode(scale, forKey: .scale)
        case .sound(let event):
            try container.encode(event, forKey: .event)
        }
    }
}

/// One archive entry after name validation.
public struct SkinEntry: Codable, Sendable, Equatable, Hashable {
    public let path: String
    public let asset: SkinAsset?

    public init(path: String, asset: SkinAsset? = nil) {
        self.path = path
        self.asset = asset
    }

    public var name: String {
        path
    }
}

/// The outcome assigned to an archive entry by the entry-rules lane.
public enum SkinEntryDisposition: Codable, Sendable, Equatable, Hashable {
    case accepted(SkinEntry)
    case skipped
    case warning(String)
    case rejected(String)

    private enum CodingKeys: String, CodingKey {
        case accepted
        case skipped
        case warning
        case rejected
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let entry = try container.decodeIfPresent(SkinEntry.self, forKey: .accepted) {
            self = .accepted(entry)
        } else if container.contains(.skipped) {
            self = .skipped
        } else if let message = try container.decodeIfPresent(String.self, forKey: .warning) {
            self = .warning(message)
        } else if let message = try container.decodeIfPresent(String.self, forKey: .rejected) {
            self = .rejected(message)
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unknown skin entry disposition"
                )
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .accepted(let entry):
            try container.encode(entry, forKey: .accepted)
        case .skipped:
            try container.encode(true, forKey: .skipped)
        case .warning(let message):
            try container.encode(message, forKey: .warning)
        case .rejected(let message):
            try container.encode(message, forKey: .rejected)
        }
    }
}
