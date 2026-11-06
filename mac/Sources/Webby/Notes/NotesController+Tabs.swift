import AppKit
import WebbyCore

/// In-memory state for "Just this tab" notes. Bindings themselves live in the store;
/// nothing here is persisted, and a Webby relaunch rebuilds it harmlessly.
@MainActor
final class TabTracking {
    /// The running Chrome's session string, or nil when Chrome isn't running.
    var chromeSession: @MainActor () -> String? = { nil }
    /// The reconciled open tabs, the only source of restore candidates.
    var openTabs: @MainActor () -> LibraryInventory = { LibraryInventory() }
    /// The bridge's last report for a live, non-incognito tab.
    var liveTab: @MainActor (TabRef) -> BridgeTab? = { _ in nil }

    var reconciler = TabBindingReconciler()
    var schedule = RestoreSchedule()
    var timer: Timer?
    /// Whether the session has been read once; the first read runs the stale pass.
    var checkedSession = false
    var session: String?
    /// The latest restore result per note, for the Library's status line.
    var outcomes: [UUID: RestoreOutcome] = [:]
    /// The last verified Chrome tab seen while Chrome was in front. The Library is in
    /// front when it reattaches a note, so it can't read the live context.
    var lastVerifiedTab: TabRef?
    var terminationObserver: NSObjectProtocol?
    /// Tab work that arrived while an import owned the store, replayed in order after it.
    var deferred: [DeferredTabWork] = []
    static let maxDeferred = 4096
}

enum DeferredTabWork {
    case event(BridgeEvent)
    case terminated(String?)
}

extension NotesController {
    /// Runs the stale-session pass and starts following Chrome's termination.
    func startTabTracking() {
        checkChromeSession()
        tabs.terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == OpenTabsInventory.bundleID else { return }
            let session = app.flatMap { app in
                app.launchDate.map { ChromeSessionIdentity.session(processIdentifier: app.processIdentifier, launchDate: $0) }
            }
            MainActor.assumeIsolated { self?.chromeTerminated(session: session) }
        }
    }

    /// Applies one bridge event to tab bindings, after Open Tabs and the browser
    /// monitor have seen it, so the inventory is current.
    func receiveBridgeEvent(_ event: BridgeEvent) {
        guard !isImporting else {
            // The import owns the store: keep the event, so a replaced tab's new ID or a
            // close isn't lost, and apply it once the import ends.
            deferTabWork(.event(event))
            return
        }
        checkChromeSession()
        let session = tabs.session
        applyTabUpdates(tabs.reconciler.receive(event, notes: store.notes, session: session, now: now()))
        switch event {
        case let .message(connection, profile, .hello):
            tabs.schedule.hello(profile: profile, connection: connection, now: now())
        case let .message(_, profile, .inventory):
            tabs.schedule.activity(profile: profile, now: now(), inventory: true)
        case let .message(_, profile, _):
            // Restored tabs often get their address in a later tabUpdated.
            tabs.schedule.activity(profile: profile, now: now())
        case let .disconnected(connection, profile):
            tabs.schedule.disconnected(connection: connection, profile: profile)
        case let .dropped(connection?, _):
            tabs.schedule.disconnected(connection: connection, profile: nil)
        case .connected, .dropped(nil, _):
            break
        }
        scheduleRestoreCheck()
    }

    /// Applies the tab work held back during an import, in arrival order. Called on
    /// every import exit, successful or not.
    func replayDeferredTabWork() {
        guard !isImporting, !tabs.deferred.isEmpty else { return }
        let work = tabs.deferred
        tabs.deferred.removeAll()
        for item in work {
            switch item {
            case .event(let event): receiveBridgeEvent(event)
            case .terminated(let session): chromeTerminated(session: session)
            }
        }
    }

    private func deferTabWork(_ work: DeferredTabWork) {
        tabs.deferred.append(work)
        // Bounded; the oldest goes first. A note it concerned ends up in Closed Tabs.
        if tabs.deferred.count > TabTracking.maxDeferred { tabs.deferred.removeFirst() }
    }

    /// Chrome quit while Webby runs. `session` is nil when the process can't be named;
    /// the last seen session is used then.
    func chromeTerminated(session: String?) {
        guard !isImporting else {
            deferTabWork(.terminated(session))
            return
        }
        guard let ended = session ?? tabs.session else { return }
        applyTabUpdates(tabs.reconciler.chromeTerminated(session: ended, notes: store.notes, now: now()))
        tabs.session = nil
        tabs.checkedSession = true
        tabs.schedule.setSession(nil)
        scheduleRestoreCheck()
    }

    /// Runs every restore check that is due at `date`.
    func runDueRestoreChecks(at date: Date? = nil) {
        guard isWritable else { return }
        guard !isImporting else {
            // The import owns the store; try again shortly instead of losing the check.
            scheduleRestoreCheck(after: 1)
            return
        }
        let at = date ?? now()
        guard let session = tabs.session else { return }
        for profile in tabs.schedule.takeDue(now: at) {
            let result = TabRestore.evaluate(notes: store.notes, profile: profile, session: session, inventory: tabs.openTabs())
            tabs.outcomes.merge(result.outcomes) { $1 }
            applyTabUpdates(result.updates)
        }
        scheduleRestoreCheck()
    }

    /// The restore result shown in Closed tabs, while Webby keeps running.
    func restoreOutcome(_ id: UUID) -> RestoreOutcome? { tabs.outcomes[id] }

    /// A binding for the tab in front, or nil without a verified live tab.
    func currentTabBinding() -> TabBinding? {
        guard let ref = monitor.context?.tab, let live = tabs.liveTab(ref) else { return nil }
        return TabBindingReconciler.binding(for: ref, tab: live)
    }

    /// The last verified tab, if it is still open in the same Chrome run and profile as
    /// the note's binding. Used by the Library's Reattach.
    func reattachTarget(for id: UUID) -> (ref: TabRef, tab: BridgeTab)? {
        guard let binding = store.note(id: id)?.tab, let target = lastVerifiedLiveTab(),
              target.ref.profile == binding.profile else { return nil }
        return target
    }

    /// The last verified tab, if it is still open in the running Chrome.
    func lastVerifiedLiveTab() -> (ref: TabRef, tab: BridgeTab)? {
        guard let ref = tabs.lastVerifiedTab, ref.session == tabs.session,
              let live = tabs.liveTab(ref) else { return nil }
        return (ref, live)
    }

    /// Binds a closed or restored note to the last verified tab. Bookkeeping (§6.2).
    func reattachToLastTab(_ id: UUID) {
        guard !isImporting, isWritable, let binding = store.note(id: id)?.tab,
              let target = reattachTarget(for: id),
              let updated = TabBindingReconciler.reattaching(binding, to: target.ref, tab: target.tab) else { return }
        tabs.outcomes[id] = nil
        applyTabUpdates([TabBindingUpdate(noteID: id, binding: updated)])
    }

    /// "Keep on this tab" from the Restored badge.
    func keepRestoredTab(_ id: UUID) {
        guard !isImporting, isWritable else { return }
        if acknowledgeRestore(id) { didMutate() }
    }

    /// "Move to Closed tabs" from the Restored badge.
    func moveToClosedTabs(_ id: UUID) {
        guard !isImporting, isWritable, var binding = store.note(id: id)?.tab, binding.closedAt == nil else { return }
        binding.closedAt = now()
        binding.pendingRestore = false
        applyTabUpdates([TabBindingUpdate(noteID: id, binding: binding)])
    }

    /// Clears the Restored badge after the user accepted the restore. Returns whether
    /// the binding changed; the caller reports the mutation.
    @discardableResult
    func acknowledgeRestore(_ id: UUID) -> Bool {
        guard let binding = TabBindingReconciler.acknowledgingRestore(store.note(id: id)?.tab),
              store.updateBinding(id: id, { $0 = binding }) else { return false }
        windows[id]?.model.restored = false
        return true
    }

    /// Applies binding updates as bookkeeping: `revision` and `updatedAt` stay as they
    /// are. A read-only store or an import takes none of them.
    @discardableResult
    func applyTabUpdates(_ updates: [TabBindingUpdate]) -> Bool {
        guard isWritable, !isImporting, !updates.isEmpty else { return false }
        var changed = false
        for update in updates {
            changed = store.updateBinding(id: update.noteID) { $0 = update.binding } || changed
        }
        guard changed else { return false }
        didMutate()
        layout()
        return true
    }

    /// Reads the running Chrome. A change (or the first read) closes bindings of other
    /// runs so they wait for one restore check.
    private func checkChromeSession() {
        let current = tabs.chromeSession()
        guard !tabs.checkedSession || current != tabs.session else { return }
        tabs.checkedSession = true
        tabs.session = current
        tabs.schedule.setSession(current)
        applyTabUpdates(TabBindingReconciler.closeStaleSessions(notes: store.notes, current: current, now: now()))
    }

    private func scheduleRestoreCheck(after delay: TimeInterval? = nil) {
        tabs.timer?.invalidate()
        tabs.timer = nil
        let fire: Date
        if let delay {
            fire = Date().addingTimeInterval(delay)
        } else if let deadline = tabs.schedule.nextDeadline {
            // The schedule runs on `now()`; the timer on the wall clock.
            fire = Date().addingTimeInterval(max(deadline.timeIntervalSince(now()), 0))
        } else {
            return
        }
        let timer = Timer(fire: fire, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.runDueRestoreChecks() }
        }
        RunLoop.main.add(timer, forMode: .common)
        tabs.timer = timer
    }
}
