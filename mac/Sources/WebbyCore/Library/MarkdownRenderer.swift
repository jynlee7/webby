import Foundation

/// Renders a compiled document as deterministic UTF-8 Markdown with LF endings.
///
/// All note-controlled text is escaped. The only Markdown structure is the
/// renderer's headings, generated links and generated tag line.
public enum MarkdownRenderer {
    public static func render(_ document: CompiledDocument) -> String {
        var lines: [String] = []
        lines.append("# " + escape(singleLine(document.title)))
        lines.append("")

        for section in document.sections {
            lines.append("## " + escape(singleLine(section.heading)))
            lines.append("")

            for note in section.notes {
                lines.append("### " + escape(singleLine(note.title)))
                lines.append("")

                if !note.body.isEmpty {
                    for line in note.body.components(separatedBy: "\n") {
                        lines.append(escapeBodyLine(line))
                    }
                    lines.append("")
                }

                lines.append(metadata(for: note))
                lines.append("")
            }
        }

        while lines.last == "" {
            lines.removeLast()
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func metadata(for note: CompiledNote) -> String {
        var parts = ["[Open note](\(note.noteLink.url))"]
        if let pageLink = note.pageLink {
            parts.append("[Open page](\(escapeLinkDestination(pageLink.url)))")
        }
        parts.append("created \(CompiledFormatting.utcDate(note.createdAt))")
        var states: [String] = []
        if note.isHidden { states.append("hidden") }
        if note.isCollapsed { states.append("collapsed") }
        if note.isExcludedFromAgent { states.append("keep away from AI") }
        if !states.isEmpty {
            parts.append(states.joined(separator: ", "))
        }
        if !note.tags.isEmpty {
            parts.append(note.tags.map { "#" + escape($0) }.joined(separator: " "))
        }
        return parts.joined(separator: " · ")
    }

    /// Headings are one line; any line break would start new block structure.
    private static func singleLine(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        for scalar in text.replacingOccurrences(of: "\r\n", with: "\n").unicodeScalars {
            if CharacterSet.newlines.contains(scalar) {
                result.append(" ")
            } else {
                result.append(scalar)
            }
        }
        return String(result)
    }

    /// Works on scalars so a combining mark cannot merge with a significant
    /// ASCII character into a grapheme that escapes nothing.
    private static func escape(_ text: String) -> String {
        var escaped = String.UnicodeScalarView()

        for scalar in text.unicodeScalars {
            switch scalar {
            case "&":
                escaped.append(contentsOf: "&amp;".unicodeScalars)
            case "<":
                escaped.append(contentsOf: "&lt;".unicodeScalars)
            case ">":
                escaped.append(contentsOf: "&gt;".unicodeScalars)
            case "\\", "`", "*", "_", "{", "}", "[", "]", "(", ")", "#", "!", "|", "~":
                escaped.append("\\")
                escaped.append(scalar)
            default:
                escaped.append(scalar)
            }
        }

        return String(escaped)
    }

    /// Leading indentation creates code blocks even when punctuation is escaped.
    /// Renderer-owned numeric entities preserve the spaces as text instead.
    private static func escapeBodyLine(_ line: String) -> String {
        var entityPrefix = ""
        var remainder = line.unicodeScalars[...]
        while let first = remainder.first, first == " " || first == "\t" {
            entityPrefix += first == " " ? "&#32;" : "&#9;"
            remainder = remainder.dropFirst()
        }
        let text = String(remainder)
        var escaped = escape(text).unicodeScalars

        if isBulletStart(remainder) {
            escaped.insert("\\", at: escaped.startIndex)
        } else if isOrderedListStart(remainder, punctuation: "."),
                  let punctuation = escaped.firstIndex(of: ".") {
            escaped.insert("\\", at: punctuation)
        } else if isOrderedListStart(remainder, punctuation: ")"),
                  let punctuation = escaped.firstIndex(of: ")") {
            escaped.insert("\\", at: punctuation)
        } else if isSetextOrRule(text), !escaped.isEmpty {
            escaped.insert("\\", at: escaped.startIndex)
        }

        return entityPrefix + String(escaped)
    }

    private static func isBulletStart(_ line: Substring.UnicodeScalarView) -> Bool {
        guard let first = line.first, first == "-" || first == "+" else { return false }
        let after = line.index(after: line.startIndex)
        return after < line.endIndex && (line[after] == " " || line[after] == "\t")
    }

    private static func isOrderedListStart(
        _ line: Substring.UnicodeScalarView,
        punctuation: Unicode.Scalar
    ) -> Bool {
        guard let index = line.firstIndex(of: punctuation), index != line.startIndex else {
            return false
        }
        let digits = line[..<index]
        let after = line.index(after: index)
        return digits.allSatisfy { $0.properties.numericType != nil }
            && after < line.endIndex
            && line[after].properties.isWhitespace
    }

    private static func isSetextOrRule(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces).unicodeScalars
        guard !trimmed.isEmpty, let first = trimmed.first,
              first == "-" || first == "="
        else { return false }
        // One or two characters are a setext underline; three or more are a rule.
        return trimmed.allSatisfy { $0 == first }
    }

    private static func escapeLinkDestination(_ url: String) -> String {
        url.replacingOccurrences(of: "(", with: "%28")
            .replacingOccurrences(of: ")", with: "%29")
            .replacingOccurrences(of: "<", with: "%3C")
            .replacingOccurrences(of: ">", with: "%3E")
    }
}
