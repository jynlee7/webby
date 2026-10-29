import Foundation
import CoreGraphics
import Testing
@testable import WebbyCore

private let browserFrame = CGRect(x: 20, y: 40, width: 1000, height: 700)
private let profileA = "3f2504e0-4f89-41d3-9a0c-0305e82c3301"
private let profileB = "3f2504e0-4f89-41d3-9a0c-0305e82c3302"

private func tab(_ url: String, id: Int = 1, active: Bool = true) -> BridgeTab {
    BridgeTab(id: id, index: 0, active: active, url: url, title: "Synthetic tab")
}
private func window(_ tabs: [BridgeTab], id: Int = 1, focused: Bool = true, incognito: Bool = false) -> BridgeWindow {
    BridgeWindow(id: id, focused: focused, incognito: incognito,
                 bounds: BridgeWindowBounds(left: 20, top: 40, width: 1000, height: 700), tabs: tabs)
}
private func receive(_ message: ExtensionMessage, into session: inout BrowserSession, connection: Int = 1, profile: String = profileA) throws {
    // Replay the actual wire encoding/decoding path, not only constructed enums.
    session.receive(.message(connection: connection, profile: profile, try ExtensionMessage.decode(message.encoded())))
}
private func connected() throws -> BrowserSession {
    var session = BrowserSession()
    session.setIdentity("100@1")
    try receive(.hello(BridgeHello(profile: profileA, extVersion: "1", incognitoAllowed: false)), into: &session)
    return session
}
private func context(_ session: BrowserSession, frame: CGRect? = browserFrame) -> Context {
    session.context(focusedFrame: frame, queryRules: QueryRules.builtIns)
}

@Test func browserReplayNavigationClosureAndInternalPage() throws {
    var session = try connected()
    try receive(.inventory(windows: [window([tab("https://leetcode.com/problems/two-sum")])]), into: &session)
    let page = try #require(context(session).page)
    let anchor = Anchor.web(page: page, scope: .prefix(path: page.path))
    for path in ["/problems/two-sum/description", "/problems/two-sum/solutions", "/problems/two-sum/submissions"] {
        try receive(.tabUpdated(tabId: 1, url: "https://leetcode.com" + path, title: nil), into: &session)
        #expect(anchor.matches(context(session)))
    }
    try receive(.tabUpdated(tabId: 1, url: "https://leetcode.com/problems/two-sum-ii", title: nil), into: &session)
    #expect(!anchor.matches(context(session)))
    try receive(.active(windowId: 1, incognito: false, tab: tab("chrome://newtab", id: 2)), into: &session)
    #expect(context(session).page == nil)
    try receive(.active(windowId: 1, incognito: false, tab: tab("https://example.com")), into: &session)
    #expect(context(session).page != nil)
    try receive(.tabClosed(tabId: 1, windowClosing: false), into: &session)
    #expect(context(session).page == nil)
}

@Test func privateAndUnverifiedWindowsNeverExposeWebContext() throws {
    var session = try connected()
    try receive(.inventory(windows: [window([tab("https://example.com")])]), into: &session)
    #expect(context(session, frame: nil).page == nil)
    #expect(context(session, frame: browserFrame.offsetBy(dx: 50, dy: 0)).page == nil)
    // Extension denied in incognito: no window is focused in its visible inventory.
    try receive(.inventory(windows: [window([tab("https://example.com")], focused: false)]), into: &session)
    #expect(context(session).page == nil)
    // Allowed: explicit incognito state still strips page and live tab identity.
    try receive(.inventory(windows: [window([tab("https://private.example")], incognito: true)]), into: &session)
    #expect(context(session) == Context(appBundleID: BrowserSession.bundleID))
    #expect(Anchor.app(bundleID: BrowserSession.bundleID).matches(context(session)))
}

@Test func profileConnectionsAndSessionsCannotReuseStaleContext() throws {
    var session = try connected()
    try receive(.inventory(windows: [window([tab("https://example.com/a")])]), into: &session)
    try receive(.hello(BridgeHello(profile: profileB, extVersion: "1", incognitoAllowed: false)), into: &session, connection: 2, profile: profileB)
    try receive(.inventory(windows: [window([tab("https://example.com/b")])]), into: &session, connection: 2, profile: profileB)
    #expect(context(session).page == nil) // ambiguous cross-profile focus fails closed
    try receive(.inventory(windows: [window([tab("https://example.com/a")], focused: false)]), into: &session)
    #expect(context(session).tab?.profile == profileB)
    try receive(.tabUpdated(tabId: 1, url: "https://example.com/old-profile", title: nil), into: &session)
    #expect(context(session).page?.path == "/b")
    try receive(.hello(BridgeHello(profile: profileB, extVersion: "1", incognitoAllowed: false)), into: &session, connection: 3, profile: profileB)
    try receive(.inventory(windows: [window([tab("https://example.com/reconnected")])]), into: &session, connection: 3, profile: profileB)
    session.receive(.disconnected(connection: 2, profile: profileB))
    #expect(context(session).page?.path == "/reconnected")
    session.setIdentity("100@2")
    #expect(context(session).page == nil)
}

@Test func backgroundTabActivationDoesNotStealWindowFocus() throws {
    var session = try connected()
    try receive(.inventory(windows: [window([tab("https://example.com/front")]), window([tab("https://example.com/back", id: 2)], id: 2, focused: false)]), into: &session)
    try receive(.active(windowId: 2, incognito: false, tab: tab("https://example.com/back", id: 2)), into: &session)
    #expect(context(session).page?.path == "/front")
    try receive(.tabReplaced(added: 3, removed: 1), into: &session)
    #expect(context(session).page == nil)
    session.receive(.disconnected(connection: 1, profile: profileA))
    #expect(context(session).page == nil)
}

@Test func videoNotesSurviveStoreAndBrowserRestart() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("notes.json")
    var session = try connected()
    try receive(.inventory(windows: [window([tab("https://www.youtube.com/watch?v=one")])]), into: &session)
    let store = NoteStore(fileURL: url)
    let note = Note(anchor: .web(page: try #require(context(session).page), scope: .page), text: "First video", frame: NoteFrame(x: 40, y: 90, width: 300, height: 240), placement: .window)
    #expect(store.add(note))
    try store.save()
    session.setIdentity(nil)
    session.setIdentity("200@2")
    try receive(.hello(BridgeHello(profile: profileA, extVersion: "1", incognitoAllowed: false)), into: &session)
    try receive(.inventory(windows: [window([tab("https://youtube.com/watch?v=two", id: 9)])]), into: &session)
    let reopened = NoteStore(fileURL: url)
    #expect(reopened.notes(matching: context(session)).isEmpty)
    try receive(.active(windowId: 1, incognito: false, tab: tab("https://youtube.com/watch?v=one", id: 10)), into: &session)
    #expect(reopened.notes(matching: context(session)).map(\.id) == [note.id])
}

@Test func scopePickerIncludesPathAndAncestorsWithoutSplittingEncodedSegments() throws {
    let page = try #require(PageURL(string: "https://example.com/a%2Fb/c"))
    let scopes = NoteScope.choices(for: Context(appBundleID: BrowserSession.bundleID, page: page))
    #expect(scopes.map(\.title) == ["This page", "/a%2Fb/c and below", "/a%2Fb and below", "Whole site", "This app"])
    #expect(NoteScope.choices(for: Context(appBundleID: BrowserSession.bundleID)).map(\.title) == ["This app"])
    let root = try #require(PageURL(string: "https://example.com"))
    #expect(NoteScope.choices(for: Context(appBundleID: BrowserSession.bundleID, page: root)).count == 3)
}

@Test func recordedChromeSequenceReplaysThroughTheMonitor() throws {
    let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("extension/tests/fixtures/browser-recording.json")
    let messages = try JSONDecoder().decode([ExtensionMessage].self, from: Data(contentsOf: fixture))
    var session = try connected()
    let frame = CGRect(x: 120, y: 140, width: 1000, height: 700)
    var paths: [String] = []
    for message in messages {
        try receive(message, into: &session)
        if let page = context(session, frame: frame).page { paths.append(page.path) }
        if case .tabClosed = message { #expect(context(session, frame: frame).page == nil) }
    }
    #expect(paths.contains("/example"))
    #expect(paths.contains("/second"))
    #expect(context(session, frame: frame).page == nil)
    #expect(messages.contains { if case .active = $0 { true } else { false } })
    #expect(messages.contains { if case .tabUpdated = $0 { true } else { false } })
    #expect(messages.contains { if case .tabClosed = $0 { true } else { false } })
}

@Test func unknownWindowClearsOldContextUntilItsInventoryArrives() throws {
    var session = try connected()
    try receive(.inventory(windows: [window([tab("https://example.com/old")])]), into: &session)
    try receive(.active(windowId: 2, incognito: false, tab: tab("https://example.com/new", id: 2)), into: &session)
    #expect(context(session).page == nil)
    try receive(.inventory(windows: [window([tab("https://example.com/old")], focused: false), window([tab("https://example.com/new", id: 2)], id: 2)]), into: &session)
    #expect(context(session).page?.path == "/new")
    #expect(context(session).tab?.windowID == 2)
    // A resend hello on the same connection must not erase a valid inventory.
    try receive(.hello(BridgeHello(profile: profileA, extVersion: "1", incognitoAllowed: false)), into: &session)
    #expect(context(session).page?.path == "/new")
    try receive(.tabMoved(tabId: 2, windowId: 1, index: 1), into: &session)
    #expect(context(session).page == nil)
    try receive(.inventory(windows: [window([tab("https://example.com/new", id: 2)])]), into: &session)
    #expect(context(session).tab?.windowID == 1)
}

@Test(arguments: ["browser-incognito-recording", "browser-incognito-denied-recording"])
func recordedPrivateWindowNeverReusesNormalPage(_ name: String) throws {
    let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("extension/tests/fixtures/\(name).json")
    let messages = try JSONDecoder().decode([ExtensionMessage].self, from: Data(contentsOf: fixture))
    var session = try connected()
    let frame = CGRect(x: 120, y: 140, width: 1000, height: 700)
    let appNote = Note(anchor: .app(bundleID: BrowserSession.bundleID), frame: NoteFrame(), placement: .window)
    var sawPrivateTransition = false
    var sawNormalPage = false
    for message in messages {
        try receive(message, into: &session)
        let current = context(session, frame: frame)
        if current.page != nil { sawNormalPage = true }
        switch message {
        case .active(_, true, _):
            sawPrivateTransition = true
        case .inventory(let windows) where windows.contains(where: { $0.incognito && $0.focused })
            || !windows.contains(where: \.focused):
            sawPrivateTransition = true
        default:
            break
        }
        if sawPrivateTransition {
            #expect(current.page == nil)
            #expect(current.tab == nil)
            #expect(NoteVisibility.isVisible(appNote, in: current))
            #expect(NoteScope.choices(for: current).map(\.title) == ["This app"])
        }
    }
    #expect(sawNormalPage)
    #expect(sawPrivateTransition)
}
