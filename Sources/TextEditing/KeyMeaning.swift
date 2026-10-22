import AppKit

/// What a navigation key means, whichever way it reaches a view: as a key event (`keyDown`) or as the
/// command a text view's key bindings turn it into (`doCommandBy`). One table, so a handler asks
/// "is this next?" instead of matching key codes and selectors twice. Pure: it names meanings, and a
/// view decides what a meaning does.
///
/// Only keys that navigate are here. Tab and Return with Option or Control held, Space with a
/// command key, and every key that types have no meaning (`nil`): they are not navigation.
public enum KeyMeaning: Equatable, Sendable, CaseIterable {
    /// Tab: the next thing.
    case next
    /// Shift-Tab (back-tab): the previous thing.
    case previous
    case up, down, left, right
    /// Return or the keypad's Enter: do or open the focused thing.
    case activate
    /// Space: toggle or press the focused thing.
    case toggle
    /// Escape: back out one level.
    case back
    /// Command-Return: finish (end editing, commit).
    case finish
    /// Delete or Forward Delete.
    case delete

    /// The modifiers a key was struck with, only the four that change what a key means (not Caps Lock,
    /// the keypad flag or the function flag, which the arrow keys carry).
    public struct Modifiers: OptionSet, Equatable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let shift = Modifiers(rawValue: 1)
        public static let control = Modifiers(rawValue: 2)
        public static let option = Modifiers(rawValue: 4)
        public static let command = Modifiers(rawValue: 8)

        public init(_ flags: NSEvent.ModifierFlags) {
            var result: Modifiers = []
            if flags.contains(.shift) { result.insert(.shift) }
            if flags.contains(.control) { result.insert(.control) }
            if flags.contains(.option) { result.insert(.option) }
            if flags.contains(.command) { result.insert(.command) }
            self = result
        }
    }

    /// A meaning with the modifiers it was read with, which tell Shift-Return from Return.
    public struct Reading: Equatable, Sendable {
        public let meaning: KeyMeaning
        public let modifiers: Modifiers

        public init(_ meaning: KeyMeaning, _ modifiers: Modifiers = []) {
            self.meaning = meaning
            self.modifiers = modifiers
        }

        /// The reading of a key-down event, or nil when it isn't a navigation key (or is one struck
        /// with modifiers that make it something else: Option-Tab, Option-Return).
        public init?(event: NSEvent) {
            guard event.type == .keyDown || event.type == .keyUp else { return nil }
            let characters = event.charactersIgnoringModifiers ?? event.characters ?? ""
            guard characters.unicodeScalars.count == 1, let scalar = characters.unicodeScalars.first else { return nil }
            let held = Modifiers(event.modifierFlags)
            guard let meaning = KeyMeaning.meaning(of: scalar.value, held: held) else { return nil }
            self.init(meaning, held)
        }

        /// The reading of the command a text view's key bindings send, with the modifiers its key
        /// binding stands for: back-tab is Shift-Tab, `insertLineBreak:` Control-Return and
        /// `insertNewlineIgnoringFieldEditor:` Option-Return, the keys the standard bindings send
        /// them for. Nil for any other command.
        public init?(command: Selector) {
            switch command {
            case #selector(NSResponder.insertTab(_:)): self.init(.next)
            case #selector(NSResponder.insertBacktab(_:)): self.init(.previous, .shift)
            case #selector(NSResponder.insertNewline(_:)): self.init(.activate)
            case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)): self.init(.activate, .option)
            case #selector(NSResponder.insertLineBreak(_:)): self.init(.activate, .control)
            case #selector(NSResponder.cancelOperation(_:)): self.init(.back)
            case #selector(NSResponder.moveUp(_:)): self.init(.up)
            case #selector(NSResponder.moveDown(_:)): self.init(.down)
            case #selector(NSResponder.moveLeft(_:)): self.init(.left)
            case #selector(NSResponder.moveRight(_:)): self.init(.right)
            case #selector(NSResponder.deleteBackward(_:)), #selector(NSResponder.deleteForward(_:)): self.init(.delete)
            default: return nil
            }
        }
    }

    /// The meaning of a key-down event, without its modifiers (`Reading` keeps them).
    public init?(event: NSEvent) {
        guard let reading = Reading(event: event) else { return nil }
        self = reading.meaning
    }

    /// The meaning of a text command, without its modifiers (`Reading` keeps them).
    public init?(command: Selector) {
        guard let reading = Reading(command: command) else { return nil }
        self = reading.meaning
    }

    // The characters a key types (the function keys are in Unicode's private use area).
    private static func meaning(of scalar: UInt32, held: Modifiers) -> KeyMeaning? {
        let plain = held.subtracting([.shift]).isEmpty
        switch scalar {
        case 0x09: return plain ? .next : nil                        // Tab
        case 0x19: return plain ? .previous : nil                    // back-tab, which Shift-Tab types
        case 0x0D, 0x03:                                              // Return, keypad Enter
            if held.contains(.option) || held.contains(.control) { return nil }
            return held.contains(.command) ? .finish : .activate
        case 0x20: return held.isDisjoint(with: [.command, .control, .option]) ? .toggle : nil
        case 0x1B: return .back
        case 0xF700: return .up
        case 0xF701: return .down
        case 0xF702: return .left
        case 0xF703: return .right
        case 0x7F, 0xF728: return .delete                            // Delete, Forward Delete
        default: return nil
        }
    }
}
