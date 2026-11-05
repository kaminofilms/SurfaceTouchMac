// SPDX-License-Identifier: MIT
// Keyboard layout model for SurfaceTouchKeys.
// Adapted from TouchKeys (TouchDeck, MIT, (c) 2026 White Oak Media), reworked:
// characters are typed as Unicode (independent of the active input layout),
// added Caps Lock, Tab, Up/Down arrows, and fixed the shifted "?" key.

public enum KeyAction: Equatable, Sendable {
    /// Types `normal`, or `shifted` when Shift/Caps is active.
    case character(normal: String, shifted: String)
    /// A special key posted by virtual key code (layout independent keys).
    case special(SpecialKey)
    case shift
    case capsLock
    case switchLayer
    case hide
    /// ⌃ ⌥ ⌘: one-shot, applies to the next key (e.g. ⌘ then C = copy)
    case modifier(Modifier)
}

public enum Modifier: String, CaseIterable, Sendable {
    case control, option, command
}

public enum SpecialKey: UInt16, Sendable {
    // macOS virtual key codes (Carbon kVK_*)
    case returnKey = 36
    case tab = 48
    case space = 49
    case delete = 51
    case escape = 53
    case left = 123
    case right = 124
    case down = 125
    case up = 126

    public var isArrow: Bool { (123...126).contains(rawValue) }
    /// Keys that repeat while held.
    public var repeats: Bool { self == .delete || isArrow || self == .space }
}

public struct Key: Equatable, Sendable {
    public let label: String
    public let action: KeyAction
    public let width: Double     // relative width, 1.0 = standard key

    public init(_ label: String, _ action: KeyAction, width: Double = 1.0) {
        self.label = label
        self.action = action
        self.width = width
    }

    public static func ch(_ normal: String, _ shifted: String? = nil, width: Double = 1.0) -> Key {
        Key(normal, .character(normal: normal, shifted: shifted ?? normal.uppercased()), width: width)
    }

    public var repeats: Bool {
        if case .special(let s) = action { return s.repeats }
        return false
    }
}

public enum Layer: Sendable { case letters, symbols }

public enum Layouts {
    // Rows are 12.5 units wide (same as before, so key sizes are unchanged).
    static let bottomMods: [Key] = [
        Key("⌃", .modifier(.control)), Key("⌥", .modifier(.option)), Key("⌘", .modifier(.command), width: 1.25),
    ]

    public static let letters: [[Key]] = [
        [Key("esc", .special(.escape)),
         .ch("1", "!"), .ch("2", "@"), .ch("3", "#"), .ch("4", "$"), .ch("5", "%"),
         .ch("6", "^"), .ch("7", "&"), .ch("8", "*"), .ch("9", "("), .ch("0", ")"),
         Key("⌫", .special(.delete), width: 1.5)],
        [Key("tab", .special(.tab), width: 1.5),
         .ch("q"), .ch("w"), .ch("e"), .ch("r"), .ch("t"), .ch("y"), .ch("u"), .ch("i"), .ch("o"), .ch("p")],
        [Key("caps", .capsLock, width: 1.75),
         .ch("a"), .ch("s"), .ch("d"), .ch("f"), .ch("g"), .ch("h"), .ch("j"), .ch("k"), .ch("l"),
         Key("return", .special(.returnKey), width: 1.75)],
        [Key("⇧", .shift, width: 1.5),
         .ch("z"), .ch("x"), .ch("c"), .ch("v"), .ch("b"), .ch("n"), .ch("m"),
         .ch(",", "<"), .ch(".", ">"), .ch("/", "?"), Key("↑", .special(.up))],
        [Key("#+=", .switchLayer, width: 1.25)] + bottomMods +
        [Key("space", .special(.space), width: 4),
         Key("←", .special(.left)), Key("↓", .special(.down)), Key("→", .special(.right)),
         Key("hide", .hide)],
    ]

    public static let symbols: [[Key]] = [
        [Key("esc", .special(.escape)),
         .ch("1", "1"), .ch("2", "2"), .ch("3", "3"), .ch("4", "4"), .ch("5", "5"),
         .ch("6", "6"), .ch("7", "7"), .ch("8", "8"), .ch("9", "9"), .ch("0", "0"),
         Key("⌫", .special(.delete), width: 1.5)],
        [Key("tab", .special(.tab), width: 1.5),
         .ch("!", "!"), .ch("@", "@"), .ch("#", "#"), .ch("$", "$"), .ch("%", "%"),
         .ch("^", "^"), .ch("&", "&"), .ch("*", "*"), .ch("(", "("), .ch(")", ")")],
        [Key("caps", .capsLock, width: 1.75),
         .ch("-", "-"), .ch("=", "="), .ch("[", "["), .ch("]", "]"), .ch("\\", "\\"),
         .ch(";", ";"), .ch("'", "'"), .ch("`", "`"), .ch("€", "€"),
         Key("return", .special(.returnKey), width: 1.75)],
        [Key("⇧", .shift, width: 1.5),
         .ch("_", "_"), .ch("+", "+"), .ch("{", "{"), .ch("}", "}"), .ch("|", "|"),
         .ch(":", ":"), .ch("\"", "\""), .ch("~", "~"), .ch("<", "<"), .ch(">", ">"),
         Key("↑", .special(.up))],
        [Key("abc", .switchLayer, width: 1.25)] + bottomMods +
        [Key("space", .special(.space), width: 4),
         Key("←", .special(.left)), Key("↓", .special(.down)), Key("→", .special(.right)),
         Key("hide", .hide)],
    ]

    public static func rows(for layer: Layer) -> [[Key]] {
        layer == .letters ? letters : symbols
    }

    /// Widest row in key units (used to size keys to the screen).
    public static func maxUnits(for layer: Layer) -> Double {
        rows(for: layer).map { $0.reduce(0) { $0 + $1.width } }.max() ?? 11
    }
}

/// US (ANSI) virtual key codes, used only for shortcuts such as ⌘C, where
/// apps look at the physical key rather than the typed character.
public enum KeyCodes {
    static let base: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19,
        "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28,
        "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38,
        "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50,
    ]
    static let shifted: [Character: Character] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8",
        "(": "9", ")": "0", "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";",
        "\"": "'", "<": ",", ">": ".", "?": "/", "~": "`",
    ]

    /// Key code for a typed character and whether Shift is part of it.
    public static func lookup(_ text: String) -> (code: UInt16, shift: Bool)? {
        guard text.count == 1, let ch = text.first else { return nil }
        if let c = base[ch] { return (c, false) }
        if ch.isUppercase, let lower = ch.lowercased().first, let c = base[lower] { return (c, true) }
        if let b = shifted[ch], let c = base[b] { return (c, true) }
        return nil
    }
}
