import Foundation

/// A manifest load result. `load(data:)` never throws; problems are diagnostics.
public struct SkinManifestDocument: Sendable, Equatable {
    public let originalData: Data
    public let manifest: SkinManifest?
    public let formatVersion: Int?
    public let isAccepted: Bool
    public let isStrictJSON: Bool
    public let diagnostics: [SkinDiagnostic]

    public init(
        originalData: Data,
        manifest: SkinManifest?,
        formatVersion: Int?,
        isAccepted: Bool,
        isStrictJSON: Bool,
        diagnostics: [SkinDiagnostic]
    ) {
        self.originalData = originalData
        self.manifest = manifest
        self.formatVersion = formatVersion
        self.isAccepted = isAccepted
        self.isStrictJSON = isStrictJSON
        self.diagnostics = diagnostics
    }
}

/// Decodes a `skin.json` without touching the filesystem or fetching `$schema`.
public enum SkinManifestLoader {
    public static func load(data: Data) -> SkinManifestDocument {
        var diagnostics: [SkinDiagnostic] = []

        let strictDecoder = JSONDecoder()
        strictDecoder.allowsJSON5 = false
        let permissiveDecoder = JSONDecoder()
        permissiveDecoder.allowsJSON5 = true

        var manifest: SkinManifest?
        var isStrictJSON = false
        do {
            manifest = try strictDecoder.decode(SkinManifest.self, from: data)
            isStrictJSON = true
        } catch {
            do {
                manifest = try permissiveDecoder.decode(SkinManifest.self, from: data)
                diagnostics.append(SkinDiagnostic(
                    code: "non-strict-json",
                    severity: .warning,
                    path: [],
                    message: "Manifest is not strict JSON; it was read as JSON5."
                ))
            } catch {
                manifest = nil
            }
        }

        guard let manifest else {
            diagnostics.append(SkinDiagnostic(
                code: "manifest-unparseable",
                severity: .fatal,
                path: [],
                message: "Manifest could not be decoded."
            ))
            return SkinManifestDocument(
                originalData: data,
                manifest: nil,
                formatVersion: nil,
                isAccepted: false,
                isStrictJSON: false,
                diagnostics: diagnostics
            )
        }

        if manifest.formatVersion > 1 {
            diagnostics.append(SkinDiagnostic(
                code: "format-version-newer",
                severity: .fatal,
                path: [.key("formatVersion")],
                message: "Manifest formatVersion \(manifest.formatVersion) requires a newer Webby."
            ))
        } else if manifest.formatVersion < 1 {
            diagnostics.append(SkinDiagnostic(
                code: "format-version-unsupported",
                severity: .fatal,
                path: [.key("formatVersion")],
                message: "Manifest formatVersion \(manifest.formatVersion) is not supported."
            ))
        }

        // The value tree is decoded with JSONDecoder rather than JSONSerialization
        // because JSON5 comments and non-finite literals have no JSONSerialization
        // representation. Decoding the tree keeps exact keys, paths and numbers.
        if let tree = try? permissiveDecoder.decode(JSONValue.self, from: data) {
            checkUnknownKeys(
                tree,
                schema: .topLevel,
                path: [],
                group: nil,
                diagnostics: &diagnostics
            )
            checkNonFiniteNumbers(tree, path: [], group: nil, diagnostics: &diagnostics)
        }

        let isAccepted = !diagnostics.contains { $0.severity == .fatal }
        return SkinManifestDocument(
            originalData: data,
            manifest: manifest,
            formatVersion: manifest.formatVersion,
            isAccepted: isAccepted,
            isStrictJSON: isStrictJSON,
            diagnostics: diagnostics
        )
    }

    private static func checkUnknownKeys(
        _ value: JSONValue,
        schema: ManifestKeySchema,
        path: [SkinDiagnostic.PathSegment],
        group: String?,
        diagnostics: inout [SkinDiagnostic]
    ) {
        switch schema {
        case .leaf:
            return
        case .appearance(let child):
            guard case .object(let members) = value else {
                return
            }
            for member in members {
                let memberPath = path + [.key(member.key)]
                if member.key == "light" || member.key == "dark" {
                    checkUnknownKeys(
                        member.value,
                        schema: child,
                        path: memberPath,
                        group: group,
                        diagnostics: &diagnostics
                    )
                } else {
                    diagnostics.append(SkinDiagnostic(
                        code: "unknown-key",
                        severity: .warning,
                        path: memberPath,
                        group: group,
                        message: "Unknown key '\(member.key)'."
                    ))
                }
            }
        case .array(let element):
            guard case .array(let elements) = value else {
                return
            }
            for (index, elementValue) in elements.enumerated() {
                checkUnknownKeys(
                    elementValue,
                    schema: element,
                    path: path + [.index(index)],
                    group: group,
                    diagnostics: &diagnostics
                )
            }
        case .object(let fields):
            guard case .object(let members) = value else {
                return
            }
            for member in members {
                let memberPath = path + [.key(member.key)]
                let memberGroup = path.isEmpty
                    ? (manifestGroupKeys.contains(member.key) ? member.key : nil)
                    : group
                if let child = fields[member.key] {
                    checkUnknownKeys(
                        member.value,
                        schema: child,
                        path: memberPath,
                        group: memberGroup,
                        diagnostics: &diagnostics
                    )
                } else {
                    diagnostics.append(SkinDiagnostic(
                        code: "unknown-key",
                        severity: .warning,
                        path: memberPath,
                        group: memberGroup,
                        message: "Unknown key '\(member.key)'."
                    ))
                }
            }
        case .objectOf(let child):
            guard case .object(let members) = value else {
                return
            }
            for member in members {
                checkUnknownKeys(
                    member.value,
                    schema: child,
                    path: path + [.key(member.key)],
                    group: group,
                    diagnostics: &diagnostics
                )
            }
        }
    }

    private static func checkNonFiniteNumbers(
        _ value: JSONValue,
        path: [SkinDiagnostic.PathSegment],
        group: String?,
        diagnostics: inout [SkinDiagnostic]
    ) {
        if path.isEmpty, case .object(let members) = value {
            for member in members {
                checkNonFiniteNumbers(
                    member.value,
                    path: [.key(member.key)],
                    group: manifestGroupKeys.contains(member.key) ? member.key : nil,
                    diagnostics: &diagnostics
                )
            }
            return
        }

        switch value {
        case .number(let number) where !number.isFinite:
            let isGrouped = group != nil
            diagnostics.append(SkinDiagnostic(
                code: isGrouped ? "non-finite-number" : "non-finite-metadata",
                severity: isGrouped ? .groupError : .fatal,
                path: path,
                group: group,
                message: "Non-finite number \(numberText(number)) is not allowed."
            ))
        case .array(let elements):
            for (index, element) in elements.enumerated() {
                checkNonFiniteNumbers(
                    element,
                    path: path + [.index(index)],
                    group: group,
                    diagnostics: &diagnostics
                )
            }
        case .object(let members):
            for member in members {
                checkNonFiniteNumbers(
                    member.value,
                    path: path + [.key(member.key)],
                    group: group,
                    diagnostics: &diagnostics
                )
            }
        default:
            return
        }
    }

    private static func numberText(_ number: Double) -> String {
        if number.isNaN {
            return "NaN"
        }
        if number == .infinity {
            return "Infinity"
        }
        if number == -.infinity {
            return "-Infinity"
        }
        return String(number)
    }
}

/// Top-level manifest keys that own a fallback group.
private let manifestGroupKeys: Set<String> = [
    "palette",
    "surface",
    "typography",
    "header",
    "collapsed",
    "decoration",
    "icons",
    "resizeHandle",
    "library",
    "voiceOrb",
    "sounds",
    "highContrast",
]

private indirect enum ManifestKeySchema: Sendable {
    case leaf
    case appearance(ManifestKeySchema)
    case array(ManifestKeySchema)
    case object([String: ManifestKeySchema])
    case objectOf(ManifestKeySchema)

    static let color: ManifestKeySchema = .appearance(.leaf)
    static let insets: ManifestKeySchema = .object([
        "top": .leaf,
        "left": .leaf,
        "bottom": .leaf,
        "right": .leaf,
    ])
    static let orbAnimation: ManifestKeySchema = .object([
        "frames": .leaf,
        "fps": .leaf,
        "loop": .leaf,
        "audioReactive": .leaf,
        "tint": color,
    ])
    static let topLevel: ManifestKeySchema = .object([
        "$schema": .leaf,
        "formatVersion": .leaf,
        "id": .leaf,
        "name": .leaf,
        "author": .leaf,
        "version": .leaf,
        "description": .leaf,
        "license": .leaf,
        "basedOn": .leaf,
        "base": .leaf,
        "credits": .array(.object(["name": .leaf, "role": .leaf])),
        "tags": .array(.leaf),
        "appearances": .array(.leaf),
        "palette": .array(color),
        "surface": .object([
            "fill": color,
            "material": .appearance(.leaf),
            "image": .object([
                "element": .leaf,
                "insets": insets,
                "mode": .leaf,
                "tintWithPalette": .leaf,
            ]),
            "cornerRadius": .leaf,
            "border": .object(["width": .leaf, "color": color]),
            "shadow": .leaf,
            "padding": insets,
            "text": .object(["color": color]),
            "placeholderColor": color,
            "selection": color,
            "caret": color,
        ]),
        "typography": .object([
            "font": .object(["family": .leaf]),
            "size": .leaf,
            "weight": .leaf,
            "lineSpacing": .leaf,
        ]),
        "header": .object(["height": .leaf, "fill": color, "showsTitle": .leaf]),
        "collapsed": .object(["height": .leaf, "showsFirstLine": .leaf]),
        "decoration": .object([
            "element": .leaf,
            "anchor": .leaf,
            "origin": .leaf,
            "offset": .object(["x": .leaf, "y": .leaf]),
            "rotation": .leaf,
            "hidden": .leaf,
        ]),
        "icons": .object(["tint": color, "template": .leaf]),
        "resizeHandle": .object(["visibility": .leaf, "tint": color]),
        "library": .object([
            "accent": color,
            "sidebarMaterial": .appearance(.leaf),
            "cardStyle": .leaf,
            "background": color,
        ]),
        "voiceOrb": .object(["states": .objectOf(orbAnimation)]),
        "sounds": .object(["volume": .leaf, "mute": .array(.leaf)]),
        "highContrast": .object([
            "surface.fill": color,
            "surface.text.color": color,
        ]),
    ])
}

private struct JSONDynamicKey: CodingKey {
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

private enum JSONValue: Decodable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([Member])

    struct Member {
        let key: String
        let value: JSONValue
    }

    init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if single.decodeNil() {
            self = .null
            return
        }
        if let value = try? single.decode(Bool.self) {
            self = .bool(value)
            return
        }
        if let value = try? single.decode(Double.self) {
            self = .number(value)
            return
        }
        if let value = try? single.decode(String.self) {
            self = .string(value)
            return
        }

        if let keyed = try? decoder.container(keyedBy: JSONDynamicKey.self) {
            var members: [Member] = []
            for key in keyed.allKeys {
                members.append(Member(
                    key: key.stringValue,
                    value: try keyed.decode(JSONValue.self, forKey: key)
                ))
            }
            self = .object(members)
            return
        }

        if var unkeyed = try? decoder.unkeyedContainer() {
            var elements: [JSONValue] = []
            while !unkeyed.isAtEnd {
                elements.append(try unkeyed.decode(JSONValue.self))
            }
            self = .array(elements)
            return
        }

        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Unsupported JSON value"
            )
        )
    }
}
