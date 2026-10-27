import Foundation
import Testing
@testable import WebbyCore

private func page(_ string: String) throws -> PageURL {
    try #require(PageURL(string: string))
}

@Test func appAnchorMatchesOnlyTheSameBundleID() throws {
    let anchor = Anchor.app(bundleID: "com.apple.dt.Xcode")

    #expect(anchor.matches(.app(bundleID: "com.apple.dt.Xcode")))
    #expect(!anchor.matches(.app(bundleID: "com.apple.Safari")))
}

@Test func appAndWebContextsDoNotMatchEachOther() throws {
    #expect(!Anchor.app(bundleID: "com.example.app").matches(.web(try page("https://example.com/a"))))
    #expect(!Anchor.web(page: try page("https://example.com/a"), scope: .site).matches(.app(bundleID: "com.example.app")))
}

@Test func pageAnchorMatchesExactPathOnTheSameHost() throws {
    let anchor = Anchor.web(page: try page("https://example.com/a/b"), scope: .page)

    #expect(anchor.matches(.web(try page("https://example.com/a/b"))))
    #expect(anchor.matches(.web(try page("https://example.com/a/b/"))))
    #expect(!anchor.matches(.web(try page("https://example.com/a/b/c"))))
    #expect(!anchor.matches(.web(try page("https://example.com/a"))))
    #expect(!anchor.matches(.web(try page("https://other.example.com/a/b"))))
}

@Test func siteAnchorMatchesEveryPathOnTheHost() throws {
    let anchor = Anchor.web(page: try page("https://example.com/a"), scope: .site)

    #expect(anchor.matches(.web(try page("https://example.com/"))))
    #expect(anchor.matches(.web(try page("https://example.com/other/path"))))
    #expect(!anchor.matches(.web(try page("https://sub.example.com/a"))))
}

@Test func prefixAnchorMatchesTheExactPathAndDescendants() throws {
    let anchor = Anchor.web(page: try page("https://example.com/problems/two-sum"), scope: .prefix(path: "/problems/two-sum"))

    #expect(anchor.matches(.web(try page("https://example.com/problems/two-sum"))))
    #expect(anchor.matches(.web(try page("https://example.com/problems/two-sum/solutions"))))
    #expect(anchor.matches(.web(try page("https://example.com/problems/two-sum/submissions/"))))
    #expect(!anchor.matches(.web(try page("https://example.com/problems/two-sum-ii"))))
    #expect(!anchor.matches(.web(try page("https://example.com/problems"))))
    #expect(!anchor.matches(.web(try page("https://other.example.com/problems/two-sum"))))
}

@Test func prefixAnchorNormalizesItsPath() throws {
    let anchor = Anchor.web(page: try page("https://example.com"), scope: .prefix(path: "problems//two-sum/"))
    let rootAnchor = Anchor.web(page: try page("https://example.com"), scope: .prefix(path: "///"))

    #expect(anchor.matches(.web(try page("https://example.com/problems/two-sum/description"))))
    #expect(!anchor.matches(.web(try page("https://example.com/problems/two-sum-ii/description"))))
    #expect(rootAnchor.matches(.web(try page("https://example.com/"))))
    #expect(rootAnchor.matches(.web(try page("https://example.com/anything/at/all"))))
    #expect(!rootAnchor.matches(.web(try page("https://other.example.com/anything"))))
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
