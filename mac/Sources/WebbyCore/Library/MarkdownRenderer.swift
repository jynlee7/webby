import Foundation

/// Renders a compiled document as deterministic UTF-8 Markdown with LF endings.
///
/// All note-controlled text is escaped. The only Markdown structure is the
/// renderer's headings, generated links and generated tag line.
public enum MarkdownRenderer {
    public static func render(_ document: CompiledDocument) -> String {
        var lines: [String] = []
        lines.append("# " + escape(document.title))
        lines.append("")

        for section in document.sections {
            lines.append("## " + escape(section.heading))
            lines.append("")

            for note in section.notes {
                lines.append("### " + escape(note.title))
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

    private static func escape(_ text: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(text.count)

        for character in text {
            switch character {
            case "&":
                escaped += "&amp;"
            case "<":
                escaped += "&lt;"
            case ">":
                escaped += "&gt;"
            case "\\", "`", "*", "_", "{", "}", "[", "]", "(", ")", "#", "!", "|", "~":
                escaped.append("\\")
                escaped.append(character)
            default:
                escaped.append(character)
            }
        }

        return escaped
    }

    /// Leading indentation creates code blocks even when punctuation is escaped.
    /// Renderer-owned numeric entities preserve the spaces as text instead.
    private static func escapeBodyLine(_ line: String) -> String {
        let leadingSpaces = line.prefix { $0 == " " }.count
        let remainder = String(line.dropFirst(leadingSpaces))
        var escaped = escape(remainder)

        if remainder.hasPrefix("- ") || remainder.hasPrefix("+ ") {
            escaped = "\\" + escaped
        } else if isOrderedListStart(remainder), let punctuation = escaped.firstIndex(of: ".") {
            escaped.insert("\\", at: punctuation)
        } else if isOrderedListStart(remainder, punctuation: ")"),
                  let punctuation = escaped.firstIndex(of: ")") {
            escaped.insert("\\", at: punctuation)
        } else if isSetextOrRule(remainder), !escaped.isEmpty {
            escaped.insert("\\", at: escaped.startIndex)
        }

        return String(repeating: "&#32;", count: leadingSpaces) + escaped
    }

    private static func isOrderedListStart(
        _ line: String,
        punctuation: Character = "."
    ) -> Bool {
        guard let index = line.firstIndex(of: punctuation), index != line.startIndex else {
            return false
        }
        let digits = line[..<index]
        let after = line.index(after: index)
        return digits.allSatisfy(\.isNumber)
            && after < line.endIndex
            && line[after].isWhitespace
    }

    private static func isSetextOrRule(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3, let first = trimmed.first,
              first == "-" || first == "="
        else { return false }
        return trimmed.allSatisfy { $0 == first }
    }

    private static func escapeLinkDestination(_ url: String) -> String {
        url.replacingOccurrences(of: "(", with: "%28")
            .replacingOccurrences(of: ")", with: "%29")
            .replacingOccurrences(of: "<", with: "%3C")
            .replacingOccurrences(of: ">", with: "%3E")
    }
}
