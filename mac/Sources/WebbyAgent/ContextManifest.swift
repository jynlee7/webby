import Foundation

/// What the agent was allowed to see for one turn.
///
/// The manifest records included, truncated and omitted notes with their sent
/// revisions. It is also the persisted "What the agent saw" value for a turn.
public struct ContextManifest: Equatable, Sendable {
    public static let maxOmittedLines = 50

    public enum Status: String, Equatable, Sendable {
        case included
        case truncated
        case omitted
    }

    public struct Entry: Equatable, Sendable {
        public let alias: String
        public let noteID: UUID
        public let status: Status
        public let revision: Int
        public let page: String
        public let updated: String
        public let summary: String
        public let omittedCharacters: Int

        public init(
            alias: String,
            noteID: UUID,
            status: Status,
            revision: Int,
            page: String,
            updated: String,
            summary: String,
            omittedCharacters: Int = 0
        ) {
            self.alias = alias
            self.noteID = noteID
            self.status = status
            self.revision = revision
            self.page = page
            self.updated = updated
            self.summary = summary
            self.omittedCharacters = omittedCharacters
        }
    }

    public struct ScreenStatus: Equatable, Sendable {
        public let captured: Bool
        public let label: String?
        public let capturedAt: String?

        public init(captured: Bool = false, label: String? = nil, capturedAt: String? = nil) {
            self.captured = captured
            self.label = label
            self.capturedAt = capturedAt
        }

        public static let notCaptured = ScreenStatus()
    }

    public let entries: [Entry]
    public let omittedLines: [String]
    public let screen: ScreenStatus

    public var included: [Entry] {
        entries.filter { $0.status == .included }
    }

    public var truncated: [Entry] {
        entries.filter { $0.status == .truncated }
    }

    public var omitted: [Entry] {
        entries.filter { $0.status == .omitted }
    }

    public var renderedOmitted: String {
        omittedLines.joined(separator: "\n")
    }

    public init(
        entries: [Entry],
        omittedLines: [String],
        screen: ScreenStatus = .notCaptured
    ) {
        self.entries = entries
        self.omittedLines = Array(omittedLines.prefix(Self.maxOmittedLines))
        self.screen = screen
    }

    /// `N3 · first line · page · 2026-10-20`
    public static func line(
        alias: String,
        summary: String,
        page: String,
        updated: String
    ) -> String {
        "\(alias) · \(summary) · \(page) · \(updated)"
    }
}
