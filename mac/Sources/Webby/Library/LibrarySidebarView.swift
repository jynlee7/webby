import SwiftUI
import WebbyCore

private enum SidebarItem: Hashable {
    case section(LibrarySection)
    case workspace(WorkspaceDestination)
    case page(LibraryPageSelection)
    case tag(String)
}

private struct PageRow: Identifiable {
    let selection: LibraryPageSelection
    let title: String
    let depth: Int

    var id: LibraryPageSelection { selection }
}

struct LibrarySidebarView: View {
    let model: LibraryModel
    let draft: LibraryTextDraft

    var body: some View {
        List(selection: sidebarSelection) {
            Section("Library") {
                sectionRow(.inbox, title: "Inbox", symbol: "tray")
                sectionRow(.pinned, title: "Pinned", symbol: "pin")
                sectionRow(.recent, title: "Recent", symbol: "clock")
                sectionRow(.all, title: "All Notes", symbol: "square.grid.2x2")
                if model.sidebarCounts[.closedTabs, default: 0] > 0 {
                    sectionRow(.closedTabs, title: "Closed Tabs", symbol: "xmark.rectangle")
                }
            }

            Section("Workspaces") {
                row(
                    item: .section(.workspaces),
                    title: "All Workspaces",
                    symbol: "rectangle.3.group",
                    count: model.sidebarCounts[.workspaces, default: 0]
                )

                ForEach(model.libraryResult.workspaces, id: \.destination) { group in
                    row(
                        item: .workspace(group.destination),
                        title: model.displayName(for: group),
                        symbol: group.pinned ? "pin" : "folder",
                        count: group.count
                    )
                }
            }

            if model.selectedSection == .workspaces, model.selectedWorkspace != nil, !pageRows.isEmpty {
                Section("Pages") {
                    ForEach(pageRows) { page in
                        HStack(spacing: 6) {
                            Image(systemName: pageSymbol(page.selection))
                                .foregroundStyle(.secondary)
                                .frame(width: 16)
                                .accessibilityHidden(true)
                            Text(page.title)
                                .lineLimit(1)
                        }
                        .padding(.leading, CGFloat(page.depth) * 12)
                        .tag(SidebarItem.page(page.selection))
                        .accessibilityLabel(page.title)
                    }
                }
            }

            if !model.libraryResult.tags.isEmpty {
                Section("Tags") {
                    ForEach(model.libraryResult.tags, id: \.searchKey) { group in
                        row(
                            item: .tag(group.searchKey),
                            title: "#\(group.name)",
                            symbol: "tag",
                            count: group.count
                        )
                    }
                }
            }

            Section {
                row(
                    item: .section(.trash),
                    title: "Trash",
                    symbol: "trash",
                    count: model.sidebarCounts[.trash]
                )
            }
        }
        .listStyle(.sidebar)
        .accessibilityLabel("Library sections")
    }

    private var sidebarSelection: Binding<SidebarItem?> {
        Binding(
            get: { currentSelection },
            set: { newValue in
                guard let newValue else { return }
                draft.commit(to: model)
                switch newValue {
                case .section(.workspaces):
                    model.select(workspace: nil)
                case let .section(section):
                    model.select(section: section)
                case let .workspace(destination):
                    model.select(workspace: destination)
                case let .page(page):
                    model.select(page: page)
                case let .tag(key):
                    model.select(tagKey: key)
                }
            }
        )
    }

    private var currentSelection: SidebarItem? {
        switch model.selectedSection {
        case .workspaces:
            if let workspace = model.selectedWorkspace {
                if model.selectedPage != .all {
                    return .page(model.selectedPage)
                }
                return .workspace(workspace)
            }
            return .section(.workspaces)
        case .tags:
            if let key = model.selectedTagKey {
                return .tag(key)
            }
            return .section(.tags)
        case let section:
            return .section(section)
        }
    }

    private var pageRows: [PageRow] {
        guard let tree = model.pageTree else { return [] }
        var rows: [PageRow] = [
            PageRow(selection: .all, title: "All pages", depth: 0),
        ]
        if !tree.notAttached.isEmpty {
            rows.append(PageRow(selection: .notAttached, title: "Not attached", depth: 0))
        }
        for host in tree.hosts {
            rows.append(PageRow(selection: .site(host: host.host), title: host.host, depth: 0))
            appendRows(from: host.root, host: host.host, depth: 1, to: &rows)
        }
        return rows
    }

    private func appendRows(
        from node: PageTreeNode,
        host: String,
        depth: Int,
        to rows: inout [PageRow]
    ) {
        if !node.path.isEmpty, !node.prefixNotes.isEmpty {
            rows.append(PageRow(
                selection: .prefix(host: host, path: node.path),
                title: "\(node.segment) and below",
                depth: depth
            ))
        }

        for exact in node.exactPages {
            let title = exact.page.path.isEmpty
                ? "/"
                : exact.page.path + (exact.page.query.map { "?\($0)" } ?? "")
            rows.append(PageRow(selection: .page(exact.page), title: title, depth: depth))
        }

        for child in node.children {
            appendRows(from: child, host: host, depth: depth + 1, to: &rows)
        }
    }

    private func sectionRow(
        _ section: LibrarySection,
        title: String,
        symbol: String
    ) -> some View {
        row(
            item: .section(section),
            title: title,
            symbol: symbol,
            count: model.sidebarCounts[section, default: 0]
        )
    }

    private func row(
        item: SidebarItem,
        title: String,
        symbol: String,
        count: Int
    ) -> some View {
        HStack(spacing: 8) {
            Label(title, systemImage: symbol)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text("\(count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .tag(item)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(count) \(count == 1 ? "note" : "notes")")
    }

    private func pageSymbol(_ selection: LibraryPageSelection) -> String {
        switch selection {
        case .all:
            return "doc.on.doc"
        case .notAttached:
            return "tray"
        case .site:
            return "globe"
        case .prefix:
            return "folder"
        case .page:
            return "doc.text"
        }
    }
}
