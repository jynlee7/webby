import Foundation

/// A global keyboard shortcut, stored in `settings.json` as text such as `"ctrl+opt+n"`.
///
/// Keys are identified by macOS virtual key codes, which name physical positions on
/// an ANSI keyboard, so the shortcut stays on the same key whatever the input source.
public struct KeyCombo: Hashable, Sendable, CustomStringConvertible {
    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let control = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let shift = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)
    }

    /// The canonical key name, for example `"n"`, `"5"`, `","`, `"space"` or `"f5"`.
    public let key: String
    public let keyCode: UInt16
    public let modifiers: Modifiers

    /// ⌃⌥N, the proposed default for New Note (plan §8.3, question 13).
    public static let defaultNewNote = KeyCombo(key: "n", keyCode: 0x2D, modifiers: [.control, .option])

    private init(key: String, keyCode: UInt16, modifiers: Modifiers) {
        self.key = key
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Parses `"ctrl+opt+n"`-style text. Modifier names are case-insensitive and may
    /// be spelled out (`control`, `option`, `alt`, `command`). Exactly one key is required.
    public init?(_ text: String) {
        var modifiers: Modifiers = []
        var key: Key?
        for token in text.lowercased().split(separator: "+", omittingEmptySubsequences: false) {
            let name = token.trimmingCharacters(in: .whitespaces)
            if let modifier = Self.modifierNames[name] {
                modifiers.insert(modifier)
            } else if key == nil, let found = Self.keys.first(where: { $0.name == name }) {
                key = found
            } else {
                return nil
            }
        }
        guard let key else { return nil }
        self.init(key: key.name, keyCode: key.code, modifiers: modifiers)
    }

    /// Creates a shortcut from a recorded key press. `nil` for keys Webby can't name.
    public init?(keyCode: UInt16, modifiers: Modifiers) {
        guard let key = Self.keys.first(where: { $0.code == keyCode }) else { return nil }
        self.init(key: key.name, keyCode: key.code, modifiers: modifiers)
    }

    /// The text stored in settings, with modifiers in a fixed order.
    public var storageString: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("opt") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.command) { parts.append("cmd") }
        parts.append(key)
        return parts.joined(separator: "+")
    }

    /// The shortcut as macOS menus show it, for example "⌃⌥N".
    public var displayString: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + (Self.keys.first { $0.name == key }?.display ?? key.uppercased())
    }

    public var description: String { displayString }

    /// A global shortcut needs ⌃, ⌥ or ⌘, unless it is a function key, so that it
    /// can't take over ordinary typing in every app.
    public var isUsableGlobally: Bool {
        !modifiers.isDisjoint(with: [.control, .option, .command]) || key.hasPrefix("f") && key.count > 1
    }

    private static let modifierNames: [String: Modifiers] = [
        "ctrl": .control, "control": .control, "⌃": .control,
        "opt": .option, "option": .option, "alt": .option, "⌥": .option,
        "shift": .shift, "⇧": .shift,
        "cmd": .command, "command": .command, "⌘": .command,
    ]

    private struct Key {
        let name: String
        let code: UInt16
        let display: String

        init(_ name: String, _ code: UInt16, _ display: String? = nil) {
            self.name = name
            self.code = code
            self.display = display ?? name.uppercased()
        }
    }

    /// Virtual key codes from HIToolbox's `Events.h` (`kVK_ANSI_*`, `kVK_*`).
    private static let keys: [Key] = [
        Key("a", 0x00), Key("s", 0x01), Key("d", 0x02), Key("f", 0x03), Key("h", 0x04),
        Key("g", 0x05), Key("z", 0x06), Key("x", 0x07), Key("c", 0x08), Key("v", 0x09),
        Key("b", 0x0B), Key("q", 0x0C), Key("w", 0x0D), Key("e", 0x0E), Key("r", 0x0F),
        Key("y", 0x10), Key("t", 0x11), Key("1", 0x12), Key("2", 0x13), Key("3", 0x14),
        Key("4", 0x15), Key("6", 0x16), Key("5", 0x17), Key("=", 0x18), Key("9", 0x19),
        Key("7", 0x1A), Key("-", 0x1B), Key("8", 0x1C), Key("0", 0x1D), Key("]", 0x1E),
        Key("o", 0x1F), Key("u", 0x20), Key("[", 0x21), Key("i", 0x22), Key("p", 0x23),
        Key("l", 0x25), Key("j", 0x26), Key("'", 0x27), Key("k", 0x28), Key(";", 0x29),
        Key("\\", 0x2A), Key(",", 0x2B), Key("/", 0x2C), Key("n", 0x2D), Key("m", 0x2E),
        Key(".", 0x2F), Key("`", 0x32),
        Key("return", 0x24, "↩"), Key("tab", 0x30, "⇥"), Key("space", 0x31, "Space"),
        Key("delete", 0x33, "⌫"),
        Key("f1", 0x7A), Key("f2", 0x78), Key("f3", 0x63), Key("f4", 0x76), Key("f5", 0x60),
        Key("f6", 0x61), Key("f7", 0x62), Key("f8", 0x64), Key("f9", 0x65), Key("f10", 0x6D),
        Key("f11", 0x67), Key("f12", 0x6F),
    ]
}
