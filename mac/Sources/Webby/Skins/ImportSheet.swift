import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebbyCore
import WebbySkinArchive

/// Plain-language text for the errors the skin library and importer throw.
enum SkinErrorText {
    static func message(for error: Error) -> String {
        switch error {
        case let error as SkinArchiveError: message(for: error)
        case let error as SkinLibraryError: message(for: error)
        default: error.localizedDescription
        }
    }

    private static func message(for error: SkinArchiveError) -> String {
        switch error {
        case .archiveTooLarge(_, let limit): "The archive is larger than the \(size(limit)) limit."
        case .malformedArchive(let reason), .archiveOpenFailed(let reason): "The file isn't a valid skin archive (\(reason))."
        case .zip64Unsupported, .multiDiskUnsupported: "The archive uses a ZIP feature that skins can't use."
        case .entryCountExceeded(_, let limit): "The archive has more than \(limit) files."
        case .declaredSizeExceeded(let path, _, let limit):
            "\(path ?? "The archive") is larger than the \(size(limit)) limit."
        case .decompressedSizeExceeded(let path, _, let limit): "\(path) expands past the \(size(limit)) limit."
        case .unsupportedCompression(_, let path): "\(path) uses an unsupported compression method."
        case .encryptedEntry(let path): "\(path) is encrypted."
        case .unsupportedEntryType(let path, let reason), .rejectedEntry(let path, let reason):
            "\(path) isn't allowed in a skin (\(reason))."
        case .unsafeEntryPath(let path, let reason): "The entry “\(path)” has an unsafe path (\(reason))."
        case .duplicateEntry(let path): "The archive contains \(path) more than once."
        case .collidingEntry(let path, let existing): "\(path) collides with \(existing)."
        case .ambiguousWrapper: "The archive has more than one top-level folder."
        case .archiveEntryMismatch(_, let reason): "The archive is inconsistent (\(reason))."
        case .destinationExists(let path): "\(path) already exists."
        case .extractionFailed(let path, let reason): "Couldn't unpack \(path) (\(reason))."
        case .crcMismatch(let path, _, _): "\(path) is damaged."
        case .cleanupFailed(_, let reason, let underlying): "\(message(for: underlying)) (\(reason))"
        case .exportSourceRejected(let reason): "This skin can't be exported (\(reason))."
        case .exportFailed(let path, let reason): "Couldn't write \(path) (\(reason))."
        case .manifestMissing: "The archive has no skin.json."
        }
    }

    private static func message(for error: SkinLibraryError) -> String {
        switch error {
        case .invalidID(let id): "“\(id)” isn't a valid skin id."
        case .reservedID(let id): "The id “\(id)” is reserved for skins built into Webby."
        case .manifestMissing: "The skin has no skin.json."
        case .manifestUnreadable: "The skin's skin.json can't be read."
        case .idMismatch(let expected, let found): "The skin declares the id “\(found ?? "none")”, not “\(expected)”."
        case .notFound(let id): "There is no skin named \(id)."
        case .operationFailed(let reason): reason
        }
    }

    private static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// Opens `.webbyskin` files one at a time in a preview window. Nothing is installed
/// until the user confirms, and every staged folder is removed when its window closes,
/// is cancelled, or the app quits.
@MainActor
final class SkinImporter {
    /// The document type declared in Info.plist, with the extension as a fallback.
    static var skinTypes: [UTType] {
        [UTType("io.github.jynlee7.webby.skin") ?? UTType(filenameExtension: "webbyskin")].compactMap { $0 }
    }

    private let store: SkinStore
    private var queue: [URL] = []
    private var window: ImportWindowController?
    private var staging = false

    init(store: SkinStore) {
        self.store = store
    }

    /// Asks for archives with an open panel, then previews them.
    func chooseFiles() {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.title = "Import Skin"
        panel.prompt = "Preview"
        panel.allowedContentTypes = Self.skinTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        enqueue(panel.urls)
    }

    func enqueue(_ urls: [URL]) {
        queue.append(contentsOf: urls)
        startNext()
    }

    /// Removes the staged folder of an open preview and drops the queue.
    func discardAll() {
        queue.removeAll()
        window?.discardIfOpen()
    }

    private func startNext() {
        guard window == nil, !staging, !queue.isEmpty else { return }
        let url = queue.removeFirst()
        staging = true
        Task {
            defer { staging = false }
            do {
                let preview = try await store.stageArchive(at: url)
                present(preview, from: url)
            } catch {
                NSApp.activate()
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "“\(url.lastPathComponent)” can't be imported"
                alert.informativeText = SkinErrorText.message(for: error)
                alert.runModal()
                startNext()
            }
        }
    }

    private func present(_ preview: StagedSkinPreview, from url: URL) {
        let controller = ImportWindowController(store: store, preview: preview, fileName: url.lastPathComponent)
        controller.onFinish = { [weak self] in
            self?.window = nil
            self?.startNext()
        }
        window = controller
        controller.present()
    }
}

@MainActor
final class ImportWindowController: NSWindowController, NSWindowDelegate {
    var onFinish: (@MainActor () -> Void)?

    private let store: SkinStore
    private let preview: StagedSkinPreview
    private var installed = false
    private var finished = false

    init(store: SkinStore, preview: StagedSkinPreview, fileName: String) {
        self.store = store
        self.preview = preview

        var themes: NoteThemes?
        var replaces = false
        var provider: SkinAssetCache.FolderProvider = { _ in nil }
        if let id = preview.manifest?.id {
            provider = store.assetFolderProvider(staging: id, at: preview.root)
            themes = store.previewThemes(for: preview)
            replaces = store.replacesInstalledSkin(id: id)
        }
        let assets = SkinAssetCache(folder: provider)
        let model = ImportPreviewModel(preview: preview, fileName: fileName, themes: themes ?? .fallback, assets: assets, replaces: replaces)
        let hosting = NSHostingController(rootView: ImportPreviewView(model: model))
        hosting.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: hosting)
        window.title = "Import Skin"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace]
        super.init(window: window)
        window.delegate = self
        window.center()
        model.install = { [weak self] in self?.install() }
        model.cancel = { [weak self] in self?.window?.close() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func present() {
        NSApp.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Removes the staged folder without waiting for the user, for app termination.
    func discardIfOpen() {
        finish()
    }

    private func install() {
        do {
            try store.install(preview)
            installed = true
            window?.close()
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Couldn't install the skin"
            alert.informativeText = SkinErrorText.message(for: error)
            alert.runModal()
        }
    }

    func windowWillClose(_ notification: Notification) {
        finish()
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        // After an install the staged folder was moved, and discard is a no-op.
        store.discard(preview)
        onFinish?()
    }
}

@MainActor @Observable
final class ImportPreviewModel {
    let preview: StagedSkinPreview
    let fileName: String
    let themes: NoteThemes
    let assets: SkinAssetCache
    let replaces: Bool
    let lightNote: NoteModel
    let darkNote: NoteModel
    @ObservationIgnored var install: @MainActor () -> Void = {}
    @ObservationIgnored var cancel: @MainActor () -> Void = {}

    init(preview: StagedSkinPreview, fileName: String, themes: NoteThemes, assets: SkinAssetCache, replaces: Bool) {
        self.preview = preview
        self.fileName = fileName
        self.themes = themes
        self.assets = assets
        self.replaces = replaces
        let text = "Sample note\nPick up the dry cleaning, then call Sam about Friday."
        lightNote = NoteModel(id: UUID(), text: text, collapsed: false, isEditable: false, themes: themes)
        darkNote = NoteModel(id: UUID(), text: text, collapsed: false, isEditable: false, themes: themes)
    }

    /// Whether the sample shows the staged skin rather than the default look it falls
    /// back to when the skin is rejected.
    var showsStagedSkin: Bool {
        themes.effectiveSkinID == preview.manifest?.id
    }

    var contrast: [(AppearanceMode, [ContrastPair])] {
        [(.light, ContrastReport.pairs(theme: themes.light, appearance: .light)),
         (.dark, ContrastReport.pairs(theme: themes.dark, appearance: .dark))]
    }
}

private struct ImportPreviewView: View {
    let model: ImportPreviewModel

    private static let samples: [(ColorScheme, String, Color)] = [
        (.light, "Light", Color(white: 0.92)),
        (.dark, "Dark", Color(white: 0.16)),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            HStack(spacing: 12) {
                ForEach(Self.samples, id: \.1) { scheme, label, backdrop in
                    VStack(spacing: 4) {
                        NoteRootView(model: scheme == .dark ? model.darkNote : model.lightNote, assets: model.assets)
                            .frame(width: 270, height: 170)
                            .padding(10)
                            .background(backdrop, in: RoundedRectangle(cornerRadius: 8))
                            .environment(\.colorScheme, scheme)
                        Text(label).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Sample note in light and dark appearance")
            if !model.showsStagedSkin {
                Text("This skin has problems, so the sample shows the default look.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    diagnostics
                    contrast
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 170)
            footer
        }
        .padding(20)
        .frame(width: 600)
    }

    private var header: some View {
        let manifest = model.preview.manifest
        return VStack(alignment: .leading, spacing: 2) {
            Text(manifest?.name ?? model.fileName).font(.title2.bold())
            if let manifest {
                Text("by \(manifest.author) · version \(manifest.version)").foregroundStyle(.secondary)
                Text(manifest.id).font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }

    private static func title(_ severity: SkinDiagnostic.Severity) -> String {
        switch severity {
        case .fatal: "Errors"
        case .groupError: "Problems"
        case .warning: "Warnings"
        }
    }

    private static func symbol(_ severity: SkinDiagnostic.Severity) -> String {
        severity == .warning ? "exclamationmark.triangle" : "xmark.octagon"
    }

    @ViewBuilder
    private var diagnostics: some View {
        let all = model.preview.diagnostics
        if all.isEmpty {
            Label("No problems found.", systemImage: "checkmark.circle").foregroundStyle(.secondary)
        }
        ForEach(SkinDiagnostic.Severity.allCases, id: \.self) { severity in
            let items = all.filter { $0.severity == severity }
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(Self.title(severity)).font(.headline)
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        Label {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(item.message)
                                Text(item.jsonPath).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: Self.symbol(severity))
                        }
                        .textSelection(.enabled)
                    }
                }
            }
        }
    }

    private var contrast: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Contrast").font(.headline)
            ForEach(model.contrast, id: \.0) { mode, pairs in
                ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
                    HStack {
                        Text("\(mode == .dark ? "Dark" : "Light"): \(Self.fillName(pair.fill))")
                        Spacer()
                        Text(String(format: "%.1f:1 (needs %.1f:1)", pair.measuredRatio, pair.requiredRatio))
                            .monospacedDigit().foregroundStyle(.secondary)
                        Label(pair.passes ? "Pass" : "Fail", systemImage: pair.passes ? "checkmark.circle" : "xmark.circle")
                            .foregroundStyle(pair.passes ? Color.green : Color.red)
                            .frame(width: 70, alignment: .leading)
                    }
                }
            }
        }
    }

    private static func fillName(_ fill: ContrastPair.Fill) -> String {
        switch fill {
        case .surface: "text on surface"
        case .palette(let index): "text on color \(index + 1)"
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Size: \(ByteCountFormatter.string(fromByteCount: Int64(model.preview.payloadBytes), countStyle: .file))")
                .foregroundStyle(.secondary)
            if model.replaces {
                Label("A skin with this id is already installed. Installing replaces it.", systemImage: "arrow.triangle.2.circlepath")
            }
            HStack {
                Spacer()
                Button("Cancel", action: model.cancel).keyboardShortcut(.cancelAction)
                Button("Install", action: model.install)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.preview.isAccepted)
            }
        }
    }
}
