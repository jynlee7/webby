import Observation
import SwiftUI
import WebbyCore

/// The Library's local text draft. It is never an authoritative note copy: a commit
/// goes through `LibraryModel.updateText`, which forwards to the only store owner.
@MainActor @Observable
final class LibraryTextDraft {
    var text = ""
    private(set) var noteID: UUID?

    @ObservationIgnored private var committedText = ""
    @ObservationIgnored private var debounceTask: Task<Void, Never>?

    var isDirty: Bool { text != committedText }

    func load(note: Note?) {
        debounceTask?.cancel()
        noteID = note?.id
        text = note?.text ?? ""
        committedText = text
    }

    /// Commits the current draft and clears the pending debounce. A selection change
    /// must call this before it changes the model's selection.
    func commit(to model: LibraryModel) {
        debounceTask?.cancel()
        debounceTask = nil
        guard model.isWritable, let noteID else {
            committedText = text
            return
        }
        guard isDirty else { return }

        let value = text
        committedText = value
        model.updateText(id: noteID, text: value)
    }

    func scheduleCommit(to model: LibraryModel) {
        debounceTask?.cancel()
        guard isDirty else { return }

        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled, let self else { return }
            self.commit(to: model)
        }
    }
}

/// Human-readable scope and status used in both the note table and the detail pane.
enum LibraryNotePresentation {
    static func scopeDescription(_ anchor: WebbyCore.Anchor?) -> String {
        guard let anchor else { return "Inbox" }
        switch anchor {
        case let .app(bundleID):
            return "App: \(bundleID)"
        case let .web(page, scope):
            switch scope {
            case .page:
                return page.description
            case .prefix(let path):
                return "\(page.host)\(path) and below"
            case .site:
                return page.host
            }
        }
    }

    static func date(_ value: Date) -> Text {
        Text(value, format: .dateTime.year().month().day().hour().minute())
    }
}

struct LibraryDetailView: View {
    let model: LibraryModel
    let actions: LibraryAnchorActions
    let draft: LibraryTextDraft

    var body: some View {
        Group {
            if let note = model.selectedNote {
                NoteDetailContent(note: note, model: model, actions: actions, draft: draft)
                    .id(note.id)
            } else {
                ContentUnavailableView(
                    "No Note Selected",
                    systemImage: "note.text",
                    description: Text("Choose a note to read or edit it.")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private enum AnchorKind: String, CaseIterable, Hashable {
    case none
    case app
    case web
}

private enum WebScopeKind: String, CaseIterable, Hashable {
    case page
    case prefix
    case site
}

private enum AnchorValidation {
    case valid(WebbyCore.Anchor?)
    case invalid(String)
}

private enum WorkspaceChoice: Hashable {
    case automatic
    case record(UUID)
    case implicit(WorkspaceKey)

    static func from(_ destination: WorkspaceDestination) -> WorkspaceChoice {
        switch destination {
        case .inbox:
            return .automatic
        case let .record(id):
            return .record(id)
        case let .implicit(key):
            return .implicit(key)
        }
    }
}

private struct NoteDetailContent: View {
    let note: Note
    let model: LibraryModel
    let actions: LibraryAnchorActions
    let draft: LibraryTextDraft

    @State private var anchorKind: AnchorKind
    @State private var bundleID: String
    @State private var webURL: String
    @State private var webScopeKind: WebScopeKind
    @State private var prefixPath: String
    @State private var workspaceChoice: WorkspaceChoice
    @State private var validationMessage: String?
    @FocusState private var editorFocused: Bool

    init(note: Note, model: LibraryModel, actions: LibraryAnchorActions, draft: LibraryTextDraft) {
        self.note = note
        self.model = model
        self.actions = actions
        self.draft = draft

        if let anchor = note.anchor {
            switch anchor {
            case let .app(bundleID):
                _anchorKind = State(initialValue: .app)
                _bundleID = State(initialValue: bundleID)
                _webURL = State(initialValue: "")
                _webScopeKind = State(initialValue: .page)
                _prefixPath = State(initialValue: "")
            case let .web(page, scope):
                _anchorKind = State(initialValue: .web)
                _bundleID = State(initialValue: "")
                _webURL = State(initialValue: "https://\(page.description)")
                switch scope {
                case .page:
                    _webScopeKind = State(initialValue: .page)
                    _prefixPath = State(initialValue: "")
                case .prefix(let path):
                    _webScopeKind = State(initialValue: .prefix)
                    _prefixPath = State(initialValue: path)
                case .site:
                    _webScopeKind = State(initialValue: .site)
                    _prefixPath = State(initialValue: "")
                }
            }
        } else {
            _anchorKind = State(initialValue: .none)
            _bundleID = State(initialValue: "")
            _webURL = State(initialValue: "")
            _webScopeKind = State(initialValue: .page)
            _prefixPath = State(initialValue: "")
        }

        _workspaceChoice = State(
            initialValue: note.workspaceOverride.map(WorkspaceChoice.record) ?? .automatic
        )
    }

    /// Reloads the anchor editor from the saved note.
    private func loadAnchorFields() {
        validationMessage = nil
        switch note.anchor {
        case let .app(bundleID)?:
            anchorKind = .app
            self.bundleID = bundleID
            webURL = ""
            webScopeKind = .page
            prefixPath = ""
        case let .web(page, scope)?:
            anchorKind = .web
            bundleID = ""
            webURL = "https://\(page.description)"
            switch scope {
            case .page:
                webScopeKind = .page
                prefixPath = ""
            case .prefix(let path):
                webScopeKind = .prefix
                prefixPath = path
            case .site:
                webScopeKind = .site
                prefixPath = ""
            }
        case nil:
            anchorKind = .none
            bundleID = ""
            webURL = ""
            webScopeKind = .page
            prefixPath = ""
        }
    }

    private var isTrashed: Bool { note.trashedAt != nil }
    private var canEdit: Bool { model.isWritable && !isTrashed }
    private var tags: [LibraryTag] { Tags.parse(note.text) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                textEditor
                status
                toggles
                anchorEditor
                actionsRow
            }
            .padding(20)
        }
        .onAppear {
            if draft.noteID != note.id {
                draft.load(note: note)
            }
            loadAnchorFields()
        }
        .onChange(of: note.anchor) { _, _ in
            // Attach or an external edit replaced the saved anchor; the editor must
            // not keep showing stale fields that a later save would write back.
            loadAnchorFields()
        }
        .onChange(of: note.workspaceOverride) { _, override in
            workspaceChoice = override.map(WorkspaceChoice.record) ?? .automatic
        }
        .onChange(of: editorFocused) { _, focused in
            if !focused {
                draft.commit(to: model)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(note.summaryLine() ?? "Empty note")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)

            HStack(spacing: 8) {
                statusChip(LibraryNotePresentation.scopeDescription(note.anchor),
                           systemImage: note.anchor == nil ? "tray" : "link")
                if note.hidden {
                    statusChip("Hidden here", systemImage: "eye.slash")
                }
                if note.excludedFromAgent {
                    statusChip("Kept away from AI", systemImage: "hand.raised")
                }
                if isTrashed {
                    statusChip("In Trash", systemImage: "trash")
                }
            }

            if !tags.isEmpty {
                HStack(spacing: 6) {
                    ForEach(tags, id: \.searchKey) { tag in
                        Button("#\(tag.name)") {
                            draft.commit(to: model)
                            model.select(tag: tag)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                        .accessibilityLabel("Show notes tagged \(tag.name)")
                    }
                }
            }
        }
    }

    private var textEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: Binding(
                get: { draft.text },
                set: { draft.text = $0 }
            ))
            .font(.body)
            .frame(minHeight: 190)
            .padding(6)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.secondary.opacity(0.25))
            }
            .focused($editorFocused)
            .onChange(of: draft.text) { _, _ in
                draft.scheduleCommit(to: model)
            }
            .disabled(!canEdit)
            .accessibilityLabel("Note text")
            .accessibilityHint(isTrashed ? "Trashed notes are read-only." : "Edits save when you pause or leave the field.")

            HStack {
                if isTrashed || !model.isWritable {
                    Text(isTrashed ? "Trashed notes are read-only." : "Notes are read-only.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Save Note") {
                    draft.commit(to: model)
                }
                .disabled(!canEdit || !draft.isDirty)
                .keyboardShortcut("s", modifiers: .command)
            }
        }
    }

    private var status: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            GridRow {
                Text("Created").foregroundStyle(.secondary)
                LibraryNotePresentation.date(note.createdAt)
            }
            GridRow {
                Text("Updated").foregroundStyle(.secondary)
                LibraryNotePresentation.date(note.updatedAt)
            }
            GridRow {
                Text("Scope").foregroundStyle(.secondary)
                Text(LibraryNotePresentation.scopeDescription(note.anchor))
            }
            if let trashedAt = note.trashedAt {
                GridRow {
                    Text("Trashed").foregroundStyle(.secondary)
                    LibraryNotePresentation.date(trashedAt)
                }
            }
            if let problem = model.readOnlyProblem, !model.isWritable {
                GridRow {
                    Label("Read-only", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                    Text(problem)
                }
            }
        }
        .font(.callout)
        .accessibilityElement(children: .contain)
    }

    private var toggles: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Pinned", isOn: Binding(
                get: { note.pinnedAt != nil },
                set: { pinned in
                    draft.commit(to: model)
                    model.setPinned(id: note.id, pinned: pinned)
                }
            ))
            Toggle("Hidden here", isOn: Binding(
                get: { note.hidden },
                set: { hidden in
                    draft.commit(to: model)
                    model.setHidden(id: note.id, hidden: hidden)
                }
            ))
            Toggle("Keep away from AI", isOn: Binding(
                get: { note.excludedFromAgent },
                set: { excluded in
                    draft.commit(to: model)
                    model.setExcludedFromAgent(id: note.id, excluded: excluded)
                }
            ))
            Text("Pinned, hidden and AI settings do not change the note's revision.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .toggleStyle(.switch)
        .disabled(!canEdit)
    }

    private var anchorEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Anchor")
                .font(.headline)

            Picker("Anchor type", selection: $anchorKind) {
                Text("None").tag(AnchorKind.none)
                Text("Mac app").tag(AnchorKind.app)
                Text("Web page").tag(AnchorKind.web)
            }
            .pickerStyle(.segmented)
            .disabled(!canEdit)
            .accessibilityLabel("Anchor type")

            if anchorKind == .app {
                TextField("App bundle identifier, for example com.apple.Safari", text: $bundleID)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!canEdit)
                    .accessibilityLabel("App bundle identifier")

                let state = actions.appState(bundleID: trimmedBundleID)
                Label(appStateDescription(state), systemImage: appStateSymbol(state))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Reopen App") {
                    _ = actions.reopenApp(bundleID: trimmedBundleID)
                }
                .disabled(trimmedBundleID.isEmpty || !canEdit)
                .accessibilityHint("Activates or launches the anchored Mac app.")
            }

            if anchorKind == .web {
                TextField("Page URL", text: $webURL)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!canEdit)
                    .accessibilityLabel("Web page URL")

                Picker("Web scope", selection: $webScopeKind) {
                    Text("Exact page").tag(WebScopeKind.page)
                    Text("Path and below").tag(WebScopeKind.prefix)
                    Text("Whole site").tag(WebScopeKind.site)
                }
                .disabled(!canEdit)
                .accessibilityLabel("Web page scope")

                if webScopeKind == .prefix {
                    TextField("Path prefix, for example /docs", text: $prefixPath)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!canEdit)
                        .accessibilityLabel("Path prefix")
                }

                HStack(spacing: 10) {
                    Button("Reopen Web Page") {}
                        .disabled(true)
                        .accessibilityHint(LibraryAnchorActions.webUnavailableExplanation)
                    Button("Attach to Current Page") {}
                        .disabled(true)
                        .accessibilityHint(LibraryAnchorActions.webUnavailableExplanation)
                }
                Text(LibraryAnchorActions.webUnavailableExplanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Browser support is not available yet. \(LibraryAnchorActions.webUnavailableExplanation)")
            }

            Picker("Workspace", selection: $workspaceChoice) {
                Text("From anchor, otherwise Inbox").tag(WorkspaceChoice.automatic)
                ForEach(model.libraryResult.workspaces, id: \.destination) { group in
                    Text(model.displayName(for: group))
                        .tag(WorkspaceChoice.from(group.destination))
                }
            }
            .disabled(!canEdit)
            .accessibilityLabel("Workspace")

            if case .implicit = workspaceChoice {
                Text("An implicit workspace follows the note's app or page anchor. Choose an app or page to keep it there.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                if let validationMessage {
                    Label(validationMessage, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .accessibilityLabel("Anchor problem: \(validationMessage)")
                }
                Spacer()
                Button("Save Anchor") {
                    saveAnchor()
                }
                .disabled(!canEdit)
            }
        }
    }

    private var actionsRow: some View {
        HStack {
            if isTrashed {
                Button("Restore Note") {
                    draft.commit(to: model)
                    model.restore(id: note.id)
                }
                .disabled(!model.isWritable)
                .accessibilityHint("Moves this note out of Trash.")
            } else {
                Button("Move to Trash") {
                    draft.commit(to: model)
                    model.trash(id: note.id)
                }
                .disabled(!model.isWritable)
                .accessibilityHint("Moves this note to Trash. You can restore it later.")
            }

            Button("Attach to Current App") {
                let applied = actions.attachCurrentAppAnchor { anchor in
                    draft.commit(to: model)
                    model.attach(id: note.id, anchor: anchor, workspace: selectedWorkspaceID)
                }
                if !applied {
                    validationMessage = "Switch to the app you want first. Webby can't attach a note to itself."
                }
            }
            .disabled(!canEdit)
            .accessibilityHint("Attaches this note to the other app that is currently in front.")

            Button("Show at Anchor") {
                if let anchor = note.anchor, case let .app(bundleID) = anchor {
                    _ = actions.reopenApp(bundleID: bundleID)
                }
                if !actions.showAtAnchor(noteID: note.id) {
                    validationMessage = "Show at anchor is available for Mac app notes."
                }
            }
            .disabled(isTrashed || !isMacAnchored)
            .accessibilityHint("Shows this note as an overlay over its Mac app.")

            Spacer()
        }
    }

    private var trimmedBundleID: String {
        bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isMacAnchored: Bool {
        guard let anchor = note.anchor else { return false }
        if case .app = anchor { return true }
        return false
    }

    private var selectedWorkspaceID: UUID? {
        if case let .record(id) = workspaceChoice { return id }
        return nil
    }

    private func saveAnchor() {
        validationMessage = nil
        let result: AnchorValidation
        switch anchorKind {
        case .none:
            result = .valid(nil)
        case .app:
            guard !trimmedBundleID.isEmpty else {
                result = .invalid("Enter the app's bundle identifier.")
                apply(result)
                return
            }
            result = .valid(.app(bundleID: trimmedBundleID))
        case .web:
            result = validatedWebAnchor()
        }
        apply(result)
    }

    private func validatedWebAnchor() -> AnchorValidation {
        guard let page = PageURL(string: webURL, queryRules: model.effectiveQueryRules) else {
            return .invalid("Enter an http, https or file URL.")
        }

        switch webScopeKind {
        case .page:
            return .valid(.web(page: page, scope: .page))
        case .site:
            return .valid(.web(page: page, scope: .site))
        case .prefix:
            let path = PageURL(host: page.host, path: prefixPath).path
            return .valid(.web(page: page, scope: .prefix(path: path)))
        }
    }

    private func apply(_ result: AnchorValidation) {
        switch result {
        case .invalid(let message):
            validationMessage = message
        case .valid(let anchor):
            draft.commit(to: model)
            model.attach(id: note.id, anchor: anchor, workspace: selectedWorkspaceID)
        }
    }

    private func appStateDescription(_ state: LibraryAppAvailabilityState) -> String {
        switch state {
        case .missing:
            return "This app isn't installed. The note stays readable and can be reattached."
        case .installed:
            return "This app is installed but not running."
        case .running:
            return "This app is running."
        }
    }

    private func appStateSymbol(_ state: LibraryAppAvailabilityState) -> String {
        switch state {
        case .missing:
            return "questionmark.circle"
        case .installed:
            return "app.dashed"
        case .running:
            return "app"
        }
    }

    private func statusChip(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.quaternary, in: Capsule())
            .accessibilityLabel(title)
    }
}
