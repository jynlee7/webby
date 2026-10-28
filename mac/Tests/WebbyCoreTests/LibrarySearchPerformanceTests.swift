import Foundation
import Testing
@testable import WebbyCore

private func performanceID(_ index: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0001-%012d", index))!
}

private func performanceNote(_ index: Int) -> Note {
    let repeated = String(repeating: "synthetic body text for search performance ", count: 11)
    let text = "Note \(index) common\n\(repeated)unique-\(index)"
    return Note(
        id: performanceID(index),
        anchor: .web(
            page: PageURL(host: "example.com", path: "/note/\(index)"),
            scope: .page
        ),
        text: text,
        frame: NoteFrame(),
        placement: .window,
        createdAt: Date(timeIntervalSinceReferenceDate: 0),
        updatedAt: Date(timeIntervalSinceReferenceDate: Double(index))
    )
}

@Test func searchPerformanceOnTenThousandSyntheticNotes() {
    var notes = (0..<10_000).map(performanceNote)
    let workspaces = [
        WorkspaceRecord(
            id: performanceID(20_000),
            keys: [.host(name: "example.com")],
            createdAt: Date(timeIntervalSinceReferenceDate: 0)
        ),
    ]
    let clock = ContinuousClock()

    var cache = LibrarySearchCache()
    let rebuildDuration = clock.measure {
        cache = LibrarySearchCache(notes: notes)
    }

    var changed = notes[5_000]
    changed.text += " common updated"
    notes[5_000] = changed
    let updateDuration = clock.measure {
        cache.update(changed)
    }

    let scanQuery = SearchQuery.parse("unique-9999")
    _ = cache.search(scanQuery, notes: notes, workspaces: workspaces)
    var scanResult: [UUID] = []
    let scanDuration = clock.measure {
        scanResult = cache.search(scanQuery, notes: notes, workspaces: workspaces)
    }

    let sortedQuery = SearchQuery.parse("site:example.com common")
    _ = cache.search(sortedQuery, notes: notes, workspaces: workspaces)
    var sortedResult: [UUID] = []
    let sortedDuration = clock.measure {
        sortedResult = cache.search(sortedQuery, notes: notes, workspaces: workspaces)
    }

    print("Library search 10k rebuild: \(rebuildDuration)")
    print("Library search 10k one update: \(updateDuration)")
    print("Library search 10k warmed scan: \(scanDuration)")
    print("Library search 10k sorted search: \(sortedDuration)")

    #expect(cache.count == 10_000)
    #expect(scanResult == [performanceID(9_999)])
    #expect(sortedResult.count == 10_000)
}
