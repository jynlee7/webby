import Foundation
import Testing
@testable import Webby
import WebbyCore

@MainActor
@Suite struct NoteLinkRouterTests {
    @Test func acceptsOnlyStrictWebbyNoteLinks() {
        let router = NoteLinkRouter()
        var routed: [UUID] = []
        router.onRoute = { id in
            routed.append(id)
            return true
        }
        router.markReady()

        let id = UUID()
        #expect(router.receive(NoteLink.url(for: id)))
        #expect(routed == [id])

        #expect(router.receive("https://example.com/note/\(id.uuidString)") == false)
        #expect(router.receive("webby://note/not-a-uuid") == false)
        #expect(router.receive("webby://note/\(id.uuidString)?extra=1") == false)
        #expect(router.receive("webby://other/\(id.uuidString)") == false)
        #expect(routed == [id])
        #expect(router.pendingNoteIDs.isEmpty)
    }

    @Test func queuesColdStartLinksUntilReadyAndFlushesInOrder() {
        let router = NoteLinkRouter()
        var routed: [UUID] = []
        router.onRoute = { id in
            routed.append(id)
            return true
        }

        let first = UUID()
        let second = UUID()
        #expect(router.receive(NoteLink.url(for: first)))
        #expect(router.receive(NoteLink.url(for: second)))
        #expect(routed.isEmpty)
        #expect(router.pendingNoteIDs == [first, second])
        #expect(router.isReady == false)

        router.markReady()
        #expect(routed == [first, second])
        #expect(router.pendingNoteIDs.isEmpty)

        let third = UUID()
        #expect(router.receive(NoteLink.url(for: third)))
        #expect(routed == [first, second, third])
        #expect(router.pendingNoteIDs.isEmpty)
    }

    @Test func boundsPendingQueueAndKeepsTheNewestLinks() {
        let router = NoteLinkRouter()
        router.onRoute = { _ in true }

        var ids: [UUID] = []
        for _ in 0..<(NoteLinkRouter.maximumPendingLinks + 5) {
            let id = UUID()
            ids.append(id)
            #expect(router.receive(NoteLink.url(for: id)))
        }

        #expect(router.pendingNoteIDs.count == NoteLinkRouter.maximumPendingLinks)
        #expect(router.pendingNoteIDs == Array(ids.suffix(NoteLinkRouter.maximumPendingLinks)))
    }

    @Test func reportsUnroutableLinksWithoutQueueingOrMutating() {
        let router = NoteLinkRouter()
        var unroutable: [UUID] = []
        router.onRoute = { _ in false }
        router.onUnroutable = { unroutable.append($0) }
        router.markReady()

        let missing = UUID()
        #expect(router.receive(NoteLink.url(for: missing)))
        #expect(unroutable == [missing])
        #expect(router.pendingNoteIDs.isEmpty)

        let queued = UUID()
        let coldRouter = NoteLinkRouter()
        coldRouter.onRoute = { _ in false }
        coldRouter.onUnroutable = { unroutable.append($0) }
        #expect(coldRouter.receive(NoteLink.url(for: queued)))
        #expect(unroutable == [missing])
        coldRouter.markReady()
        #expect(unroutable == [missing, queued])
        #expect(coldRouter.pendingNoteIDs.isEmpty)
    }
}
