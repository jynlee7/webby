import CoreGraphics
import Testing
@testable import WebbyCore

@Suite struct GeometryTests {
    // A 1512x982 primary display (14" MacBook Pro, default scaling).
    let primaryHeight: CGFloat = 982

    @Test func topLeftToAppKitOnPrimaryScreen() {
        // A 300x200 rect 100pt from the top-left corner...
        let topLeft = CGRect(x: 100, y: 100, width: 300, height: 200)
        // ...has its bottom edge at 300 from the top, i.e. 982 - 300 = 682 from the bottom.
        let appKit = Geometry.appKitRect(fromTopLeft: topLeft, primaryScreenHeight: primaryHeight)
        #expect(appKit == CGRect(x: 100, y: 682, width: 300, height: 200))
    }

    @Test func fullPrimaryScreenMapsToItself() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        #expect(Geometry.appKitRect(fromTopLeft: screen, primaryScreenHeight: primaryHeight) == screen)
    }

    @Test func secondaryScreenAboveAndLeft() {
        // External 1920x1080 display arranged above and to the left of the primary.
        // AppKit frame: x = -1920, y = 982 (sits on top of the primary).
        let externalAppKit = CGRect(x: -1920, y: 982, width: 1920, height: 1080)
        let externalTopLeft = Geometry.topLeftRect(fromAppKit: externalAppKit, primaryScreenHeight: primaryHeight)
        // In top-left coordinates it starts 1080pt *above* the primary's top edge.
        #expect(externalTopLeft == CGRect(x: -1920, y: -1080, width: 1920, height: 1080))
    }

    @Test(arguments: [
        CGRect(x: 0, y: 0, width: 10, height: 10),
        CGRect(x: -1920, y: -1080, width: 640, height: 480),
        CGRect(x: 2000, y: 1500, width: 123.5, height: 77.25),
    ])
    func conversionRoundTrips(_ rect: CGRect) {
        let there = Geometry.appKitRect(fromTopLeft: rect, primaryScreenHeight: primaryHeight)
        #expect(Geometry.topLeftRect(fromAppKit: there, primaryScreenHeight: primaryHeight) == rect)
    }

    func note(_ frame: NoteFrame, _ placement: Placement) -> Note {
        Note(anchor: .app(bundleID: "x"), frame: frame, placement: placement)
    }

    @Test func windowPlacedNoteFollowsWindow() {
        let n = note(NoteFrame(x: 20, y: 60, width: 250, height: 150), .window)
        let window = CGRect(x: 300, y: 40, width: 1200, height: 800)
        #expect(Geometry.absoluteFrame(for: n, window: window) == CGRect(x: 320, y: 100, width: 250, height: 150))

        let moved = window.offsetBy(dx: -500, dy: 200)
        #expect(Geometry.absoluteFrame(for: n, window: moved) == CGRect(x: -180, y: 300, width: 250, height: 150))
    }

    @Test func screenPlacedNoteIgnoresWindow() {
        let n = note(NoteFrame(x: 20, y: 60, width: 250, height: 150), .screen)
        #expect(Geometry.absoluteFrame(for: n, window: CGRect(x: 300, y: 40, width: 1, height: 1))
                == CGRect(x: 20, y: 60, width: 250, height: 150))
    }

    @Test func windowPlacedNoteWithoutWindowFallsBackToAbsolute() {
        let n = note(NoteFrame(x: 20, y: 60, width: 250, height: 150), .window)
        #expect(Geometry.absoluteFrame(for: n, window: nil) == CGRect(x: 20, y: 60, width: 250, height: 150))
    }

    @Test(arguments: [Placement.window, .screen])
    func storedFrameInvertsAbsoluteFrame(_ placement: Placement) {
        let window = CGRect(x: -800, y: 25, width: 1000, height: 700)
        let absolute = CGRect(x: -500, y: 300, width: 220, height: 140)
        let stored = Geometry.storedFrame(absolute: absolute, placement: placement, window: window)
        #expect(Geometry.absoluteFrame(for: note(stored, placement), window: window) == absolute)
    }
}
