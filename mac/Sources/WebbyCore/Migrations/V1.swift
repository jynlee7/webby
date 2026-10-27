import Foundation

/// Frozen copy of the version 1 notes schema.
///
/// These types are deliberately independent of the live model. Later changes to
/// `Note`, `Anchor`, `PageURL` or `WebScope` must not alter how version 1 files
/// decode.

struct NoteFrameV1: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}

enum PlacementV1: String, Codable, Equatable, Sendable {
    case window
    case screen
}

struct PageURLV1: Codable, Equatable, Sendable {
    let host: String
    let path: String

    private enum CodingKeys: String, CodingKey {
        case host
        case path
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawHost = try container.decode(String.self, forKey: .host)
        let normalizedHost = Self.normalizeStoredHost(rawHost)
        guard !normalizedHost.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .host,
                in: container,
                debugDescription: "PageURL host must not be empty"
            )
        }
        host = normalizedHost
        path = Self.normalizePath(try container.decode(String.self, forKey: .path))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(host, forKey: .host)
        try container.encode(path, forKey: .path)
    }

    private static func normalizeStoredHost(_ rawHost: String) -> String {
        rawHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func normalizePath(_ rawPath: String) -> String {
        var normalized = ""
        var previousWasSlash = false

        for character in rawPath {
            if character == "/" {
                if !previousWasSlash {
                    normalized.append(character)
                }
                previousWasSlash = true
            } else {
                normalized.append(character)
                previousWasSlash = false
            }
        }

        if normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        if !normalized.isEmpty && !normalized.hasPrefix("/") {
            normalized.insert("/", at: normalized.startIndex)
        }
        return normalized
    }
}

enum WebScopeV1: Codable, Equatable, Sendable {
    case page
    case prefix(path: String)
    case site
}

enum AnchorV1: Codable, Equatable, Sendable {
    case app(bundleID: String)
    case web(page: PageURLV1, scope: WebScopeV1)
}

struct NoteV1: Codable, Equatable, Sendable {
    let id: UUID
    let anchor: AnchorV1
    let text: String
    let frame: NoteFrameV1
    let placement: PlacementV1
    let collapsed: Bool
    let createdAt: Date
    let updatedAt: Date
}

struct NotesFileV1: Codable, Sendable {
    let version: Int
    let notes: [NoteV1]
}
