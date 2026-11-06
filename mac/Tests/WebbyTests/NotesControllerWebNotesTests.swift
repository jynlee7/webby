import Foundation
import Testing
@testable import Webby
import WebbyCore

private let chromeFrame = CGRect(x: 20, y: 40, width: 1000, height: 700)
private let profile = "3f2504e0-4f89-41d3-9a0c-0305e82c3301"

private func window(_ url: String, tabID: Int = 1, incognito: Bool = false) -> BridgeWindow {
    BridgeWindow(
        id: 1,
        focused: true,
        incognito: incognito,
        bounds: BridgeWindowBounds(left: 20, top: 40, width: 1000, height: 700),
        tabs: [BridgeTab(id: tabID, index: 0, active: true, url: url, title: "Synthetic tab")]
    )
}

@MainActor
private func send(_ message: ExtensionMessage, to browser: BrowserMonitor) {
    browser.receive(.message(connection: 1, profile: profile, message))
}

/// Web notes go through the same controller, store and overlays as app notes.
@MainActor
@Suite struct NotesControllerWebNotesTests {
    @Test func chromeNotesDefaultToThePageAndFollowTheScopePicker() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WebbyWebNotes-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NoteStore(fileURL: directory.appendingPathComponent("notes.json"))
        let permission = AccessibilityPermission()
        let browser = BrowserMonitor(sessionIdentity: { "100@1" })
        let monitor = ContextMonitor(permission: permission, browser: browser)
        monitor.app = ContextMonitor.FrontApp(bundleID: BrowserSession.bundleID, pid: 1, name: "Google Chrome")
        monitor.windowFrame = chromeFrame
        let controller = NotesController(store: store, monitor: monitor, permission: permission, themes: .fallback)
        defer { controller.windows.values.forEach { $0.close() } }

        send(.hello(BridgeHello(profile: profile, extVersion: "1", incognitoAllowed: true)), to: browser)
        send(.inventory(windows: [window("https://leetcode.com/problems/two-sum/description")]), to: browser)
        controller.newNote()

        let note = try #require(store.notes.first)
        let page = try #require(PageURL(string: "https://leetcode.com/problems/two-sum/description", queryRules: QueryRules.builtIns))
        #expect(note.anchor == .web(page: page, scope: .page))
        let model = try #require(controller.windows[note.id]?.model)
        #expect(model.scopes.map(\.title) == [
            "This page",
            "/problems/two-sum/description and below",
            "/problems/two-sum and below",
            "/problems and below",
            "Whole site",
            "Just this tab",
            "This app",
        ])
        #expect(model.selectedScope == 0)

        model.chooseScope(at: 2)
        #expect(store.note(id: note.id)?.anchor == .web(page: page, scope: .prefix(path: "/problems/two-sum")))
        #expect(model.selectedScope == 2)

        send(.tabUpdated(tabId: 1, url: "https://leetcode.com/problems/two-sum/submissions", title: nil), to: browser)
        controller.layout()
        #expect(controller.windows[note.id] != nil)
        // The path anchor keeps its creation page but still reads as the same choice.
        #expect(controller.windows[note.id]?.model.selectedScope == 2)

        send(.tabUpdated(tabId: 1, url: "https://leetcode.com/problems/two-sum-ii", title: nil), to: browser)
        controller.layout()
        #expect(controller.windows[note.id] == nil)
    }

    @Test func privateWindowsShowOnlyAppNotes() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WebbyWebNotes-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NoteStore(fileURL: directory.appendingPathComponent("notes.json"))
        let page = try #require(PageURL(string: "https://example.com/a", queryRules: QueryRules.builtIns))
        let webNote = Note(anchor: .web(page: page, scope: .site), frame: NoteFrame(), placement: .screen)
        let appNote = Note(anchor: .app(bundleID: BrowserSession.bundleID), frame: NoteFrame(), placement: .screen)
        #expect(store.add(webNote))
        #expect(store.add(appNote))

        let permission = AccessibilityPermission()
        let browser = BrowserMonitor(sessionIdentity: { "100@1" })
        let monitor = ContextMonitor(permission: permission, browser: browser)
        monitor.app = ContextMonitor.FrontApp(bundleID: BrowserSession.bundleID, pid: 1, name: "Google Chrome")
        monitor.windowFrame = chromeFrame
        let controller = NotesController(store: store, monitor: monitor, permission: permission, themes: .fallback)
        defer { controller.windows.values.forEach { $0.close() } }

        send(.hello(BridgeHello(profile: profile, extVersion: "1", incognitoAllowed: true)), to: browser)
        send(.inventory(windows: [window("https://example.com/a")]), to: browser)
        controller.layout()
        #expect(Set(controller.windows.keys) == [webNote.id, appNote.id])

        send(.inventory(windows: [window("https://example.com/a", tabID: 2, incognito: true)]), to: browser)
        controller.layout()
        #expect(Set(controller.windows.keys) == [appNote.id])
        #expect(controller.windows[appNote.id]?.model.scopes.map(\.title) == ["This app"])

        // A frame that doesn't match the bridge's bounds is never trusted with a page.
        send(.inventory(windows: [window("https://example.com/a")]), to: browser)
        monitor.windowFrame = chromeFrame.offsetBy(dx: 80, dy: 0)
        controller.layout()
        #expect(Set(controller.windows.keys) == [appNote.id])
    }
}
