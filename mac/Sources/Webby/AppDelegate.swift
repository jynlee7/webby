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
    private var permission: AccessibilityPermission!
    private var monitor: ContextMonitor!
    private var storedShortcutProblem: String?
    private var skins: SkinStore!
    private var skinImporter: SkinImporter!
    private var pendingSkinURLs: [URL] = []
    private var accessibilityObserver: NSObjectProtocol?
    private let logger = Logger(subsystem: Webby.bundleID, category: "app")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = Self.makeMainMenu()

        permission = AccessibilityPermission()
        monitor = ContextMonitor(permission: permission)
        settingsStore = SettingsStore()
        let noteStore = NoteStore()
        skins = SkinStore(
            userRoot: Self.userSkinsRoot,
            builtInDirectory: NoteThemes.bundledSkinsDirectory,
            settings: settingsStore,
            noteStore: noteStore
        )
        if skins.rows.filter({ !$0.isUserSkin && $0.isAccepted }).count < NoteThemes.builtInIDs.count {
            logger.error("Fewer than \(NoteThemes.builtInIDs.count) built-in skins loaded; notes use the fallback look")
        }
        if let notice = skins.notice { logger.notice("\(notice, privacy: .public)") }
        let assets = SkinAssetCache(folder: skins.assetFolderProvider)
        skins.assetCache = assets
        notes = NotesController(store: noteStore, monitor: monitor, permission: permission, skins: skins, assets: assets)
        skinImporter = SkinImporter(store: skins)
        skins.onThemesChanged = { [weak self] in self?.notes.refreshThemes() }
        skins.onNotesMutated = { [weak self] in self?.notes.workspacesMutated() }
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.skins.accessibilityChanged()
            }
        }

        hotkeys = Hotkeys { [weak self] in self?.notes.newNote() }
        let shortcut = SettingsWindowController.shortcut(from: settingsStore.settings)
        if shortcut.storageString != KeyCombo(settingsStore.settings.newNoteHotkey)?.storageString {
            storedShortcutProblem = "The saved shortcut “\(settingsStore.settings.newNoteHotkey)” can't be used, so \(shortcut.displayString) is used instead."
        }
        statusMenu = StatusMenu(
            notes: notes,
            openSettings: { [weak self] in self?.showSettings() },
            importSkin: { [weak self] in self?.skinImporter.chooseFiles() },
            revealSkinsFolder: { [weak self] in self?.revealSkinsFolder() },
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

        // Files opened while launching arrive before this point.
        if !pendingSkinURLs.isEmpty {
            skinImporter.enqueue(pendingSkinURLs)
            pendingSkinURLs = []
        }
    }

    /// Double-clicked or dropped `.webbyskin` files. This is the only open entry point
    /// needed: AppKit prefers it to `application(_:openFile:)` when it exists.
    func application(_ application: NSApplication, open urls: [URL]) {
        let skinFiles = urls.filter { $0.pathExtension.lowercased() == "webbyskin" }
        guard !skinFiles.isEmpty else { return }
        if let skinImporter {
            skinImporter.enqueue(skinFiles)
        } else {
            pendingSkinURLs.append(contentsOf: skinFiles)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        notes.terminationReply()
    }

    func applicationWillTerminate(_ notification: Notification) {
        skinImporter?.discardAll()
        skins.stop()
        chromeBridge.stop()
        monitor.stop()
    }

    private static var userSkinsRoot: URL {
        SettingsStore.defaultFileURL.deletingLastPathComponent().appendingPathComponent("Skins", isDirectory: true)
    }

    private func showSettings() {
        if settingsWindow == nil {
            let window = SettingsWindowController(
                settings: settingsStore,
                skins: skins,
                importSkin: { [weak self] in self?.skinImporter.chooseFiles() },
                hotkeys: hotkeys,
                permission: permission,
                storedShortcutProblem: storedShortcutProblem
            )
            window.onClose = { [weak self] in self?.settingsClosed() }
            settingsWindow = window
        }
        settingsWindow?.present()
    }

    private func revealSkinsFolder() {
        do {
            NSWorkspace.shared.activateFileViewerSelecting([try skins.skinsFolderURL])
        } catch {
            NSApp.activate()
            let alert = NSAlert()
            alert.messageText = "Couldn't open the skins folder"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
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
