import Foundation
import Testing
import WebKit
@testable import Webby
import WebbyCore

/// These are configuration-level checks for the locked-down compiled view. The
/// initial `loadHTMLString(_:baseURL: nil)` and post-load navigation cancellation
/// need a live WebKit process, so no window or web view is launched here.
@MainActor
@Suite struct CompiledWebViewControllerConfigurationTests {
    @Test func contentRuleJSONBlocksBothHTTPAndHTTPS() throws {
        let json = CompiledWebViewController.contentRuleJSON
        #expect(json == #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}]"#)

        let rules = try #require(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]]
        )
        let trigger = try #require(rules.first?["trigger"] as? [String: Any])
        let filter = try #require(trigger["url-filter"] as? String)
        let regex = try NSRegularExpression(pattern: filter)

        for url in ["http://example.com/page", "https://example.com/page"] {
            let range = NSRange(location: 0, length: (url as NSString).length)
            #expect(regex.firstMatch(in: url, range: range) != nil)
        }

        let fileURL = "file:///tmp/page.html"
        #expect(
            regex.firstMatch(
                in: fileURL,
                range: NSRange(location: 0, length: (fileURL as NSString).length)
            ) == nil
        )
    }

    @Test func configurationDisablesJavaScriptAndUsesANonPersistentStore() {
        let configuration = CompiledWebViewController.makeConfiguration()

        #expect(configuration.defaultWebpagePreferences.allowsContentJavaScript == false)
        #expect(configuration.websiteDataStore.isPersistent == false)
    }

    @Test func routingAllowsOnlyHTTPSAndStrictNoteLinks() throws {
        let id = UUID(uuidString: "ABCDEF00-1234-5678-9ABC-DEF012345678")!

        let https = URL(string: "https://example.com/docs")!
        #expect(CompiledWebViewController.route(for: https) == .external(https))

        let uppercaseHTTPS = URL(string: "HTTPS://Example.com/Docs")!
        #expect(CompiledWebViewController.route(for: uppercaseHTTPS) == .external(uppercaseHTTPS))

        let noteURL = URL(string: NoteLink.url(for: id))!
        #expect(CompiledWebViewController.route(for: noteURL) == .note(id))

        let rejected = [
            "http://example.com/docs",
            "file:///tmp/compiled.html",
            "javascript:alert(1)",
            "data:text/html,hello",
            "about:blank",
            "webby://note/not-a-uuid",
            "webby://note/\(id.uuidString)?query=1",
            "webby://note/\(id.uuidString)#fragment",
            "webby://note/\(id.uuidString)/extra",
            "webby://other/\(id.uuidString)",
        ]
        for raw in rejected {
            let url = try #require(URL(string: raw))
            #expect(CompiledWebViewController.route(for: url) == nil)
        }
    }
}
