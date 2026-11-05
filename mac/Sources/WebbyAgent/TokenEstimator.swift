import Foundation

/// Estimates request size and applies the single documented per-note truncation.
///
/// The token estimate is `ceil(characters / 2.5)`. `characters` means Swift
/// Unicode scalars, so a single grapheme cluster cannot hide unbounded size.
/// Truncation still cuts only at `Character` boundaries.
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

    /// The size of `text` for every budget check: its Unicode scalar count.
    public static func size(_ text: some StringProtocol) -> Int {
        text.unicodeScalars.count
    }

    public static func estimate(_ text: String) -> Int {
        tokens(forCharacters: size(text))
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
        return min(size(text), cap)
    }

    /// Truncates at the last sentence boundary that fits, then falls back to a
    /// `Character` boundary. Sizes are Unicode scalars, so one grapheme cluster
    /// cannot exceed the cap; a `Character` larger than the budget is dropped.
    /// The omitted-character marker is counted inside the same cap. The same
    /// input always produces the same result.
    public static func truncate(
        _ text: String,
        maxCharacters: Int,
        alias: String
    ) -> Truncation {
        let characters = Array(text)
        // cumulative[i] is the scalar size of the first i Characters.
        var cumulative = [0]
        cumulative.reserveCapacity(characters.count + 1)
        for character in characters {
            cumulative.append(cumulative[cumulative.count - 1] + character.unicodeScalars.count)
        }
        let total = cumulative[characters.count]
        guard maxCharacters > 0 else {
            return Truncation(
                text: "",
                omittedCharacters: total,
                isTruncated: total > 0,
                marker: nil
            )
        }
        guard total > maxCharacters else {
            return Truncation(
                text: text,
                omittedCharacters: 0,
                isTruncated: false,
                marker: nil
            )
        }

        /// The longest Character prefix whose scalar size is at most `limit`.
        func longestPrefix(fitting limit: Int, upTo end: Int) -> Int {
            var index = end
            while index > 0, cumulative[index] > limit {
                index -= 1
            }
            return index
        }

        // The marker grows with the omitted digit count, so converge before
        // choosing the sentence cut.
        var bodyLimit = maxCharacters
        for _ in 0..<8 {
            let marker = marker(omittedCharacters: total - bodyLimit, alias: alias)
            let next = max(0, maxCharacters - size(marker))
            if next == bodyLimit {
                break
            }
            bodyLimit = next
        }

        var keep = longestPrefix(fitting: bodyLimit, upTo: characters.count)
        if keep > 0 {
            let prefix = characters[0..<keep]
            if let sentenceEnd = prefix.lastIndex(where: { ".!?".contains($0) }) {
                keep = sentenceEnd + 1
            }
        }

        var markerText = marker(omittedCharacters: total - cumulative[keep], alias: alias)
        if size(markerText) > maxCharacters {
            // A tiny cap cannot fit the explanatory marker; return a hard prefix
            // that still respects the caller's bound.
            let hard = longestPrefix(fitting: maxCharacters, upTo: characters.count)
            return Truncation(
                text: String(characters[0..<hard]),
                omittedCharacters: total - cumulative[hard],
                isTruncated: true,
                marker: nil
            )
        }
        // The sentence cut can occasionally add enough marker digits to exceed
        // the cap. Reduce by whole Characters, never through a grapheme.
        while keep > 0, cumulative[keep] + size(markerText) > maxCharacters {
            let overflow = cumulative[keep] + size(markerText) - maxCharacters
            keep = longestPrefix(fitting: cumulative[keep] - overflow, upTo: keep - 1)
            markerText = marker(omittedCharacters: total - cumulative[keep], alias: alias)
        }

        return Truncation(
            text: String(characters[0..<keep]),
            omittedCharacters: total - cumulative[keep],
            isTruncated: true,
            marker: markerText
        )
    }

    public static func marker(omittedCharacters: Int, alias: String) -> String {
        "[truncated: \(omittedCharacters) chars omitted; read_note(\"\(alias)\")]"
    }
}
