import AppKit
import SwiftUI
import WebbyCore

/// The Settings window: a toolbar of panes. Step 3b has General; later steps add theirs
/// as further tab items.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    /// Called when the window closes, so the app the user came from can take focus back.
    var onClose: (@MainActor () -> Void)?

    private let settings: SettingsStore
    private let hotkeys: Hotkeys
    private let permission: AccessibilityPermission
    private let general: GeneralSettingsModel
    private var keyMonitor: Any?

    init(settings: SettingsStore, hotkeys: Hotkeys, permission: AccessibilityPermission, storedShortcutProblem: String?) {
        self.settings = settings
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
