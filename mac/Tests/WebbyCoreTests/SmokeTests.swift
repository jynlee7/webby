import Testing
@testable import WebbyCore

@Test func bundleIdentifierIsStable() {
    #expect(Webby.bundleID == "com.webby.app")
}
