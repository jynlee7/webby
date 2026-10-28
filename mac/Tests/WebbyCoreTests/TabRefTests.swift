import Foundation
import Testing
@testable import WebbyCore

private let reference = TabRef(
    browser: "com.google.Chrome",
    profile: "profile-a",
    session: "123@2026-01-01",
    tabID: 42,
    windowID: 7
)

private func binding(
    browser: String = "com.google.Chrome",
    profile: String = "profile-a",
    session: String = "123@2026-01-01",
    tabID: Int = 42,
    windowID: Int = 7,
    closedAt: Date? = nil
) -> TabBinding {
    TabBinding(
        browser: browser,
        profile: profile,
        session: session,
        tabID: tabID,
        windowID: windowID,
        index: 1,
        lastURL: "https://example.com/",
        lastTitle: "Example",
        closedAt: closedAt,
        pendingRestore: closedAt != nil
    )
}

@Test func matchesRequiresBrowserProfileSessionAndTabID() {
    #expect(reference.matches(binding()))

    #expect(!reference.matches(binding(browser: "org.mozilla.firefox")))
    #expect(!reference.matches(binding(profile: "profile-b")))
    #expect(!reference.matches(binding(session: "456@2026-01-02")))
    #expect(!reference.matches(binding(tabID: 43)))
}

@Test func changedWindowIDStillMatches() {
    let moved = binding(windowID: 8)

    #expect(reference.windowID != moved.windowID)
    #expect(reference.matches(moved))
}

@Test func closedBindingStillMatchesBecauseClosedAtIsBookkeeping() {
    let closed = binding(closedAt: Date(timeIntervalSince1970: 1_234))

    #expect(closed.closedAt != nil)
    #expect(closed.pendingRestore)
    #expect(reference.matches(closed))
}
