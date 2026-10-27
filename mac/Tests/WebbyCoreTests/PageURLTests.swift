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
