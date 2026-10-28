/// Pure rules for deciding whether a note belongs to a context and is shown.
public enum NoteVisibility {
    /// Whether the note belongs to the context, including hidden notes.
    public static func isAttached(_ note: Note, to context: Context) -> Bool {
        guard note.trashedAt == nil else { return false }

        if let binding = note.tab {
            return liveTabBindingMatches(binding, context: context)
        }

        guard let anchor = note.anchor else { return false }
        return anchor.matches(context)
    }

    private static func liveTabBindingMatches(_ binding: TabBinding, context: Context) -> Bool {
        binding.closedAt == nil && context.tab?.matches(binding) == true
    }

    /// Whether the note is attached to the context and not hidden by the user.
    public static func isVisible(_ note: Note, in context: Context) -> Bool {
        isAttached(note, to: context) && !note.hidden
    }
}
