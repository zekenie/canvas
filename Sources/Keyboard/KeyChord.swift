import Canvas

/// A key, and the modifiers held with it: what a shortcut is pressed with. A character literal is a
/// key alone (`"v"`), and a letter's case doesn't count (`"V"` is the same chord).
/// `KeyChord("d", .command)` is ⌘D, and the keys that type no character have names: `.escape`,
/// `.return`, `.delete`, `.leftArrow`, ...
public struct KeyChord: Hashable, Sendable, CustomStringConvertible, ExpressibleByExtendedGraphemeClusterLiteral {
    /// As the keyboard's layout types it with no modifier, lowercased: "v", "?", "\u{1b}".
    public let key: Character
    public let modifiers: Modifiers

    public init(_ key: Character, _ modifiers: Modifiers = []) {
        let lowered = key.lowercased()
        self.key = lowered.count == 1 ? Character(lowered) : key
        self.modifiers = modifiers
    }

    public init(extendedGraphemeClusterLiteral key: Character) { self.init(key) }
    public init(unicodeScalarLiteral key: Unicode.Scalar) { self.init(Character(key)) }

    // The keys that type no character, as AppKit reports them (`NSEvent.charactersIgnoringModifiers`).
    public static let escape = KeyChord("\u{1b}")
    public static let `return` = KeyChord("\r")
    /// The keypad's Enter (fn-Return on a laptop).
    public static let enter = KeyChord("\u{3}")
    /// Delete, which deletes backward.
    public static let delete = KeyChord("\u{7f}")
    /// Forward Delete (fn-Delete on a laptop).
    public static let deleteForward = KeyChord("\u{F728}")
    public static let tab = KeyChord("\t")
    public static let space = KeyChord(" ")
    public static let upArrow = KeyChord("\u{F700}")
    public static let downArrow = KeyChord("\u{F701}")
    public static let leftArrow = KeyChord("\u{F702}")
    public static let rightArrow = KeyChord("\u{F703}")

    /// As menus show it: the modifiers in the order ⌃ ⌥ ⇧ ⌘, then the key, a letter as a capital:
    /// "V", "⇧⌘G", "⌘.", "⎋", "Space".
    public var description: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + (Self.names[key] ?? key.uppercased())
    }

    private static let names: [Character: String] = [
        "\u{1b}": "⎋", "\r": "↩", "\u{3}": "⌤", "\u{7f}": "⌫", "\u{F728}": "⌦", "\t": "⇥", " ": "Space",
        "\u{F700}": "↑", "\u{F701}": "↓", "\u{F702}": "←", "\u{F703}": "→",
    ]
}

extension KeyChord {
    /// The chord a key stroke makes; nil when it isn't one key (a dead key, which types nothing yet).
    init?(_ stroke: KeyStroke) {
        guard stroke.characters.count == 1, let key = stroke.characters.first else { return nil }
        self.init(key, stroke.modifiers)
    }

    /// The chords a key stroke answers to, best first: exactly its own; then, when ⇧ is held and
    /// may be only what typed the key, the same without ⇧. That's any key held with ⇧ alone (⇧ makes
    /// a letter a capital, or types a character: "V" is V with caps lock too, and "?" is the key
    /// that types it), and punctuation, a symbol or a digit with ⌘, ⌥ or ⌃ too (⌘? is ⇧⌘/ on a US
    /// keyboard, and ⌘. is ⇧⌘; on a French one). Otherwise ⇧ counts: ⇧⌘Z isn't ⌘Z, nor ⇧⌘→ ⌘→.
    var answers: [KeyChord] {
        guard modifiers.contains(.shift), modifiers == .shift || isTypedWithShift else { return [self] }
        return [self, KeyChord(key, modifiers.subtracting(.shift))]
    }

    /// Whether ⇧ can be what types the key on some keyboard: punctuation, a symbol or a digit. Not a
    /// letter (⇧ makes it a capital), nor a key that types no character.
    private var isTypedWithShift: Bool {
        guard key.unicodeScalars.count == 1, let scalar = key.unicodeScalars.first else { return false }
        switch scalar.properties.generalCategory {
        case .decimalNumber, .letterNumber, .otherNumber,
             .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation, .initialPunctuation, .finalPunctuation,
             .otherPunctuation, .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol:
            return true
        default:
            return false
        }
    }
}
