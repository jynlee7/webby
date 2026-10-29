import Foundation

/// Renders a compiled document as a complete, deterministic HTML document.
///
/// The page has no scripts, images, fonts or remote styles. Note-controlled text
/// and attributes are escaped, and the CSP allows only renderer-owned inline CSS.
public enum HTMLRenderer {
    public static func render(_ document: CompiledDocument) -> String {
        var lines: [String] = []

        lines.append("<!DOCTYPE html>")
        lines.append("<html lang=\"en\">")
        lines.append("<head>")
        lines.append("<meta charset=\"utf-8\">")
        lines.append("<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; style-src 'unsafe-inline'\">")
        lines.append("<title>" + escape(document.title) + "</title>")
        lines.append("<style>")
        lines.append(contentsOf: styleSheet.components(separatedBy: "\n"))
        lines.append("</style>")
        lines.append("</head>")
        lines.append("<body>")
        lines.append("<main>")
        lines.append("<h1>" + escape(document.title) + "</h1>")

        for section in document.sections {
            lines.append("<section>")
            lines.append("<h2>" + escape(section.heading) + "</h2>")

            for note in section.notes {
                lines.append("<article class=\"note\">")
                lines.append("<h3>" + escape(note.title) + "</h3>")

                if !note.body.isEmpty {
                    lines.append("<div class=\"body\">" + escape(note.body) + "</div>")
                }

                lines.append(metadata(for: note))
                lines.append("</article>")
            }

            lines.append("</section>")
        }

        lines.append("</main>")
        lines.append("</body>")
        lines.append("</html>")

        return lines.joined(separator: "\n") + "\n"
    }

    private static func metadata(for note: CompiledNote) -> String {
        var markup = "<p class=\"meta\">"
        markup += "<a href=\"" + escape(note.noteLink.url) + "\">Open note</a>"

        if let pageLink = note.pageLink {
            markup += " · <a href=\"" + escape(pageLink.url) + "\">Open page</a>"
        }

        markup += " · created " + CompiledFormatting.utcDate(note.createdAt)

        var states: [String] = []
        if note.isHidden { states.append("hidden") }
        if note.isCollapsed { states.append("collapsed") }
        if note.isExcludedFromAgent { states.append("keep away from AI") }
        if !states.isEmpty {
            markup += " · <span class=\"states\">" + escape(states.joined(separator: ", ")) + "</span>"
        }

        if !note.tags.isEmpty {
            let tags = note.tags
                .map { "<span class=\"tag\">#" + escape($0) + "</span>" }
                .joined(separator: " ")
            markup += " · " + tags
        }

        markup += "</p>"
        return markup
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
            case "\"":
                escaped += "&quot;"
            case "'":
                escaped += "&#39;"
            default:
                escaped.append(character)
            }
        }

        return escaped
    }

    private static let styleSheet = """
    :root { color-scheme: light dark; }
    body { margin: 0; padding: 24px; font: 15px/1.5 -apple-system, BlinkMacSystemFont, sans-serif; }
    main { max-width: 720px; margin: 0 auto; }
    h1 { margin: 0 0 24px; font-size: 24px; }
    h2 { margin: 28px 0 12px; font-size: 18px; }
    h3 { margin: 0 0 8px; font-size: 15px; }
    .note { padding: 16px 0; border-top: 1px solid #8884; }
    .body { white-space: pre-wrap; }
    .meta { margin: 8px 0 0; color: #666; font-size: 13px; }
    .states { font-weight: 600; }
    a { color: inherit; }
    .tag { margin-right: 4px; }
    """
}
