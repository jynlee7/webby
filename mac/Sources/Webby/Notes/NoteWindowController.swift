import AppKit
import SwiftUI
import WebbyCore

/// Owns one note's panel and its SwiftUI view. It reports user moves, resizes and blur;
/// `NotesController` decides what they mean.
@MainActor
final class NoteWindowController: NSObject, NSWindowDelegate {
    let model: NoteModel
    let panel: NotePanel
    /// The user moved the panel, or finished resizing it. Read `panel.frame`.
    var onUserLayout: (@MainActor () -> Void)?
    /// The note lost keyboard focus.
    var onResignKey: (@MainActor () -> Void)?

    private var applyingFrame = false

    init(model: NoteModel) {
        self.model = model
        panel = NotePanel(contentRect: NSRect(origin: .zero, size: OverlayPlanner.defaultNoteSize))
        super.init()

        let hosting = FirstMouseHostingView(rootView: NoteRootView(model: model))
        // The planner owns the panel's size; SwiftUI must not resize the window.
        hosting.sizingOptions = []
        panel.contentView = hosting
        panel.title = "Note"
        panel.delegate = self
        applyShadow()
    }

    /// Follows a theme change: the shadow is the only part drawn outside SwiftUI.
    func themesChanged() {
        applyShadow()
        panel.invalidateShadow()
    }

    private func applyShadow() {
        panel.hasShadow = model.themes.light.surface.shadow != .known(.none)
    }

    /// Moves the panel to `frame`, in AppKit coordinates, without reporting a user move.
    func apply(frame: NSRect) {
        guard frame != panel.frame else { return }
        applyingFrame = true
        panel.setFrame(frame, display: true)
        applyingFrame = false
        panel.invalidateShadow()
    }

    func show() {
        // The app is usually inactive, so order front regardless of activation. A panel
        // left on another Space is ordered front again so it moves to the active one.
        if !panel.isVisible || !panel.isOnActiveSpace { panel.orderFrontRegardless() }
    }

    func focus() {
        panel.makeKeyAndOrderFront(nil)
        model.focusRequest += 1
    }

    func close() {
        panel.delegate = nil
        panel.orderOut(nil)
    }

    func windowDidMove(_ notification: Notification) {
        guard !applyingFrame else { return }
        onUserLayout?()
    }

    func windowDidResignKey(_ notification: Notification) {
        onResignKey?()
    }
}

/// Lets the first click on an unfocused note reach its buttons and text.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
