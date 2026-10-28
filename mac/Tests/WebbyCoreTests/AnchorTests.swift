import Foundation
import Testing
@testable import WebbyCore

private func page(_ string: String) throws -> PageURL {
    try #require(PageURL(string: string))
}

private let tab = TabRef(
    browser: "com.google.Chrome",
    profile: "profile-a",
    session: "123@2026-01-01",
    tabID: 7,
    windowID: 2
)

@Test func appAnchorMatchesTheSameBundleIDWhetherOrNotAPageIsKnown() throws {
    let anchor = Anchor.app(bundleID: "com.apple.dt.Xcode")

    #expect(anchor.matches(Context(appBundleID: "com.apple.dt.Xcode")))
    #expect(anchor.matches(Context(appBundleID: "com.apple.dt.Xcode", page: try page("https://example.com/a"))))
    #expect(anchor.matches(Context(appBundleID: "com.apple.dt.Xcode", tab: tab)))
    #expect(anchor.matches(Context(appBundleID: "com.apple.dt.Xcode", page: try page("https://example.com/a"), tab: tab)))

    #expect(!anchor.matches(Context(appBundleID: "com.apple.Safari")))
    #expect(!anchor.matches(Context(appBundleID: "com.apple.Safari", page: try page("https://example.com/a"))))
    #expect(!anchor.matches(Context(appBundleID: "com.apple.Safari", tab: tab)))
}

@Test func webAnchorNeedsAKnownPageAndAppAnchorsIgnoreKnownPages() throws {
    let anchor = Anchor.web(page: try page("https://example.com/a"), scope: .site)

    #expect(!anchor.matches(Context(appBundleID: "com.google.Chrome")))
    #expect(!anchor.matches(Context(appBundleID: "com.google.Chrome", tab: tab)))
    #expect(!Anchor.app(bundleID: "com.example.app").matches(Context(appBundleID: "com.example.other", page: try page("https://example.com/a"))))
}

@Test func pageAnchorMatchesExactPathOnTheSameHost() throws {
    let anchor = Anchor.web(page: try page("https://example.com/a/b"), scope: .page)

    #expect(anchor.matches(Context(appBundleID: "com.google.Chrome", page: try page("https://example.com/a/b"))))
    #expect(anchor.matches(Context(appBundleID: "com.google.Chrome", page: try page("https://example.com/a/b/"))))
    #expect(!anchor.matches(Context(appBundleID: "com.google.Chrome", page: try page("https://example.com/a/b/c"))))
    #expect(!anchor.matches(Context(appBundleID: "com.google.Chrome", page: try page("https://example.com/a"))))
    #expect(!anchor.matches(Context(appBundleID: "com.google.Chrome", page: try page("https://other.example.com/a/b"))))
}

@Test func pageAnchorComparesQueriesOnlyWhenTheAnchorHasOne() {
    let withoutQuery = Anchor.web(page: PageURL(host: "example.com", path: "/watch"), scope: .page)
    let withQuery = Anchor.web(
        page: PageURL(host: "example.com", path: "/watch", query: "v=abc"),
        scope: .page
    )

    #expect(withoutQuery.matches(Context(
        appBundleID: "com.google.Chrome",
        page: PageURL(host: "example.com", path: "/watch", query: "v=abc")
    )))
    #expect(withoutQuery.matches(Context(
        appBundleID: "com.google.Chrome",
        page: PageURL(host: "example.com", path: "/watch")
    )))
    #expect(withQuery.matches(Context(
        appBundleID: "com.google.Chrome",
        page: PageURL(host: "example.com", path: "/watch", query: "v=abc")
    )))
    #expect(withQuery.matches(Context(
        appBundleID: "com.google.Chrome",
        page: PageURL(host: "example.com", path: "/watch", query: "t=10&v=abc")
    )))
    #expect(!withQuery.matches(Context(
        appBundleID: "com.google.Chrome",
        page: PageURL(host: "example.com", path: "/watch", query: "t=10&v=other")
    )))
    #expect(!withQuery.matches(Context(
        appBundleID: "com.google.Chrome",
        page: PageURL(host: "example.com", path: "/watch", query: "t=10")
    )))
    #expect(!withQuery.matches(Context(
        appBundleID: "com.google.Chrome",
        page: PageURL(host: "example.com", path: "/watch")
    )))
    #expect(!withQuery.matches(Context(
        appBundleID: "com.google.Chrome",
        page: PageURL(host: "example.com", path: "/other", query: "v=abc")
    )))
    #expect(!withQuery.matches(Context(
        appBundleID: "com.google.Chrome",
        page: PageURL(host: "other.example.com", path: "/watch", query: "v=abc")
    )))
}

@Test func siteAnchorMatchesEveryPathOnTheHostAndIgnoresQuery() throws {
    let anchor = Anchor.web(
        page: PageURL(host: "example.com", path: "/a", query: "v=abc"),
        scope: .site
    )

    #expect(anchor.matches(Context(appBundleID: "com.google.Chrome", page: try page("https://example.com/"))))
    #expect(anchor.matches(Context(appBundleID: "com.google.Chrome", page: try page("https://example.com/other/path"))))
    #expect(anchor.matches(Context(
        appBundleID: "com.google.Chrome",
        page: PageURL(host: "example.com", path: "/other", query: "v=other")
    )))
    #expect(!anchor.matches(Context(appBundleID: "com.google.Chrome", page: try page("https://sub.example.com/a"))))
}

@Test func prefixAnchorMatchesTheExactPathAndDescendants() throws {
    let anchor = Anchor.web(page: try page("https://example.com/problems/two-sum"), scope: .prefix(path: "/problems/two-sum"))

    #expect(anchor.matches(Context(appBundleID: "com.google.Chrome", page: try page("https://example.com/problems/two-sum"))))
    #expect(anchor.matches(Context(appBundleID: "com.google.Chrome", page: try page("https://example.com/problems/two-sum/solutions"))))
    #expect(anchor.matches(Context(appBundleID: "com.google.Chrome", page: try page("https://example.com/problems/two-sum/submissions/"))))
    #expect(!anchor.matches(Context(appBundleID: "com.google.Chrome", page: try page("https://example.com/problems/two-sum-ii"))))
    #expect(!anchor.matches(Context(appBundleID: "com.google.Chrome", page: try page("https://example.com/problems"))))
    #expect(!anchor.matches(Context(appBundleID: "com.google.Chrome", page: try page("https://other.example.com/problems/two-sum"))))
}

@Test func prefixAnchorIgnoresQuery() {
    let anchor = Anchor.web(
        page: PageURL(host: "example.com", path: "/problems/two-sum", query: "v=abc"),
        scope: .prefix(path: "/problems/two-sum")
    )

    #expect(anchor.matches(Context(
        appBundleID: "com.google.Chrome",
        page: PageURL(host: "example.com", path: "/problems/two-sum/description", query: "v=other")
    )))
    #expect(anchor.matches(Context(
        appBundleID: "com.google.Chrome",
        page: PageURL(host: "example.com", path: "/problems/two-sum")
    )))
}

@Test func prefixAnchorNormalizesItsPath() throws {
    let anchor = Anchor.web(page: try page("https://example.com"), scope: .prefix(path: "problems//two-sum/"))
    let rootAnchor = Anchor.web(page: try page("https://example.com"), scope: .prefix(path: "///"))

    #expect(anchor.matches(Context(appBundleID: "com.google.Chrome", page: try page("https://example.com/problems/two-sum/description"))))
    #expect(!anchor.matches(Context(appBundleID: "com.google.Chrome", page: try page("https://example.com/problems/two-sum-ii/description"))))
    #expect(rootAnchor.matches(Context(appBundleID: "com.google.Chrome", page: try page("https://example.com/"))))
    #expect(rootAnchor.matches(Context(appBundleID: "com.google.Chrome", page: try page("https://example.com/anything/at/all"))))
    #expect(!rootAnchor.matches(Context(appBundleID: "com.google.Chrome", page: try page("https://other.example.com/anything"))))
}

@Test func webAnchorsNeedAPageEvenWhenATabIsReported() throws {
    let anchor = Anchor.web(page: try page("https://example.com/a"), scope: .page)

    #expect(!anchor.matches(Context(appBundleID: "com.google.Chrome", tab: tab)))
}

@Test func codableRoundTripPreservesEveryAnchorShape() throws {
    let anchors: [Anchor] = [
        .app(bundleID: "com.example.app"),
        .web(page: try page("https://example.com/a"), scope: .page),
        .web(page: try page("https://example.com/a"), scope: .prefix(path: "/a")),
        .web(page: try page("https://example.com/a"), scope: .site),
    ]

    for anchor in anchors {
        let data = try JSONEncoder().encode(anchor)
        let decoded = try JSONDecoder().decode(Anchor.self, from: data)
        #expect(decoded == anchor)
    }
}
