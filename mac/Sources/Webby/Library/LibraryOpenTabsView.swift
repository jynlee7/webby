import SwiftUI
import WebbyCore

/// The Open Tabs section: each open tab that has notes, with those notes beneath it.
struct LibraryOpenTabsView: View {
    let groups: [LibraryOpenTabGroup]
    @Binding var selection: Set<UUID>

    var body: some View {
        if groups.isEmpty {
            ContentUnavailableView {
                Label("No Open Tabs With Notes", systemImage: "rectangle.on.rectangle")
            } description: {
                Text("Chrome tabs that have notes appear here while they are open.")
            }
        } else {
            List(selection: $selection) {
                ForEach(groups, id: \.tab) { group in
                    Section {
                        ForEach(group.notes, id: \.id) { item in
                            HStack(spacing: 8) {
                                Image(systemName: item.note.pinnedAt != nil ? "pin" : "note.text")
                                    .foregroundStyle(.secondary)
                                    .accessibilityHidden(true)
                                Text(item.note.summaryLine() ?? "Empty note")
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                Text(LibraryNotePresentation.scopeDescription(item.note.anchor))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .tag(item.id)
                            .accessibilityElement(children: .combine)
                        }
                    } header: {
                        header(for: group)
                    }
                }
            }
        }
    }

    private func header(for group: LibraryOpenTabGroup) -> some View {
        let title = Self.title(for: group)
        return HStack(spacing: 6) {
            Image(systemName: group.active ? "rectangle.fill.on.rectangle.fill" : "rectangle.on.rectangle")
                .accessibilityHidden(true)
            Text(title)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title)\(group.active ? ", active tab" : "")")
    }

    /// The tab's title, or its URL when Chrome has not reported a title.
    static func title(for group: LibraryOpenTabGroup) -> String {
        if let title = group.title, !title.isEmpty { return title }
        if let url = group.url, !url.isEmpty { return url }
        return "Untitled tab"
    }
}
