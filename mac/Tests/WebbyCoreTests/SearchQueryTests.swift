import Foundation
import Testing
@testable import WebbyCore

private func utcDate(_ year: Int, _ month: Int, _ day: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar.date(from: DateComponents(year: year, month: month, day: day))!
}

private func clauses(_ source: String) -> [SearchQuery.Clause] {
    SearchQuery.parse(source).clauses
}

@Test func parsesWhitespaceTokensAndQuotedPhrases() {
    let query = SearchQuery.parse(#"hash   "two words"  last"#)

    #expect(query.clauses == [
        .text("hash"),
        .text("two words"),
        .text("last"),
    ])
    #expect(query.diagnostics.isEmpty)
}

@Test func parsesEverySupportedField() {
    let query = SearchQuery.parse(
        "site:leetcode.com app:com.example.Notes tag:dp "
            + "is:pinned is:inbox is:trashed is:tab is:hidden "
            + "scope:page scope:prefix scope:site updated:>2024-02-29"
    )

    #expect(query.clauses == [
        .site("leetcode.com"),
        .app("com.example.Notes"),
        .tag("dp"),
        .state(.pinned),
        .state(.inbox),
        .state(.trashed),
        .state(.tab),
        .state(.hidden),
        .scope(.page),
        .scope(.prefix),
        .scope(.site),
        .updatedAfter(utcDate(2024, 2, 29)),
    ])
    #expect(query.diagnostics.isEmpty)
}

@Test func parsesQuotedFieldValuesAndSupportedEscapes() {
    let query = SearchQuery.parse(#"tag:"say \"hi\"" site:"Example.COM" "a\\b""#)

    #expect(query.clauses == [
        .tag(#"say "hi""#),
        .site("Example.COM"),
        .text(#"a\b"#),
    ])
    #expect(query.diagnostics.isEmpty)
}

@Test func onlyQuoteAndBackslashAreEscapes() {
    #expect(clauses(#""a\nb""#) == [.text(#"a\nb"#)])
    #expect(clauses(#""a\"b""#) == [.text(#"a"b"#)])
    #expect(clauses(#""a\\b""#) == [.text(#"a\b"#)])
}

@Test func emptyInputMatchesTheOrdinaryUniverseWithNoDiagnostics() {
    let query = SearchQuery.parse("   ")

    #expect(query.clauses.isEmpty)
    #expect(query.diagnostics.isEmpty)
}

@Test func recoversMalformedFieldsAsLiteralTextWithDiagnostics() {
    let source = "unknown:value site: tag: app: scope:nope is:maybe "
        + "updated:2024-01-01 updated:<2024-01-01 updated:>2023-02-29"
    let query = SearchQuery.parse(source)
    let tokens = source.split(separator: " ").map(String.init)

    #expect(query.clauses == tokens.map { .text($0) })
    #expect(query.diagnostics.count == tokens.count)
    #expect(query.diagnostics.map(\.token) == tokens)
}

@Test func recoversAnUnterminatedQuoteAsTheLiteralRemainder() {
    let query = SearchQuery.parse(#"start "unterminated tag:dp"#)

    #expect(query.clauses == [
        .text("start"),
        .text(#""unterminated tag:dp"#),
    ])
    #expect(query.diagnostics.count == 1)
    #expect(query.diagnostics.first?.token == #""unterminated tag:dp"#)
}

@Test func validatesActualGregorianCalendarDatesInUTC() {
    let valid = [
        "2024-02-29": utcDate(2024, 2, 29),
        "2000-02-29": utcDate(2000, 2, 29),
        "2023-01-01": utcDate(2023, 1, 1),
    ]

    for (text, date) in valid {
        let query = SearchQuery.parse("updated:>\(text)")
        #expect(query.clauses == [.updatedAfter(date)])
        #expect(query.diagnostics.isEmpty)
    }

    let invalid = [
        "2023-02-29",
        "1900-02-29",
        "2024-13-01",
        "2024-00-01",
        "2024-04-31",
        "2024-1-01",
        "2024/01/01",
        "0000-01-01",
    ]

    for text in invalid {
        let query = SearchQuery.parse("updated:>\(text)")
        #expect(query.clauses == [.text("updated:>\(text)")])
        #expect(query.diagnostics.count == 1)
    }
}

@Test func fieldNamesAreCaseInsensitiveButValuesKeepTheirSpelling() {
    let query = SearchQuery.parse("SITE:Example.COM IS:PINNED scope:PREFIX")

    #expect(query.clauses == [
        .site("Example.COM"),
        .state(.pinned),
        .scope(.prefix),
    ])
    #expect(query.diagnostics.isEmpty)
}

@Test func booleanOperatorsGroupingAndNegationStayLiteralText() {
    let query = SearchQuery.parse("foo OR bar -baz (qux) /re.*/")

    #expect(query.clauses == [
        .text("foo"),
        .text("OR"),
        .text("bar"),
        .text("-baz"),
        .text("(qux)"),
        .text("/re.*/"),
    ])
    #expect(query.diagnostics.isEmpty)
}
