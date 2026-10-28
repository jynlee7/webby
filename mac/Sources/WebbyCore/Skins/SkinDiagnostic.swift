import Foundation

/// A validation problem with a stable code and a structured JSON path.
public struct SkinDiagnostic: Codable, Sendable, Equatable, Hashable {
    public enum Severity: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
        case fatal
        case groupError
        case warning
    }

    public enum PathSegment: Codable, Sendable, Equatable, Hashable {
        case key(String)
        case index(Int)

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let index = try? container.decode(Int.self) {
                self = .index(index)
            } else {
                self = .key(try container.decode(String.self))
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .key(let key):
                try container.encode(key)
            case .index(let index):
                try container.encode(index)
            }
        }
    }

    public static let maxSummaryLength = 512

    public let code: String
    public let severity: Severity
    public let path: [PathSegment]
    public let group: String?
    public let assetPath: String?
    public let message: String

    public init(
        code: String,
        severity: Severity,
        path: [PathSegment] = [],
        group: String? = nil,
        assetPath: String? = nil,
        message: String
    ) {
        self.code = code
        self.severity = severity
        self.path = path
        self.group = group
        self.assetPath = assetPath
        self.message = message
    }

    public var jsonPath: String {
        Self.render(path: path)
    }

    /// A single-line summary truncated to `maxSummaryLength` characters.
    public var summary: String {
        let rendered = "\(severity.rawValue): \(code) at \(jsonPath): \(message)"
        return String(rendered.prefix(Self.maxSummaryLength))
    }

    public static func render(path: [PathSegment]) -> String {
        var result = "$"
        for segment in path {
            switch segment {
            case .key(let key) where isBareKey(key):
                result += ".\(key)"
            case .key(let key):
                result += "[\"\(escaped(key))\"]"
            case .index(let index):
                result += "[\(index)]"
            }
        }
        return result
    }

    private static func isBareKey(_ key: String) -> Bool {
        guard !key.isEmpty, !key.contains("."), key.first?.isNumber != true else {
            return false
        }
        return key.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "_"
        }
    }

    private static func escaped(_ key: String) -> String {
        key
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

public typealias SkinDiagnosticSeverity = SkinDiagnostic.Severity
public typealias SkinDiagnosticPathSegment = SkinDiagnostic.PathSegment
public typealias PathSegment = SkinDiagnostic.PathSegment
