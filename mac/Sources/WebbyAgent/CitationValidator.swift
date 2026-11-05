import Foundation
import WebbyCore

/// Validates `[N#]` citations from an answer against one immutable turn snapshot.
///
/// Only aliases that were authorized and sent or read may remain. Unknown and
/// retired aliases are removed from the answer text. A citation keeps the stored
/// revision and a small snippet so later UI can show "edited since", "note deleted"
/// or "now excluded" without re-reading a live store.
public enum CitationValidator {
    public enum Status: String, Codable, Equatable, Sendable {
        case current
        case edited
        case deleted
        case excluded
    }

    public struct Citation: Codable, Equatable, Sendable {
        public let alias: String
        public let noteID: UUID
        public let revision: Int
        public let status: Status
        public let snippet: String?

        public init(
            alias: String,
            noteID: UUID,
            revision: Int,
            status: Status = .current,
            snippet: String? = nil
        ) {
            self.alias = alias
            self.noteID = noteID
            self.revision = revision
            self.status = status
            self.snippet = snippet
        }
    }

    public struct Validation: Equatable, Sendable {
        /// The answer with unknown or retired citation markers removed.
        public let answerText: String
        /// Citations in first-appearance order, with duplicates removed.
        public let citations: [Citation]

        public init(answerText: String, citations: [Citation]) {
            self.answerText = answerText
            self.citations = citations
        }
    }

    /// - Parameters:
    ///   - sentAliases: Aliases present in the sent notes block or manifest. `nil`
    ///     means every alias in the snapshot was sent.
    ///   - readAliases: Aliases returned by a successful `read_note` call.
    ///   - liveNotes: Optional current notes used only to classify a citation as
    ///     current, edited, deleted or excluded. Missing entries count as deleted.
    public static func validate(
        answerText: String,
        snapshot: AgentTurnSnapshot,
        sentAliases: Set<String>? = nil,
        readAliases: Set<String> = [],
        liveNotes: [UUID: Note]? = nil
    ) -> Validation {
        let authorized = Set(snapshot.notesByAlias.keys)
        let defaultSent = Set(snapshot.notesByAlias.compactMap { alias, note in
            note.status == .omitted ? nil : alias
        })
        let sent = sentAliases.map { $0.intersection(authorized) } ?? defaultSent
        let eligible = sent.union(readAliases.intersection(authorized))

        let characters = Array(answerText)
        var sanitized = ""
        sanitized.reserveCapacity(answerText.count)
        var citations: [Citation] = []
        var seen: Set<String> = []
        var index = 0

        while index < characters.count {
            if characters[index] == "[",
               let parsed = parseAlias(characters, from: index),
               eligible.contains(parsed.alias) {
                if seen.insert(parsed.alias).inserted,
                   let note = snapshot.notesByAlias[parsed.alias] {
                    citations.append(citation(
                        alias: parsed.alias,
                        note: note,
                        liveNotes: liveNotes
                    ))
                }
                sanitized += String(characters[index...parsed.end])
                index = parsed.end + 1
                continue
            } else if characters[index] == "[",
                      let parsed = parseAlias(characters, from: index),
                      !eligible.contains(parsed.alias) {
                // Drop the marker, keep all surrounding answer text.
                index = parsed.end + 1
                continue
            }

            sanitized.append(characters[index])
            index += 1
        }

        return Validation(answerText: sanitized, citations: citations)
    }

    private static func citation(
        alias: String,
        note: AgentTurnSnapshot.AuthorizedNote,
        liveNotes: [UUID: Note]?
    ) -> Citation {
        var status = Status.current
        if let liveNotes {
            if let live = liveNotes[note.note.id] {
                if live.trashedAt != nil {
                    status = .deleted
                } else if live.excludedFromAgent {
                    status = .excluded
                } else if live.revision != note.note.revision {
                    status = .edited
                }
            } else {
                status = .deleted
            }
        }
        return Citation(
            alias: alias,
            noteID: note.note.id,
            revision: note.note.revision,
            status: status,
            snippet: note.note.summaryLine(limit: 120)
        )
    }

    private static func parseAlias(
        _ characters: [Character],
        from start: Int
    ) -> (alias: String, end: Int)? {
        guard start + 2 < characters.count,
              characters[start] == "[",
              characters[start + 1] == "N" else {
            return nil
        }
        var index = start + 2
        var digits = ""
        while index < characters.count, characters[index].isNumber {
            digits.append(characters[index])
            index += 1
        }
        guard !digits.isEmpty,
              index < characters.count,
              characters[index] == "]" else {
            return nil
        }
        return ("N" + digits, index)
    }
}
