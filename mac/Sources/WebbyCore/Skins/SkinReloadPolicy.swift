import Foundation

/// The hot-reload quiet period for edits to an installed skin folder.
public enum SkinReload {
    public static let quietPeriod: Duration = .milliseconds(250)

    /// A debouncer that runs `reload` once file events have been quiet for 250 ms.
    /// Call `schedule()` on every file event.
    @MainActor
    public static func makeDebouncer(
        sleep: @escaping AutosaveDebouncer.Sleep = { try await Task.sleep(for: $0) },
        reload: @escaping @MainActor () -> Void
    ) -> AutosaveDebouncer {
        AutosaveDebouncer(delay: quietPeriod, sleep: sleep, action: reload)
    }

    /// The outcome of reloading one skin folder.
    public struct Outcome: Sendable, Equatable {
        /// The skin to use now: the new one when accepted, else the previous one.
        public let skin: InstalledSkin?
        /// Diagnostics from the new load, to show in the skin's detail view.
        public let diagnostics: [SkinDiagnostic]
        public let usedNewLoad: Bool
    }

    /// Keeps the last good skin when an edit leaves the folder invalid.
    ///
    /// `fresh` is nil when the folder produced no skin at all (for example,
    /// unreadable JSON). The previous skin stays active in that case too.
    public static func keepLastGood(
        previous: InstalledSkin?,
        fresh: InstalledSkin?,
        diagnostics: [SkinDiagnostic]
    ) -> Outcome {
        if let fresh, fresh.isAccepted {
            return Outcome(skin: fresh, diagnostics: diagnostics, usedNewLoad: true)
        }
        return Outcome(skin: previous, diagnostics: diagnostics, usedNewLoad: false)
    }
}
