import CoreGraphics
import Foundation

/// Where one note's overlay goes in the current context.
public struct OverlayPlan: Hashable, Sendable {
    public let noteID: UUID
    /// The panel frame in top-left screen coordinates, already kept on a screen.
    public let frame: CGRect
    public let collapsed: Bool

    public init(noteID: UUID, frame: CGRect, collapsed: Bool) {
        self.noteID = noteID
        self.frame = frame
        self.collapsed = collapsed
    }
}

/// A context's notes as the menu bar lists them, in store order.
public struct ContextNotes: Equatable, Sendable {
    /// Attached and shown, expanded or collapsed.
    public var shown: [Note]
    /// Attached but hidden with "Hide here".
    public var hidden: [Note]

    public init(shown: [Note] = [], hidden: [Note] = []) {
        self.shown = shown
        self.hidden = hidden
    }
}

/// Pure rules for where note overlays go. Every rect uses top-left coordinates
/// (see `Geometry`); `screens` are the screens' visible frames.
public enum OverlayPlanner {
    public static let defaultNoteSize = CGSize(width: 240, height: 180)
    public static let minimumNoteSize = CGSize(width: 160, height: 96)
    /// Gap between a new note and the edge of its window or screen, and the cascade step.
    public static let newNoteInset: CGFloat = 24
    /// Room left for a window's title bar and toolbar above a new note.
    public static let titleBarAllowance: CGFloat = 52

    /// The overlays to show for `context`. Notes for other contexts, hidden notes and
    /// trashed notes get none. Collapsed notes keep their width and use the bar height.
    public static func plan(
        notes: [Note],
        context: Context?,
        window: CGRect?,
        screens: [CGRect],
        collapsedHeight: CGFloat
    ) -> [OverlayPlan] {
        guard let context else { return [] }
        return notes.filter { NoteVisibility.isVisible($0, in: context) }.map { note in
            var frame = Geometry.absoluteFrame(for: note, window: window)
            frame.size.width = max(frame.width, minimumNoteSize.width)
            frame.size.height = note.collapsed ? collapsedHeight : max(frame.height, minimumNoteSize.height)
            return OverlayPlan(
                noteID: note.id,
                frame: keepOnScreen(frame, screens: screens),
                collapsed: note.collapsed
            )
        }
    }

    /// Splits the notes attached to `context` into shown and hidden ones.
    public static func contextNotes(_ notes: [Note], context: Context?) -> ContextNotes {
        guard let context else { return ContextNotes() }
        var result = ContextNotes()
        for note in notes where NoteVisibility.isAttached(note, to: context) {
            if note.hidden {
                result.hidden.append(note)
            } else {
                result.shown.append(note)
            }
        }
        return result
    }

    /// New notes follow their window when its frame is known (Accessibility granted),
    /// and stay at a fixed screen position otherwise.
    public static func placement(window: CGRect?) -> Placement {
        window == nil ? .screen : .window
    }

    /// Where a new note appears: near the top-right of the window, or of the first
    /// screen when there is no window, stepped down and left past notes already there.
    public static func newNoteFrame(
        window: CGRect?,
        screens: [CGRect],
        occupied: [CGRect],
        size: CGSize = defaultNoteSize
    ) -> CGRect {
        var origin: CGPoint
        if let window {
            origin = CGPoint(
                x: max(window.minX + newNoteInset, window.maxX - size.width - newNoteInset),
                y: window.minY + titleBarAllowance
            )
        } else if let screen = screens.first {
            origin = CGPoint(x: screen.maxX - size.width - newNoteInset, y: screen.minY + newNoteInset)
        } else {
            origin = CGPoint(x: newNoteInset, y: newNoteInset)
        }

        let tolerance = newNoteInset / 2
        for _ in 0..<20 {
            let taken = occupied.contains {
                abs($0.minX - origin.x) < tolerance && abs($0.minY - origin.y) < tolerance
            }
            guard taken else { break }
            origin.x -= newNoteInset
            origin.y += newNoteInset
        }

        return keepOnScreen(CGRect(origin: origin, size: size), screens: screens)
    }

    /// Returns `rect` unchanged while screens cover all of it. Otherwise moves it, and
    /// shrinks it if it is larger, into the screen it overlaps most, or the nearest
    /// screen when it overlaps none. Stored frames are never changed by this.
    public static func keepOnScreen(_ rect: CGRect, screens: [CGRect]) -> CGRect {
        guard !screens.isEmpty, rect.width > 0, rect.height > 0 else { return rect }

        // Visible frames don't overlap, so their intersections add up to the covered area.
        let covered = screens.reduce(CGFloat(0)) { $0 + area($1.intersection(rect)) }
        if covered >= area(rect) - 0.5 { return rect }

        let target = screens.max { lhs, rhs in
            let left = area(lhs.intersection(rect))
            let right = area(rhs.intersection(rect))
            if left != right { return left < right }
            return distance(from: rect, to: lhs) > distance(from: rect, to: rhs)
        } ?? screens[0]

        var moved = rect
        moved.size.width = min(rect.width, target.width)
        moved.size.height = min(rect.height, target.height)
        moved.origin.x = min(max(rect.minX, target.minX), target.maxX - moved.width)
        moved.origin.y = min(max(rect.minY, target.minY), target.maxY - moved.height)
        return moved
    }

    /// The frame to store after the user moved or resized a panel to `panel`. A
    /// collapsed note keeps its expanded size; an expanded one keeps at least the
    /// minimum size.
    public static func storedFrame(forPanel panel: CGRect, note: Note, window: CGRect?) -> NoteFrame {
        var absolute = panel
        if note.collapsed {
            absolute.size = CGSize(width: note.frame.width, height: note.frame.height)
        } else {
            absolute.size.width = max(panel.width, minimumNoteSize.width)
            absolute.size.height = max(panel.height, minimumNoteSize.height)
        }
        return Geometry.storedFrame(absolute: absolute, placement: note.placement, window: window)
    }

    private static func area(_ rect: CGRect) -> CGFloat {
        rect.isNull ? 0 : rect.width * rect.height
    }

    private static func distance(from rect: CGRect, to screen: CGRect) -> CGFloat {
        let dx = max(screen.minX - rect.midX, 0, rect.midX - screen.maxX)
        let dy = max(screen.minY - rect.midY, 0, rect.midY - screen.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }
}
