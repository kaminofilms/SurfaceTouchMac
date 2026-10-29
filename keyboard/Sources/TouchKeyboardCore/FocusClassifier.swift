// SPDX-License-Identifier: MIT
// Decides whether a focused accessibility element accepts typed text.
// Only the element's role, subrole and attribute *names* are inspected —
// never its value, so typed text and passwords are not read.

public struct FocusInfo: Equatable, Sendable {
    public var role: String?
    public var subrole: String?
    public var attributeNames: [String]
    public var isEditableFlag: Bool?        // AXEditable (web content)
    public var isOwnProcess: Bool

    public init(role: String?, subrole: String? = nil, attributeNames: [String] = [],
                isEditableFlag: Bool? = nil, isOwnProcess: Bool = false) {
        self.role = role
        self.subrole = subrole
        self.attributeNames = attributeNames
        self.isEditableFlag = isEditableFlag
        self.isOwnProcess = isOwnProcess
    }
}

public enum FocusDecision: Equatable, Sendable {
    case text          // show keyboard
    case notText       // hide (after debounce)
    case ownPanel      // focus is on our own keyboard: keep current state
}

public enum FocusClassifier {
    public static let textRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXSearchField", "AXComboBox",
    ]
    public static let secureSubrole = "AXSecureTextField"

    /// Roles that are never text inputs even if they expose a selection range.
    /// (Same exclusion list TouchKeys uses in practice.)
    static let nonInputRoles: Set<String> = [
        "AXStaticText", "AXWindow", "AXApplication", "AXWebArea",
    ]

    public static func classify(_ info: FocusInfo) -> FocusDecision {
        if info.isOwnProcess { return .ownPanel }
        guard let role = info.role else { return .notText }
        if textRoles.contains(role) { return .text }
        if info.subrole == secureSubrole { return .text }
        if nonInputRoles.contains(role) { return .notText }
        // Browsers / web views / custom editors: editable content exposes an
        // insertion point through AXSelectedTextRange, or sets AXEditable.
        if info.isEditableFlag == true { return .text }
        if info.attributeNames.contains("AXSelectedTextRange") { return .text }
        return .notText
    }
}

/// Debounces hide decisions: apps sometimes report focus erratically
/// between keystrokes.
public struct HideDebouncer: Sendable {
    public var requiredMisses = 2
    public var typingGrace: Double = 1.0
    private var misses = 0
    public init() {}

    /// Returns true when the keyboard should hide now.
    public mutating func notText(now: Double, lastKeyPress: Double) -> Bool {
        if now - lastKeyPress < typingGrace { return false }
        misses += 1
        return misses >= requiredMisses
    }

    public mutating func text() { misses = 0 }
}
