import Foundation

/// Why a pending binding was or wasn't re-attached after a Chrome restart.
public enum RestoreOutcome: Equatable, Sendable {
    case rebound
    /// More than one open tab had the URL, or another old tab claimed the same one.
    case ambiguous
    case unmatched
}

/// Re-attaches notes after Chrome restarts with session restore (plan §5.1.4).
///
/// Tab IDs don't survive a restart, so the only evidence is the exact URL. Notes of one
/// old tab move together, and only when the match is one-to-one: exactly one open tab
/// has the URL and no other old tab claims it. Anything else stays in Closed tabs; a
/// note is never deleted or guessed onto a tab.
public enum TabRestore {
    public struct Result: Equatable, Sendable {
        public var updates: [TabBindingUpdate] = []
        public var outcomes: [UUID: RestoreOutcome] = [:]
    }

    private struct Group: Hashable {
        let session: String
        let tabID: Int
        let lastURL: String
    }

    private struct Candidate: Hashable {
        let windowID: Int
        let tabID: Int
        let index: Int
        let title: String?
    }

    /// Evaluates every pending binding of `profile` from an earlier run against the open,
    /// non-incognito tabs of `session`. The URL comparison is exact after stripping the
    /// fragment; the query is kept.
    public static func evaluate(notes: [Note], profile: String, session: String, inventory: LibraryInventory) -> Result {
        var result = Result()
        guard session != OpenTabsInventory.unknownSession else { return result }

        var groups: [Group: [Note]] = [:]
        for note in notes {
            guard let binding = note.tab, binding.browser == OpenTabsInventory.bundleID,
                  binding.profile == profile, binding.closedAt != nil, binding.pendingRestore,
                  binding.session != session else { continue }
            groups[Group(session: binding.session, tabID: binding.tabID, lastURL: binding.lastURL), default: []].append(note)
        }
        guard !groups.isEmpty else { return result }

        var openTabs: [(url: String, candidate: Candidate)] = []
        for window in inventory.windows where window.browser == OpenTabsInventory.bundleID
            && window.profile == profile && window.session == session && !window.incognito {
            for tab in window.tabs {
                guard let url = tab.url else { continue }
                openTabs.append((TabBindingReconciler.strippingFragment(url),
                                 Candidate(windowID: window.windowID, tabID: tab.tabID, index: tab.index, title: tab.title)))
            }
        }

        var candidates: [Group: [Candidate]] = [:]
        var claims: [Int: Int] = [:]
        for group in groups.keys {
            let matching = openTabs.filter { $0.url == group.lastURL }.map(\.candidate)
            candidates[group] = matching
            for candidate in matching { claims[candidate.tabID, default: 0] += 1 }
        }

        for (group, members) in groups {
            let matching = candidates[group] ?? []
            let outcome: RestoreOutcome
            if matching.count == 1, let match = matching.first, claims[match.tabID] == 1 {
                outcome = .rebound
                for note in members {
                    guard var binding = note.tab else { continue }
                    binding.session = session
                    binding.tabID = match.tabID
                    binding.windowID = match.windowID
                    binding.index = match.index
                    if let title = match.title, !title.isEmpty { binding.lastTitle = title }
                    binding.closedAt = nil
                    binding.pendingRestore = true
                    result.updates.append(TabBindingUpdate(noteID: note.id, binding: binding))
                }
            } else {
                outcome = matching.isEmpty ? .unmatched : .ambiguous
                for note in members {
                    guard var binding = note.tab else { continue }
                    binding.pendingRestore = false
                    result.updates.append(TabBindingUpdate(noteID: note.id, binding: binding))
                }
            }
            for note in members { result.outcomes[note.id] = outcome }
        }
        result.updates.sort { $0.noteID.uuidString < $1.noteID.uuidString }
        return result
    }
}

/// Decides when a profile's restore check runs. Session restore opens windows and
/// tabs over several seconds, and restored tabs can start with an empty URL, so the
/// check waits for a quiet period after the profile's first `hello` of a Chrome run,
/// up to a cap, and runs once per profile and run.
public struct RestoreSchedule: Sendable {
    public static let quietPeriod: TimeInterval = 3
    public static let cap: TimeInterval = 30

    private struct Pending: Sendable {
        let started: Date
        var lastActivity: Date
    }

    private var session: String?
    private var pending: [String: Pending] = [:]
    private var evaluated: Set<String> = []

    public init() {}

    /// The running Chrome changed: every profile may be checked again.
    public mutating func setSession(_ session: String?) {
        guard self.session != session else { return }
        self.session = session
        pending.removeAll()
        evaluated.removeAll()
    }

    /// A profile said hello. Starts its wait unless it already ran in this session.
    public mutating func hello(profile: String, now: Date) {
        guard session != nil, session != OpenTabsInventory.unknownSession,
              !evaluated.contains(profile), pending[profile] == nil else { return }
        pending[profile] = Pending(started: now, lastActivity: now)
    }

    /// Tabs were created or the open tabs changed for `profile`: restore isn't settled.
    public mutating func activity(profile: String, now: Date) {
        pending[profile]?.lastActivity = now
    }

    /// The profiles whose check is due at `now`, which are then marked as run.
    public mutating func takeDue(now: Date) -> [String] {
        let due = pending.filter { _, wait in
            now.timeIntervalSince(wait.lastActivity) >= Self.quietPeriod
                || now.timeIntervalSince(wait.started) >= Self.cap
        }.keys.sorted()
        for profile in due {
            pending[profile] = nil
            evaluated.insert(profile)
        }
        return due
    }

    /// When the next check could become due, for scheduling a timer.
    public var nextDeadline: Date? {
        pending.values.map { min($0.lastActivity.addingTimeInterval(Self.quietPeriod), $0.started.addingTimeInterval(Self.cap)) }.min()
    }
}
