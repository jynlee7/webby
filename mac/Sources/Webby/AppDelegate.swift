import AppKit
import OSLog
import WebbyCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let chromeBridge = ChromeBridge()
    private var notes: NotesController!
    private var statusMenu: StatusMenu!
    private var hotkeys: Hotkeys!
    private var settingsStore: SettingsStore!
    private var settingsWindow: SettingsWindowController?
    private var libraryWindow: LibraryWindowController?
    private let linkRouter = NoteLinkRouter()
    private var permission: AccessibilityPermission!
    private var monitor: ContextMonitor!
    private var storedShortcutProblem: String?
    private var builtInSkins: [InstalledSkin] = []
    private var accessibilityObserver: NSObjectProtocol?
    private let logger = Logger(subsystem: Webby.bundleID, category: "app")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = Self.makeMainMenu()

        permission = AccessibilityPermission()
        monitor = ContextMonitor(permission: permission)
        settingsStore = SettingsStore()
        builtInSkins = NoteThemes.loadBuiltInSkins(from: NoteThemes.bundledSkinsDirectory)
        if builtInSkins.count < NoteThemes.builtInIDs.count {
            logger.error("Loaded \(self.builtInSkins.count) of \(NoteThemes.builtInIDs.count) built-in skins; notes use the fallback look")
        }
        notes = NotesController(store: NoteStore(), monitor: monitor, permission: permission, themes: resolveThemes())
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.notes.updateThemes(self.resolveThemes())
            }
        }

        hotkeys = Hotkeys { [weak self] in self?.notes.newNote() }
        let shortcut = SettingsWindowController.shortcut(from: settingsStore.settings)
        if shortcut.storageString != KeyCombo(settingsStore.settings.newNoteHotkey)?.storageString {
            storedShortcutProblem = "The saved shortcut “\(settingsStore.settings.newNoteHotkey)” can't be used, so \(shortcut.displayString) is used instead."
        }
        statusMenu = StatusMenu(
            notes: notes,
            openLibrary: { [weak self] in self?.showLibrary() },
            openSettings: { [weak self] in self?.showSettings() },
            showMoveToApplications: { [weak self] in self?.showMoveToApplications() }
        )
        hotkeys.onStatusChange = { [weak self] in self?.hotkeyStatusChanged() }
        hotkeys.registerNewNote(shortcut)
        notes.onStatusChange = { [weak self] in self?.statusMenu.refreshIcon() }

        chromeBridge.start()
        if chromeBridge.needsMoveToApplications {
            statusMenu.needsMoveToApplications = true
            DispatchQueue.main.async { self.showMoveToApplications() }
        }

        notes.start()

        linkRouter.onRoute = { [weak self] id in
            guard let self else { return false }
            self.ensureLibraryWindow()
            return self.libraryWindow?.showNote(id) ?? false
        }
        linkRouter.onUnroutable = { [weak self] _ in self?.showMissingNoteLinkAlert() }
        linkRouter.markReady()
    }

    /// External `webby://note/<uuid>` links. Links that arrive before launch finishes
    /// are queued by the router and flushed once `notes.start()` has completed.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            linkRouter.receive(url)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // The Library keeps its own draft; commit it before quit captures the request.
        libraryWindow?.commitPendingEdits()
        return notes.terminationReply()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        chromeBridge.stop()
        monitor.stop()
    }

    private func resolveThemes() -> NoteThemes {
        NoteThemes(
            skins: builtInSkins,
            globalSkinID: settingsStore.settings.globalSkinID,
            accessibility: NoteThemes.systemAccessibility
        )
    }

    private func showLibrary() {
        ensureLibraryWindow()
        libraryWindow?.present()
    }

    /// Creates the one retained Library without presenting it. Both the status menu
    /// and external URL routing use this so a link never waits for a menu action.
    private func ensureLibraryWindow() {
        if libraryWindow == nil {
            libraryWindow = LibraryWindowController(
                notes: notes,
                currentAppBundleID: { [weak self] in self?.monitor.app?.bundleID },
                userQueryRules: settingsStore.settings.queryRules
            )
        }
    }

    private func showMissingNoteLinkAlert() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Note Not Found"
        alert.informativeText = "This link points to a note that is not in the Library anymore. Nothing was changed."
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func showSettings() {
        if settingsWindow == nil {
            let window = SettingsWindowController(
                settings: settingsStore,
                hotkeys: hotkeys,
                permission: permission,
                storedShortcutProblem: storedShortcutProblem
            )
            window.onClose = { [weak self] in self?.settingsClosed() }
            settingsWindow = window
        }
        settingsWindow?.present()
    }

    /// The menu shows the shortcut only while it is registered.
    private func hotkeyStatusChanged() {
        switch hotkeys.newNoteStatus {
        case .registered(let combo): statusMenu.newNoteShortcut = combo
        case .failed: statusMenu.newNoteShortcut = nil
        case .paused: break
        }
        settingsWindow?.refresh()
    }

    private func settingsClosed() {
        // Hand the keyboard back to the app whose notes are showing.
        if let pid = monitor.app?.pid {
            NSRunningApplication(processIdentifier: pid)?.activate()
        }
    }

    /// Webby is running from a temporary App Translocation mount, so Chrome can't be
    /// pointed at its bridge. Moving the app clears translocation.
    private func showMoveToApplications() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Move Webby to Applications"
        alert.informativeText = "Webby is running from a temporary location, so it can't connect to Chrome. Quit Webby, move it to your Applications folder, and open it again."
        alert.runModal()
    }

    /// Webby never shows a menu bar, but while Settings is open these key equivalents
    /// (⌘Q, ⌘W and editing) still apply.
    private static func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Quit Webby", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        main.addItem(submenu: appMenu, title: "Webby")

        let edit = NSMenu(title: "Edit")
        edit.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        main.addItem(submenu: edit, title: "Edit")

        let window = NSMenu(title: "Window")
        window.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        main.addItem(submenu: window, title: "Window")
        return main
    }
}

private extension NSMenu {
    func addItem(submenu: NSMenu, title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}
