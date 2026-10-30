import Foundation

/// Estimates request size and applies the single documented per-note truncation.
///
/// The token estimate is `ceil(characters / 2.5)`. `characters` means Swift
/// `Character` values, so a combining sequence or an emoji is never split.
public enum TokenEstimator {
    /// One named constant shared by packing and tests.
    public static let charsPerToken: Double = 2.5
    /// The per-note cap from plan.md §5.3.6.
    public static let maxNoteTokens = 1_500

    public struct Truncation: Equatable, Sendable {
        public let text: String
        public let omittedCharacters: Int
        public let isTruncated: Bool
        public let marker: String?

        public init(
            text: String,
            omittedCharacters: Int,
            isTruncated: Bool,
            marker: String?
        ) {
            self.text = text
            self.omittedCharacters = omittedCharacters
            self.isTruncated = isTruncated
            self.marker = marker
        }
    }

    public static func estimate(_ text: String) -> Int {
        tokens(forCharacters: text.count)
    }

    public static func tokens(forCharacters characters: Int) -> Int {
        guard characters > 0 else { return 0 }
        return Int(ceil(Double(characters) / charsPerToken))
    }

    public static func maxCharacters(forTokens tokens: Int) -> Int {
        guard tokens > 0 else { return 0 }
        return Int(floor(Double(tokens) * charsPerToken))
    }

    public static func estimateNoteCharactersTruncatedToCap(_ text: String) -> Int {
        let cap = maxCharacters(forTokens: maxNoteTokens)
        return min(text.count, cap)
    }

    /// Truncates at the last sentence boundary that fits, then falls back to a
    /// `Character` boundary. The omitted-character marker is counted inside the
    /// same cap. The same input always produces the same result.
    public static func truncate(
        _ text: String,
        maxCharacters: Int,
        alias: String
    ) -> Truncation {
        let characters = Array(text)
        let total = characters.count
        guard maxCharacters > 0, total > maxCharacters else {
            return Truncation(
                text: text,
                omittedCharacters: 0,
                isTruncated: false,
                marker: nil
            )
        }

        // The marker grows with the omitted digit count, so converge before
        // choosing the sentence cut.
        var bodyLimit = maxCharacters
        for _ in 0..<8 {
            let marker = marker(omittedCharacters: total - bodyLimit, alias: alias)
            let next = max(0, maxCharacters - marker.count)
            if next == bodyLimit {
                break
            }
            bodyLimit = next
        }

        var keep = bodyLimit
        if keep > 0 {
            let prefix = characters[0..<keep]
            if let sentenceEnd = prefix.lastIndex(where: { ".!?".contains($0) }) {
                keep = sentenceEnd + 1
            }
        }

        var body = String(characters[0..<keep])
        var markerText = marker(omittedCharacters: total - keep, alias: alias)
        // The sentence cut can occasionally add enough marker digits to exceed
        // the cap. Reduce by whole Characters, never through a grapheme.
        while keep > 0, body.count + markerText.count > maxCharacters {
            let overflow = body.count + markerText.count - maxCharacters
            keep = max(0, keep - max(1, overflow))
            body = String(characters[0..<keep])
            markerText = marker(omittedCharacters: total - keep, alias: alias)
        }

        return Truncation(
            text: body,
            omittedCharacters: total - keep,
            isTruncated: true,
            marker: markerText
        )
    }

    public static func marker(omittedCharacters: Int, alias: String) -> String {
        "[truncated: \(omittedCharacters) chars omitted; read_note(\"\(alias)\")]"
    }
}
