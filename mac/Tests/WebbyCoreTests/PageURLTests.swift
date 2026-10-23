import Testing
@testable import WebbyCore

@Suite struct PageURLTests {
    @Test(arguments: [
        "https://leetcode.com/problems/two-sum/",
        "https://leetcode.com/problems/two-sum",
        "http://leetcode.com/problems/two-sum/",
        "https://www.leetcode.com/problems/two-sum/",
        "https://LeetCode.com/problems/two-sum/?envType=study-plan&id=top-150",
        "https://leetcode.com/problems/two-sum/#discussion",
        "https://leetcode.com//problems//two-sum//",
        "https://leetcode.com:443/problems/two-sum/",
        "  https://leetcode.com/problems/two-sum/  ",
    ])
    func normalizesToSamePage(_ raw: String) throws {
        let page = try #require(PageURL(string: raw))
        #expect(page.host == "leetcode.com")
        #expect(page.path == "/problems/two-sum")
    }

    @Test func pathCaseIsPreserved() throws {
        // Paths are case-sensitive on most servers; only the host is lowercased.
        let page = try #require(PageURL(string: "https://Example.com/Docs/API"))
        #expect(page.description == "example.com/Docs/API")
    }

    @Test func nonDefaultPortIsKept() throws {
        #expect(try #require(PageURL(string: "http://localhost:3000/app/")).description == "localhost:3000/app")
        #expect(try #require(PageURL(string: "http://example.com:80/x")).description == "example.com/x")
    }

    @Test func rootHasEmptyPath() throws {
        let page = try #require(PageURL(string: "https://leetcode.com/"))
        #expect(page.path == "")
        #expect(page.segments.isEmpty)
    }

    @Test func fileURLs() throws {
        let page = try #require(PageURL(string: "file:///Users/me/notes.html"))
        #expect(page.description == "file/Users/me/notes.html")
    }

    @Test(arguments: ["chrome://extensions", "about:blank", "not a url", "", "https://"])
    func rejectsNonPages(_ raw: String) {
        #expect(PageURL(string: raw) == nil)
    }

    @Test func ancestorPaths() throws {
        let page = try #require(PageURL(string: "https://leetcode.com/problems/two-sum/description/"))
        #expect(page.ancestorPaths == ["", "/problems", "/problems/two-sum", "/problems/two-sum/description"])
        #expect(PageURL(host: "a.com", path: "").ancestorPaths == [""])
    }
}
