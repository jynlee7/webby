import CoreGraphics
import Foundation
import Testing
@testable import WebbyCore

@Suite struct OverlayPlannerTests {
    private let textEdit = Context(appBundleID: "com.apple.TextEdit")
    private let safari = Context(appBundleID: "com.apple.Safari")
    /// A 1440×900 screen with a 25 pt menu bar, in top-left coordinates.
    private let screen = CGRect(x: 0, y: 25, width: 1440, height: 875)
    private let collapsedHeight: CGFloat = 32

    private func note(
        _ bundleID: String = "com.apple.TextEdit",
        frame: NoteFrame = NoteFrame(x: 20, y: 40, width: 240, height: 180),
        placement: Placement = .window,
        collapsed: Bool = false,
        hidden: Bool = false,
        trashed: Bool = false
    ) -> Note {
        Note(anchor: .app(bundleID: bundleID), frame: frame, placement: placement,
             collapsed: collapsed, hidden: hidden, trashedAt: trashed ? Date() : nil)
    }

    private func plan(_ notes: [Note], _ context: Context?, window: CGRect?, screens: [CGRect]? = nil) -> [OverlayPlan] {
        OverlayPlanner.plan(notes: notes, context: context, window: window,
                            screens: screens ?? [screen], collapsedHeight: collapsedHeight)
    }

    @Test func windowNoteFollowsItsWindow() {
        let anchored = note()
        let first = plan([anchored], textEdit, window: CGRect(x: 100, y: 200, width: 800, height: 600))
        let moved = plan([anchored], textEdit, window: CGRect(x: 300, y: 250, width: 800, height: 600))

        #expect(first == [OverlayPlan(noteID: anchored.id, frame: CGRect(x: 120, y: 240, width: 240, height: 180), collapsed: false)])
        #expect(moved.first?.frame == CGRect(x: 320, y: 290, width: 240, height: 180))
    }

    @Test func screenNoteIgnoresTheWindow() {
        let fixed = note(frame: NoteFrame(x: 500, y: 300, width: 240, height: 180), placement: .screen)
        let planned = plan([fixed], textEdit, window: CGRect(x: 100, y: 200, width: 800, height: 600))
        #expect(planned.first?.frame == CGRect(x: 500, y: 300, width: 240, height: 180))
    }

    @Test func windowNoteWithoutAKnownWindowStaysOnScreen() {
        // Accessibility was revoked, so the offset is all there is.
        let anchored = note(frame: NoteFrame(x: 20, y: 10, width: 240, height: 180))
        let planned = plan([anchored], textEdit, window: nil)
        #expect(planned.first?.frame == CGRect(x: 20, y: 25, width: 240, height: 180))
    }

    @Test func onlyTheCurrentAppsShownNotesArePlanned() {
        let notes = [
            note(),
            note("com.apple.Safari"),
            note(hidden: true),
            note(trashed: true),
        ]
        #expect(plan(notes, textEdit, window: nil).map(\.noteID) == [notes[0].id])
        #expect(plan(notes, safari, window: nil).map(\.noteID) == [notes[1].id])
        #expect(plan(notes, nil, window: nil).isEmpty)
    }

    @Test func plansKeepStoreOrder() {
        let notes = (0..<4).map { index in
            note(frame: NoteFrame(x: Double(index) * 50, y: 100, width: 200, height: 120), placement: .screen)
        }
        #expect(plan(notes, textEdit, window: nil).map(\.noteID) == notes.map(\.id))
    }

    @Test func collapsedNoteIsABarWithTheSameWidthAndOrigin() {
        let collapsed = note(collapsed: true)
        let planned = plan([collapsed], textEdit, window: CGRect(x: 100, y: 200, width: 800, height: 600))
        #expect(planned == [OverlayPlan(noteID: collapsed.id, frame: CGRect(x: 120, y: 240, width: 240, height: collapsedHeight), collapsed: true)])
    }

    @Test func tinyStoredFramesGrowToTheMinimumSize() {
        let tiny = note(frame: NoteFrame(x: 400, y: 400, width: 0, height: 0), placement: .screen)
        let planned = plan([tiny], textEdit, window: nil)
        #expect(planned.first?.frame.size == OverlayPlanner.minimumNoteSize)
    }

    @Test func noteThatWouldLeaveTheScreenIsBroughtBackWithoutChangingItsStoredFrame() {
        let anchored = note(frame: NoteFrame(x: 700, y: 40, width: 240, height: 180))
        // The window moved right, so the note would end at x = 1840.
        let planned = plan([anchored], textEdit, window: CGRect(x: 900, y: 200, width: 800, height: 600))
        #expect(planned.first?.frame == CGRect(x: 1200, y: 240, width: 240, height: 180))
        #expect(anchored.frame == NoteFrame(x: 700, y: 40, width: 240, height: 180))
    }

    @Test func noteAcrossTwoScreensIsLeftWhereItIs() {
        let right = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let straddling = CGRect(x: 1300, y: 300, width: 240, height: 180)
        #expect(OverlayPlanner.keepOnScreen(straddling, screens: [screen, right]) == straddling)
    }

    @Test func noteOnADisconnectedScreenMovesToTheNearestScreen() {
        let right = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let orphan = CGRect(x: 4000, y: 500, width: 240, height: 180)
        #expect(OverlayPlanner.keepOnScreen(orphan, screens: [screen, right]) == CGRect(x: 3120, y: 500, width: 240, height: 180))
    }

    @Test func noteLargerThanTheScreenIsShrunkToFit() {
        let huge = CGRect(x: -100, y: 0, width: 2000, height: 1000)
        #expect(OverlayPlanner.keepOnScreen(huge, screens: [screen]) == screen)
    }

    @Test func placementFollowsWhetherTheWindowIsKnown() {
        #expect(OverlayPlanner.placement(window: CGRect(x: 0, y: 0, width: 10, height: 10)) == .window)
        #expect(OverlayPlanner.placement(window: nil) == .screen)
    }

    @Test func newNoteStartsAtTheTopRightOfItsWindow() {
        let window = CGRect(x: 100, y: 200, width: 800, height: 600)
        let frame = OverlayPlanner.newNoteFrame(window: window, screens: [screen], occupied: [])
        #expect(frame == CGRect(x: 636, y: 252, width: 240, height: 180))
        #expect(window.contains(frame))
    }

    @Test func newNoteInANarrowWindowStartsAtItsLeftInset() {
        let window = CGRect(x: 100, y: 200, width: 200, height: 600)
        let frame = OverlayPlanner.newNoteFrame(window: window, screens: [screen], occupied: [])
        #expect(frame.minX == 124)
    }

    @Test func newNoteWithoutAWindowStartsAtTheTopRightOfTheFirstScreen() {
        let frame = OverlayPlanner.newNoteFrame(window: nil, screens: [screen], occupied: [])
        #expect(frame == CGRect(x: 1176, y: 49, width: 240, height: 180))
    }

    @Test func newNotesCascadeInsteadOfStacking() {
        let window = CGRect(x: 100, y: 200, width: 800, height: 600)
        let first = OverlayPlanner.newNoteFrame(window: window, screens: [screen], occupied: [])
        let second = OverlayPlanner.newNoteFrame(window: window, screens: [screen], occupied: [first])
        let third = OverlayPlanner.newNoteFrame(window: window, screens: [screen], occupied: [first, second])
        #expect(second.origin == CGPoint(x: first.minX - 24, y: first.minY + 24))
        #expect(third.origin == CGPoint(x: first.minX - 48, y: first.minY + 48))
    }

    @Test func newNoteNearTheScreenEdgeStaysOnScreen() {
        let window = CGRect(x: 1300, y: 800, width: 800, height: 600)
        let frame = OverlayPlanner.newNoteFrame(window: window, screens: [screen], occupied: [])
        #expect(screen.contains(frame))
    }

    @Test func storingAPlannedFrameRoundTrips() {
        let window = CGRect(x: 100, y: 200, width: 800, height: 600)
        let anchored = note()
        let planned = plan([anchored], textEdit, window: window)[0]
        #expect(OverlayPlanner.storedFrame(forPanel: planned.frame, note: anchored, window: window) == anchored.frame)
    }

    @Test func movingACollapsedNoteKeepsItsExpandedSize() {
        let window = CGRect(x: 100, y: 200, width: 800, height: 600)
        let collapsed = note(collapsed: true)
        let bar = CGRect(x: 400, y: 300, width: 240, height: collapsedHeight)
        #expect(OverlayPlanner.storedFrame(forPanel: bar, note: collapsed, window: window)
            == NoteFrame(x: 300, y: 100, width: 240, height: 180))
    }

    @Test func resizingBelowTheMinimumStoresTheMinimum() {
        let fixed = note(placement: .screen)
        let squashed = CGRect(x: 10, y: 50, width: 40, height: 20)
        #expect(OverlayPlanner.storedFrame(forPanel: squashed, note: fixed, window: nil)
            == NoteFrame(x: 10, y: 50, width: 160, height: 96))
    }

    @Test func contextNotesListCollapsedNotesAndCountHiddenOnes() {
        let notes = [
            note(),
            note(collapsed: true),
            note(hidden: true),
            note(collapsed: true, hidden: true),
            note(trashed: true),
            note("com.apple.Safari"),
        ]
        let listed = OverlayPlanner.contextNotes(notes, context: textEdit)
        #expect(listed.shown.map(\.id) == [notes[0].id, notes[1].id])
        #expect(listed.hidden.map(\.id) == [notes[2].id, notes[3].id])
        #expect(OverlayPlanner.contextNotes(notes, context: nil) == ContextNotes())
    }

    @Test func summaryLineUsesTheFirstNonBlankLine() {
        var titled = note()
        titled.text = "\n   \n  Groceries  \nmilk"
        #expect(titled.summaryLine() == "Groceries")

        titled.text = String(repeating: "a", count: 50)
        #expect(titled.summaryLine(limit: 10) == "aaaaaaaaa…")

        titled.text = " \n\t"
        #expect(titled.summaryLine() == nil)
    }
}
