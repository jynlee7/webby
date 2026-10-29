import AppKit
import WebbyCore

/// The menu-bar item. Its menu is rebuilt each time it opens, so it always lists the
/// notes of the app the user is in.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    var newNoteShortcut: KeyCombo?
    var needsMoveToApplications = false

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let notes: NotesController
    private let openSettings: @MainActor () -> Void
    private let importSkin: @MainActor () -> Void
    private let revealSkinsFolder: @MainActor () -> Void
    private let showMoveToApplications: @MainActor () -> Void

    init(
        notes: NotesController,
        openSettings: @escaping @MainActor () -> Void,
        importSkin: @escaping @MainActor () -> Void,
        revealSkinsFolder: @escaping @MainActor () -> Void,
        showMoveToApplications: @escaping @MainActor () -> Void
    ) {
        self.notes = notes
        self.openSettings = openSettings
        self.importSkin = importSkin
        self.revealSkinsFolder = revealSkinsFolder
        self.showMoveToApplications = showMoveToApplications
        super.init()
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
        refreshIcon()
    }

    /// Shows a warning icon while notes can't be saved.
    func refreshIcon() {
        let problem = notes.saveFailure != nil || !notes.isWritable
        statusItem.button?.image = NSImage(
            systemSymbolName: problem ? "exclamationmark.triangle" : "note.text",
            accessibilityDescription: problem ? "Webby: notes aren't being saved" : "Webby"
        )
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild()
    }

    private func rebuild() {
        menu.removeAllItems()

        let title = NSMenuItem(title: "Webby \(Webby.version)", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        if needsMoveToApplications {
            menu.addItem(ActionMenuItem("Move Webby to Applications…", run: showMoveToApplications))
        }
        menu.addItem(.separator())

        let newNote = ActionMenuItem(notes.appName.map { "New Note in \($0)" } ?? "New Note") { [notes] in
            notes.newNote()
        }
        newNote.isEnabled = notes.canCreateNote
        if let newNoteShortcut, let key = Self.keyEquivalent(for: newNoteShortcut) {
            newNote.keyEquivalent = key
            newNote.keyEquivalentModifierMask = Self.modifierMask(newNoteShortcut.modifiers)
        }
        menu.addItem(newNote)

        if let appName = notes.appName {
            addNotes(of: appName)
        }
        menu.addItem(.separator())

        if let failure = notes.saveFailure {
            let status = NSMenuItem(title: "Notes couldn't be saved", action: nil, keyEquivalent: "")
            status.isEnabled = false
            status.toolTip = failure
            menu.addItem(status)
            menu.addItem(ActionMenuItem("Retry Saving") { [notes] in notes.retrySave() })
            menu.addItem(.separator())
        }
        if let problem = notes.readOnlyProblem {
            let status = NSMenuItem(title: "Notes are read-only", action: nil, keyEquivalent: "")
            status.isEnabled = false
            status.toolTip = problem
            menu.addItem(status)
            let fileURL = notes.store.fileURL
            menu.addItem(ActionMenuItem("Show Notes File in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            })
            menu.addItem(.separator())
        }

        // The Library arrives in Step 5b.
        let library = NSMenuItem(title: "Library", action: nil, keyEquivalent: "")
        library.isEnabled = false
        menu.addItem(library)
        menu.addItem(ActionMenuItem("Import Skin…", run: importSkin))
        menu.addItem(ActionMenuItem("Reveal Skins Folder", run: revealSkinsFolder))
        menu.addItem(ActionMenuItem("Settings…", key: ",", run: openSettings))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Webby", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func addNotes(of appName: String) {
        menu.addItem(.sectionHeader(title: appName))
        let listed = notes.currentContextNotes()
        if listed.shown.isEmpty && listed.hidden.isEmpty {
            let empty = NSMenuItem(title: "No notes here", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for note in listed.shown {
            let id = note.id
            let item = ActionMenuItem(note.summaryLine() ?? "Empty note") { [notes] in notes.show(id) }
            item.image = NSImage(
                systemSymbolName: note.collapsed ? "rectangle.compress.vertical" : "note.text",
                accessibilityDescription: note.collapsed ? "Collapsed" : nil
            )
            item.toolTip = note.collapsed ? "Collapsed. Choose to expand it." : nil
            menu.addItem(item)
        }
        if !listed.hidden.isEmpty {
            let count = listed.hidden.count
            let label = NSMenuItem(title: "\(count) hidden \(count == 1 ? "note" : "notes") here", action: nil, keyEquivalent: "")
            label.isEnabled = false
            menu.addItem(label)
            menu.addItem(ActionMenuItem("Show All") { [notes] in notes.showAllHidden() })
        }
    }

    private static func keyEquivalent(for combo: KeyCombo) -> String? {
        switch combo.key {
        case "return": return "\r"
        case "tab": return "\t"
        case "space": return " "
        case "delete": return "\u{8}"
        case let key where key.count == 1: return key
        default: return nil  // Function keys are shown in Settings only.
        }
    }

    private static func modifierMask(_ modifiers: KeyCombo.Modifiers) -> NSEvent.ModifierFlags {
        var mask: NSEvent.ModifierFlags = []
        if modifiers.contains(.control) { mask.insert(.control) }
        if modifiers.contains(.option) { mask.insert(.option) }
        if modifiers.contains(.shift) { mask.insert(.shift) }
        if modifiers.contains(.command) { mask.insert(.command) }
        return mask
    }
}

/// A menu item that runs a closure.
@MainActor
private final class ActionMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(_ title: String, key: String = "", run: @escaping @MainActor () -> Void) {
        handler = run
        super.init(title: title, action: #selector(runHandler), keyEquivalent: key)
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func runHandler() {
        handler()
    }
}
