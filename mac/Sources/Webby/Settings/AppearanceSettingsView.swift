import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebbyCore

/// Settings → Appearance: choose the global skin and manage the skins on disk.
struct AppearanceSettingsView: View {
    let store: SkinStore
    let importSkin: @MainActor () -> Void

    private static let defaultSkinID = "webby.clear"

    @State private var selection: String?
    @State private var errorMessage: String?
    @State private var confirmingRemoval = false

    private var selectedRow: SkinRow? {
        store.rows.first { $0.id == selection }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Skin for all notes").font(.headline)
            List(store.rows, selection: $selection) { row in
                SkinRowView(row: row, isChosen: chosenID == row.id) { choose(row) }
            }
            .frame(height: 220)
            .border(Color(nsColor: .separatorColor))
            .accessibilityLabel("Skins")

            if let notice = store.notice {
                Label(notice, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
            }

            HStack {
                Button("Import Skin…") { importSkin() }
                Button("Export…", action: export).disabled(selectedRow == nil)
                Button("Duplicate to Edit", action: duplicate).disabled(selectedRow == nil)
                Button("Reveal Skins Folder", action: Self.revealSkinsFolder(store, report: report))
                Spacer()
                Button("Remove…") { confirmingRemoval = true }
                    .disabled(selectedRow?.isUserSkin != true)
            }

            Text("Each workspace can have its own skin, chosen in the Library (not built yet). A note uses its workspace's skin, else the skin above, else Webby Clear.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 520)
        .confirmationDialog(
            "Remove “\(selectedRow?.name ?? "")”?",
            isPresented: $confirmingRemoval
        ) {
            Button("Remove", role: .destructive, action: remove)
        } message: {
            Text("The skin's folder is deleted. Notes that use it fall back to the default look.")
        }
        .alert("Skin problem", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    /// The skin notes use by default: the saved choice, else Webby Clear.
    private var chosenID: String {
        store.globalSkinID ?? Self.defaultSkinID
    }

    private func report(_ error: Error) {
        errorMessage = SkinErrorText.message(for: error)
    }

    private func choose(_ row: SkinRow) {
        do {
            try store.setGlobalSkinID(row.id == Self.defaultSkinID ? nil : row.id)
        } catch {
            report(error)
        }
    }

    private func export() {
        guard let row = selectedRow else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = SkinImporter.skinTypes
        panel.nameFieldStringValue = "\(row.id).webbyskin"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.exportArchive(skinID: row.id, to: url)
        } catch {
            report(error)
        }
    }

    private func duplicate() {
        guard let row = selectedRow else { return }
        do {
            let id = try store.duplicate(skinID: row.id)
            let manifest = try store.skinsFolderURL
                .appendingPathComponent(id, isDirectory: true)
                .appendingPathComponent("skin.json")
            NSWorkspace.shared.activateFileViewerSelecting([manifest])
            selection = id
        } catch {
            report(error)
        }
    }

    private func remove() {
        guard let row = selectedRow else { return }
        do {
            try store.remove(skinID: row.id)
            selection = nil
        } catch {
            report(error)
        }
    }

    /// The Reveal Skins Folder action, shared with the status menu.
    static func revealSkinsFolder(_ store: SkinStore, report: @escaping (Error) -> Void) -> () -> Void {
        {
            do {
                NSWorkspace.shared.activateFileViewerSelecting([try store.skinsFolderURL])
            } catch {
                report(error)
            }
        }
    }
}

private struct SkinRowView: View {
    let row: SkinRow
    let isChosen: Bool
    let choose: () -> Void

    @State private var showingIssues = false

    private var hasIssues: Bool { !row.diagnostics.isEmpty || row.usingLastGood }
    private var canChoose: Bool { row.isAccepted || row.usingLastGood }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: choose) {
                Image(systemName: isChosen ? "largecircle.fill.circle" : "circle")
            }
            .buttonStyle(.plain)
            .disabled(!canChoose)
            .accessibilityLabel("Use \(row.name) for all notes")
            .accessibilityValue(isChosen ? "Selected" : "Not selected")

            VStack(alignment: .leading, spacing: 1) {
                Text(row.name)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if hasIssues {
                Button { showingIssues.toggle() } label: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
                .help("This skin has problems")
                .accessibilityLabel("Show problems with \(row.name)")
                .popover(isPresented: $showingIssues) { issues }
            }
        }
        .padding(.vertical, 2)
    }

    private var detail: String {
        let origin = row.isUserSkin ? "Installed" : "Built in"
        return row.author.isEmpty ? origin : "\(row.author) · \(origin)"
    }

    private var issues: some View {
        VStack(alignment: .leading, spacing: 6) {
            if row.usingLastGood {
                Text("The skin on disk has errors, so the last good version is in use.").fontWeight(.medium)
            }
            ForEach(Array(row.diagnostics.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 0) {
                    Text(item.message)
                    Text(item.jsonPath).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: 360, alignment: .leading)
    }
}
