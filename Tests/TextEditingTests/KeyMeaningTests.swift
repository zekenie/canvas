import AppKit
import CanvasTesting
import TestKit
import TextEditing

// The one key table: every navigation key as an event and as a text command, with the modifiers it
// was struck with; keys that aren't navigation give nothing.

private func event(_ characters: String, ignoring: String? = nil, code: UInt16 = 0, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 1, windowNumber: 0, context: nil,
                     characters: characters, charactersIgnoringModifiers: ignoring ?? characters, isARepeat: false, keyCode: code)!
}

private func arrow(_ code: Int) -> String { String(UnicodeScalar(UInt32(code))!) }

private let upArrow = arrow(NSUpArrowFunctionKey)
private let downArrow = arrow(NSDownArrowFunctionKey)
private let leftArrow = arrow(NSLeftArrowFunctionKey)
private let rightArrow = arrow(NSRightArrowFunctionKey)
private let forwardDelete = arrow(NSDeleteFunctionKey)

private typealias Reading = KeyMeaning.Reading

@MainActor let keyMeaningTests = Suite("Key meaning", [
    test("every navigation key as an event reads as its meaning, with its modifiers") {
        let cases: [(String, NSEvent, Reading)] = [
            ("Tab", event("\t", code: 48), Reading(.next)),
            ("Shift-Tab", event("\u{19}", code: 48, .shift), Reading(.previous, .shift)),
            ("Return", event("\r", code: 36), Reading(.activate)),
            ("keypad Enter", event("\u{3}", code: 76), Reading(.activate)),
            ("Shift-Return", event("\r", code: 36, .shift), Reading(.activate, .shift)),
            ("Space", event(" ", code: 49), Reading(.toggle)),
            ("Shift-Space", event(" ", code: 49, .shift), Reading(.toggle, .shift)),
            ("Escape", event("\u{1b}", code: 53), Reading(.back)),
            ("Up", event(upArrow, code: 126, .function), Reading(.up)),
            ("Down", event(downArrow, code: 125, .function), Reading(.down)),
            ("Left", event(leftArrow, code: 123, .function), Reading(.left)),
            ("Right", event(rightArrow, code: 124, .function), Reading(.right)),
            ("Up from the numeric pad", event(upArrow, code: 126, [.numericPad, .function]), Reading(.up)),
            ("Shift-Right", event(rightArrow, code: 124, [.shift, .function, .numericPad]), Reading(.right, .shift)),
            ("Option-Left", event(leftArrow, code: 123, [.option, .function]), Reading(.left, .option)),
            ("Delete", event("\u{7f}", code: 51), Reading(.delete)),
            ("Forward Delete", event(forwardDelete, code: 117, .function), Reading(.delete)),
            ("Command-Return", event("\r", code: 36, .command), Reading(.finish, .command)),
            ("Command-keypad Enter", event("\u{3}", code: 76, .command), Reading(.finish, .command)),
            ("Caps Lock is no modifier", event("\r", code: 36, .capsLock), Reading(.activate)),
        ]
        for (name, key, want) in cases {
            expect(Reading(event: key) == want, name)
            expect(KeyMeaning(event: key) == want.meaning, name)
        }
    },
    test("a key that isn't navigation has no meaning") {
        let cases: [(String, NSEvent)] = [
            ("Option-Tab", event("\t", code: 48, .option)),
            ("Option-Shift-Tab", event("\u{19}", code: 48, [.option, .shift])),
            ("Control-Tab", event("\t", code: 48, .control)),
            ("Command-Tab", event("\t", code: 48, .command)),
            ("Option-Return", event("\r", code: 36, .option)),
            ("Control-Return", event("\r", code: 36, .control)),
            ("Command-Space", event(" ", code: 49, .command)),
            ("Option-Space", event(" ", code: 49, .option)),
            ("a letter", event("a", code: 0)),
            ("a digit", event("1", code: 18)),
            ("Home", event(arrow(NSHomeFunctionKey), code: 115, .function)),
            ("two characters", event("ab")),
        ]
        for (name, key) in cases { expect(Reading(event: key) == nil, name) }
    },
    test("every text command reads as its meaning, with the modifiers its key stands for") {
        let cases: [(Selector, Reading)] = [
            (#selector(NSResponder.insertTab(_:)), Reading(.next)),
            (#selector(NSResponder.insertBacktab(_:)), Reading(.previous, .shift)),
            (#selector(NSResponder.insertNewline(_:)), Reading(.activate)),
            (#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)), Reading(.activate, .option)),
            (#selector(NSResponder.insertLineBreak(_:)), Reading(.activate, .control)),
            (#selector(NSResponder.cancelOperation(_:)), Reading(.back)),
            (#selector(NSResponder.moveUp(_:)), Reading(.up)),
            (#selector(NSResponder.moveDown(_:)), Reading(.down)),
            (#selector(NSResponder.moveLeft(_:)), Reading(.left)),
            (#selector(NSResponder.moveRight(_:)), Reading(.right)),
            (#selector(NSResponder.deleteBackward(_:)), Reading(.delete)),
            (#selector(NSResponder.deleteForward(_:)), Reading(.delete)),
        ]
        for (command, want) in cases {
            expect(Reading(command: command) == want, "\(command)")
            expect(KeyMeaning(command: command) == want.meaning, "\(command)")
        }
        expect(KeyMeaning(command: #selector(NSResponder.insertText(_:))) == nil, "a command that isn't navigation")
        expect(KeyMeaning(command: #selector(NSResponder.moveToEndOfLine(_:))) == nil)
    },
    test("an event and its command agree on the meaning") {
        let pairs: [(NSEvent, Selector)] = [
            (event("\t", code: 48), #selector(NSResponder.insertTab(_:))),
            (event("\u{19}", code: 48, .shift), #selector(NSResponder.insertBacktab(_:))),
            (event("\r", code: 36), #selector(NSResponder.insertNewline(_:))),
            (event("\u{1b}", code: 53), #selector(NSResponder.cancelOperation(_:))),
            (event(upArrow, code: 126, .function), #selector(NSResponder.moveUp(_:))),
            (event("\u{7f}", code: 51), #selector(NSResponder.deleteBackward(_:))),
        ]
        for (key, command) in pairs { expect(Reading(event: key) == Reading(command: command), "\(command)") }
    },
])
