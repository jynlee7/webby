import AppKit
import WebbyCore

/// A nonactivating editor keeps Chrome as the frontmost application while typing.
@MainActor
final class WebNotePanel: NSPanel, NSTextViewDelegate, NSWindowDelegate {
    private let editor = NSTextView()
    private let scope = NSPopUpButton()
    private var choices: [NoteScope] = []
    private var applyingFrame = false
    var onText: ((String) -> Void)?
    var onScope: ((Anchor) -> Void)?
    var onFrame: ((CGRect) -> Void)?
    var onTrash: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(note: Note, context: Context, editable: Bool) {
        super.init(contentRect: .zero, styleMask: [.titled, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        title = "Webby"
        isReleasedWhenClosed = false
        level = .floating
        hidesOnDeactivate = false
        collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace, .ignoresCycle]
        minSize = NSSize(width: 240, height: 170)
        delegate = self
        let root = NSView()
        contentView = root
        scope.target = self
        scope.action = #selector(changeScope)
        scope.isEnabled = editable
        let trash = NSButton(title: "Delete", target: self, action: #selector(deleteNote))
        trash.isEnabled = editable
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        editor.isRichText = false
        editor.isEditable = editable
        editor.font = .systemFont(ofSize: 15)
        editor.textContainerInset = NSSize(width: 10, height: 10)
        editor.string = note.text
        editor.delegate = self
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        scroll.documentView = editor
        for view in [scope, trash, scroll] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            scope.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            scope.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            scope.trailingAnchor.constraint(equalTo: trash.leadingAnchor, constant: -4),
            trash.centerYAnchor.constraint(equalTo: scope.centerYAnchor),
            trash.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            scroll.topAnchor.constraint(equalTo: scope.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        updateScope(note: note, context: context)
    }

    func updateScope(note: Note, context: Context) {
        let next = NoteScope.choices(for: context)
        guard choices != next else { return }
        choices = next
        scope.removeAllItems()
        scope.addItems(withTitles: choices.map(\.title))
        scope.selectItem(at: choices.firstIndex { $0.anchor == note.anchor } ?? -1)
        // Site/prefix anchors may store the page where the note was originally created.
        if scope.indexOfSelectedItem < 0, let anchor = note.anchor {
            scope.addItem(withTitle: "Current scope")
            scope.selectItem(at: choices.count)
            scope.toolTip = String(describing: anchor)
        }
    }

    func place(at frame: CGRect) {
        // Older notes can have empty frames. Never pass invalid sizes to AppKit.
        var target = frame
        target.size.width = max(minSize.width, target.width)
        target.size.height = max(minSize.height, target.height)
        guard self.frame != target else { return }
        applyingFrame = true
        setFrame(target, display: true)
        applyingFrame = false
    }

    func textDidChange(_ notification: Notification) { onText?(editor.string) }
    func windowDidMove(_ notification: Notification) { reportFrame() }
    func windowDidResize(_ notification: Notification) { reportFrame() }
    private func reportFrame() { if !applyingFrame { onFrame?(frame) } }
    @objc private func changeScope() {
        guard choices.indices.contains(scope.indexOfSelectedItem) else { return }
        onScope?(choices[scope.indexOfSelectedItem].anchor)
    }
    @objc private func deleteNote() { onTrash?() }
}
