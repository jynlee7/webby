import Foundation

/// A parsed library search. Every clause is required to match (logical AND).
///
/// Parsing is deliberately forgiving: a malformed token becomes literal text and
/// adds a diagnostic, so a half-typed query never crashes or silently drops text.
public struct SearchQuery: Equatable, Sendable {
    public enum State: String, Equatable, Sendable {
        case pinned
        case inbox
        case trashed
        case tab
        case hidden
    }

    public enum Scope: String, Equatable, Sendable {
        case page
        case prefix
        case site
    }

    public enum Clause: Equatable, Sendable {
        case text(String)
        case site(String)
        case app(String)
        case tag(String)
        case state(State)
        case scope(Scope)
        case updatedAfter(Date)
    }

    public struct Diagnostic: Equatable, Sendable {
        public let token: String
        public let message: String

        public init(token: String, message: String) {
            self.token = token
            self.message = message
        }
    }

    public let clauses: [Clause]
    public let diagnostics: [Diagnostic]

    public init(clauses: [Clause] = [], diagnostics: [Diagnostic] = []) {
        self.clauses = clauses
        self.diagnostics = diagnostics
    }

    public init(_ source: String) {
        self = Self.parse(source)
    }

    public static func parse(_ source: String) -> SearchQuery {
        let tokens = tokenize(source)
        var clauses: [Clause] = []
        var diagnostics: [Diagnostic] = []

        func recover(_ token: Token, message: String) {
            clauses.append(.text(token.raw))
            diagnostics.append(Diagnostic(token: token.raw, message: message))
        }

        for token in tokens {
            guard token.terminated else {
                recover(token, message: "unterminated quote")
                continue
            }

            guard let fieldName = token.fieldName else {
                clauses.append(.text(token.value))
                continue
            }

            let value = String(token.value.dropFirst(fieldName.count + 1))

            switch fieldName.lowercased() {
            case "site":
                guard !value.isEmpty else {
                    recover(token, message: "missing value for site")
                    continue
                }
                clauses.append(.site(value))

            case "app":
                guard !value.isEmpty else {
                    recover(token, message: "missing value for app")
                    continue
                }
                clauses.append(.app(value))

            case "tag":
                guard !value.isEmpty else {
                    recover(token, message: "missing value for tag")
                    continue
                }
                clauses.append(.tag(value))

            case "is":
                guard !value.isEmpty else {
                    recover(token, message: "missing value for is")
                    continue
                }
                guard let state = State(rawValue: value.lowercased()) else {
                    recover(token, message: "invalid state '\(value)'")
                    continue
                }
                clauses.append(.state(state))

            case "scope":
                guard !value.isEmpty else {
                    recover(token, message: "missing value for scope")
                    continue
                }
                guard let scope = Scope(rawValue: value.lowercased()) else {
                    recover(token, message: "invalid scope '\(value)'")
                    continue
                }
                clauses.append(.scope(scope))

            case "updated":
                guard !value.isEmpty else {
                    recover(token, message: "missing value for updated")
                    continue
                }
                guard value.hasPrefix(">") else {
                    recover(token, message: "unsupported updated operator")
                    continue
                }
                guard let date = parseDate(String(value.dropFirst())) else {
                    recover(token, message: "invalid updated date")
                    continue
                }
                clauses.append(.updatedAfter(date))

            default:
                recover(token, message: "unknown field '\(fieldName)'")
            }
        }

        return SearchQuery(clauses: clauses, diagnostics: diagnostics)
    }

    private struct Token {
        let raw: String
        let value: String
        let fieldName: String?
        let terminated: Bool
    }

    private static func tokenize(_ source: String) -> [Token] {
        let characters = Array(source)
        var tokens: [Token] = []
        var index = 0

        while index < characters.count {
            while index < characters.count, characters[index].isWhitespace {
                index += 1
            }
            guard index < characters.count else { break }

            let start = index
            var value = ""
            var fieldName: String?
            var fieldBuffer = ""
            var sawQuote = false
            var sawFieldColon = false
            var terminated = true

            while index < characters.count, !characters[index].isWhitespace {
                let character = characters[index]

                if character == "\"" {
                    sawQuote = true
                    index += 1
                    var closed = false

                    while index < characters.count {
                        let quoted = characters[index]

                        if quoted == "\\" {
                            if index + 1 < characters.count {
                                let next = characters[index + 1]
                                if next == "\"" || next == "\\" {
                                    value.append(next)
                                    index += 2
                                    continue
                                }
                            }
                            value.append("\\")
                            index += 1
                            continue
                        }

                        if quoted == "\"" {
                            closed = true
                            index += 1
                            break
                        }

                        value.append(quoted)
                        index += 1
                    }

                    if !closed {
                        terminated = false
                        break
                    }
                } else {
                    if character == ":", !sawQuote, !sawFieldColon {
                        fieldName = fieldBuffer
                        sawFieldColon = true
                    } else if !sawQuote, !sawFieldColon {
                        fieldBuffer.append(character)
                    }

                    value.append(character)
                    index += 1
                }
            }

            let raw = String(characters[start..<index])
            tokens.append(Token(
                raw: raw,
                value: value,
                fieldName: fieldName,
                terminated: terminated
            ))

            if !terminated {
                break
            }
        }

        return tokens
    }

    private static func parseDate(_ text: String) -> Date? {
        let scalars = Array(text.unicodeScalars)
        guard scalars.count == 10, scalars[4] == "-", scalars[7] == "-" else {
            return nil
        }

        func digits(_ range: Range<Int>) -> Int? {
            var result = 0
            for index in range {
                let scalar = scalars[index]
                guard scalar.value >= 48, scalar.value <= 57 else { return nil }
                result = result * 10 + Int(scalar.value - 48)
            }
            return result
        }

        guard let year = digits(0..<4),
              let month = digits(5..<7),
              let day = digits(8..<10),
              year >= 1,
              (1...12).contains(month)
        else { return nil }

        let timeZone = TimeZone(secondsFromGMT: 0)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = Locale(identifier: "en_US_POSIX")

        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = timeZone
        components.year = year
        components.month = month
        components.day = day

        guard let date = calendar.date(from: components) else { return nil }
        let checked = calendar.dateComponents([.year, .month, .day], from: date)
        guard checked.year == year, checked.month == month, checked.day == day else {
            return nil
        }
        return date
    }
}
