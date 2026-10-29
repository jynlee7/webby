import AppKit
import SwiftUI
import WebbyCore

/// One note window's state. `text` is the draft: `NotesController` commits it to the
/// store when the autosave fires, on blur and on Done, so the content revision goes up
/// once per pause in typing rather than once per keystroke.
@MainActor @Observable
final class NoteModel {
    let id: UUID
    var text: String
    var collapsed: Bool
    var isEditable: Bool
    var themes: NoteThemes
    /// The note's saved palette slot and decoration choice.
    var appearance: NoteAppearance?
    /// Bumped to move keyboard focus into the text.
    var focusRequest = 0

    @ObservationIgnored var onTextChange: @MainActor () -> Void = {}
    @ObservationIgnored var onToggleCollapsed: @MainActor () -> Void = {}
    @ObservationIgnored var onHide: @MainActor () -> Void = {}
    @ObservationIgnored var onTrash: @MainActor () -> Void = {}
    @ObservationIgnored var onDone: @MainActor () -> Void = {}
    @ObservationIgnored var onSelectPalette: @MainActor (Int?) -> Void = { _ in }
    @ObservationIgnored var onSetDecorationHidden: @MainActor (Bool) -> Void = { _ in }
    @ObservationIgnored var onResizeEnded: @MainActor () -> Void = {}

    init(id: UUID, text: String, collapsed: Bool, isEditable: Bool, themes: NoteThemes) {
        self.id = id
        self.text = text
        self.collapsed = collapsed
        self.isEditable = isEditable
        self.themes = themes
    }

    var title: String {
        Note.summaryLine(of: text) ?? "Empty note"
    }
}

/// Injects the theme for the panel's current appearance, so every view below reads
/// `webbyTheme` and none hard-codes styling.
struct NoteRootView: View {
    let model: NoteModel
    let assets: SkinAssetCache

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = model.themes.theme(for: scheme)
        ZStack {
            DecorationView(decoration: theme.decoration)
            NoteView(model: model)
                .padding(Geometry.decorationMargin)
        }
        .environment(\.webbyTheme, theme)
        .environment(\.skinAssetCache, assets)
    }
}

struct NoteView: View {
    /// Room for the note's controls. Skins without a header (height 0, as in
    /// `webby.clear`) still need a row for collapse, ⋯ and close.
    static let minimumControlRowHeight = 28.0

    /// The smallest panel: the minimum note plus the decoration margin on every side.
    static let minimumPanelSize = CGSize(
        width: OverlayPlanner.minimumNoteSize.width + 2 * Geometry.decorationMargin,
        height: OverlayPlanner.minimumNoteSize.height + 2 * Geometry.decorationMargin
    )

    let model: NoteModel

    @Environment(\.webbyTheme) private var theme
    @State private var hovering = false

    private var surface: ResolvedSurface { theme.surface }

    private var palette: RGBAColor? {
        guard let index = theme.selectedIndex, theme.palette.indices.contains(index) else { return nil }
        return theme.palette[index]
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: surface.cornerRadius, style: .continuous)
    }

    private var controlRowHeight: Double {
        model.collapsed ? theme.collapsed.height : max(theme.header.height, Self.minimumControlRowHeight)
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            if !model.collapsed {
                content
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            ZStack {
                if let material = surface.material.visualEffectMaterial {
                    VisualEffectBackground(material: material, cornerRadius: surface.cornerRadius)
                }
                Color(surface.fill)
                if let image = surface.image {
                    SurfaceArtwork(image: image, tint: palette)
                }
                if model.collapsed {
                    Color(theme.collapsed.fill)
                }
            }
        }
        .overlay {
            if surface.border.width > 0 {
                shape.strokeBorder(Color(surface.border.color), lineWidth: surface.border.width)
            }
        }
        .clipShape(shape)
        .onHover { hovering = $0 }
    }

    private var controls: some View {
        HStack(spacing: 2) {
            NoteIconButton(
                symbol: model.collapsed ? "chevron.right" : "chevron.down",
                label: model.collapsed ? "Expand note" : "Collapse note",
                action: model.onToggleCollapsed
            )
            .disabled(!model.isEditable)

            ZStack(alignment: .leading) {
                WindowDragArea(onDoubleClick: model.isEditable ? model.onToggleCollapsed : nil)
                    .accessibilityHidden(true)
                if model.collapsed ? theme.collapsed.showsFirstLine : theme.header.showsTitle {
                    Text(model.title)
                        .font(theme.typography.swiftUIFont)
                        .foregroundStyle(Color(surface.text))
                        .lineLimit(1)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Menu {
                Button("Hide Here", action: model.onHide)
                if model.themes.paletteSlotCount > 0 || model.themes.hasDecoration {
                    Divider()
                    skinItems
                }
                Divider()
                Button("Move to Trash", action: model.onTrash)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(width: 22, height: 22)
            .tint(Color(theme.icons.tint))
            .foregroundStyle(Color(theme.icons.tint))
            .help("Note options")
            .accessibilityLabel("Note options")
            .disabled(!model.isEditable)

            NoteIconButton(symbol: "xmark", label: "Close note", action: model.onTrash)
                .disabled(!model.isEditable)
        }
        .padding(.horizontal, 6)
        .frame(height: controlRowHeight)
        .background(model.collapsed ? Color.clear : Color(theme.header.fill))
    }

    @ViewBuilder
    private var skinItems: some View {
        let themes = model.themes
        if themes.paletteSlotCount > 0 {
            // A saved index past the end of a shrunken palette resolves to slot 1.
            let saved = model.appearance?.paletteIndex
            let selected = saved.map { min($0, themes.paletteSlotCount - 1) }
            Menu("Color") {
                Toggle("Skin Default", isOn: Binding(get: { saved == nil }, set: { _ in model.onSelectPalette(nil) }))
                Divider()
                ForEach(0..<themes.paletteSlotCount, id: \.self) { index in
                    Toggle("Color \(index + 1)", isOn: Binding(get: { selected == index }, set: { _ in model.onSelectPalette(index) }))
                }
            }
        }
        if themes.hasDecoration {
            Toggle("Show Decoration", isOn: Binding(
                get: { !(model.appearance?.hideDecoration ?? false) },
                set: { model.onSetDecorationHidden(!$0) }
            ))
        }
    }

    private var content: some View {
        let padding = surface.padding
        return ZStack(alignment: .topLeading) {
            NoteTextView(
                model: model,
                text: model.text,
                isEditable: model.isEditable,
                focusRequest: model.focusRequest,
                theme: theme
            )
            if model.text.isEmpty {
                Text(model.isEditable ? "Type a note…" : "Notes are read-only")
                    .font(theme.typography.swiftUIFont)
                    .foregroundStyle(Color(surface.placeholder))
                    .padding(.leading, NoteTextView.lineFragmentPadding)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        // The control row already sits above the text, so only padding beyond it applies.
        .padding(.top, max((padding.top ?? 0) - controlRowHeight, 0))
        .padding(.leading, max((padding.left ?? 0) - NoteTextView.lineFragmentPadding, 0))
        .padding(.trailing, max((padding.right ?? 0) - NoteTextView.lineFragmentPadding, 0))
        .padding(.bottom, padding.bottom ?? 0)
        .overlay(alignment: .bottomTrailing) {
            if model.isEditable {
                ResizeGrip(minimumSize: Self.minimumPanelSize, onEnded: model.onResizeEnded)
                    .frame(width: 18, height: 18)
                    .overlay {
                        if theme.resizeHandle.visibility.isShown(hovering: hovering) {
                            GripMark()
                                .stroke(Color(theme.resizeHandle.tint), lineWidth: 1)
                                .allowsHitTesting(false)
                        }
                    }
                    .accessibilityHidden(true)
            }
        }
    }
}

/// A control with a hit area of at least 20×20 pt and a spoken label.
private struct NoteIconButton: View {
    let symbol: String
    let label: String
    let action: @MainActor () -> Void

    @Environment(\.webbyTheme) private var theme

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color(theme.icons.tint))
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Three short diagonal strokes in the bottom-right corner.
private struct GripMark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for inset in [4.0, 8.0, 12.0] {
            path.move(to: CGPoint(x: rect.maxX - inset, y: rect.maxY - 3))
            path.addLine(to: CGPoint(x: rect.maxX - 3, y: rect.maxY - inset))
        }
        return path
    }
}

// MARK: - AppKit pieces

/// The note's text: a plain-text `NSTextView`, because the note needs Done on ⌘Return
/// and Esc, and editing shortcuts in an app that has no active menu bar.
struct NoteTextView: NSViewRepresentable {
    static let lineFragmentPadding: CGFloat = 5

    let model: NoteModel
    let text: String
    let isEditable: Bool
    let focusRequest: Int
    let theme: ResolvedTheme

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: NSViewRepresentableContext<Self>) -> NSScrollView {
        let textView = NoteTextEditor(frame: .zero)
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = Self.lineFragmentPadding
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.setAccessibilityLabel("Note text")
        Self.style(textView, theme: theme)
        context.coordinator.theme = theme
        textView.string = text
        textView.isEditable = isEditable

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: NSViewRepresentableContext<Self>) {
        guard let textView = scrollView.documentView as? NoteTextEditor else { return }
        context.coordinator.model = model
        if context.coordinator.theme != theme {
            context.coordinator.theme = theme
            Self.style(textView, theme: theme)
        }
        textView.onDone = { [weak model] in model?.onDone() }
        textView.isEditable = isEditable
        // Never replace text mid-composition, or an input method loses its marked text.
        if textView.string != text, !textView.hasMarkedText() {
            textView.string = text
        }
        if context.coordinator.focusRequest != focusRequest {
            context.coordinator.focusRequest = focusRequest
            Task { @MainActor in
                textView.window?.makeFirstResponder(textView)
            }
        }
    }

    private static func style(_ textView: NSTextView, theme: ResolvedTheme) {
        let font = theme.typography.nsFont
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = theme.typography.lineSpacing
        let color = NSColor(theme.surface.text)
        textView.font = font
        textView.textColor = color
        textView.insertionPointColor = NSColor(theme.surface.caret)
        textView.selectedTextAttributes = [.backgroundColor: NSColor(theme.surface.selection)]
        textView.defaultParagraphStyle = paragraph
        textView.typingAttributes = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
        // Plain text keeps one style, so restyle what is already there too.
        if let storage = textView.textStorage, storage.length > 0 {
            storage.setAttributes(textView.typingAttributes, range: NSRange(location: 0, length: storage.length))
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var model: NoteModel
        var focusRequest = 0
        var theme: ResolvedTheme?

        init(model: NoteModel) {
            self.model = model
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            model.text = textView.string
            model.onTextChange()
        }
    }
}

final class NoteTextEditor: NSTextView {
    var onDone: (@MainActor () -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Return and keypad Enter.
        if flags == .command, event.keyCode == 0x24 || event.keyCode == 0x4C {
            onDone?()
            return true
        }
        guard flags == .command || flags == [.command, .shift] else {
            return super.performKeyEquivalent(with: event)
        }
        switch (event.charactersIgnoringModifiers?.lowercased(), flags.contains(.shift)) {
        case ("x", false): cut(nil)
        case ("c", false): copy(nil)
        case ("v", false): paste(nil)
        case ("a", false): selectAll(nil)
        case ("z", false): undoManager?.undo()
        case ("z", true): undoManager?.redo()
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }

    /// Esc.
    override func cancelOperation(_ sender: Any?) {
        onDone?()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The empty part of the header. Dragging it moves the note; a double-click collapses.
struct WindowDragArea: NSViewRepresentable {
    var onDoubleClick: (@MainActor () -> Void)?

    func makeNSView(context: NSViewRepresentableContext<Self>) -> DragView {
        let view = DragView()
        view.onDoubleClick = onDoubleClick
        return view
    }

    func updateNSView(_ view: DragView, context: NSViewRepresentableContext<Self>) {
        view.onDoubleClick = onDoubleClick
    }

    final class DragView: NSView {
        var onDoubleClick: (@MainActor () -> Void)?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2, let onDoubleClick {
                onDoubleClick()
                return
            }
            window?.performDrag(with: event)
        }
    }
}

/// The bottom-right corner. Dragging it resizes the note with its top-left fixed.
struct ResizeGrip: NSViewRepresentable {
    let minimumSize: CGSize
    let onEnded: @MainActor () -> Void

    func makeNSView(context: NSViewRepresentableContext<Self>) -> GripView {
        let view = GripView()
        view.minimumSize = minimumSize
        view.onEnded = onEnded
        return view
    }

    func updateNSView(_ view: GripView, context: NSViewRepresentableContext<Self>) {
        view.minimumSize = minimumSize
        view.onEnded = onEnded
    }

    final class GripView: NSView {
        var minimumSize = CGSize.zero
        var onEnded: (@MainActor () -> Void)?
        private var start: (frame: NSRect, mouse: NSPoint)?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            start = (window.frame, NSEvent.mouseLocation)
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start, let window else { return }
            let mouse = NSEvent.mouseLocation
            let width = max(minimumSize.width, start.frame.width + mouse.x - start.mouse.x)
            let height = max(minimumSize.height, start.frame.height - (mouse.y - start.mouse.y))
            // AppKit's y axis points up, so keep the top edge where it was.
            window.setFrame(NSRect(x: start.frame.minX, y: start.frame.maxY - height, width: width, height: height),
                            display: true)
        }

        override func mouseUp(with event: NSEvent) {
            guard start != nil else { return }
            start = nil
            window?.invalidateShadow()
            onEnded?()
        }
    }
}
