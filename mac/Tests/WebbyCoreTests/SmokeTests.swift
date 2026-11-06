import Testing
@testable import WebbyCore

@Test func bundleIdentifierIsStable() {
    #expect(Webby.bundleID == "io.github.jynlee7.webby")
    #expect(Webby.version == "0.1.0")
}
