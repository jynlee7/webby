import AppKit
import SwiftUI
import WebbyCore

/// The one Library window. The model, actions and draft are created once, so repeated
/// presentations show the same store and selection instead of rebuilding state.
///
/// Closing the window only orders it out. The app remains a menu-bar accessory; the
/// controller owns deep-link routing through `showNote`.
@MainActor
final class LibraryWindowController: NSWindowController, NSWindowDelegate {
    typealias Presentation = @MainActor (LibraryWindowController) -> Void
    typealias DetailFocus = @MainActor (UUID) -> Void

    let model: LibraryModel
    let draft = LibraryTextDraft()
    private(set) lazy var exportController = ExportController(
        model: model,
        commitDrafts: { [weak self] in self?.commitPendingEdits() }
    )
    private(set) lazy var importController = ImportController(
        model: model,
        notes: model.notesController,
        commitDrafts: { [weak self] in self?.commitPendingEdits() }
    )

    private let actions: LibraryAnchorActions
    private let presentation: Presentation
    private let focusDetail: DetailFocus
    private var hostingController: NSHostingController<LibraryView>?

    init(
        model: LibraryModel,
        actions: LibraryAnchorActions,
        presentation: @escaping Presentation = { $0.showLibraryWindow() },
        focusDetail: @escaping DetailFocus = { _ in }
    ) {
        self.model = model
        self.actions = actions
        self.presentation = presentation
        self.focusDetail = focusDetail
        super.init(window: nil)
    }

    convenience init(
        notes: NotesController,
        currentAppBundleID: @escaping @MainActor () -> String?,
        userQueryRules: [QueryRule] = []
    ) {
        let currentApp = LiveLibraryCurrentAppProvider(currentBundleID: currentAppBundleID)
        let actions = LibraryAnchorActions(
            appAvailability: WorkspaceLibraryAppAvailability(),
            appActivation: WorkspaceLibraryAppActivation(),
            pageOpening: UnavailableLibraryPageOpening(),
            overlayPresentation: NotesControllerLibraryOverlayPresenter(controller: notes),
            currentApp: currentApp
        )
        let model = LibraryModel(
            controller: notes,
            workspaceDisplayName: { key in
                LibraryWorkspaceNames.displayName(for: key) { bundleID in
                    guard let url = NSWorkspace.shared
                        .urlForApplication(withBundleIdentifier: bundleID)
                    else { return nil }
                    return FileManager.default.displayName(atPath: url.path)
                }
            },
            userQueryRules: userQueryRules
        )
        self.init(model: model, actions: actions)
        // An import owns the store; commit this window's editor draft before its barrier.
        notes.commitLibraryDrafts = { [weak self] in self?.commitPendingEdits() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func present() {
        presentation(self)
    }

    /// Commits the retained editor draft before quit captures the save request.
    func commitPendingEdits() {
        draft.commit(to: model)
    }

    /// Implements the #15 navigation contract: select the note's destination and show
    /// it. Missing and ephemeral IDs leave the selection alone and return false.
    @discardableResult
    func present(noteID: UUID) -> Bool {
        showNote(noteID)
    }

    @discardableResult
    func showNote(_ id: UUID) -> Bool {
        // Route against the committed text, not a draft that a later save would drop.
        commitPendingEdits()
        guard model.revealNote(id) else { return false }

        // A link always lands in List mode with its detail ready to read or edit.
        model.contentMode = .list
        model.requestDetailFocus(id)
        focusDetail(id)
        present()
        return true
    }

    @discardableResult
    func selectNote(_ id: UUID) -> Bool {
        model.selectNote(id)
    }

    private func showLibraryWindow() {
        NSApp.activate()
        ensureWindow()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private func ensureWindow() {
        guard window == nil else { return }

        let hosting = NSHostingController(
            rootView: LibraryView(
                model: model,
                actions: actions,
                draft: draft,
                exportController: exportController,
                importController: importController
            )
        )
        hosting.sizingOptions = []

        let window = NSWindow(contentViewController: hosting)
        window.title = "Library"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.setContentSize(NSSize(width: 1_060, height: 680))
        window.minSize = NSSize(width: 860, height: 520)
        window.delegate = self
        window.center()

        self.window = window
        hostingController = hosting
    }

    func windowWillClose(_ notification: Notification) {
        // Closing the Library must not quit Webby or disturb open note panels.
    }
}
