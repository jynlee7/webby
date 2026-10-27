import AppKit
import WebbyCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let chromeBridge = ChromeBridge()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "note.text", accessibilityDescription: "Webby")

        let menu = NSMenu()
        let title = NSMenuItem(title: "Webby \(Webby.version)", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Webby", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        chromeBridge.start()
        if chromeBridge.needsMoveToApplications {
            let item = NSMenuItem(title: "Move Webby to Applications…", action: #selector(showMoveToApplications), keyEquivalent: "")
            item.target = self
            menu.insertItem(item, at: 1)
            DispatchQueue.main.async { self.showMoveToApplications() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        chromeBridge.stop()
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
