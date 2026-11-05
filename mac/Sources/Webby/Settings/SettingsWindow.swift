import AppKit
import SwiftUI
import WebbyCore

/// The Settings window: a toolbar of panes. Step 3b has General; later steps add theirs
/// as further tab items.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    /// Called when the window closes, so the app the user came from can take focus back.
    var onClose: (@MainActor () -> Void)?
    /// Called with the rules in force after they change, so caches can refresh.
    var onQueryRulesChange: (@MainActor ([QueryRule]) -> Void)?

    private let settings: SettingsStore
    private let hotkeys: Hotkeys
    private let permission: AccessibilityPermission
    private let general: GeneralSettingsModel
    private let notes: NotesController
    private let queryRules = QueryRulesSettingsModel()
    private var keyMonitor: Any?

    init(settings: SettingsStore, notes: NotesController, hotkeys: Hotkeys, permission: AccessibilityPermission, storedShortcutProblem: String?) {
        self.settings = settings
        self.notes = notes
        self.hotkeys = hotkeys
        self.permission = permission
        general = GeneralSettingsModel(
            shortcut: Self.shortcut(from: settings.settings),
            storedShortcutProblem: storedShortcutProblem
        )

        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        let hosting = NSHostingController(rootView: GeneralSettingsView(model: general))
        hosting.sizingOptions = [.preferredContentSize]
        let item = NSTabViewItem(viewController: hosting)
        item.label = "General"
        item.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        tabs.addTabViewItem(item)

        let queryHosting = NSHostingController(rootView: QueryRulesSettingsView(model: queryRules))
        queryHosting.sizingOptions = [.preferredContentSize]
        let queryItem = NSTabViewItem(viewController: queryHosting)
        queryItem.label = "Pages"
        queryItem.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        tabs.addTabViewItem(queryItem)

        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        super.init(window: window)
        window.delegate = self
        window.center()

        general.startRecording = { [weak self] in self?.startRecording() }
        general.stopRecording = { [weak self] in self?.stopRecording() }
        general.resetShortcut = { [weak self] in self?.save(.defaultNewNote) }
        general.allowAccessibility = { [weak self] in self?.permission.requestAccess() }
        general.openAccessibilitySettings = { [weak self] in self?.permission.openSystemSettings() }
        permission.onChange { [weak self] in self?.refresh() }
        queryRules.add = { [weak self] in self?.addQueryRule() }
        queryRules.remove = { [weak self] row in self?.removeQueryRule(row) }
        queryRules.convert = { [weak self] row in self?.convertQueryRule(row) }
        // The window lives as long as the app, so the observer is never removed.
        notes.addLibraryObserver { [weak self] in self?.refreshQueryRules() }
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The New Note shortcut stored in settings, or the default when the stored text
    /// isn't a usable global shortcut.
    static func shortcut(from settings: WebbyCore.Settings) -> KeyCombo {
        guard let combo = KeyCombo(settings.newNoteHotkey), combo.isUsableGlobally else { return .defaultNewNote }
        return combo
    }

    func present() {
        refresh()
        NSApp.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Re-reads the hotkey, permission and storage state.
    func refresh() {
        let status = hotkeys.newNoteStatus
        if status != .paused {
            general.hotkeyMessage = status.message
            general.hotkeyFailed = status.isFailure
        }
        general.accessibilityTrusted = permission.isTrusted
        if case .readOnly(let problem) = settings.mode {
            general.storageProblem = SettingsError.readOnly(problem).localizedDescription
        } else {
            general.storageProblem = nil
        }
        queryRules.storageProblem = general.storageProblem
        refreshQueryRules()
    }

    // MARK: Pages that differ by query

    private func refreshQueryRules() {
        queryRules.pane = QueryRulesPane(settings: settings.settings, notes: notes.libraryNotes)
    }

    /// Persists changed rules, then refreshes the pane and whatever caches the rules.
    private func saveQueryRules(_ updated: WebbyCore.Settings) -> Bool {
        do {
            try settings.replace(updated)
        } catch {
            queryRules.message = error.localizedDescription
            return false
        }
        onQueryRulesChange?(settings.settings.enabledQueryRules)
        refreshQueryRules()
        return true
    }

    private func addQueryRule() {
        do {
            let updated = try QueryRulesPane.adding(host: queryRules.newHost, key: queryRules.newKey, to: settings.settings)
            guard saveQueryRules(updated) else { return }
            queryRules.newHost = ""
            queryRules.newKey = ""
            queryRules.message = nil
        } catch {
            queryRules.message = error.localizedDescription
        }
    }

    private func removeQueryRule(_ row: QueryRulesPane.Row) {
        guard saveQueryRules(QueryRulesPane.removing(host: row.host, key: row.key, from: settings.settings)) else { return }
        queryRules.message = nil
    }

    private func convertQueryRule(_ row: QueryRulesPane.Row) {
        guard let plan = queryRules.pane.convertPlan(host: row.host, key: row.key) else { return }
        guard notes.isWritable else {
            queryRules.message = "Notes are read-only, so nothing was changed."
            return
        }
        let alert = NSAlert()
        alert.messageText = plan.confirmationTitle
        alert.informativeText = plan.confirmationMessage
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Convert")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let changed = notes.applyAnchorRewrites(plan.rewrites)
        queryRules.message = changed == plan.rewrites.count ? nil : "Some notes could not be converted."
        refreshQueryRules()
    }

    func windowWillClose(_ notification: Notification) {
        stopRecording()
        onClose?()
    }

    // MARK: Recording a shortcut

    private func startRecording() {
        guard keyMonitor == nil else { return }
        hotkeys.pause()
        general.isRecording = true
        general.recordingMessage = nil
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.record(event) ?? false }
            return handled ? nil : event
        }
    }

    /// Returns true when the key press was used, so no view receives it.
    private func record(_ event: NSEvent) -> Bool {
        if event.keyCode == 0x35 {  // Escape
            stopRecording()
            return true
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: KeyCombo.Modifiers = []
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.command) { modifiers.insert(.command) }

        guard let combo = KeyCombo(keyCode: event.keyCode, modifiers: modifiers) else {
            general.recordingMessage = "That key can't be used. Try a letter, number or function key."
            return true
        }
        guard combo.isUsableGlobally else {
            general.recordingMessage = "Include ⌃, ⌥ or ⌘ so the shortcut doesn't get in the way of typing."
            return true
        }
        save(combo)
        return true
    }

    private func stopRecording() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        guard general.isRecording else { return }
        general.isRecording = false
        general.recordingMessage = nil
        hotkeys.resume()
        refresh()
    }

    private func save(_ combo: KeyCombo) {
        var updated = settings.settings
        updated.newNoteHotkey = combo.storageString
        do {
            try settings.replace(updated)
            general.shortcut = combo
            general.storedShortcutProblem = nil
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
            general.isRecording = false
            general.recordingMessage = nil
            hotkeys.registerNewNote(combo)
        } catch {
            general.recordingMessage = error.localizedDescription
            stopRecording()
        }
        refresh()
    }
}

@MainActor @Observable
final class GeneralSettingsModel {
    var shortcut: KeyCombo
    var isRecording = false
    var recordingMessage: String?
    var hotkeyMessage = ""
    var hotkeyFailed = false
    var storedShortcutProblem: String?
    var storageProblem: String?
    var accessibilityTrusted = false

    @ObservationIgnored var startRecording: @MainActor () -> Void = {}
    @ObservationIgnored var stopRecording: @MainActor () -> Void = {}
    @ObservationIgnored var resetShortcut: @MainActor () -> Void = {}
    @ObservationIgnored var allowAccessibility: @MainActor () -> Void = {}
    @ObservationIgnored var openAccessibilitySettings: @MainActor () -> Void = {}

    init(shortcut: KeyCombo, storedShortcutProblem: String?) {
        self.shortcut = shortcut
        self.storedShortcutProblem = storedShortcutProblem
    }
}

private struct GeneralSettingsView: View {
    let model: GeneralSettingsModel

    var body: some View {
        Form {
            Section("New Note") {
                LabeledContent("Shortcut") {
                    HStack {
                        Button(model.isRecording ? "Press a shortcut…" : model.shortcut.displayString) {
                            if model.isRecording { model.stopRecording() } else { model.startRecording() }
                        }
                        .frame(minWidth: 140)
                        .accessibilityHint(model.isRecording ? "Press Escape to cancel" : "Records a new shortcut")
                        Button("Reset to ⌃⌥N") { model.resetShortcut() }
                            .disabled(model.shortcut == .defaultNewNote || model.isRecording)
                    }
                }
                if let message = model.recordingMessage {
                    note(message, failure: true)
                } else if !model.isRecording, !model.hotkeyMessage.isEmpty {
                    note(model.hotkeyMessage, failure: model.hotkeyFailed)
                }
                if let problem = model.storedShortcutProblem {
                    note(problem, failure: true)
                }
            }

            Section("Accessibility") {
                LabeledContent("Notes follow their window") {
                    Text(model.accessibilityTrusted ? "On" : "Off")
                }
                note(model.accessibilityTrusted
                     ? "Webby reads only where the front window is, so a note stays in the same place on it."
                     : "Without Accessibility access, notes stay at fixed places on the screen.",
                     failure: false)
                if !model.accessibilityTrusted {
                    HStack {
                        Button("Allow Accessibility…") { model.allowAccessibility() }
                        Button("Open System Settings") { model.openAccessibilitySettings() }
                    }
                }
            }

            if let problem = model.storageProblem {
                Section {
                    Label(problem, systemImage: "exclamationmark.triangle")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func note(_ text: String, failure: Bool) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(failure ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            .fixedSize(horizontal: false, vertical: true)
    }
}

@MainActor @Observable
final class QueryRulesSettingsModel {
    var pane = QueryRulesPane(settings: .default, notes: [])
    var newHost = ""
    var newKey = ""
    var message: String?
    var storageProblem: String?

    @ObservationIgnored var add: @MainActor () -> Void = {}
    @ObservationIgnored var remove: @MainActor (QueryRulesPane.Row) -> Void = { _ in }
    @ObservationIgnored var convert: @MainActor (QueryRulesPane.Row) -> Void = { _ in }
}

private struct QueryRulesSettingsView: View {
    @Bindable var model: QueryRulesSettingsModel

    var body: some View {
        Form {
            Section("Pages that differ by query") {
                Text("Pages on these sites are told apart by the listed address parameter, so each video or item gets its own notes.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(model.pane.rows) { row in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(row.host) · \(row.key)")
                            if row.isBuiltIn {
                                Text("Built-in").font(.caption).foregroundStyle(.secondary)
                            }
                            if let status = row.status {
                                Text(status).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if row.isEnabled {
                            Button("Remove") { model.remove(row) }
                                .accessibilityLabel("Remove \(row.host) \(row.key)")
                        } else {
                            Button("Convert…") { model.convert(row) }
                                .accessibilityLabel("Convert notes using \(row.key) on \(row.host)")
                        }
                    }
                }
            }

            Section("Add") {
                TextField("Website", text: $model.newHost, prompt: Text("youtube.com"))
                TextField("Parameter", text: $model.newKey, prompt: Text("v"))
                    .onSubmit { model.add() }
                Button("Add") { model.add() }
                    .disabled(model.newHost.isEmpty || model.newKey.isEmpty)
                if let message = model.message {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let problem = model.storageProblem {
                Section {
                    Label(problem, systemImage: "exclamationmark.triangle")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}
