import AppKit
import OSLog
import WebbyCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let chromeBridge = ChromeBridge()
    private let openTabs = OpenTabsFeed()
    private let browser = BrowserMonitor()
    private var notes: NotesController!
    private var statusMenu: StatusMenu!
    private var hotkeys: Hotkeys!
    private var settingsStore: SettingsStore!
    private var settingsWindow: SettingsWindowController?
    private var libraryWindow: LibraryWindowController?
    private let linkRouter = NoteLinkRouter()
    private var isShowingMissingNoteAlert = false
    private var permission: AccessibilityPermission!
    private var monitor: ContextMonitor!
    private var storedShortcutProblem: String?
    private var chromeSettings: ChromeSettingsModel!
    private var skins: SkinStore!
    private var skinImporter: SkinImporter!
    private var pendingSkinURLs: [URL] = []
    private var accessibilityObserver: NSObjectProtocol?
    private let logger = Logger(subsystem: Webby.bundleID, category: "app")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = Self.makeMainMenu()

        permission = AccessibilityPermission()
        monitor = ContextMonitor(permission: permission, browser: browser)
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
        browser.queryRules = { [weak self] in
            guard let self else { return QueryRules.builtIns }
            return QueryRules.effective(
                rules: self.settingsStore.settings.enabledQueryRules,
                anchors: self.notes.store.notes.lazy.filter { $0.trashedAt == nil }.compactMap(\.anchor)
            )
        }
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
        chromeSettings = ChromeSettingsModel(
            bundledVersion: { [weak self] in
                guard let self else { return nil }
                return Self.bundledVersion(from: self.chromeBridge.extensionInstall)
            },
            installedVersion: { [weak self] in self?.chromeBridge.installedExtensionVersion() },
            extensionOutcome: { [weak self] in self?.chromeBridge.extensionInstall },
            hostInspection: { [weak self] in self?.chromeBridge.inspectHost() ?? .missing }
        )
        chromeSettings.repairExtension = { [weak self] in
            guard let self else { return }
            self.chromeBridge.repairExtension()
            self.chromeSettings.refresh()
        }
        chromeSettings.reRegisterHost = { [weak self] in
            guard let self else { return }
            self.chromeBridge.reRegisterHost()
            self.chromeSettings.refresh()
        }
        let shortcut = SettingsWindowController.shortcut(from: settingsStore.settings)
        if shortcut.storageString != KeyCombo(settingsStore.settings.newNoteHotkey)?.storageString {
            storedShortcutProblem = "The saved shortcut “\(settingsStore.settings.newNoteHotkey)” can't be used, so \(shortcut.displayString) is used instead."
        }
        statusMenu = StatusMenu(
            notes: notes,
            openLibrary: { [weak self] in self?.showLibrary() },
            openSettings: { [weak self] in self?.showSettings() },
            importSkin: { [weak self] in self?.skinImporter.chooseFiles() },
            revealSkinsFolder: { [weak self] in self?.revealSkinsFolder() },
            showMoveToApplications: { [weak self] in self?.showMoveToApplications() }
        )
        hotkeys.onStatusChange = { [weak self] in self?.hotkeyStatusChanged() }
        hotkeys.registerNewNote(shortcut)
        notes.onStatusChange = { [weak self] in self?.statusMenu.refreshIcon() }

        // Every consumer sees every event: Open Tabs lists tabs, the browser monitor
        // follows the focused window's page for web notes, and Chrome settings tracks
        // connected profiles.
        chromeBridge.onEvent = { [weak self] event in
            self?.openTabs.receive(event)
            self?.browser.receive(event)
            self?.chromeSettings.receive(event)
        }
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

        linkRouter.onRoute = { [weak self] id in
            guard let self else { return false }
            self.ensureLibraryWindow()
            return self.libraryWindow?.showNote(id) ?? false
        }
        linkRouter.onUnroutable = { [weak self] _ in self?.showMissingNoteLinkAlert() }
        linkRouter.markReady()
    }

    /// Double-clicked or dropped `.webbyskin` files and external `webby://note/<uuid>`
    /// links. This is the only open entry point needed: AppKit prefers it to
    /// `application(_:openFile:)` when it exists. Links that arrive before launch
    /// finishes are queued by the router and flushed once `notes.start()` has completed.
    func application(_ application: NSApplication, open urls: [URL]) {
        let skinFiles = urls.filter { $0.isFileURL && $0.pathExtension.lowercased() == "webbyskin" }
        if !skinFiles.isEmpty {
            if let skinImporter {
                skinImporter.enqueue(skinFiles)
            } else {
                pendingSkinURLs.append(contentsOf: skinFiles)
            }
        }
        for url in urls where !skinFiles.contains(url) {
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
        skinImporter?.discardAll()
        skins.stop()
        chromeBridge.stop()
        monitor.stop()
    }

    private static var userSkinsRoot: URL {
        SettingsStore.defaultFileURL.deletingLastPathComponent().appendingPathComponent("Skins", isDirectory: true)
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
                openTabs: openTabs,
                currentAppBundleID: { [weak self] in self?.monitor.app?.bundleID },
                currentContext: { [weak self] in self?.monitor.context },
                enabledQueryRules: settingsStore.settings.enabledQueryRules
            )
        }
    }

    private func showMissingNoteLinkAlert() {
        // runModal spins a nested loop; links arriving meanwhile are absorbed.
        guard !isShowingMissingNoteAlert else { return }
        isShowingMissingNoteAlert = true
        defer { isShowingMissingNoteAlert = false }
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
                notes: notes,
                skins: skins,
                importSkin: { [weak self] in self?.skinImporter.chooseFiles() },
                hotkeys: hotkeys,
                permission: permission,
                chrome: chromeSettings,
                storedShortcutProblem: storedShortcutProblem
            )
            window.onClose = { [weak self] in self?.settingsClosed() }
            window.chromeIncognitoAccess = { [weak self] in self?.browser.incognitoAccess ?? [:] }
            window.onQueryRulesChange = { [weak self] rules in
                self?.libraryWindow?.model.enabledQueryRules = rules
                // Page identity may have changed for the current Chrome tab.
                self?.notes.layout()
            }
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
