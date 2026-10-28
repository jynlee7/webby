import Foundation

/// The deterministic ranking rules for library search results.
public enum SearchRanking {
    /// The folding used for both cached note text and query values.
    public static func fold(_ text: String) -> String {
        text.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: nil
        )
    }

    /// The note title: its first physical line, without trimming.
    public static func firstLine(of text: String) -> String {
        guard let newline = text.firstIndex(where: { $0.isNewline }) else { return text }
        return String(text[..<newline])
    }

    /// Calculates a result tier from unfolded values.
    public static func tier(
        textClauses: [String],
        firstLine: String,
        fullText: String
    ) -> Int {
        tier(
            foldedTextClauses: textClauses.map(fold),
            foldedFirstLine: fold(firstLine),
            foldedFullText: fold(fullText)
        )
    }

    static func tier(
        foldedTextClauses: [String],
        foldedFirstLine: String,
        foldedFullText: String
    ) -> Int {
        guard !foldedTextClauses.isEmpty else { return 0 }

        let phrase = foldedTextClauses.joined(separator: " ")
        if foldedFirstLine.contains(phrase) {
            return 0
        }

        if foldedTextClauses.allSatisfy({ foldedFirstLine.contains($0) }) {
            return 1
        }

        if foldedTextClauses.allSatisfy({ foldedFullText.contains($0) }) {
            return 2
        }

        return 3
    }

    /// Orders lower tiers first, then newest edits, then lowercase UUID.
    public static func isOrderedBefore(
        tier lhsTier: Int,
        updatedAt lhsUpdatedAt: Date,
        id lhsID: UUID,
        tier rhsTier: Int,
        updatedAt rhsUpdatedAt: Date,
        id rhsID: UUID
    ) -> Bool {
        if lhsTier != rhsTier {
            return lhsTier < rhsTier
        }
        if lhsUpdatedAt != rhsUpdatedAt {
            return lhsUpdatedAt > rhsUpdatedAt
        }
        return lhsID.uuidString.lowercased() < rhsID.uuidString.lowercased()
    }
}
