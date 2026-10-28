import Foundation
import WebbyCore

func tabFixtureID(_ suffix: String) -> UUID {
    UUID(uuidString: "00000000-0000-0000-0000-000000000" + suffix)!
}

func tabFixtureDate(_ value: TimeInterval) -> Date {
    Date(timeIntervalSinceReferenceDate: value)
}

func tabFixtureBinding(
    browser: String = "com.google.Chrome",
    profile: String = "profile-a",
    session: String = "100@2026-01-01",
    tabID: Int = 1,
    windowID: Int = 1,
    index: Int = 0,
    lastURL: String = "https://example.com/a",
    lastTitle: String? = "Example",
    closedAt: Date? = nil,
    pendingRestore: Bool = false
) -> TabBinding {
    TabBinding(
        browser: browser,
        profile: profile,
        session: session,
        tabID: tabID,
        windowID: windowID,
        index: index,
        lastURL: lastURL,
        lastTitle: lastTitle,
        closedAt: closedAt,
        pendingRestore: pendingRestore
    )
}

func tabFixtureNote(
    id: UUID = UUID(),
    anchor: Anchor? = nil,
    tab: TabBinding? = nil,
    workspaceOverride: UUID? = nil,
    text: String = "note",
    source: NoteSource? = nil,
    hidden: Bool = false,
    trashedAt: Date? = nil,
    createdAt: Date = tabFixtureDate(0),
    updatedAt: Date? = nil,
    ephemeral: Bool = false
) -> Note {
    Note(
        id: id,
        anchor: anchor,
        tab: tab,
        workspaceOverride: workspaceOverride,
        text: text,
        source: source,
        frame: NoteFrame(),
        placement: .window,
        hidden: hidden,
        trashedAt: trashedAt,
        createdAt: createdAt,
        updatedAt: updatedAt ?? createdAt,
        ephemeral: ephemeral
    )
}

func tabFixtureWebAnchor(
    _ url: String,
    scope: WebScope = .page,
    rules: [QueryRule] = []
) -> Anchor? {
    guard let page = PageURL(string: url, queryRules: rules) else { return nil }
    return .web(page: page, scope: scope)
}

func tabFixtureTab(
    tabID: Int,
    index: Int,
    active: Bool = false,
    url: String? = nil,
    title: String? = nil
) -> LibraryInventoryTab {
    LibraryInventoryTab(tabID: tabID, index: index, active: active, url: url, title: title)
}

func tabFixtureWindow(
    browser: String = "com.google.Chrome",
    profile: String = "profile-a",
    session: String = "100@2026-01-01",
    appBundleID: String = "com.google.Chrome",
    windowID: Int = 1,
    order: Int = 0,
    focused: Bool = false,
    incognito: Bool = false,
    tabs: [LibraryInventoryTab]
) -> LibraryInventoryWindow {
    LibraryInventoryWindow(
        browser: browser,
        profile: profile,
        session: session,
        appBundleID: appBundleID,
        windowID: windowID,
        order: order,
        focused: focused,
        incognito: incognito,
        tabs: tabs
    )
}

func tabFixtureInventory(_ windows: [LibraryInventoryWindow]) -> LibraryInventory {
    LibraryInventory(windows: windows)
}

func tabFixtureNoteIDs(_ notes: [LibraryNote]) -> [String] {
    notes.map { $0.id.uuidString.suffix(3).lowercased() }
}

func tabFixtureIDs(_ notes: [Note]) -> [String] {
    notes.map { $0.id.uuidString.suffix(3).lowercased() }
}
