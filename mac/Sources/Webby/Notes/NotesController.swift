import AppKit
import OSLog
import WebbyCore

/// Owns the notes: the store, the overlays for the current app, autosave with retry,
/// trash with Undo, and the quit flush.
///
/// Typing changes only the open note's draft. Drafts reach the store when the 500 ms
/// autosave fires, when a note loses focus, on Done, before any other action on the
/// note, and before quitting; each commit is one content revision.
@MainActor
final class NotesController {
    let store: NoteStore
    /// Called when the save or read-only status changes.
    var onStatusChange: (@MainActor () -> Void)?

    private let monitor: ContextMonitor
    private let permission: AccessibilityPermission
    private var themes: NoteThemes
    private let assets: SkinAssetCache
    private let latestSave: LatestSave
    private let logger = Logger(subsystem: Webby.bundleID, category: "notes")
    private lazy var autosave = AutosaveDebouncer { [weak self] in self?.saveNow() }
    private(set) lazy var quit = makeQuitCoordinator()

    private var windows: [UUID: NoteWindowController] = [:]
    private var toasts: [UUID: UndoToast] = [:]
    private let banner = StatusBanner()
    private var onboardingShown = false
    private var screenObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?

    private var savedGeneration: UInt64 = 0
    private var failedGeneration: UInt64?
    private var failureCount = 0
    private var retryTask: Task<Void, Never>?
    /// The latest save error, while saving keeps failing.
    private(set) var saveFailure: String?

    init(store: NoteStore, monitor: ContextMonitor, permission: AccessibilityPermission, themes: NoteThemes, assets: SkinAssetCache) {
        self.store = store
        self.monitor = monitor
        self.permission = permission
        self.themes = themes
        self.assets = assets
        latestSave = LatestSave(store.saveRequest())
    }

    /// Applies a new look, for example after an accessibility display setting changed.
    func updateThemes(_ themes: NoteThemes) {
        guard themes != self.themes else { return }
        self.themes = themes
        for controller in windows.values {
            controller.model.themes = themes
            controller.themesChanged()
        }
        layout()
    }

    func start() {
        monitor.onChange = { [weak self] in self?.layout() }
        permission.onChange { [weak self] in
            self?.monitor.permissionChanged()
            self?.onStatusChange?()
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout() }
        }
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout() }
        }
        _ = quit
        monitor.start()
        layout()
        if let problem = readOnlyProblem {
            showReadOnlyBanner(problem)
        }
    }

    // MARK: State for the menu bar and Settings

    var isWritable: Bool { store.mode == .writable }

    var readOnlyProblem: String? {
        guard case .readOnly(let problem) = store.mode else { return nil }
        return NoteStore.StoreError.readOnly(problem).localizedDescription
    }

    var appName: String? { monitor.app?.name }

    var canCreateNote: Bool { isWritable && monitor.app != nil }

    /// The current app's notes, with open drafts committed so titles are current.
    func currentContextNotes() -> ContextNotes {
        commitDrafts()
        return OverlayPlanner.contextNotes(store.notes, context: monitor.context)
    }

    // MARK: Note actions

    func newNote() {
        guard isWritable else {
            NSSound.beep()
            if let problem = readOnlyProblem { showReadOnlyBanner(problem) }
            return
        }
        guard let app = monitor.app else {
            NSSound.beep()
            return
        }
        commitDrafts()

        let window = monitor.windowFrame
        let screens = Self.visibleScreens(preferring: window.map { CGPoint(x: $0.midX, y: $0.midY) } ?? Self.mouseLocation)
        let occupied = windows.values.map { Geometry.topLeftRect(fromAppKit: $0.visualFrame, primaryScreenHeight: Self.primaryScreenHeight) }
        let absolute = OverlayPlanner.newNoteFrame(window: window, screens: screens, occupied: occupied)
        let placement = OverlayPlanner.placement(window: window)
        let note = Note(
            anchor: .app(bundleID: app.bundleID),
            frame: Geometry.storedFrame(absolute: absolute, placement: placement, window: window),
            placement: placement
        )
        guard store.add(note) else { return }
        didMutate()
        layout()

        guard let controller = windows[note.id] else { return }
        controller.focus()
        if !permission.isTrusted, !onboardingShown {
            onboardingShown = true
            permission.showOnboarding(near: controller.visualFrame)
        }
    }

    /// Shows a note from the menu bar: unhides and expands it, then focuses it.
    func show(_ id: UUID) {
        commitDrafts()
        var changed = store.updateLayout(id: id, change: .hidden(false))
        changed = store.updateLayout(id: id, change: .collapsed(false)) || changed
        if changed { didMutate() }
        layout()
        windows[id]?.focus()
    }

    func showAllHidden() {
        var changed = false
        for note in currentContextNotes().hidden {
            changed = store.updateLayout(id: note.id, change: .hidden(false)) || changed
        }
        if changed { didMutate() }
        layout()
    }

    private func toggleCollapsed(_ id: UUID) {
        commitDrafts()
        guard let note = store.note(id: id),
              store.updateLayout(id: id, change: .collapsed(!note.collapsed)) else { return }
        didMutate()
        layout()
    }

    private func hideHere(_ id: UUID) {
        commitDrafts()
        guard store.updateLayout(id: id, change: .hidden(true)) else { return }
        didMutate()
        layout()
    }

    private func trash(_ id: UUID) {
        commitDrafts()
        let frame = windows[id]?.visualFrame
        guard store.trash(id: id) else { return }
        didMutate()
        layout()
        toasts[id]?.close()
        toasts[id] = UndoToast(
            at: frame.map { NSPoint(x: $0.minX, y: $0.maxY) },
            undo: { [weak self] in self?.undoTrash(id) },
            closed: { [weak self] in self?.toasts[id] = nil }
        )
    }

    private func undoTrash(_ id: UUID) {
        toasts.removeValue(forKey: id)?.close()
        guard store.restore(id: id) else { return }
        didMutate()
        layout()
    }

    /// ⌘Return or Esc: save now and give the keyboard back to the app.
    private func done(_ id: UUID) {
        autosave.cancel()
        saveNow()
        windows[id]?.panel.makeFirstResponder(nil)
        if let pid = monitor.app?.pid {
            NSRunningApplication(processIdentifier: pid)?.activate()
        }
    }

    private func userLaidOut(_ id: UUID) {
        guard let controller = windows[id], let note = store.note(id: id) else { return }
        let panel = Geometry.topLeftRect(fromAppKit: controller.visualFrame, primaryScreenHeight: Self.primaryScreenHeight)
        let frame = OverlayPlanner.storedFrame(forPanel: panel, note: note, window: monitor.windowFrame)
        guard store.updateLayout(id: id, change: .frame(frame)) else { return }
        didMutate()
    }

    // MARK: Overlays

    /// Shows the current app's notes where the planner puts them and closes the rest.
    func layout() {
        let window = monitor.windowFrame
        let screens = Self.visibleScreens(preferring: window.map { CGPoint(x: $0.midX, y: $0.midY) })
        let plans = OverlayPlanner.plan(
            notes: store.notes,
            context: monitor.context,
            window: window,
            screens: screens,
            collapsedHeight: themes.collapsedHeight
        )

        let planned = Set(plans.map(\.noteID))
        let leaving = windows.keys.filter { !planned.contains($0) }
        if !leaving.isEmpty {
            if commitDrafts() { autosave.schedule() }
            for id in leaving {
                windows.removeValue(forKey: id)?.close()
            }
        }

        for plan in plans {
            guard let note = store.note(id: plan.noteID) else { continue }
            let controller = windows[plan.noteID] ?? makeWindow(for: note)
            controller.model.collapsed = plan.collapsed
            controller.model.isEditable = isWritable
            controller.apply(frame: Geometry.appKitRect(fromTopLeft: plan.frame, primaryScreenHeight: Self.primaryScreenHeight))
            controller.show()
        }
    }

    private func makeWindow(for note: Note) -> NoteWindowController {
        let id = note.id
        let model = NoteModel(id: id, text: note.text, collapsed: note.collapsed, isEditable: isWritable, themes: themes)
        model.onTextChange = { [weak self] in self?.autosave.schedule() }
        model.onToggleCollapsed = { [weak self] in self?.toggleCollapsed(id) }
        model.onHide = { [weak self] in self?.hideHere(id) }
        model.onTrash = { [weak self] in self?.trash(id) }
        model.onDone = { [weak self] in self?.done(id) }
        model.onResizeEnded = { [weak self] in self?.userLaidOut(id) }

        let controller = NoteWindowController(model: model, assets: assets)
        controller.onUserLayout = { [weak self] in self?.userLaidOut(id) }
        // Autosave on blur.
        controller.onResignKey = { [weak self] in self?.autosave.fireNow() }
        windows[id] = controller
        return controller
    }

    // MARK: Saving

    /// Commits drafts that differ from the store. Returns true if any did.
    @discardableResult
    private func commitDrafts() -> Bool {
        var changed = false
        for (id, controller) in windows where store.note(id: id)?.text != controller.model.text {
            changed = store.updateContent(id: id, change: .text(controller.model.text)) || changed
        }
        if changed { quit.noteMutation(generation: store.mutationGeneration) }
        return changed
    }

    private func didMutate() {
        quit.noteMutation(generation: store.mutationGeneration)
        autosave.schedule()
    }

    private func currentSaveRequest() -> NoteStore.SaveRequest {
        let request = store.saveRequest()
        latestSave.request = request
        return request
    }

    /// Commits drafts and writes the newest state in the background.
    private func saveNow() {
        commitDrafts()
        guard isWritable, store.hasUnsavedChanges else { return }
        let request = currentSaveRequest()
        Task { [weak self] in
            do {
                let generation = try await request.flush()
                self?.saveSucceeded(generation)
            } catch {
                self?.saveFailed(error, generation: request.generation)
            }
        }
    }

    func retrySave() {
        retryTask?.cancel()
        retryTask = nil
        saveNow()
    }

    private func saveSucceeded(_ generation: UInt64) {
        savedGeneration = max(savedGeneration, generation)
        quit.noteCommitted(generation: generation)
        guard let failed = failedGeneration, generation >= failed else { return }
        failedGeneration = nil
        failureCount = 0
        retryTask?.cancel()
        retryTask = nil
        saveFailure = nil
        banner.hide()
        onStatusChange?()
    }

    private func saveFailed(_ error: any Error, generation: UInt64) {
        // A newer state already reached the disk, so this failure is moot.
        guard generation > savedGeneration else { return }
        failureCount += 1
        failedGeneration = max(failedGeneration ?? 0, generation)
        let message = error.localizedDescription
        logger.error("Saving notes failed (attempt \(self.failureCount)): \(message, privacy: .public)")
        if saveFailure == nil {
            banner.show(
                title: "Webby couldn't save your notes",
                message: "\(message) Your notes are kept in memory and Webby keeps trying.",
                actions: [StatusBanner.Action(title: "Retry") { [weak self] in self?.retrySave() }]
            )
        }
        saveFailure = message
        onStatusChange?()

        retryTask?.cancel()
        let delay = SaveRetryBackoff.delay(afterFailures: failureCount)
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    private func showReadOnlyBanner(_ problem: String) {
        let fileURL = store.fileURL
        banner.show(
            title: "Notes are read-only",
            message: "\(problem) New notes and editing are off until this is fixed.",
            actions: [StatusBanner.Action(title: "Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            }]
        )
    }

    // MARK: Quit

    /// Answers `applicationShouldTerminate(_:)`: waits for the newest state to reach the
    /// disk, with the coordinator's 3 s synchronous fallback.
    ///
    /// Nothing after this point may wait for the main actor. While termination is
    /// pending AppKit runs a nested run loop, and when `terminate(_:)` was called from a
    /// main-queue block or main-actor job, the main queue can't drain until it returns.
    /// So drafts are committed here, the flush runs detached on the request captured
    /// now, and the reply is scheduled on the run loop, which the nested loop services.
    func terminationReply() -> NSApplication.TerminateReply {
        autosave.cancel()
        retryTask?.cancel()
        commitDrafts()
        _ = currentSaveRequest()
        guard quit.plan().shouldWait else { return .terminateNow }

        let quit = quit
        Task.detached { [weak self] in
            let flushed = await quit.handleTermination()
            RunLoop.main.perform(inModes: [.common, .modalPanel]) {
                MainActor.assumeIsolated {
                    var mayQuit = flushed
                    if !mayQuit, let self {
                        mayQuit = self.confirmQuitWithoutSaving()
                        if !mayQuit { self.retrySave() }
                    }
                    NSApp.reply(toApplicationShouldTerminate: mayQuit)
                }
            }
        }
        return .terminateLater
    }

    private func confirmQuitWithoutSaving() -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Webby couldn't save your latest changes"
        alert.informativeText = "If you quit now, changes since the last save are lost."
            + (saveFailure.map { "\n\n\($0)" } ?? "")
        alert.addButton(withTitle: "Keep Webby Open")
        let quitButton = alert.addButton(withTitle: "Quit Anyway")
        quitButton.hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn
    }

    private func makeQuitCoordinator() -> QuitFlushCoordinator {
        let latestSave = latestSave
        let readOnly = !isWritable
        let logger = logger
        // Every closure reads the request captured at termination; see `terminationReply()`.
        return QuitFlushCoordinator(
            flush: { try await latestSave.request.flush() },
            fallback: { try latestSave.request.commitNow() },
            isReadOnly: { readOnly },
            hasUnsavedChanges: { latestSave.request.isUnsaved },
            suddenTermination: { disable in
                if disable {
                    ProcessInfo.processInfo.disableSuddenTermination()
                } else {
                    ProcessInfo.processInfo.enableSuddenTermination()
                }
            },
            onOutcome: { outcome in
                logger.info("Quit flush: \(String(describing: outcome), privacy: .public)")
            }
        )
    }

    // MARK: Screens

    private static var primaryScreenHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }

    private static var mouseLocation: CGPoint {
        let point = NSEvent.mouseLocation
        return CGPoint(x: point.x, y: primaryScreenHeight - point.y)
    }

    /// Visible screen frames in top-left coordinates, with the screen containing
    /// `point` first.
    private static func visibleScreens(preferring point: CGPoint?) -> [CGRect] {
        let frames = NSScreen.screens.map {
            Geometry.topLeftRect(fromAppKit: $0.visibleFrame, primaryScreenHeight: primaryScreenHeight)
        }
        guard let point, let index = frames.firstIndex(where: { $0.contains(point) }) else { return frames }
        var ordered = frames
        ordered.insert(ordered.remove(at: index), at: 0)
        return ordered
    }
}

/// The newest save request, which the quit coordinator reads off the main thread.
private final class LatestSave: @unchecked Sendable {
    private let lock = NSLock()
    private var value: NoteStore.SaveRequest

    init(_ request: NoteStore.SaveRequest) {
        value = request
    }

    var request: NoteStore.SaveRequest {
        get {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
        set {
            lock.lock()
            value = newValue
            lock.unlock()
        }
    }
}
