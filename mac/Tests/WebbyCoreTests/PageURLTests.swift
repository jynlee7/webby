import Foundation
import Testing
@testable import WebbyCore

@Test func issueExampleURLsIdentifyTheSamePage() throws {
    let withWww = try #require(PageURL(string: "https://www.example.com/a//b/?x=1#top"))
    let withoutWww = try #require(PageURL(string: "http://example.com/a/b"))

    #expect(withWww == withoutWww)
    #expect(withWww.host == "example.com")
    #expect(withWww.path == "/a/b")
    #expect(withWww.segments == ["a", "b"])
    #expect(withWww.description == "example.com/a/b")
}

@Test func acceptsOnlySupportedSchemes() throws {
    #expect(PageURL(string: "http://example.com/a") != nil)
    #expect(PageURL(string: "https://example.com/a") != nil)
    #expect(PageURL(string: "file:///Users/me/note.md") != nil)

    #expect(PageURL(string: "chrome://newtab") == nil)
    #expect(PageURL(string: "ftp://example.com/a") == nil)
    #expect(PageURL(string: "mailto:me@example.com") == nil)
    #expect(PageURL(string: "javascript:alert(1)") == nil)
    #expect(PageURL(string: "example.com/a") == nil)
    #expect(PageURL(string: "https://www./a") == nil)
    #expect(PageURL(string: "https://www.:8443/a") == nil)
}

@Test func trimsSurroundingWhitespace() throws {
    let page = try #require(PageURL(string: " \n\thttps://example.com/a \t\r\n"))

    #expect(page.host == "example.com")
    #expect(page.path == "/a")
}

@Test func lowercasesHostAndStripsOneWwwPrefix() throws {
    let page = try #require(PageURL(string: "HTTPS://WWW.Example.COM/Path"))

    #expect(page.host == "example.com")
    #expect(page.path == "/Path")
}

@Test func stripsOnlyOneWwwPrefix() throws {
    let page = try #require(PageURL(string: "https://www.www.example.com/a"))

    #expect(page.host == "www.example.com")
}

@Test func preservesPathCaseAndPercentEncoding() throws {
    let page = try #require(PageURL(string: "https://example.com/A%2Fb/%7EUser/"))

    #expect(page.path == "/A%2Fb/%7EUser")
    #expect(page.segments == ["A%2Fb", "%7EUser"])
}

@Test func fileURLsUseFileHostIdentity() throws {
    let page = try #require(PageURL(string: "file:///Users/me/My%20Notes.md?x=1#top"))
    let root = try #require(PageURL(string: "file:///"))
    let networkFile = try #require(PageURL(string: "file://server/share/note.md"))

    #expect(page.host == "file")
    #expect(page.path == "/Users/me/My%20Notes.md")
    #expect(root.host == "file")
    #expect(root.path == "")
    #expect(networkFile.host == "file")
    #expect(networkFile.path == "/share/note.md")
}

@Test func dropsDefaultPortsAndKeepsNonDefaultPorts() throws {
    #expect(try #require(PageURL(string: "http://example.com:80/a")).host == "example.com")
    #expect(try #require(PageURL(string: "https://example.com:443/a")).host == "example.com")
    #expect(try #require(PageURL(string: "http://example.com:443/a")).host == "example.com:443")
    #expect(try #require(PageURL(string: "https://example.com:80/a")).host == "example.com:80")
    #expect(try #require(PageURL(string: "http://example.com:8080/a")).host == "example.com:8080")
}

@Test func ignoresQueryAndFragment() throws {
    let page = try #require(PageURL(string: "https://example.com/a/b?x=1&y=2#section"))

    #expect(page.path == "/a/b")
    #expect(page.query == nil)
    #expect(page.description == "example.com/a/b")
}

@Test func normalizesRepeatedTrailingAndRootSlashes() throws {
    #expect(try #require(PageURL(string: "https://example.com")).path == "")
    #expect(try #require(PageURL(string: "https://example.com/")).path == "")
    #expect(try #require(PageURL(string: "https://example.com///")).path == "")
    #expect(try #require(PageURL(string: "https://example.com//a///b//")).path == "/a/b")
    #expect(try #require(PageURL(string: "https://example.com/a/b/")).segments == ["a", "b"])
    #expect(try #require(PageURL(string: "https://example.com/")).segments == [])
}

@Test func hostPathInitializerNormalizesStoredIdentity() throws {
    let page = PageURL(host: "WWW.Example.COM", path: "problems//two-sum/")

    #expect(page.host == "www.example.com")
    #expect(page.path == "/problems/two-sum")
    #expect(page.query == nil)
    #expect(page.segments == ["problems", "two-sum"])
    #expect(PageURL(host: "example.com", path: "").path == "")
    #expect(PageURL(host: "example.com", path: "///").path == "")
}

@Test func storedQueryRoundTripsWithoutAffectingParsedPages() throws {
    let page = PageURL(host: "example.com", path: "/search", query: "q=swift&page=2")

    #expect(page.query == "q=swift&page=2")

    let data = try JSONEncoder().encode(page)
    let decoded = try JSONDecoder().decode(PageURL.self, from: data)

    #expect(decoded == page)
    #expect(decoded.query == "q=swift&page=2")

    let parsed = try #require(PageURL(string: "https://example.com/search?q=swift&page=2"))
    #expect(parsed.query == nil)
    #expect(parsed.path == "/search")
}

@Test func decodingAPageWithoutAQueryStillWorks() throws {
    let data = Data(#"{"host":"example.com","path":"/a"}"#.utf8)
    let decoded = try JSONDecoder().decode(PageURL.self, from: data)

    #expect(decoded.query == nil)
    #expect(decoded == PageURL(host: "example.com", path: "/a"))
}

@Test func codableRoundTripPreservesIdentity() throws {
    let page = try #require(PageURL(string: "https://www.example.com:8443/a//b/?x=1#top"))
    let data = try JSONEncoder().encode(page)
    let decoded = try JSONDecoder().decode(PageURL.self, from: data)

    #expect(decoded == page)
}

@Test func decodingNormalizesStoredIdentityWithoutStrippingAnotherWww() throws {
    let data = Data(#"{"host":"WWW.Example.COM","path":"a//b/"}"#.utf8)
    let decoded = try JSONDecoder().decode(PageURL.self, from: data)

    #expect(decoded == PageURL(host: "www.example.com", path: "/a/b"))
}

@Test func decodingRejectsAnEmptyHost() {
    let data = Data(#"{"host":"","path":"/a"}"#.utf8)

    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(PageURL.self, from: data)
    }
}

@Test func youtubeVideoIDsArePartOfPageIdentity() throws {
    let first = try #require(PageURL(string: "https://www.youtube.com/watch?v=a&t=10#comments"))
    let second = try #require(PageURL(string: "https://youtube.com/watch?v=b"))

    #expect(first.query == "v=a")
    #expect(second.query == "v=b")
    #expect(first != second)
    #expect(first.host == "youtube.com")
    #expect(first.path == "/watch")
    #expect(first.description == "youtube.com/watch?v=a")
}

@Test func hackerNewsItemIDsArePartOfPageIdentity() throws {
    let first = try #require(PageURL(string: "https://news.ycombinator.com/item?id=1"))
    let second = try #require(PageURL(string: "https://news.ycombinator.com/item?id=2"))

    #expect(first.query == "id=1")
    #expect(second.query == "id=2")
    #expect(first != second)
}

@Test func queryRulesDropIrrelevantParametersAndFragments() throws {
    let page = try #require(PageURL(string: "https://youtube.com/watch?t=10&v=a&list=PL#t=10"))

    #expect(page.query == "v=a")
    #expect(page.description == "youtube.com/watch?v=a")
}

@Test func queryRulesUseTheExactHostIncludingNonDefaultPorts() throws {
    #expect(try #require(PageURL(string: "https://youtube.com:8443/watch?v=a")).query == nil)

    let portRule = [QueryRule(host: "youtube.com:8443", key: "v")]
    #expect(try #require(PageURL(string: "https://youtube.com:8443/watch?v=a", queryRules: portRule)).query == "v=a")
    #expect(try #require(PageURL(string: "https://youtube.com/watch?v=a", queryRules: portRule)).query == nil)
    #expect(try #require(PageURL(string: "https://music.youtube.com/watch?v=a")).query == nil)
}

@Test func queryRuleHostsMatchTrimmedCaseFoldedNFCWithoutStrippingWww() throws {
    let rule = [QueryRule(host: " E\u{301}XAMPLE.COM ", key: "q")]
    let nfcPage = try #require(PageURL(string: "https://Éxample.com/search?q=1", queryRules: rule))

    #expect(nfcPage.host == "éxample.com")
    #expect(nfcPage.query == "q=1")

    let stored = PageURL(host: "WWW.Example.COM", path: "/a")
    #expect(stored.host == "www.example.com")
    #expect(PageURL(host: "www.example.com", path: "/a") == stored)
}

@Test func queryKeysAreCaseSensitive() throws {
    let lowerRule = [QueryRule(host: "example.com", key: "v")]
    let upperRule = [QueryRule(host: "example.com", key: "V")]

    #expect(try #require(PageURL(string: "https://example.com/?V=1", queryRules: lowerRule)).query == nil)
    #expect(try #require(PageURL(string: "https://example.com/?V=1", queryRules: upperRule)).query == "V=1")
}

@Test func repeatedQueryKeysKeepTheirRelativeOrderAfterStableKeySorting() throws {
    let rules = [QueryRule(host: "example.com", key: "a"), QueryRule(host: "example.com", key: "b")]
    let page = try #require(PageURL(
        string: "https://example.com/?b=1&a=1&b=2&a=2&c=3",
        queryRules: rules
    ))

    #expect(page.query == "a=1&a=2&b=1&b=2")
}

@Test func bareAndEmptyQueryValuesRemainDistinctAndOrdered() throws {
    let rule = [QueryRule(host: "example.com", key: "v")]
    let page = try #require(PageURL(string: "https://example.com/?v&v=&v=x", queryRules: rule))

    #expect(page.query == "v&v=&v=x")
    #expect(page.matchesPageAnchor(PageURL(host: "example.com", path: "", query: "v")))
    #expect(page.matchesPageAnchor(PageURL(host: "example.com", path: "", query: "v=")))
    #expect(page.matchesPageAnchor(PageURL(host: "example.com", path: "", query: "v=x")))
}

@Test func canonicalQueryEncodingKeepsPlusAndSpaceDistinct() throws {
    let rule = [QueryRule(host: "example.com", key: "v")]
    let page = try #require(PageURL(string: "https://example.com/?v=a+b%20c&v=%2B", queryRules: rule))

    #expect(page.query == "v=a%2Bb%20c&v=%2B")
}

@Test func canonicalQueryEncodingNormalizesPercentEscapes() throws {
    let rule = [QueryRule(host: "example.com", key: "v")]
    let page = try #require(PageURL(string: "https://example.com/?v=%7e%41%2f%e4%b8%ad", queryRules: rule))

    #expect(page.query == "v=~A%2F%E4%B8%AD")
}

@Test func unicodeQueryKeysAndValuesRoundTripCanonically() throws {
    let rule = [QueryRule(host: "example.com", key: "关键词")]
    let page = try #require(PageURL(
        string: "https://example.com/?%e5%85%b3%e9%94%ae%e8%af%8d=%e4%b8%ad%e6%96%87",
        queryRules: rule
    ))

    #expect(page.query == "%E5%85%B3%E9%94%AE%E8%AF%8D=%E4%B8%AD%E6%96%87")
    #expect(QueryRules.effective(rules: [], anchors: [.web(page: PageURL(host: "example.com", path: "", query: page.query), scope: .page)])
        == [QueryRule(host: "example.com", key: "关键词")])
}

@Test func fileURLsNeverCarryAQuery() throws {
    let page = try #require(PageURL(string: "file:///Users/me/notes.md?v=a&id=1#top"))

    #expect(page.host == "file")
    #expect(page.path == "/Users/me/notes.md")
    #expect(page.query == nil)
    #expect(page.description == "file/Users/me/notes.md")
}

@Test func v1AnchorsWithoutAQueryMatchEveryQueryValue() throws {
    let wildcard = PageURL(host: "youtube.com", path: "/watch")
    let first = try #require(PageURL(string: "https://youtube.com/watch?v=a"))
    let second = try #require(PageURL(string: "https://youtube.com/watch?v=b"))

    #expect(first.matchesPageAnchor(wildcard))
    #expect(second.matchesPageAnchor(wildcard))
    #expect(wildcard.matchesPageAnchor(wildcard))
}

@Test func newerSignificantKeysDoNotStrandExistingQueryAnchors() throws {
    let oldAnchor = PageURL(host: "youtube.com", path: "/watch", query: "v=a")
    let current = try #require(PageURL(
        string: "https://youtube.com/watch?v=a&t=30",
        queryRules: [QueryRule(host: "youtube.com", key: "v"), QueryRule(host: "youtube.com", key: "t")]
    ))

    #expect(current.query == "t=30&v=a")
    #expect(current.matchesPageAnchor(oldAnchor))
}

@Test func queryMatchingComparesMultisetsAndDistinguishesBareFromEmpty() throws {
    let current = PageURL(host: "example.com", path: "/a", query: "v=1&v=2&v=3&x=1")

    #expect(current.matchesPageAnchor(PageURL(host: "example.com", path: "/a", query: "v=1&v=2")))
    #expect(!current.matchesPageAnchor(PageURL(host: "example.com", path: "/a", query: "v=1&v=1")))
    #expect(!current.matchesPageAnchor(PageURL(host: "example.com", path: "/a", query: "v=1&v=4")))
    #expect(!current.matchesPageAnchor(PageURL(host: "example.com", path: "/a", query: "v")))
    #expect(current.matchesPageAnchor(PageURL(host: "example.com", path: "/a", query: "v=3")))
    #expect(PageURL(host: "example.com", path: "/a", query: "v").matchesPageAnchor(PageURL(host: "example.com", path: "/a", query: "v=A")) == false)
    #expect(PageURL(host: "example.com", path: "/a", query: "v").matchesPageAnchor(PageURL(host: "example.com", path: "/a", query: "v=")) == false)
    #expect(PageURL(host: "example.com", path: "/a", query: "v=").matchesPageAnchor(PageURL(host: "example.com", path: "/a", query: "v")) == false)
}

@Test func pageAnchorMatchingRequiresExactHostAndPath() throws {
    let current = try #require(PageURL(string: "https://youtube.com/watch?v=a"))
    let anchor = PageURL(host: "youtube.com", path: "/watch", query: "v=a")

    #expect(current.matchesPageAnchor(anchor))
    #expect(!current.matchesPageAnchor(PageURL(host: "youtube.com:8443", path: "/watch", query: "v=a")))
    #expect(!current.matchesPageAnchor(PageURL(host: "music.youtube.com", path: "/watch", query: "v=a")))
    #expect(!current.matchesPageAnchor(PageURL(host: "youtube.com", path: "/watch/extra", query: "v=a")))
    #expect(!current.matchesPageAnchor(PageURL(host: "youtube.com", path: "/other", query: "v=a")))
}

@Test func pageAnchorMatchingTreatsPercentEscapesAsEquivalent() throws {
    let current = PageURL(host: "example.com", path: "/a", query: "v=A")

    #expect(current.matchesPageAnchor(PageURL(host: "example.com", path: "/a", query: "v=%41")))
    #expect(current.matchesPageAnchor(PageURL(host: "example.com", path: "/a", query: "v=%61")) == false)
}

@Test func descriptionIncludesTheQueryOnlyWhenPresent() throws {
    let withQuery = try #require(PageURL(string: "https://youtube.com/watch?v=a&t=10"))
    let withoutQuery = try #require(PageURL(string: "https://youtube.com/watch?t=10"))
    let storedEmpty = PageURL(host: "example.com", path: "/a", query: "")

    #expect(withQuery.description == "youtube.com/watch?v=a")
    #expect(withoutQuery.description == "youtube.com/watch")
    #expect(storedEmpty.description == "example.com/a?")
}

@Test func passingNoRulesOptsOutOfTheBuiltIns() throws {
    let page = try #require(PageURL(string: "https://youtube.com/watch?v=a", queryRules: []))

    #expect(page.query == nil)
    #expect(page.description == "youtube.com/watch")
}
