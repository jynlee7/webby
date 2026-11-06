import Testing
@testable import WebbyCore

@MainActor
@Suite struct BridgeEventHandlersTests {
    @Test func handlersRunInTheOrderAdded() {
        let handlers = BridgeEventHandlers()
        var calls: [String] = []
        handlers.add { _ in calls.append("open tabs") }
        handlers.add { _ in calls.append("browser") }
        handlers.add { _ in calls.append("settings") }

        handlers.deliver(.connected(connection: 1))
        handlers.deliver(.disconnected(connection: 1, profile: nil))

        #expect(calls == ["open tabs", "browser", "settings", "open tabs", "browser", "settings"])
    }

    @Test func removedHandlersStopReceiving() {
        let handlers = BridgeEventHandlers()
        var first = 0
        var second = 0
        let token = handlers.add { _ in first += 1 }
        handlers.add { _ in second += 1 }

        handlers.deliver(.connected(connection: 1))
        handlers.remove(token)
        handlers.deliver(.connected(connection: 2))

        #expect(first == 1)
        #expect(second == 2)
        #expect(handlers.count == 1)
    }

    @Test func changesDuringDeliveryApplyPredictably() {
        let handlers = BridgeEventHandlers()
        var calls: [String] = []
        var laterToken: BridgeEventHandlers.Token?
        handlers.add { _ in
            calls.append("first")
            if let laterToken { handlers.remove(laterToken) }
            handlers.add { _ in calls.append("added") }
        }
        laterToken = handlers.add { _ in calls.append("removed") }

        handlers.deliver(.connected(connection: 1))
        #expect(calls == ["first"])
    }
}
