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
        // Built-ins only until Step 9b adds installed skins.
        let assets = SkinAssetCache { id in
            NoteThemes.bundledSkinsDirectory?.appendingPathComponent(id, isDirectory: true)
        }
        notes = NotesController(store: NoteStore(), monitor: monitor, permission: permission, themes: resolveThemes(), assets: assets)
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
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        notes.terminationReply()
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
