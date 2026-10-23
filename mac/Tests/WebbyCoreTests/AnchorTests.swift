import Testing
@testable import WebbyCore

@Suite struct AnchorTests {
    let twoSum = PageURL(host: "leetcode.com", path: "/problems/two-sum")

    func web(_ path: String, host: String = "leetcode.com") -> Context {
        .web(PageURL(host: host, path: path))
    }

    @Test func appMatchesSameBundleOnly() {
        let anchor = Anchor.app(bundleID: "com.apple.Notes")
        #expect(anchor.matches(.app(bundleID: "com.apple.Notes")))
        #expect(!anchor.matches(.app(bundleID: "com.apple.Safari")))
        #expect(!anchor.matches(web("/problems/two-sum")))
    }

    @Test func pageScopeIsExact() {
        let anchor = Anchor.web(page: twoSum, scope: .page)
        #expect(anchor.matches(web("/problems/two-sum")))
        #expect(!anchor.matches(web("/problems/two-sum/description")))
        #expect(!anchor.matches(web("/problems")))
        #expect(!anchor.matches(web("/problems/two-sum", host: "example.com")))
        #expect(!anchor.matches(.app(bundleID: "com.google.Chrome")))
    }

    @Test func prefixScopeMatchesWholeSegments() {
        let anchor = Anchor.web(page: twoSum, scope: .prefix(path: "/problems/two-sum"))
        #expect(anchor.matches(web("/problems/two-sum")))
        #expect(anchor.matches(web("/problems/two-sum/description")))
        #expect(anchor.matches(web("/problems/two-sum/submissions/123")))
        #expect(!anchor.matches(web("/problems/two-sum-ii")))
        #expect(!anchor.matches(web("/problems")))
    }

    @Test func prefixToleratesUnnormalizedPrefix() {
        let anchor = Anchor.web(page: twoSum, scope: .prefix(path: "problems//two-sum/"))
        #expect(anchor.matches(web("/problems/two-sum/description")))
    }

    @Test func siteScopeMatchesAnyPathOnHost() {
        let anchor = Anchor.web(page: twoSum, scope: .site)
        #expect(anchor.matches(web("")))
        #expect(anchor.matches(web("/contest")))
        #expect(!anchor.matches(web("/contest", host: "leetcode.cn")))
    }
}
