import Foundation
import Testing
@testable import WebbyCore

private let visibilityDate = Date(timeIntervalSinceReferenceDate: 123_456.789)

private func visibilityPage(_ url: String) throws -> PageURL {
    try #require(PageURL(string: url))
}

private func visibilityContext(
    app: String = "com.google.Chrome",
    page: PageURL? = nil,
    tab: TabRef? = nil
) -> Context {
    Context(appBundleID: app, page: page, tab: tab)
}

private func visibilityTab(
    browser: String = "com.google.Chrome",
    profile: String = "profile-a",
    session: String = "123@2026-01-01",
    tabID: Int = 7,
    windowID: Int = 2
) -> TabRef {
    TabRef(browser: browser, profile: profile, session: session, tabID: tabID, windowID: windowID)
}

private func visibilityBinding(
    browser: String = "com.google.Chrome",
    profile: String = "profile-a",
    session: String = "123@2026-01-01",
    tabID: Int = 7,
    windowID: Int = 2,
    closedAt: Date? = nil,
    pendingRestore: Bool = false
) -> TabBinding {
    TabBinding(
        browser: browser,
        profile: profile,
        session: session,
        tabID: tabID,
        windowID: windowID,
        index: 0,
        lastURL: "https://example.com/a",
        lastTitle: "Example",
        closedAt: closedAt,
        pendingRestore: pendingRestore
    )
}

private func visibilityNote(
    anchor: Anchor? = nil,
    tab: TabBinding? = nil,
    hidden: Bool = false,
    trashedAt: Date? = nil,
    collapsed: Bool = false,
    pinnedAt: Date? = nil,
    appearance: NoteAppearance? = nil,
    excludedFromAgent: Bool = false,
    placement: Placement = .window,
    ephemeral: Bool = false,
    workspaceOverride: UUID? = nil,
    source: NoteSource? = nil
) -> Note {
    Note(
        anchor: anchor,
        tab: tab,
        workspaceOverride: workspaceOverride,
        text: "visibility",
        source: source,
        frame: NoteFrame(x: 1, y: 2, width: 300, height: 200),
        placement: placement,
        collapsed: collapsed,
        hidden: hidden,
        pinnedAt: pinnedAt,
        trashedAt: trashedAt,
        excludedFromAgent: excludedFromAgent,
        appearance: appearance,
        createdAt: visibilityDate,
        updatedAt: visibilityDate,
        ephemeral: ephemeral
    )
}

@Test func anchoredAppNotesAttachByBundleIDEvenWhenAPageIsKnown() {
    let anchor = Anchor.app(bundleID: "com.apple.TextEdit")
    let note = visibilityNote(anchor: anchor)

    #expect(NoteVisibility.isAttached(note, to: visibilityContext(app: "com.apple.TextEdit")))
    #expect(NoteVisibility.isVisible(note, in: visibilityContext(app: "com.apple.TextEdit")))
    #expect(NoteVisibility.isAttached(
        note,
        to: visibilityContext(
            app: "com.apple.TextEdit",
            page: PageURL(host: "example.com", path: "/a"),
            tab: visibilityTab()
        )
    ))

    #expect(!NoteVisibility.isAttached(note, to: visibilityContext(app: "com.apple.Safari")))
    #expect(!NoteVisibility.isVisible(note, in: visibilityContext(app: "com.apple.Safari")))
}

@Test func anchoredWebNotesFollowPagePrefixAndSiteScopes() throws {
    let pageNote = visibilityNote(anchor: .web(
        page: try visibilityPage("https://example.com/docs"),
        scope: .page
    ))
    #expect(NoteVisibility.isAttached(pageNote, to: visibilityContext(
        page: try visibilityPage("https://example.com/docs/")
    )))
    #expect(!NoteVisibility.isAttached(pageNote, to: visibilityContext(
        page: try visibilityPage("https://example.com/docs/extra")
    )))
    #expect(!NoteVisibility.isAttached(pageNote, to: visibilityContext(
        page: try visibilityPage("https://example.com/other")
    )))
    #expect(!NoteVisibility.isAttached(pageNote, to: visibilityContext(
        page: try visibilityPage("https://other.example.com/docs")
    )))

    let prefixNote = visibilityNote(anchor: .web(
        page: try visibilityPage("https://example.com/docs"),
        scope: .prefix(path: "/docs")
    ))
    #expect(NoteVisibility.isAttached(prefixNote, to: visibilityContext(
        page: try visibilityPage("https://example.com/docs")
    )))
    #expect(NoteVisibility.isAttached(prefixNote, to: visibilityContext(
        page: try visibilityPage("https://example.com/docs/guide")
    )))
    #expect(!NoteVisibility.isAttached(prefixNote, to: visibilityContext(
        page: try visibilityPage("https://example.com/docs-other")
    )))
    #expect(!NoteVisibility.isAttached(prefixNote, to: visibilityContext(
        page: try visibilityPage("https://other.example.com/docs")
    )))

    let siteNote = visibilityNote(anchor: .web(
        page: try visibilityPage("https://example.com/start"),
        scope: .site
    ))
    #expect(NoteVisibility.isAttached(siteNote, to: visibilityContext(
        page: try visibilityPage("https://example.com/any/path")
    )))
    #expect(!NoteVisibility.isAttached(siteNote, to: visibilityContext(
        page: try visibilityPage("https://sub.example.com/any/path")
    )))
}

@Test func anchoredWebNotesNeedAKnownPage() {
    let note = visibilityNote(anchor: .web(
        page: PageURL(host: "example.com", path: "/a"),
        scope: .page
    ))

    #expect(!NoteVisibility.isAttached(note, to: visibilityContext()))
    #expect(!NoteVisibility.isAttached(
        note,
        to: visibilityContext(tab: visibilityTab())
    ))
}

@Test func pageQueriesMatchWhenTheAnchorQueryIsASubset() {
    let partial = visibilityNote(anchor: .web(
        page: PageURL(host: "youtube.com", path: "/watch", query: "v=a"),
        scope: .page
    ))
    #expect(NoteVisibility.isAttached(partial, to: visibilityContext(
        page: PageURL(host: "youtube.com", path: "/watch", query: "v=a&t=9")
    )))
    #expect(!NoteVisibility.isAttached(partial, to: visibilityContext(
        page: PageURL(host: "youtube.com", path: "/watch", query: "v=b")
    )))
    #expect(!NoteVisibility.isAttached(partial, to: visibilityContext(
        page: PageURL(host: "youtube.com", path: "/watch", query: "t=9")
    )))

    let multiKey = visibilityNote(anchor: .web(
        page: PageURL(host: "example.com", path: "/watch", query: "t=9&v=a"),
        scope: .page
    ))
    #expect(NoteVisibility.isAttached(multiKey, to: visibilityContext(
        page: PageURL(host: "example.com", path: "/watch", query: "extra=1&v=a&t=9")
    )))
    #expect(!NoteVisibility.isAttached(multiKey, to: visibilityContext(
        page: PageURL(host: "example.com", path: "/watch", query: "v=a")
    )))
}

@Test func migratedNilQueryAnchorsStillMatchEveryCurrentQuery() {
    let note = visibilityNote(anchor: .web(
        page: PageURL(host: "youtube.com", path: "/watch", query: nil),
        scope: .page
    ))

    #expect(NoteVisibility.isAttached(note, to: visibilityContext(
        page: PageURL(host: "youtube.com", path: "/watch", query: nil)
    )))
    #expect(NoteVisibility.isAttached(note, to: visibilityContext(
        page: PageURL(host: "youtube.com", path: "/watch", query: "v=a")
    )))
    #expect(NoteVisibility.isAttached(note, to: visibilityContext(
        page: PageURL(host: "youtube.com", path: "/watch", query: "v=b&t=10")
    )))
    #expect(!NoteVisibility.isAttached(note, to: visibilityContext(
        page: PageURL(host: "youtube.com", path: "/other", query: "v=a")
    )))
}

@Test func tabBindingsMatchEveryIdentityFieldExceptWindow() {
    let note = visibilityNote(tab: visibilityBinding())

    #expect(NoteVisibility.isAttached(note, to: visibilityContext(tab: visibilityTab())))
    #expect(NoteVisibility.isAttached(note, to: visibilityContext(tab: visibilityTab(windowID: 99))))

    #expect(!NoteVisibility.isAttached(note, to: visibilityContext(
        tab: visibilityTab(browser: "com.microsoft.edgemac")
    )))
    #expect(!NoteVisibility.isAttached(note, to: visibilityContext(
        tab: visibilityTab(profile: "profile-b")
    )))
    #expect(!NoteVisibility.isAttached(note, to: visibilityContext(
        tab: visibilityTab(session: "456@2026-02-02")
    )))
    #expect(!NoteVisibility.isAttached(note, to: visibilityContext(
        tab: visibilityTab(tabID: 8)
    )))
}

@Test func tabBindingsFollowNavigationAndTakePrecedenceOverTheAnchor() throws {
    let note = visibilityNote(
        anchor: .web(page: try visibilityPage("https://example.com/a"), scope: .page),
        tab: visibilityBinding()
    )

    #expect(NoteVisibility.isAttached(note, to: visibilityContext(
        page: try visibilityPage("https://other.example/b"),
        tab: visibilityTab()
    )))
    #expect(NoteVisibility.isAttached(note, to: visibilityContext(tab: visibilityTab())))

    let contradictory = visibilityNote(
        anchor: .app(bundleID: "com.example.other"),
        tab: visibilityBinding()
    )
    #expect(NoteVisibility.isAttached(contradictory, to: visibilityContext(
        app: "com.apple.TextEdit",
        tab: visibilityTab()
    )))
}

@Test func tabBindingsRequireAReportedMatchingTabAndDoNotFallBackToTheAnchor() throws {
    let note = visibilityNote(
        anchor: .web(page: try visibilityPage("https://example.com/a"), scope: .page),
        tab: visibilityBinding()
    )

    #expect(!NoteVisibility.isAttached(note, to: visibilityContext(
        page: try visibilityPage("https://example.com/a")
    )))
    #expect(!NoteVisibility.isAttached(note, to: visibilityContext(
        page: try visibilityPage("https://example.com/a"),
        tab: visibilityTab(tabID: 8)
    )))
    #expect(!NoteVisibility.isVisible(note, in: visibilityContext(
        page: try visibilityPage("https://example.com/a")
    )))
}

@Test func closedTabBindingsNeverAttachAndPendingRestoreDoesNotChangeThat() throws {
    let open = visibilityNote(tab: visibilityBinding())
    let openPending = visibilityNote(tab: visibilityBinding(pendingRestore: true))
    let closed = visibilityNote(tab: visibilityBinding(closedAt: visibilityDate))
    let closedPending = visibilityNote(tab: visibilityBinding(
        closedAt: visibilityDate,
        pendingRestore: true
    ))
    let context = visibilityContext(tab: visibilityTab())

    #expect(NoteVisibility.isAttached(open, to: context))
    #expect(NoteVisibility.isAttached(openPending, to: context))
    #expect(!NoteVisibility.isAttached(closed, to: context))
    #expect(!NoteVisibility.isAttached(closedPending, to: context))
    #expect(!NoteVisibility.isVisible(closedPending, in: context))

    let closedWithMatchingAnchor = visibilityNote(
        anchor: .web(page: try visibilityPage("https://example.com/a"), scope: .page),
        tab: visibilityBinding(closedAt: visibilityDate)
    )
    #expect(!NoteVisibility.isAttached(closedWithMatchingAnchor, to: visibilityContext(
        page: try visibilityPage("https://example.com/a"),
        tab: visibilityTab()
    )))
}

@Test func hiddenNotesStayAttachedButAreNotVisible() {
    let anchored = visibilityNote(
        anchor: .app(bundleID: "com.apple.TextEdit"),
        hidden: true
    )
    let appContext = visibilityContext(app: "com.apple.TextEdit")
    #expect(NoteVisibility.isAttached(anchored, to: appContext))
    #expect(!NoteVisibility.isVisible(anchored, in: appContext))

    let tabbed = visibilityNote(tab: visibilityBinding(), hidden: true)
    let tabContext = visibilityContext(tab: visibilityTab())
    #expect(NoteVisibility.isAttached(tabbed, to: tabContext))
    #expect(!NoteVisibility.isVisible(tabbed, in: tabContext))
}

@Test func trashedNotesAreNeitherAttachedNorVisible() throws {
    let anchored = visibilityNote(
        anchor: .web(page: try visibilityPage("https://example.com/a"), scope: .page),
        trashedAt: visibilityDate
    )
    let anchoredContext = visibilityContext(page: try visibilityPage("https://example.com/a"))
    #expect(!NoteVisibility.isAttached(anchored, to: anchoredContext))
    #expect(!NoteVisibility.isVisible(anchored, in: anchoredContext))

    let tabbed = visibilityNote(tab: visibilityBinding(), trashedAt: visibilityDate)
    let tabContext = visibilityContext(tab: visibilityTab())
    #expect(!NoteVisibility.isAttached(tabbed, to: tabContext))
    #expect(!NoteVisibility.isVisible(tabbed, in: tabContext))

    let both = visibilityNote(
        anchor: .web(page: try visibilityPage("https://example.com/a"), scope: .page),
        tab: visibilityBinding(),
        hidden: false,
        trashedAt: visibilityDate
    )
    #expect(!NoteVisibility.isAttached(both, to: visibilityContext(
        page: try visibilityPage("https://example.com/a"),
        tab: visibilityTab()
    )))
}

@Test func unrelatedFlagsDoNotAffectAttachmentOrVisibility() {
    let flags = [
        (collapsed: true, pinned: true, appearance: true, excluded: true, screen: true, ephemeral: true),
        (collapsed: false, pinned: false, appearance: false, excluded: false, screen: false, ephemeral: false),
    ]

    for flag in flags {
        let anchored = visibilityNote(
            anchor: .app(bundleID: "com.apple.TextEdit"),
            collapsed: flag.collapsed,
            pinnedAt: flag.pinned ? visibilityDate : nil,
            appearance: flag.appearance ? NoteAppearance(paletteIndex: 2, hideDecoration: true) : nil,
            excludedFromAgent: flag.excluded,
            placement: flag.screen ? .screen : .window,
            ephemeral: flag.ephemeral,
            workspaceOverride: UUID(),
            source: NoteSource(url: "https://example.com/a", title: "Example")
        )
        let appContext = visibilityContext(app: "com.apple.TextEdit")
        #expect(NoteVisibility.isAttached(anchored, to: appContext))
        #expect(NoteVisibility.isVisible(anchored, in: appContext))

        let tabbed = visibilityNote(
            tab: visibilityBinding(pendingRestore: flag.pinned),
            collapsed: flag.collapsed,
            pinnedAt: flag.pinned ? visibilityDate : nil,
            appearance: flag.appearance ? NoteAppearance(paletteIndex: 2, hideDecoration: true) : nil,
            excludedFromAgent: flag.excluded,
            placement: flag.screen ? .screen : .window,
            ephemeral: flag.ephemeral,
            workspaceOverride: UUID(),
            source: NoteSource(url: "https://example.com/a", title: "Example")
        )
        let tabContext = visibilityContext(tab: visibilityTab())
        #expect(NoteVisibility.isAttached(tabbed, to: tabContext))
        #expect(NoteVisibility.isVisible(tabbed, in: tabContext))
    }
}

@Test func inboxAndWorkspaceOnlyNotesAreUnattached() {
    let inbox = visibilityNote()
    let workspaceOnly = visibilityNote(workspaceOverride: UUID())

    for note in [inbox, workspaceOnly] {
        #expect(!NoteVisibility.isAttached(note, to: visibilityContext(app: "com.apple.TextEdit")))
        #expect(!NoteVisibility.isAttached(note, to: visibilityContext(
            page: PageURL(host: "example.com", path: "/a")
        )))
        #expect(!NoteVisibility.isAttached(note, to: visibilityContext(tab: visibilityTab())))
        #expect(!NoteVisibility.isVisible(note, in: visibilityContext(tab: visibilityTab())))
    }
}
