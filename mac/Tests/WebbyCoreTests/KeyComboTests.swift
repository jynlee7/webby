import Testing
@testable import WebbyCore

@Suite struct KeyComboTests {
    @Test func defaultSettingParsesToTheDefaultShortcut() throws {
        let parsed = try #require(KeyCombo(Settings.default.newNoteHotkey))
        #expect(parsed == KeyCombo.defaultNewNote)
        #expect(parsed.keyCode == 0x2D)
        #expect(parsed.modifiers == [.control, .option])
        #expect(parsed.displayString == "⌃⌥N")
    }

    @Test func parsingAcceptsAliasesCaseAndSpaces() {
        #expect(KeyCombo("Control + Option + N") == KeyCombo.defaultNewNote)
        #expect(KeyCombo("alt+ctrl+n") == KeyCombo.defaultNewNote)
        #expect(KeyCombo("⌃+⌥+n") == KeyCombo.defaultNewNote)
        #expect(KeyCombo("command+shift+space")?.storageString == "shift+cmd+space")
    }

    @Test func malformedTextIsRejected() {
        for text in ["", "ctrl+opt", "ctrl+opt+n+m", "ctrl++", "hyper+n", "ctrl+opt+escape", "ctrl+opt+f13"] {
            #expect(KeyCombo(text) == nil, "\(text)")
        }
    }

    @Test func storageTextRoundTripsInCanonicalOrder() throws {
        for text in ["ctrl+opt+n", "shift+cmd+5", "opt+,", "ctrl+cmd+-", "f5", "ctrl+opt+shift+cmd+return"] {
            let parsed = try #require(KeyCombo(text), "\(text)")
            #expect(parsed.storageString == text)
            #expect(KeyCombo(parsed.storageString) == parsed)
        }
    }

    @Test func recordedKeyPressesBecomeShortcuts() throws {
        let recorded = try #require(KeyCombo(keyCode: 0x2D, modifiers: [.option, .control]))
        #expect(recorded == KeyCombo.defaultNewNote)
        #expect(KeyCombo(keyCode: 0x35, modifiers: [.control]) == nil)  // Escape cancels recording
        #expect(KeyCombo(keyCode: 0x60, modifiers: [])?.displayString == "F5")
    }

    @Test func displayUsesMenuSymbolsInMenuOrder() {
        #expect(KeyCombo("cmd+shift+opt+ctrl+k")?.displayString == "⌃⌥⇧⌘K")
        #expect(KeyCombo("ctrl+space")?.displayString == "⌃Space")
        #expect(KeyCombo("opt+return")?.displayString == "⌥↩")
    }

    @Test func globalShortcutsNeedAModifierOtherThanShiftUnlessTheyUseAFunctionKey() {
        #expect(KeyCombo("ctrl+n")?.isUsableGlobally == true)
        #expect(KeyCombo("cmd+n")?.isUsableGlobally == true)
        #expect(KeyCombo("n")?.isUsableGlobally == false)
        #expect(KeyCombo("shift+n")?.isUsableGlobally == false)
        #expect(KeyCombo("f")?.isUsableGlobally == false)
        #expect(KeyCombo("f6")?.isUsableGlobally == true)
    }
}
