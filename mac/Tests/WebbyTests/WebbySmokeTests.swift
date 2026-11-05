import Testing
@testable import Webby
import WebbyCore

@Test func appTargetAndCoreImportTogether() {
    let themes = NoteThemes.fallback

    #expect(themes.theme(for: .light) == themes.light)
    #expect(themes.theme(for: .dark) == themes.dark)
    #expect(themes.collapsedHeight >= 0)
    #expect(WebbyCore.Webby.bundleID.isEmpty == false)
}
