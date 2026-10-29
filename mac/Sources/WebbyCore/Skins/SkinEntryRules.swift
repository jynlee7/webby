import Foundation

/// The entry-name allowlist for a `.webbyskin` archive.
///
/// This lane receives logical, root-relative names. Wrapper-folder stripping and
/// ZIP reading belong to the archive layer. Only names that pass the structural
/// safety checks may be admitted; harmless unknown files produce warnings.
public enum SkinEntryRules {
    private static let archiveExtensions: Set<String> = [
        "zip", "webbyskin", "osk", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar",
    ]

    private static let fontExtensions: Set<String> = [
        "otf", "ttf", "ttc", "dfont", "woff", "woff2",
    ]

    private static let executableExtensions: Set<String> = [
        "app", "exe", "dll", "so", "dylib", "bundle", "com", "bat", "cmd",
        "sh", "bash", "zsh", "fish", "command", "mach-o", "o", "a", "jar",
        "class", "wasm",
    ]

    private static let soundExtensions: Set<String> = ["wav", "aif", "aiff", "caf"]

    private static let maximumOrbFrame = 59

    public static func classify(_ rawPath: String) -> SkinEntryDisposition {
        if rawPath.isEmpty {
            return .rejected("empty path")
        }
        if rawPath.contains("\0") {
            return .rejected("NUL byte in path")
        }
        if rawPath.contains("\\") {
            return .rejected("backslash in path")
        }
        if rawPath.hasPrefix("/") {
            return .rejected("absolute path")
        }
        if hasDrivePrefix(rawPath) {
            return .rejected("drive prefix")
        }
        if rawPath.contains("..") {
            return .rejected("path traversal")
        }

        let components = rawPath.split(separator: "/", omittingEmptySubsequences: false)
        let extensionName = fileExtension(of: rawPath)

        if archiveExtensions.contains(extensionName) {
            return .rejected("nested archive")
        }
        if fontExtensions.contains(extensionName) {
            return .rejected("font file")
        }
        if executableExtensions.contains(extensionName) {
            return .rejected("executable file")
        }

        if components.last == ".DS_Store" || rawPath == "__MACOSX" || rawPath.hasPrefix("__MACOSX/") {
            return .skipped
        }

        if rawPath == "skin.json" {
            return .accepted(SkinEntry(path: rawPath))
        }
        if rawPath == "preview.png" || rawPath == "preview@2x.png" {
            return .accepted(SkinEntry(path: rawPath))
        }

        // Accepted names are lowercase. If the lowercased spelling would be
        // admitted, the uppercase spelling is a rejected, not a warning.
        if rawPath != rawPath.lowercased(), acceptedEntry(path: rawPath.lowercased()) != nil {
            return .rejected("uppercase file name")
        }

        if rawPath.hasPrefix("images/") {
            return classifyImage(rawPath)
        }
        if rawPath.hasPrefix("sounds/") {
            return classifySound(rawPath)
        }

        return .warning("unknown file")
    }

    private static func classifyImage(_ path: String) -> SkinEntryDisposition {
        guard path.hasSuffix(".png") else {
            return .warning("unknown file")
        }

        let stem = String(path.dropFirst("images/".count).dropLast(".png".count))
        guard !stem.isEmpty else {
            return .rejected("missing image name")
        }

        var remainder = stem
        var scale = SkinScale.one

        if remainder.hasSuffix("@2x") {
            scale = .two
            remainder.removeLast("@2x".count)
        } else if remainder.hasSuffix("@1x") || remainder.hasSuffix("@3x") {
            return .rejected("unsupported image scale")
        }

        var appearance: SkinAppearance?
        if remainder.hasSuffix("~dark") {
            appearance = .dark
            remainder.removeLast("~dark".count)
        }

        if remainder.contains("@") || remainder.contains("~") {
            return .rejected("malformed image suffix order")
        }
        guard !remainder.isEmpty else {
            return .rejected("missing image name")
        }

        if remainder.hasPrefix("orb-") {
            return classifyOrb(
                String(remainder.dropFirst("orb-".count)),
                path: path,
                appearance: appearance,
                scale: scale
            )
        }

        if let element = SkinImageElement(rawValue: remainder) {
            return .accepted(SkinEntry(
                path: path,
                asset: .image(element: element, appearance: appearance, scale: scale)
            ))
        }

        if let frame = frameSuffix(of: remainder),
           SkinImageElement(rawValue: frame.element) != nil {
            return .rejected("static image cannot have a frame")
        }

        return .rejected("unknown image element")
    }

    private static func classifyOrb(
        _ remainder: String,
        path: String,
        appearance: SkinAppearance?,
        scale: SkinScale
    ) -> SkinEntryDisposition {
        guard let separator = remainder.lastIndex(of: "-") else {
            return .rejected("orb image requires a frame")
        }

        let stateName = String(remainder[..<separator])
        let frameName = String(remainder[remainder.index(after: separator)...])

        guard let state = SkinOrbState.Known(rawValue: stateName) else {
            return .rejected("unknown orb state")
        }
        guard isCanonicalFrame(frameName), let frame = Int(frameName) else {
            return .rejected("non-canonical orb frame")
        }
        guard frame <= maximumOrbFrame else {
            return .rejected("orb frame out of range")
        }

        return .accepted(SkinEntry(
            path: path,
            asset: .orb(state: state, frame: frame, appearance: appearance, scale: scale)
        ))
    }

    private static func classifySound(_ path: String) -> SkinEntryDisposition {
        let extensionName = fileExtension(of: path)
        guard soundExtensions.contains(extensionName) else {
            return .warning("unknown file")
        }

        let fileName = String(path.dropFirst("sounds/".count))
        guard let separator = fileName.lastIndex(of: ".") else {
            return .warning("unknown file")
        }

        let eventName = String(fileName[..<separator])
        guard let event = SkinSoundEvent.Known(rawValue: eventName) else {
            return .rejected("unknown sound event")
        }

        return .accepted(SkinEntry(path: path, asset: .sound(event: .known(event))))
    }

    private static func acceptedEntry(path: String) -> SkinEntry? {
        let disposition = classifyAcceptedLowercase(path)
        guard case .accepted(let entry) = disposition else {
            return nil
        }
        return entry
    }

    /// Parses only the accepted grammar. Callers use this for the lowercase
    /// case-fold check; `classify` handles rejection reasons for real names.
    private static func classifyAcceptedLowercase(_ path: String) -> SkinEntryDisposition {
        if path == "skin.json" || path == "preview.png" || path == "preview@2x.png" {
            return .accepted(SkinEntry(path: path))
        }

        if path.hasPrefix("images/") && path.hasSuffix(".png") {
            let stem = String(path.dropFirst("images/".count).dropLast(".png".count))
            return parseLowercaseImageStem(stem, path: path) ?? .warning("unknown file")
        }

        if path.hasPrefix("sounds/") {
            let extensionName = fileExtension(of: path)
            guard soundExtensions.contains(extensionName) else {
                return .warning("unknown file")
            }
            let fileName = String(path.dropFirst("sounds/".count))
            guard let separator = fileName.lastIndex(of: "."),
                  let event = SkinSoundEvent.Known(rawValue: String(fileName[..<separator])) else {
                return .rejected("unknown sound event")
            }
            return .accepted(SkinEntry(path: path, asset: .sound(event: .known(event))))
        }

        return .warning("unknown file")
    }

    private static func parseLowercaseImageStem(_ stem: String, path: String) -> SkinEntryDisposition? {
        var remainder = stem
        var scale = SkinScale.one

        if remainder.hasSuffix("@2x") {
            scale = .two
            remainder.removeLast("@2x".count)
        } else if remainder.hasSuffix("@1x") || remainder.hasSuffix("@3x") {
            return .rejected("unsupported image scale")
        }

        var appearance: SkinAppearance?
        if remainder.hasSuffix("~dark") {
            appearance = .dark
            remainder.removeLast("~dark".count)
        }

        guard !remainder.contains("@"), !remainder.contains("~"), !remainder.isEmpty else {
            return nil
        }

        if remainder.hasPrefix("orb-") {
            let orbRemainder = String(remainder.dropFirst("orb-".count))
            guard let separator = orbRemainder.lastIndex(of: "-") else {
                return nil
            }
            let stateName = String(orbRemainder[..<separator])
            let frameName = String(orbRemainder[orbRemainder.index(after: separator)...])
            guard let state = SkinOrbState.Known(rawValue: stateName) else {
                return nil
            }
            guard isCanonicalFrame(frameName), let frame = Int(frameName), frame <= maximumOrbFrame else {
                return nil
            }
            return .accepted(SkinEntry(
                path: path,
                asset: .orb(state: state, frame: frame, appearance: appearance, scale: scale)
            ))
        }

        guard let element = SkinImageElement(rawValue: remainder) else {
            return nil
        }
        return .accepted(SkinEntry(
            path: path,
            asset: .image(element: element, appearance: appearance, scale: scale)
        ))
    }

    private static func frameSuffix(of elementName: String) -> (element: String, frame: String)? {
        guard let separator = elementName.lastIndex(of: "-") else {
            return nil
        }
        let frame = String(elementName[elementName.index(after: separator)...])
        guard isCanonicalFrame(frame) else {
            return nil
        }
        return (String(elementName[..<separator]), frame)
    }

    private static func isCanonicalFrame(_ value: String) -> Bool {
        guard !value.isEmpty, value.allSatisfy({ $0 >= "0" && $0 <= "9" }) else {
            return false
        }
        return value == "0" || value.first != "0"
    }

    private static func fileExtension(of path: String) -> String {
        guard let separator = path.lastIndex(of: ".") else {
            return ""
        }
        return path[path.index(after: separator)...].lowercased()
    }

    private static func hasDrivePrefix(_ path: String) -> Bool {
        let characters = Array(path)
        guard characters.count >= 2, characters[1] == ":" else {
            return false
        }
        let first = characters[0]
        return (first >= "A" && first <= "Z") || (first >= "a" && first <= "z")
    }
}
