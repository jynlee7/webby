import Foundation
import Testing
@testable import WebbyCore

@Test func builtInsAreTheCanonicalYoutubeAndHackerNewsRules() {
    #expect(QueryRules.builtIns == [
        QueryRule(host: "youtube.com", key: "v"),
        QueryRule(host: "news.ycombinator.com", key: "id"),
    ])
}

@Test func effectiveUnionsRulesAndPageAnchorKeysDeterministically() throws {
    let rules = [
        QueryRule(host: "Example.COM", key: "q"),
        QueryRule(host: "example.com", key: "q"),
        QueryRule(host: "a.example", key: "z"),
    ]
    let anchors: [Anchor] = [
        .web(page: PageURL(host: "example.com", path: "/a", query: "v=2&q=1"), scope: .page),
        .web(page: PageURL(host: "example.com", path: "/b", query: "r=1"), scope: .prefix(path: "/b")),
        .web(page: PageURL(host: "example.com", path: "/c", query: "s=1"), scope: .site),
        .web(page: PageURL(host: "other.example", path: "/d", query: "t=1&t=2"), scope: .page),
        .web(page: PageURL(host: "example.com", path: "/nil"), scope: .page),
        .app(bundleID: "com.example.app"),
    ]

    #expect(QueryRules.effective(rules: rules, anchors: anchors) == [
        QueryRule(host: "a.example", key: "z"),
        QueryRule(host: "example.com", key: "q"),
        QueryRule(host: "example.com", key: "v"),
        QueryRule(host: "other.example", key: "t"),
    ])
}

@Test func effectiveDoesNotAddBuiltInsOnItsOwn() {
    #expect(QueryRules.effective(rules: [], anchors: []).isEmpty)
}

@Test func effectiveKeepsAnchoredKeysAfterTheirRuleIsRemoved() throws {
    let anchor = try #require(PageURL(string: "https://youtube.com/watch?v=abc", queryRules: []))
    let anchoredPage = try #require(PageURL(
        string: "https://youtube.com/watch?v=abc",
        queryRules: [QueryRule(host: "youtube.com", key: "v")]
    ))

    #expect(QueryRules.effective(rules: [], anchors: [.web(page: anchoredPage, scope: .page)])
        == [QueryRule(host: "youtube.com", key: "v")])

    let converted = Anchor.web(page: anchor, scope: .page)
    #expect(QueryRules.effective(rules: [], anchors: [converted]).isEmpty)
}

@Test func effectiveNormalizesHostsForDeduplication() {
    let rules = [
        QueryRule(host: " WWW.Example.COM ", key: "q"),
        QueryRule(host: "www.example.com", key: "q"),
        QueryRule(host: "www.example.com", key: "Q"),
    ]

    #expect(QueryRules.effective(rules: rules, anchors: []) == [
        QueryRule(host: "www.example.com", key: "Q"),
        QueryRule(host: "www.example.com", key: "q"),
    ])
}

@Test func effectiveUsesNFCForAnchorHosts() throws {
    let decomposed = "e\u{301}xample.com"
    let page = PageURL(host: decomposed, path: "/a", query: "q=1")

    #expect(QueryRules.effective(rules: [QueryRule(host: "E\u{301}XAMPLE.COM", key: "z")], anchors: [
        .web(page: page, scope: .page),
    ]) == [
        QueryRule(host: "éxample.com", key: "q"),
        QueryRule(host: "éxample.com", key: "z"),
    ])
}

@Test func effectiveSortsByHostThenKey() {
    let rules = [
        QueryRule(host: "b.example", key: "b"),
        QueryRule(host: "b.example", key: "a"),
        QueryRule(host: "a.example", key: "z"),
        QueryRule(host: "a.example", key: "a"),
    ]

    #expect(QueryRules.effective(rules: rules, anchors: []) == [
        QueryRule(host: "a.example", key: "a"),
        QueryRule(host: "a.example", key: "z"),
        QueryRule(host: "b.example", key: "a"),
        QueryRule(host: "b.example", key: "b"),
    ])
}
