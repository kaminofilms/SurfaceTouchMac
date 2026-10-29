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
    public static let letters: [[Key]] = [
        [.ch("1", "!"), .ch("2", "@"), .ch("3", "#"), .ch("4", "$"), .ch("5", "%"),
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
        [Key("#+=", .switchLayer, width: 1.5), Key("esc", .special(.escape)),
         Key("space", .special(.space), width: 5.5),
         Key("←", .special(.left)), Key("↓", .special(.down)), Key("→", .special(.right)),
         Key("hide", .hide, width: 1.5)],
    ]

    public static let symbols: [[Key]] = [
        [.ch("1", "1"), .ch("2", "2"), .ch("3", "3"), .ch("4", "4"), .ch("5", "5"),
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
        [Key("abc", .switchLayer, width: 1.5), Key("esc", .special(.escape)),
         Key("space", .special(.space), width: 5.5),
         Key("←", .special(.left)), Key("↓", .special(.down)), Key("→", .special(.right)),
         Key("hide", .hide, width: 1.5)],
    ]

    public static func rows(for layer: Layer) -> [[Key]] {
        layer == .letters ? letters : symbols
    }

    /// Widest row in key units (used to size keys to the screen).
    public static func maxUnits(for layer: Layer) -> Double {
        rows(for: layer).map { $0.reduce(0) { $0 + $1.width } }.max() ?? 11
    }
}
