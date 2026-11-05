import Foundation
import WebbyCore

/// Queues strict `webby://note/<uuid>` links until the Library is ready, then routes
/// each one through the injected handler. Invalid links are ignored without mutation.
///
/// The queue is bounded so a burst of links received before launch cannot grow
/// without limit. The oldest link is dropped when the bound is exceeded.
@MainActor
final class NoteLinkRouter {
    static let maximumPendingLinks = 8

    /// Returns whether the Library accepted the note. A false result is reported to
    /// `onUnroutable` (once per flushed batch) but never creates, restores or mutates a note.
    var onRoute: (@MainActor (UUID) -> Bool)?
    var onUnroutable: (@MainActor (UUID) -> Void)?

    private(set) var pendingNoteIDs: [UUID] = []
    private(set) var isReady = false

    /// Parses and routes a link, or queues it while the Library is not ready.
    /// Returns whether the link was a valid Webby note link.
    @discardableResult
    func receive(_ url: URL) -> Bool {
        receive(url.absoluteString)
    }

    @discardableResult
    func receive(_ string: String) -> Bool {
        guard let id = NoteLink.parse(string) else { return false }

        if isReady {
            route(id)
        } else {
            enqueue(id)
        }
        return true
    }

    /// Marks the Library ready and flushes queued links once, in arrival order.
    func markReady() {
        guard !isReady else { return }
        isReady = true

        let queued = pendingNoteIDs
        pendingNoteIDs.removeAll(keepingCapacity: true)
        // One notification per flush: a burst of missing notes needs one alert.
        var reported = false
        for id in queued where !deliver(id) && !reported {
            reported = true
            onUnroutable?(id)
        }
    }

    private func enqueue(_ id: UUID) {
        pendingNoteIDs.append(id)
        if pendingNoteIDs.count > Self.maximumPendingLinks {
            pendingNoteIDs.removeFirst(pendingNoteIDs.count - Self.maximumPendingLinks)
        }
    }

    private func route(_ id: UUID) {
        if !deliver(id) {
            onUnroutable?(id)
        }
    }

    private func deliver(_ id: UUID) -> Bool {
        onRoute?(id) ?? false
    }
}
