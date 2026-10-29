import AppKit
import SwiftUI
import WebKit
import WebbyCore

/// A locked-down WebKit host for Compiled output.
///
/// The configuration is nonpersistent, JavaScript is disabled and every HTTP(S)
/// request is blocked before the document is loaded. Navigation after the initial
/// load is cancelled; only validated link clicks leave the view through closures.
@MainActor
final class CompiledWebViewController: NSObject, WKNavigationDelegate {
    enum LinkRoute: Equatable {
        case external(URL)
        case note(UUID)
    }

    /// Tests inspect this exact string. `^https?://` covers both schemes.
    static let contentRuleJSON = #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}]"#

    static func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.userContentController = WKUserContentController()
        return configuration
    }

    /// Accepts only validated HTTPS links and strict `webby://note/<uuid>` links.
    static func route(for url: URL) -> LinkRoute? {
        if url.scheme?.lowercased() == "https",
           let host = url.host,
           !host.isEmpty {
            return .external(url)
        }
        if let id = NoteLink.parse(url.absoluteString) {
            return .note(id)
        }
        return nil
    }

    let webView: WKWebView
    var onOpenExternalURL: ((URL) -> Void)?
    var onOpenNote: ((UUID) -> Void)?

    private var contentRuleList: WKContentRuleList?
    private var allowsInitialNavigation = false
    private(set) var lastLoadedHTML: String?
    private(set) var lastLoadedBaseURL: URL?

    override init() {
        webView = WKWebView(frame: .zero, configuration: Self.makeConfiguration())
        super.init()
        webView.navigationDelegate = self
    }

    /// Loading waits for the blocking rule to compile. The rule is installed before
    /// the HTML request starts, so a document can never race ahead of it.
    func load(html: String) {
        lastLoadedHTML = html
        lastLoadedBaseURL = nil
        allowsInitialNavigation = false

        if let contentRuleList {
            loadNow(html: html, contentRuleList: contentRuleList)
            return
        }

        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "Webby.Compiled.BlockHTTP",
            encodedContentRuleList: Self.contentRuleJSON
        ) { [weak self] list, _ in
            guard let list else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.contentRuleList = list
                self.loadNow(html: html, contentRuleList: list)
            }
        }
    }

    private func loadNow(html: String, contentRuleList: WKContentRuleList) {
        let userContentController = webView.configuration.userContentController
        if self.contentRuleList == nil {
            userContentController.add(contentRuleList)
        } else {
            userContentController.removeAllContentRuleLists()
            userContentController.add(contentRuleList)
        }
        self.contentRuleList = contentRuleList
        allowsInitialNavigation = true
        webView.loadHTMLString(html, baseURL: nil)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        if allowsInitialNavigation, navigationAction.navigationType == .other {
            allowsInitialNavigation = false
            decisionHandler(.allow)
            return
        }

        if navigationAction.navigationType == .linkActivated,
           let url = navigationAction.request.url,
           let route = Self.route(for: url) {
            switch route {
            case .external(let url):
                onOpenExternalURL?(url)
            case .note(let id):
                onOpenNote?(id)
            }
        }
        decisionHandler(.cancel)
    }
}

/// A small SwiftUI host. The coordinator retains the controller for the view's life.
struct CompiledView: NSViewRepresentable {
    let html: String
    var onOpenExternalURL: ((URL) -> Void)?
    var onOpenNote: ((UUID) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: NSViewRepresentableContext<Self>) -> WKWebView {
        let controller = CompiledWebViewController()
        controller.onOpenExternalURL = onOpenExternalURL
        controller.onOpenNote = onOpenNote
        context.coordinator.controller = controller
        controller.load(html: html)
        return controller.webView
    }

    func updateNSView(_ nsView: WKWebView, context: NSViewRepresentableContext<Self>) {
        guard let controller = context.coordinator.controller else { return }
        controller.onOpenExternalURL = onOpenExternalURL
        controller.onOpenNote = onOpenNote
        if controller.lastLoadedHTML != html {
            controller.load(html: html)
        }
    }

    final class Coordinator {
        var controller: CompiledWebViewController?
    }
}
