import AppKit
import WebbyCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let chromeBridge = ChromeBridge()
    private let browser = BrowserMonitor()
    private var notes: WebNotesController!
    private var saveError: String?
    private var saveStatus: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "note.text", accessibilityDescription: "Webby")

        let menu = NSMenu()
        let title = NSMenuItem(title: "Webby \(Webby.version)", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())
        for (title, action) in [("New Chrome Note", #selector(newNote)),
                                ("Enable Window Access…", #selector(enableWindowAccess)),
                                ("Retry Saving Notes", #selector(retrySave))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        saveStatus = NSMenuItem(title: "Notes saved", action: nil, keyEquivalent: "")
        menu.addItem(saveStatus)
        menu.addItem(NSMenuItem(title: "Quit Webby", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        notes = WebNotesController(browser: browser)
        notes.onSaveError = { [weak self] error in
            self?.saveError = error
            self?.saveStatus.title = error == nil ? "Notes saved" : "Notes not saved — retry saving"
            self?.saveStatus.toolTip = error
        }
        browser.onChange = { [weak self] in self?.notes.refresh() }
        chromeBridge.onEvent = { [weak self] in self?.browser.receive($0) }
        browser.start()
        chromeBridge.start()
        if chromeBridge.needsMoveToApplications {
            let item = NSMenuItem(title: "Move Webby to Applications…", action: #selector(showMoveToApplications), keyEquivalent: "")
            item.target = self
            menu.insertItem(item, at: 1)
            DispatchQueue.main.async { self.showMoveToApplications() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        browser.stop()
        chromeBridge.stop()
    }

    @objc private func newNote() {
        guard browser.isChromeActive else {
            let alert = NSAlert()
            alert.messageText = "Open a Chrome window first"
            alert.informativeText = "Switch to Chrome, then choose New Chrome Note from Webby's menu."
            alert.runModal()
            return
        }
        guard browser.frame != nil else { browser.requestAccessibility(); return }
        notes.createNote()
    }
    @objc private func enableWindowAccess() { browser.requestAccessibility() }
    @objc private func retrySave() {
        if !notes.saveNow() {
            let alert = NSAlert()
            alert.messageText = "Could not save notes"
            alert.informativeText = saveError ?? "Your edits are still in memory."
            alert.runModal()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !notes.saveNow() else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Your notes have unsaved changes"
        alert.informativeText = saveError ?? "The notes file could not be saved."
        alert.addButton(withTitle: "Keep Webby Open")
        alert.addButton(withTitle: "Quit Without Saving")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    /// Webby is running from a temporary App Translocation mount, so Chrome can't be
    /// pointed at its bridge. Moving the app clears translocation.
    @objc private func showMoveToApplications() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Move Webby to Applications"
        alert.informativeText = "Webby is running from a temporary location, so it can't connect to Chrome. Quit Webby, move it to your Applications folder, and open it again."
        alert.runModal()
    }
}

@main
enum WebbyApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
