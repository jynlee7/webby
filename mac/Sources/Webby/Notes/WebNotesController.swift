import AppKit
import WebbyCore

@MainActor
final class WebNotesController {
    private let store: NoteStore
    private let browser: BrowserMonitor
    private var panels: [UUID: WebNotePanel] = [:]
    private var saveTask: Task<Void, Never>?
    var onSaveError: ((String?) -> Void)?

    init(browser: BrowserMonitor, store: NoteStore = NoteStore()) {
        self.browser = browser
        self.store = store
        let settings = SettingsStore()
        browser.queryRules = QueryRules.effective(rules: QueryRules.builtIns + settings.settings.queryRules, anchors: store.notes.compactMap(\.anchor))
    }

    func refresh() {
        let context = browser.context
        let visible = browser.isChromeActive && browser.frame != nil
            ? store.notes.filter { NoteVisibility.isVisible($0, in: context) } : []
        let ids = Set(visible.map(\.id))
        for id in Array(panels.keys) where !ids.contains(id) {
            panels.removeValue(forKey: id)?.close()
        }
        for note in visible {
            let panel: WebNotePanel
            if let existing = panels[note.id] { panel = existing }
            else {
                panel = makePanel(note: note, context: context)
                panels[note.id] = panel
            }
            panel.updateScope(note: note, context: context)
            let absolute = Geometry.absoluteFrame(for: note, window: browser.frame)
            panel.place(at: Geometry.appKitRect(fromTopLeft: absolute, primaryScreenHeight: primaryScreenHeight))
            if !panel.isVisible { panel.orderFront(nil) }
        }
    }

    func createNote() {
        guard browser.isChromeActive, browser.frame != nil, store.mode == .writable,
              let anchor = NoteScope.choices(for: browser.context).first?.anchor else { return }
        let note = Note(anchor: anchor, frame: NoteFrame(x: 40, y: 90, width: 300, height: 240), placement: .window)
        guard store.add(note) else { return }
        saveNow()
        refresh()
        panels[note.id]?.makeKeyAndOrderFront(nil)
    }

    /// A failed save keeps the edited note in memory and leaves quitting to the user.
    @discardableResult
    func saveNow() -> Bool {
        saveTask?.cancel()
        saveTask = nil
        guard store.hasUnsavedChanges else { return true }
        do {
            try store.saveSynchronously()
            onSaveError?(nil)
            return true
        } catch {
            onSaveError?(error.localizedDescription)
            return false
        }
    }

    private var primaryScreenHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    private func changed() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            guard let self else { return }
            let request = store.saveRequest()
            do {
                _ = try await request.flush()
                if !store.hasUnsavedChanges { onSaveError?(nil) }
            } catch {
                onSaveError?(error.localizedDescription)
            }
        }
    }

    private func makePanel(note: Note, context: Context) -> WebNotePanel {
        let panel = WebNotePanel(note: note, context: context, editable: store.mode == .writable)
        panel.onText = { [weak self] text in
            guard let self, store.updateContent(id: note.id, change: .text(text)) else { return }
            changed()
        }
        panel.onScope = { [weak self] anchor in
            guard let self, store.updateContent(id: note.id, change: .anchor(anchor)) else { return }
            changed()
            refresh()
        }
        panel.onFrame = { [weak self] frame in
            guard let self, let window = browser.frame else { return }
            let absolute = Geometry.topLeftRect(fromAppKit: frame, primaryScreenHeight: primaryScreenHeight)
            let stored = Geometry.storedFrame(absolute: absolute, placement: note.placement, window: window)
            if store.updateLayout(id: note.id, change: .frame(stored)) { changed() }
        }
        panel.onTrash = { [weak self] in
            guard let self, store.trash(id: note.id) else { return }
            changed()
            refresh()
        }
        return panel
    }
}
