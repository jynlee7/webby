import Foundation

public enum Tags {
    private enum URLScan {
        case url(end: Int)
        /// No URL here; `stop` is the first position that cannot belong to the same
        /// scheme run, so the caller can skip the span it already examined.
        case notURL(stop: Int)
    }

    public static func parse(_ text: String) -> [LibraryTag] {
        let scalars = Array(text.unicodeScalars)
        var result: [LibraryTag] = []
        var seen: Set<String> = []
        var index = 0

        while index < scalars.count {
            switch scanURL(in: scalars, at: index) {
            case .url(let end):
                index = end
                continue
            case .notURL(let stop):
                if stop > index {
                    index = stop
                    continue
                }
            }

            guard scalars[index] == "#", isTagBoundary(in: scalars, at: index) else {
                index += 1
                continue
            }

            let nameStart = index + 1
            guard nameStart < scalars.count, isTagFirst(scalars[nameStart]) else {
                index += 1
                continue
            }

            var end = nameStart + 1
            while end < scalars.count, isTagContinuation(scalars[end]) {
                end += 1
            }

            let name = String(String.UnicodeScalarView(scalars[nameStart..<end]))
                .precomposedStringWithCanonicalMapping
            let searchKey = name.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: nil
            )

            if seen.insert(searchKey).inserted {
                result.append(LibraryTag(name: name, searchKey: searchKey))
            }

            index = end
        }

        return result
    }

    private static func scanURL(in scalars: [Unicode.Scalar], at index: Int) -> URLScan {
        guard isURLBoundary(in: scalars, at: index) else { return .notURL(stop: index) }

        if isWWW(in: scalars, at: index) {
            return .url(end: urlSpanEnd(in: scalars, from: index + 4))
        }

        guard isASCIIAlpha(scalars[index]) else { return .notURL(stop: index) }

        var cursor = index + 1
        while cursor < scalars.count, isSchemeCharacter(scalars[cursor]) {
            cursor += 1
        }
        guard cursor < scalars.count, scalars[cursor] == ":" else {
            // Every start inside this run fails the same way, but a `www.` URL can
            // still begin inside it, so check that span before skipping it.
            if let www = wwwStart(in: scalars, from: index + 1, to: cursor) {
                return .url(end: urlSpanEnd(in: scalars, from: www + 4))
            }
            return .notURL(stop: max(cursor, index + 1))
        }

        return .url(end: urlSpanEnd(in: scalars, from: cursor + 1))
    }

    private static func wwwStart(
        in scalars: [Unicode.Scalar],
        from start: Int,
        to end: Int
    ) -> Int? {
        var index = start
        while index < end {
            if isWWW(in: scalars, at: index), isURLBoundary(in: scalars, at: index) {
                return index
            }
            index += 1
        }
        return nil
    }

    private static func urlSpanEnd(in scalars: [Unicode.Scalar], from start: Int) -> Int {
        var end = start
        while end < scalars.count {
            let scalar = scalars[end]
            if scalar.properties.isWhitespace || scalar == "<" || scalar == ">" || scalar == "\"" {
                break
            }
            end += 1
        }
        return end
    }

    private static func isWWW(in scalars: [Unicode.Scalar], at index: Int) -> Bool {
        guard index + 3 < scalars.count else { return false }
        return isASCII(scalars[index], "w")
            && isASCII(scalars[index + 1], "w")
            && isASCII(scalars[index + 2], "w")
            && scalars[index + 3] == "."
    }

    private static func isASCII(_ scalar: Unicode.Scalar, _ lowercase: Unicode.Scalar) -> Bool {
        scalar.value == lowercase.value || scalar.value == lowercase.value - 0x20
    }

    private static func isASCIIAlpha(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value >= 0x41 && scalar.value <= 0x5A)
            || (scalar.value >= 0x61 && scalar.value <= 0x7A)
    }

    private static func isSchemeCharacter(_ scalar: Unicode.Scalar) -> Bool {
        isASCIIAlpha(scalar)
            || (scalar.value >= 0x30 && scalar.value <= 0x39)
            || scalar == "+"
            || scalar == "."
            || scalar == "-"
    }

    private static func isURLBoundary(in scalars: [Unicode.Scalar], at index: Int) -> Bool {
        guard index > 0 else { return true }
        let previous = scalars[index - 1]
        return !(isLetterOrNumber(previous) || previous == "_")
    }

    private static func isTagBoundary(in scalars: [Unicode.Scalar], at index: Int) -> Bool {
        guard index > 0 else { return true }
        let previous = scalars[index - 1]
        return !(isLetterOrNumber(previous)
            || previous == "_"
            || previous == "#"
            || previous == "/"
            || previous == "\\")
    }

    private static func isTagFirst(_ scalar: Unicode.Scalar) -> Bool {
        isLetterOrNumber(scalar) || scalar == "_"
    }

    private static func isTagContinuation(_ scalar: Unicode.Scalar) -> Bool {
        isTagFirst(scalar) || isCombiningMark(scalar) || scalar == "-"
    }

    private static func isLetterOrNumber(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber:
            return true
        default:
            return false
        }
    }

    private static func isCombiningMark(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark:
            return true
        default:
            return false
        }
    }
}
