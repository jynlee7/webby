import AppKit
import SwiftUI
import WebbyAgent
import WebbyCore

/// The agent panel's window: a floating, non-activating panel like a note, so the
/// page the question is about stays frontmost while the user types.
@MainActor
final class AgentPanelController: NSObject, NSWindowDelegate {
    let controller: AgentController
    private let panel: NotePanel
    private var themes: NoteThemes

    init(controller: AgentController, themes: NoteThemes) {
        self.controller = controller
        self.themes = themes
        panel = NotePanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 560))
        super.init()
        panel.styleMask.insert(.resizable)
        panel.minSize = NSSize(width: 360, height: 320)
        panel.title = "Ask Webby"
        panel.delegate = self
        render()
    }

    func updateThemes(_ themes: NoteThemes) {
        self.themes = themes
        render()
    }

    private func render() {
        let hosting = FirstMouseHostingView(rootView: AgentPanelRoot(model: controller, themes: themes, close: { [weak self] in self?.close() }))
        hosting.sizingOptions = []
        panel.contentView = hosting
    }

    var isVisible: Bool { panel.isVisible }

    func show() {
        if !panel.isVisible {
            if let screen = NSScreen.main?.visibleFrame {
                panel.setFrameOrigin(NSPoint(x: screen.maxX - panel.frame.width - 24, y: screen.maxY - panel.frame.height - 24))
            }
        }
        panel.makeKeyAndOrderFront(nil)
    }

    func toggle() {
        if panel.isVisible && panel.isKeyWindow { close() } else { show() }
    }

    func close() {
        panel.orderOut(nil)
    }
}

private struct AgentPanelRoot: View {
    let model: AgentController
    let themes: NoteThemes
    let close: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        AgentPanelView(model: model, close: close)
            .environment(\.webbyTheme, themes.theme(for: scheme))
    }
}

/// The panel follows the moodboard's Clear Glass rules (design.md): the global skin's
/// surface, text on frost, mono pill chips, no motion while text streams, and a dim
/// key legend at the foot (Graphite direction).
struct AgentPanelView: View {
    @Bindable var model: AgentController
    let close: () -> Void
    @Environment(\.webbyTheme) private var theme

    private var surface: ResolvedSurface { theme.surface }
    private var ink: Color { Color(surface.text) }
    private var meta: Color { Color(surface.text).opacity(0.72) }
    private var chipFill: Color { Color(surface.text).opacity(0.07) }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: surface.cornerRadius, style: .continuous) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(ink.opacity(0.12)).frame(height: 1)
            transcript
            if let prompt = model.scopePrompt { scopePrompt(prompt) }
            if model.needsKey { keyNotice }
            if let problem = model.storageProblem {
                Label(problem, systemImage: "externaldrive.badge.exclamationmark")
                    .font(.callout)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            questionBox
        }
        .foregroundStyle(ink)
        .background {
            ZStack {
                if let material = surface.material.visualEffectMaterial {
                    VisualEffectBackground(material: material, cornerRadius: surface.cornerRadius)
                }
                Color(surface.fill)
            }
        }
        .overlay {
            if surface.border.width > 0 {
                shape.strokeBorder(Color(surface.border.color), lineWidth: surface.border.width)
            }
        }
        .clipShape(shape)
        .onExitCommand(perform: close)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            statusGlyph
            Menu {
                Button("This workspace") { model.setScope(.workspace) }
                Button("All notes") { model.setScope(.allNotes) }
            } label: {
                Text(model.scope == .allNotes ? "ALL NOTES" : "WORKSPACE · \(model.scopeTitle)")
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(chipFill))
            .disabled(model.isRunning)
            .accessibilityLabel("Scope: \(model.scope == .allNotes ? "All notes" : model.scopeTitle)")
            .accessibilityHint("Choosing another scope starts a new conversation.")

            // The drag area's NSView is flexible in both directions; pin its height so
            // the header stays one row and the transcript gets the space.
            WindowDragArea()
                .accessibilityHidden(true)
                .frame(maxWidth: .infinity)
                .frame(height: 28)

            iconButton("square.and.pencil", label: "New conversation") { model.newConversation() }
                .disabled(model.isRunning || !model.hasConversation)
            iconButton("xmark", label: "Close", action: close)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// A compact legend of agent states: a spinner while working, an amber mark when
    /// the panel needs the user, a check when the answer is done.
    @ViewBuilder private var statusGlyph: some View {
        if model.isRunning {
            ProgressView().controlSize(.small).accessibilityLabel("Answering")
        } else if model.scopePrompt != nil || model.needsKey || model.turns.last?.isRetryable == true {
            Image(systemName: "exclamationmark.circle").foregroundStyle(.orange).accessibilityLabel("Needs you")
        } else if model.hasConversation {
            Image(systemName: "checkmark.circle").foregroundStyle(meta).accessibilityLabel("Done")
        } else {
            Image(systemName: "circle.dotted").foregroundStyle(meta).accessibilityHidden(true)
        }
    }

    private func iconButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 22, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color(theme.icons.tint))
        .accessibilityLabel(label)
        .help(label)
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if model.turns.isEmpty {
                        Text("Ask about the notes in this workspace. Answers cite the notes they used.")
                            .font(.callout)
                            .foregroundStyle(meta)
                    }
                    ForEach(model.turns) { turn in
                        AgentTurnRow(model: model, turn: turn, meta: meta, chipFill: chipFill)
                            .id(turn.id)
                    }
                    if let activity = model.activity {
                        Text(activity).font(.callout).foregroundStyle(meta)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: model.turns.last?.answer) {
                if let id = model.turns.last?.id { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
    }

    private func scopePrompt(_ prompt: AgentController.ScopePrompt) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("This conversation is about \(prompt.conversationTitle). You're now in \(prompt.currentTitle).")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("New conversation for \(prompt.currentTitle)") { model.resolveScopePrompt(.newConversation) }
                    .keyboardShortcut(.defaultAction)
                Button("Keep \(prompt.conversationTitle)") { model.resolveScopePrompt(.keepConversation) }
                Button("Cancel") { model.resolveScopePrompt(.cancel) }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(chipFill)
    }

    private var keyNotice: some View {
        HStack {
            Text("Add your Anthropic key in Settings to ask about your notes. Your notes are unaffected.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Open Settings") { model.openSettings() }
        }
        .padding(12)
        .background(chipFill)
    }

    // MARK: Question

    private var questionBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Ask about your notes", text: $model.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(theme.typography.swiftUIFont)
                    .lineLimit(1...5)
                    .onSubmit { model.ask() }
                    .disabled(model.isRunning)
                    .accessibilityLabel("Question")
                if model.isRunning {
                    Button("Stop") { model.cancel() }
                } else {
                    Button("Ask") { model.ask() }
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(chipFill))

            Text("↩ ask · esc close")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(meta)
                .accessibilityHidden(true)
        }
        .padding(12)
    }
}

private struct AgentTurnRow: View {
    let model: AgentController
    let turn: AgentTurnView
    let meta: Color
    let chipFill: Color
    @Environment(\.webbyTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @State private var showsManifest = false

    /// Warning text: design.md's orange text colour (#B8410E) in light mode, which
    /// keeps the contrast floor that plain orange misses; system orange on dark.
    private var warning: Color {
        scheme == .dark ? .orange : Color(red: 0xB8 / 255, green: 0x41 / 255, blue: 0x0E / 255)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(turn.question)
                .font(.system(size: 13, weight: .semibold))
                .textSelection(.enabled)
            if !turn.answer.isEmpty {
                Text(turn.answer)
                    .font(theme.typography.swiftUIFont)
                    .lineSpacing(6)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            statusLine
            let chips = model.chips(for: turn)
            if !chips.isEmpty {
                AgentFlowLayout(spacing: 6) {
                    ForEach(chips) { chip in chipView(chip) }
                }
            }
            if turn.status != .streaming { actions }
            if showsManifest { manifest }
        }
    }

    @ViewBuilder private var statusLine: some View {
        switch turn.status {
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(warning)
        case .refused:
            Label("The model declined this request.", systemImage: "hand.raised").font(.callout).foregroundStyle(warning)
        case .truncated:
            Label("The answer was cut off.", systemImage: "scissors").font(.callout).foregroundStyle(meta)
        case .streaming, .complete:
            EmptyView()
        }
    }

    private func chipView(_ chip: AgentCitationChip) -> some View {
        Button {
            model.open(chip)
        } label: {
            HStack(spacing: 5) {
                Text(chip.alias).fontWeight(.semibold).fixedSize()
                Text(chip.snippet).lineLimit(1).truncationMode(.tail)
                if let label = chip.mark.label {
                    // The mark outranks the snippet, so truncation never hides it.
                    Text("· \(label)")
                        .foregroundStyle(chip.mark == .current ? meta : warning)
                        .fixedSize()
                        .layoutPriority(1)
                }
            }
            .font(.system(size: 11, design: .monospaced))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(chipFill))
        }
        .buttonStyle(.plain)
        .disabled(!chip.canOpen)
        .accessibilityLabel("Source \(chip.alias): \(chip.snippet)\(chip.mark.label.map { ", \($0)" } ?? "")")
        .accessibilityHint(chip.canOpen ? "Opens the note in the Library." : "")
        .help(chip.canOpen ? "Open in the Library" : "This note was deleted")
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Button(showsManifest ? "Hide what the agent saw" : "What the agent saw") { showsManifest.toggle() }
            if turn.savedNoteID != nil {
                Text("Saved as note").foregroundStyle(meta)
            } else {
                Button("Save as note") { model.saveAsNote(turn.id) }
                    .disabled(!model.canSave(turn))
            }
            if turn.id == model.turns.last?.id, turn.isRetryable {
                Button("Retry") { model.retry() }.disabled(model.isRunning)
            }
        }
        .buttonStyle(.link)
        .font(.callout)
    }

    /// Rows use a mono caps eyebrow over the note's first line (Graphite Library rows).
    private var manifest: some View {
        VStack(alignment: .leading, spacing: 8) {
            if turn.manifest.entries.isEmpty {
                Text("No notes were in scope.").font(.callout).foregroundStyle(meta)
            }
            ForEach(turn.manifest.entries, id: \.alias) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(entry.alias) · \(entry.status.rawValue.uppercased()) · REV \(entry.revision) · \(entry.updated)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(meta)
                    Text(entry.summary).font(.callout).lineLimit(2)
                    Text(entry.page).font(.caption).foregroundStyle(meta).lineLimit(1)
                }
            }
            Text(turn.manifest.screen.captured ? "Screen: captured" : "Screen: not captured")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(meta)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(chipFill))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("What the agent saw")
    }
}

/// Wraps chips onto as many lines as they need.
struct AgentFlowLayout: Layout {
    var spacing: CGFloat

    /// A chip is never measured wider than the row, so a long snippet truncates in
    /// the chip instead of pushing its edited or excluded mark out of view.
    private func size(of subview: LayoutSubview, maxWidth: CGFloat) -> CGSize {
        let natural = subview.sizeThatFits(.unspecified)
        guard natural.width > maxWidth, maxWidth.isFinite else { return natural }
        return subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = size(of: subview, maxWidth: width)
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: min(maxX, width), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = size(of: subview, maxWidth: bounds.width)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
