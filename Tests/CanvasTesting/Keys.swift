import AppKit
@_spi(Host) import Canvas

// Keys sent as a user's keyboard sends them: each key with its real key code and the flags the
// hardware adds (an arrow carries the keypad and function flags, ⇧Tab types the back-tab character),
// routed in NSApplication's order (the window's key equivalents, then the menu bar, then the first
// responder). Every walk (`KeyWalk`) and every press helper (`NSWindow.press`) goes through here.

/// A key on a US keyboard: its key code (`kVK_…`, the same key whatever the layout), what it types
/// alone and with ⇧, and the flags AppKit sets on its events whatever is held (an arrow's
/// `.numericPad` and `.function`, a function key's `.function`).
public struct Key: Hashable, Sendable, CustomStringConvertible {
    public let code: UInt16
    /// What it types with no modifier (`charactersIgnoringModifiers` with none held).
    public let character: String
    /// What it types with ⇧ (a capital, "!" on the 1 key); the same as `character` for a key ⇧ doesn't change.
    public let shifted: String
    /// What it types with ⌥ on the US layout ("œ" on Q), when that differs from `character`.
    public let optioned: String?
    /// The flags its events always carry.
    public let baseFlags: NSEvent.ModifierFlags
    /// How a trace names it: "Tab", "↓", "a".
    public let name: String

    public init(code: UInt16, character: String, shifted: String? = nil, optioned: String? = nil, baseFlags: NSEvent.ModifierFlags = [], name: String? = nil) {
        self.code = code
        self.character = character
        self.shifted = shifted ?? character
        self.optioned = optioned
        self.baseFlags = baseFlags
        self.name = name ?? character
    }

    public var description: String { name }

    public static func == (a: Key, b: Key) -> Bool { a.code == b.code && a.character == b.character }
    public func hash(into hasher: inout Hasher) { hasher.combine(code); hasher.combine(character) }

    private static let arrow: NSEvent.ModifierFlags = [.numericPad, .function]

    public static let tab = Key(code: 48, character: "\t", shifted: "\u{19}", name: "Tab")
    public static let `return` = Key(code: 36, character: "\r", name: "Return")
    /// The keypad's Enter (fn-Return on a laptop).
    public static let enter = Key(code: 76, character: "\u{3}", baseFlags: .numericPad, name: "Enter")
    public static let escape = Key(code: 53, character: "\u{1b}", name: "Escape")
    public static let space = Key(code: 49, character: " ", name: "Space")
    /// Delete, which deletes backward.
    public static let delete = Key(code: 51, character: "\u{7f}", name: "Delete")
    public static let forwardDelete = Key(code: 117, character: "\u{F728}", baseFlags: .function, name: "ForwardDelete")
    public static let up = Key(code: 126, character: "\u{F700}", baseFlags: arrow, name: "↑")
    public static let down = Key(code: 125, character: "\u{F701}", baseFlags: arrow, name: "↓")
    public static let left = Key(code: 123, character: "\u{F702}", baseFlags: arrow, name: "←")
    public static let right = Key(code: 124, character: "\u{F703}", baseFlags: arrow, name: "→")
    public static let home = Key(code: 115, character: "\u{F729}", baseFlags: .function, name: "Home")
    public static let end = Key(code: 119, character: "\u{F72B}", baseFlags: .function, name: "End")
    public static let pageUp = Key(code: 116, character: "\u{F72C}", baseFlags: .function, name: "PageUp")
    public static let pageDown = Key(code: 121, character: "\u{F72D}", baseFlags: .function, name: "PageDown")
    public static let f6 = Key(code: 97, character: "\u{F709}", baseFlags: .function, name: "F6")
    /// A PC keyboard's Menu key (`kVK_ContextualMenu`).
    public static let menu = Key(code: 110, character: "\u{F735}", baseFlags: .function, name: "Menu")

    /// The keys that type no character, by what they type.
    static let named: [Key] = [.tab, .return, .enter, .escape, .space, .delete, .forwardDelete, .up, .down, .left, .right,
                               .home, .end, .pageUp, .pageDown, .f6, .menu]

    /// The US layout's keys that type a character: (key code, alone, with ⇧, with ⌥).
    private static let typing: [(UInt16, String, String, String?)] = [
        (0, "a", "A", "å"), (11, "b", "B", "∫"), (8, "c", "C", "ç"), (2, "d", "D", "∂"), (14, "e", "E", nil), (3, "f", "F", "ƒ"),
        (5, "g", "G", "©"), (4, "h", "H", "˙"), (34, "i", "I", nil), (38, "j", "J", "∆"), (40, "k", "K", "˚"), (37, "l", "L", "¬"),
        (46, "m", "M", "µ"), (45, "n", "N", nil), (31, "o", "O", "ø"), (35, "p", "P", "π"), (12, "q", "Q", "œ"), (15, "r", "R", "®"),
        (1, "s", "S", "ß"), (17, "t", "T", "†"), (32, "u", "U", nil), (9, "v", "V", "√"), (13, "w", "W", "∑"), (7, "x", "X", "≈"),
        (16, "y", "Y", "¥"), (6, "z", "Z", "Ω"),
        (18, "1", "!", "¡"), (19, "2", "@", "™"), (20, "3", "#", "£"), (21, "4", "$", "¢"), (23, "5", "%", "∞"), (22, "6", "^", "§"),
        (26, "7", "&", "¶"), (28, "8", "*", "•"), (25, "9", "(", "ª"), (29, "0", ")", "º"),
        (27, "-", "_", "–"), (24, "=", "+", "≠"), (33, "[", "{", "“"), (30, "]", "}", "‘"), (42, "\\", "|", "«"), (41, ";", ":", "…"),
        (39, "'", "\"", "æ"), (43, ",", "<", "≤"), (47, ".", ">", "≥"), (44, "/", "?", "÷"), (50, "`", "~", nil),
    ]

    /// The key that types `character`, alone or with ⇧, and whether ⇧ is what types it ("A", "!").
    public static func typing(_ character: Character) -> (key: Key, shifted: Bool)? {
        let text = String(character)
        if let key = named.first(where: { $0.character == text }) { return (key, false) }
        if text == Key.tab.shifted { return (.tab, true) }
        for (code, alone, shifted, optioned) in typing {
            if alone == text { return (Key(code: code, character: alone, shifted: shifted, optioned: optioned), false) }
            if shifted == text { return (Key(code: code, character: alone, shifted: shifted, optioned: optioned), true) }
        }
        return nil
    }

    /// The key code of the key that types `characters` on a US keyboard, when it is one key.
    public static func code(typing characters: String) -> UInt16? {
        guard characters.count == 1, let character = characters.first else { return nil }
        return typing(character)?.key.code
    }
}

/// A key and the modifiers held with it, as a user presses it: `.tab`, `.backTab` (⇧Tab),
/// `Chord("v")`, `Chord("z", .command)`, `Chord(.down, .option)`.
public struct Chord: Hashable, Sendable, CustomStringConvertible {
    public var key: Key
    /// What is held (⇧ ⌃ ⌥ ⌘), apart from the key's own flags, and Caps Lock when it is on (`capsLock`),
    /// which the canvas never hears as a modifier.
    public var modifiers: NSEvent.ModifierFlags

    public init(_ key: Key, _ modifiers: NSEvent.ModifierFlags = []) {
        self.key = key
        self.modifiers = modifiers.intersection([.shift, .control, .option, .command, .capsLock])
    }

    /// The key that types `character` on a US keyboard: "v", "V" (V with ⇧), "!" (1 with ⇧), "\t".
    public init(_ character: Character, _ modifiers: NSEvent.ModifierFlags = []) {
        guard let (key, shifted) = Key.typing(character) else { preconditionFailure("no US key types \(character.debugDescription)") }
        self.init(key, shifted ? modifiers.union(.shift) : modifiers)
    }

    public static func == (a: Chord, b: Chord) -> Bool { a.key == b.key && a.modifiers == b.modifiers }
    public func hash(into hasher: inout Hasher) { hasher.combine(key); hasher.combine(modifiers.rawValue) }

    public static let tab = Chord(Key.tab)
    public static let backTab = Chord(Key.tab, .shift)
    public static let optionTab = Chord(Key.tab, .option)
    public static let optionBackTab = Chord(Key.tab, [.option, .shift])
    public static let up = Chord(Key.up), down = Chord(Key.down), left = Chord(Key.left), right = Chord(Key.right)
    public static let `return` = Chord(Key.return)
    public static let enter = Chord(Key.enter)
    public static let escape = Chord(Key.escape)
    public static let space = Chord(Key.space)
    public static let delete = Chord(Key.delete)
    public static let forwardDelete = Chord(Key.forwardDelete)
    public static let commandReturn = Chord(Key.return, .command)
    public static let commandPeriod = Chord(".", .command)

    /// Keys a focused thing that takes no text has no use for, which must change no document there
    /// (P8): tool letters, a digit, Delete and Forward Delete, a plain-key menu item's key.
    public static let inert: [Chord] = [Chord("v"), Chord("n"), Chord("f"), Chord("1"), .delete, .forwardDelete, Chord("]")]

    /// This chord struck with Caps Lock on, which changes the meaning of no key.
    public var capsLock: Chord { Chord(key, modifiers.union(.capsLock)) }

    /// The flags its event carries: what is held, and the key's own.
    public var flags: NSEvent.ModifierFlags { modifiers.union(key.baseFlags) }

    /// What the event reports as `charactersIgnoringModifiers`: what the key types with ⇧ if held,
    /// else alone (⌃, ⌥ and ⌘ don't count).
    public var charactersIgnoringModifiers: String { modifiers.contains(.shift) ? key.shifted : key.character }

    /// What the event reports as `characters`: ⌃ with a letter types its control character, ⌥ what
    /// the layout gives it (with ⇧ too, the shifted character: the table has no ⌥⇧ column), ⌘ nothing different.
    public var characters: String {
        let base = charactersIgnoringModifiers
        if modifiers.contains(.command) { return base }
        if modifiers.contains(.control), let scalar = key.character.unicodeScalars.first, key.character.count == 1,
           ("a"..."z").contains(key.character) {
            return String(UnicodeScalar(UInt8(scalar.value & 0x1f)))
        }
        if modifiers.contains(.option), !modifiers.contains(.shift), let optioned = key.optioned { return optioned }
        return base
    }

    /// A key-down (or key-up) event of this chord for `window`.
    @MainActor
    public func event(_ type: NSEvent.EventType = .keyDown, in window: NSWindow, isRepeat: Bool = false,
                      timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime) -> NSEvent {
        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: timestamp, windowNumber: window.windowNumber,
                         context: nil, characters: characters, charactersIgnoringModifiers: charactersIgnoringModifiers,
                         isARepeat: isRepeat, keyCode: key.code)!
    }

    // MARK: As the canvas hears it

    /// The modifiers the canvas hears with it (`KeyStroke.modifiers`).
    public var strokeModifiers: Modifiers {
        var held: Modifiers = []
        if modifiers.contains(.shift) { held.insert(.shift) }
        if modifiers.contains(.option) { held.insert(.option) }
        if modifiers.contains(.command) { held.insert(.command) }
        if modifiers.contains(.control) { held.insert(.control) }
        return held
    }

    /// The characters the canvas hears (`KeyStroke.characters`): what the event reports ignoring
    /// modifiers, with ⇧Tab's back-tab heard as Tab (⇧ is in the modifiers).
    public var strokeCharacters: String { charactersIgnoringModifiers == Key.tab.shifted ? "\t" : charactersIgnoringModifiers }

    /// The number row's digit, for a key of it (`KeyStroke.numberRowKey`).
    public var numberRowKey: Character? {
        guard (18...29).contains(key.code), key.code != 24, key.code != 27, let digit = key.character.first, digit.isNumber else { return nil }
        return digit
    }

    /// The stroke the canvas makes of it (`CanvasView`'s `KeyStroke(event)`).
    public func stroke(isRepeat: Bool = false) -> KeyStroke {
        KeyStroke(strokeCharacters, modifiers: strokeModifiers, isRepeat: isRepeat, numberRowKey: numberRowKey)
    }

    // MARK: Named

    /// How a trace names it: "⇧Tab", "⌥⇧Tab", "⌘↩", "v".
    public var description: String {
        var text = modifiers.contains(.capsLock) ? "⇪" : ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + key.name
    }
}

/// Where a key went (`KeyDriver.send`).
public enum Delivery: CustomStringConvertible {
    /// A view of the window took it as a key equivalent (`performKeyEquivalent`): a button's key, the
    /// canvas's ⌘ shortcuts.
    case keyEquivalent
    /// The menu bar took it: the item whose action it sent, when one did.
    case menu(NSMenuItem?)
    /// The first responder had it, and something on the responder chain took it.
    case responder(NSResponder)
    /// It went down the whole responder chain and nothing took it: a key-down, the text it types or
    /// the command it binds to reached the end of the chain (where AppKit beeps).
    case unhandled

    public var description: String {
        switch self {
        case .keyEquivalent: "keyEquivalent"
        case .menu(let item): "menu(\(item?.title ?? "?"))"
        case .responder(let responder): "responder(\(type(of: responder)))"
        case .unhandled: "unhandled"
        }
    }

    public var isUnhandled: Bool { if case .unhandled = self { true } else { false } }
    public var isKeyEquivalent: Bool { if case .keyEquivalent = self { true } else { false } }
    public var menuItem: NSMenuItem? { if case .menu(let item) = self { item } else { nil } }
    public var responder: NSResponder? { if case .responder(let responder) = self { responder } else { nil } }
}

/// Sends keys to a window as NSApplication routes them (`sendEvent:` for a key-down): first the
/// window's key equivalents (`performKeyEquivalent`, which walks its views: a button's Return, the
/// canvas's ⌘ keys), then the menu bar's when one is given, then the window (`sendEvent`), which
/// hands the key to its first responder. An unshown window is never key, so `NSApp.sendEvent` would
/// route nothing to it: this does what it would.
@MainActor
public struct KeyDriver {
    public let window: NSWindow
    public let menu: NSMenu?

    public init(_ window: NSWindow, menu: NSMenu? = nil) {
        self.window = window
        self.menu = menu
    }

    /// One press of `chord` (`repeating`: a repeat of a key held down, `isARepeat`).
    @discardableResult
    public func send(_ chord: Chord, repeating: Bool = false) -> Delivery {
        deliver(chord.event(in: window, isRepeat: repeating))
    }

    /// A key held down: one press, then `repeats` more with `isARepeat` set, then its release.
    @discardableResult
    public func hold(_ chord: Chord, repeats: Int) -> [Delivery] {
        var deliveries = [send(chord)]
        for _ in 0..<max(0, repeats) { deliveries.append(send(chord, repeating: true)) }
        release(chord)
        return deliveries
    }

    /// The key let go (a key-up, to the window).
    public func release(_ chord: Chord) {
        window.sendEvent(chord.event(.keyUp, in: window))
    }

    /// A key event routed as NSApplication routes one.
    @discardableResult
    public func deliver(_ event: NSEvent) -> Delivery {
        _ = NSApplication.shared                 // menu items send their actions through NSApp
        if window.performKeyEquivalent(with: event) { return .keyEquivalent }
        if let menu {
            let sent = SentItem()
            NotificationCenter.default.addObserver(sent, selector: #selector(SentItem.sent(_:)), name: NSMenu.didSendActionNotification, object: nil)
            defer { NotificationCenter.default.removeObserver(sent) }
            menu.update()
            if menu.performKeyEquivalent(with: event) { return .menu(sent.item) }
        }
        let responder = window.firstResponder ?? window
        let end = ChainEnd()
        let tail = end.append(after: window)
        defer { tail?.nextResponder = nil }
        window.sendEvent(event)
        return end.reached ? .unhandled : .responder(responder)
    }
}

/// The item a menu sent its action from.
@MainActor
private final class SentItem: NSObject {
    var item: NSMenuItem?
    @objc func sent(_ note: Notification) { item = item ?? note.userInfo?["MenuItem"] as? NSMenuItem }
}

/// A responder put at the end of a window's responder chain while a key is delivered: what reaches
/// it, nothing before it took.
@MainActor
private final class ChainEnd: NSResponder {
    var reached = false

    /// Puts this after the last responder of `window`'s chain; returns that responder.
    func append(after window: NSWindow) -> NSResponder? {
        var last: NSResponder = window
        var seen = 0
        while let next = last.nextResponder, seen < 64 {
            last = next
            seen += 1
        }
        guard last.nextResponder == nil else { return nil }
        last.nextResponder = self
        return last
    }

    override func keyDown(with event: NSEvent) { reached = true }
    override func insertText(_ insertString: Any) { reached = true }
    override func doCommand(by selector: Selector) { reached = true }
    override func noResponder(for eventSelector: Selector) { reached = true }
}

extension EditorHarness {
    /// A chord pressed on the canvas, heard as a real window's canvas hears it (`Chord.stroke`: the
    /// number row's digit included), with what `hold` holds added to its modifiers. KeyDriverTests
    /// hold the two the same.
    @discardableResult
    public func key(_ chord: Chord, isRepeat: Bool = false) -> Bool {
        var stroke = chord.stroke(isRepeat: isRepeat)
        stroke.modifiers.formUnion(held)
        return editor.keyDown(stroke)
    }
}
