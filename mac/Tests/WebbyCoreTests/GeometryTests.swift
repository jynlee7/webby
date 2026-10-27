import CoreGraphics
import Testing
@testable import WebbyCore

private let anchor = Anchor.app(bundleID: "com.example.Notes")

@Test func appKitAndTopLeftConversions() {
    let topLeft = CGRect(x: 12.5, y: 40.25, width: 300, height: 120.75)
    let appKit = Geometry.appKitRect(fromTopLeft: topLeft, primaryScreenHeight: 1000)

    #expect(appKit == CGRect(x: 12.5, y: 839, width: 300, height: 120.75))
    #expect(Geometry.topLeftRect(fromAppKit: appKit, primaryScreenHeight: 1000) == topLeft)
}

@Test func appKitAndTopLeftConversionsPreserveNegativeAndFractionalValues() {
    let topLeft = CGRect(x: -100.5, y: -20.25, width: 50.5, height: 30.25)
    let appKit = Geometry.appKitRect(fromTopLeft: topLeft, primaryScreenHeight: 1000)

    #expect(appKit == CGRect(x: -100.5, y: 990, width: 50.5, height: 30.25))
    #expect(Geometry.topLeftRect(fromAppKit: appKit, primaryScreenHeight: 1000) == topLeft)
}

@Test func absoluteFrameAddsWindowOriginForWindowPlacement() {
    let note = Note(
        anchor: anchor,
        frame: NoteFrame(x: -10.5, y: 20.25, width: 100, height: 50),
        placement: .window
    )
    let window = CGRect(x: 200.5, y: 300.25, width: 800, height: 600)

    #expect(
        Geometry.absoluteFrame(for: note, window: window)
            == CGRect(x: 190, y: 320.5, width: 100, height: 50)
    )
    #expect(
        Geometry.absoluteFrame(for: note, window: nil)
            == CGRect(x: -10.5, y: 20.25, width: 100, height: 50)
    )
}

@Test func absoluteFrameIgnoresWindowForScreenPlacement() {
    let note = Note(
        anchor: anchor,
        frame: NoteFrame(x: -10.5, y: 20.25, width: 100, height: 50),
        placement: .screen
    )
    let window = CGRect(x: 200.5, y: 300.25, width: 800, height: 600)

    #expect(
        Geometry.absoluteFrame(for: note, window: window)
            == CGRect(x: -10.5, y: 20.25, width: 100, height: 50)
    )
    #expect(
        Geometry.absoluteFrame(for: note, window: nil)
            == CGRect(x: -10.5, y: 20.25, width: 100, height: 50)
    )
}

@Test func storedFrameInvertsAbsoluteFrame() {
    let absolute = CGRect(x: -20.5, y: 40.75, width: 120.5, height: 80.25)
    let window = CGRect(x: 50.25, y: 60.5, width: 800, height: 600)
    let windows: [CGRect?] = [window, nil]

    for placement in [Placement.window, .screen] {
        for candidateWindow in windows {
            let stored = Geometry.storedFrame(
                absolute: absolute,
                placement: placement,
                window: candidateWindow
            )
            let note = Note(anchor: anchor, frame: stored, placement: placement)

            #expect(Geometry.absoluteFrame(for: note, window: candidateWindow) == absolute)
        }
    }
}

@Test func storedFrameSubtractsWindowOriginForWindowPlacement() {
    let absolute = CGRect(x: 190, y: 320.5, width: 100, height: 50)
    let window = CGRect(x: 200.5, y: 300.25, width: 800, height: 600)

    #expect(
        Geometry.storedFrame(absolute: absolute, placement: .window, window: window)
            == NoteFrame(x: -10.5, y: 20.25, width: 100, height: 50)
    )
    #expect(
        Geometry.storedFrame(absolute: absolute, placement: .window, window: nil)
            == NoteFrame(x: 190, y: 320.5, width: 100, height: 50)
    )
    #expect(
        Geometry.storedFrame(absolute: absolute, placement: .screen, window: window)
            == NoteFrame(x: 190, y: 320.5, width: 100, height: 50)
    )
}

@Test func movingAbsoluteFrameMovesStoredFrameBySameDelta() {
    let window = CGRect(x: 50, y: 60, width: 800, height: 600)
    let note = Note(
        anchor: anchor,
        frame: NoteFrame(x: 10, y: 20, width: 100, height: 50),
        placement: .window
    )
    let start = Geometry.absoluteFrame(for: note, window: window)
    let moved = start.offsetBy(dx: 15.5, dy: -7.25)
    let stored = Geometry.storedFrame(absolute: moved, placement: .window, window: window)

    #expect(stored == NoteFrame(x: 25.5, y: 12.75, width: 100, height: 50))

    let movedNote = Note(anchor: anchor, frame: stored, placement: .window)
    #expect(Geometry.absoluteFrame(for: movedNote, window: window) == moved)
}
