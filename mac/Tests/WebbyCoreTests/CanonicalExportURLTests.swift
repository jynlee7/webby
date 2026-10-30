import Foundation
import Testing
@testable import WebbyCore

private func canonicalPage(
    host: String = "example.com",
    path: String = "/a",
    query: String? = nil
) -> PageURL {
    PageURL(host: host, path: path, query: query)
}

@Test func canonicalURLAssumesHTTPSAndKeepsRootPath() {
    #expect(CanonicalExportURL.make(for: canonicalPage(path: "")) == "https://example.com/")
    #expect(CanonicalExportURL.make(for: canonicalPage()) == "https://example.com/a")
}

@Test func canonicalURLKeepsNonDefaultPortsEmbeddedInTheHost() {
    let page = canonicalPage(host: "Example.COM:8443", path: "/a")

    #expect(CanonicalExportURL.make(for: page) == "https://example.com:8443/a")
}

@Test func canonicalURLKeepsOnlySignificantQueryKeysInSortedOrder() {
    let rules = [
        QueryRule(host: "example.com", key: "b"),
        QueryRule(host: "example.com", key: "a"),
    ]
    let page = canonicalPage(path: "/path", query: "b=2&token=secret&a=1")

    #expect(
        CanonicalExportURL.make(for: page, queryRules: rules)
            == "https://example.com/path?a=1&b=2"
    )
}

@Test func canonicalURLDropsAQueryWithNoEffectiveRules() {
    let page = canonicalPage(path: "/path", query: "v=2")

    #expect(CanonicalExportURL.make(for: page, queryRules: []) == "https://example.com/path")
}

@Test func canonicalURLDropsKeysForOtherHosts() {
    let rules = [QueryRule(host: "example.com", key: "v")]
    let page = canonicalPage(host: "other.com", path: "/path", query: "v=2")

    #expect(
        CanonicalExportURL.make(for: page, queryRules: rules)
            == "https://other.com/path"
    )
}

@Test func canonicalURLReturnsNilForFileAndAppScopes() {
    let file = canonicalPage(host: "file", path: "/Users/me/note.md")

    #expect(CanonicalExportURL.make(for: file) == nil)
    #expect(CanonicalExportURL.make(for: Anchor.app(bundleID: "com.example.app")) == nil)
    #expect(CanonicalExportURL.make(for: Anchor.web(page: canonicalPage(), scope: .site)) != nil)
}

@Test func canonicalURLRejectsCredentialsInTheStoredHost() {
    let page = canonicalPage(host: "user:pass@example.com", path: "/a")

    #expect(CanonicalExportURL.make(for: page) == nil)
}

@Test func canonicalURLRejectsInvalidHosts() {
    #expect(CanonicalExportURL.make(for: canonicalPage(host: "exa mple.com")) == nil)
    #expect(CanonicalExportURL.make(for: canonicalPage(host: "example.com:abc")) == nil)
    #expect(CanonicalExportURL.make(for: canonicalPage(host: "example.com:70000")) == nil)
    #expect(CanonicalExportURL.make(for: canonicalPage(host: "example.com:")) == nil)
    #expect(CanonicalExportURL.make(for: canonicalPage(host: "example.com/evil")) == nil)
    #expect(CanonicalExportURL.make(for: canonicalPage(host: "example.com?x=1")) == nil)
    #expect(CanonicalExportURL.make(for: canonicalPage(host: "example.com#frag")) == nil)
    #expect(CanonicalExportURL.make(for: canonicalPage(host: ".example.com")) == nil)
    #expect(CanonicalExportURL.make(for: canonicalPage(host: "example..com")) == nil)
}

@Test func canonicalURLRejectsFragmentsQueriesAndBackslashesInPaths() {
    #expect(CanonicalExportURL.make(for: canonicalPage(path: "/a#frag")) == nil)
    #expect(CanonicalExportURL.make(for: canonicalPage(path: "/a?x=1")) == nil)
    #expect(CanonicalExportURL.make(for: canonicalPage(path: "/a\\b")) == nil)
    #expect(CanonicalExportURL.make(for: canonicalPage(path: "/a b")) == nil)
}

@Test func canonicalURLPreservesPercentEncodedPathCase() {
    let page = canonicalPage(path: "/A%2Fb/%7EUser")

    #expect(CanonicalExportURL.make(for: page) == "https://example.com/A%2Fb/%7EUser")
}

@Test func canonicalURLKeepsUnicodeUnderscoreAndIPv6Hosts() {
    let unicode = CanonicalExportURL.make(for: canonicalPage(host: "münchen.de", path: "/a"))
    #expect(unicode != nil)
    #expect(unicode?.hasSuffix("/a") == true)

    #expect(
        CanonicalExportURL.make(for: canonicalPage(host: "internal_host", path: "/a"))
            == "https://internal_host/a"
    )
    #expect(
        CanonicalExportURL.make(for: canonicalPage(host: "2001:db8::1", path: "/a"))
            == "https://[2001:db8::1]/a"
    )
}

@Test func canonicalURLUsesRulesForTheStoredHostWithPort() {
    let rules = [QueryRule(host: "example.com:8443", key: "v")]
    let page = canonicalPage(host: "example.com:8443", path: "/watch", query: "v=abc&t=9")

    #expect(
        CanonicalExportURL.make(for: page, queryRules: rules)
            == "https://example.com:8443/watch?v=abc"
    )
}
