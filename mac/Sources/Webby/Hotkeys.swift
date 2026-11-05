import AppKit
import Carbon.HIToolbox
import WebbyCore

/// Global shortcuts through Carbon's `RegisterEventHotKey`, which needs no
/// Accessibility permission. Events arrive on the main run loop.
@MainActor
final class Hotkeys {
    enum Status: Equatable {
        case registered(KeyCombo)
        case failed(KeyCombo, OSStatus)
        case paused
    }

    private(set) var newNoteStatus: Status = .paused
    /// Called after `newNoteStatus` changes.
    var onStatusChange: (@MainActor () -> Void)?

    private let newNote: @MainActor () -> Void
    private var handler: EventHandlerRef?
    private var newNoteRef: EventHotKeyRef?
    private var newNoteCombo: KeyCombo?

    private static let signature: OSType = 0x5742_4259  // "WBBY"
    private static let newNoteID: UInt32 = 1

    init(newNote: @escaping @MainActor () -> Void) {
        self.newNote = newNote
    }

    /// Registers `combo` for New Note, replacing any earlier shortcut.
    func registerNewNote(_ combo: KeyCombo) {
        installHandlerIfNeeded()
        unregisterNewNote()
        newNoteCombo = combo

        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(combo.keyCode),
            Self.carbonModifiers(combo.modifiers),
            EventHotKeyID(signature: Self.signature, id: Self.newNoteID),
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status == noErr, let ref {
            newNoteRef = ref
            setStatus(.registered(combo))
        } else {
            setStatus(.failed(combo, status))
        }
    }

    /// Releases the shortcut while Settings records a new one, so pressing the old
    /// combination records it instead of creating a note.
    func pause() {
        unregisterNewNote()
        setStatus(.paused)
    }

    func resume() {
        if let newNoteCombo { registerNewNote(newNoteCombo) }
    }

    private func unregisterNewNote() {
        if let newNoteRef { UnregisterEventHotKey(newNoteRef) }
        newNoteRef = nil
    }

    private func setStatus(_ status: Status) {
        guard status != newNoteStatus else { return }
        newNoteStatus = status
        onStatusChange?()
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, refcon in
                guard let event, let refcon else { return OSStatus(eventNotHandledErr) }
                var id = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &id
                )
                guard status == noErr, id.signature == Hotkeys.signature else { return OSStatus(eventNotHandledErr) }
                let hotkeys = Unmanaged<Hotkeys>.fromOpaque(refcon).takeUnretainedValue()
                MainActor.assumeIsolated { hotkeys.pressed(id.id) }
                return noErr
            },
            1,
            &pressed,
            Unmanaged.passUnretained(self).toOpaque(),
            &handler
        )
    }

    private func pressed(_ id: UInt32) {
        if id == Self.newNoteID { newNote() }
    }

    private static func carbonModifiers(_ modifiers: KeyCombo.Modifiers) -> UInt32 {
        var flags = 0
        if modifiers.contains(.control) { flags |= controlKey }
        if modifiers.contains(.option) { flags |= optionKey }
        if modifiers.contains(.shift) { flags |= shiftKey }
        if modifiers.contains(.command) { flags |= cmdKey }
        return UInt32(flags)
    }
}

extension Hotkeys.Status {
    /// What Settings shows under the shortcut.
    var message: String {
        switch self {
        case .registered(let combo):
            return "\(combo.displayString) creates a note in the app you're using."
        case .failed(let combo, let status) where status == OSStatus(eventHotKeyExistsErr):
            return "\(combo.displayString) is already used by another shortcut. Choose a different one."
        case .failed(let combo, let status):
            return "\(combo.displayString) couldn't be registered (error \(status)). Choose a different shortcut."
        case .paused:
            return "Press the new shortcut."
        }
    }

    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}
