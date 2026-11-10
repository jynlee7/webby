import Foundation

/// Main-actor subscribers to bridge events, called in the order they were added. The
/// bridge delivers each event once through `deliver(_:)`, so every consumer (Open Tabs,
/// web-note page tracking, the Chrome settings) sees the same events in the same order
/// without a second socket consumer or polling.
@MainActor
public final class BridgeEventHandlers {
    /// Identifies one handler for `remove(_:)`.
    public struct Token: Hashable, Sendable {
        fileprivate let id: Int
    }

    private var handlers: [(id: Int, handle: @MainActor (BridgeEvent) -> Void)] = []
    private var nextID = 0

    public init() {}

    public var count: Int { handlers.count }

    @discardableResult
    public func add(_ handler: @escaping @MainActor (BridgeEvent) -> Void) -> Token {
        nextID += 1
        handlers.append((nextID, handler))
        return Token(id: nextID)
    }

    public func remove(_ token: Token) {
        handlers.removeAll { $0.id == token.id }
    }

    /// Calls each handler registered when delivery starts. A handler removed by an earlier
    /// one during this delivery is skipped; one added during it starts with the next event.
    public func deliver(_ event: BridgeEvent) {
        for (id, handle) in handlers where handlers.contains(where: { $0.id == id }) {
            handle(event)
        }
    }
}
