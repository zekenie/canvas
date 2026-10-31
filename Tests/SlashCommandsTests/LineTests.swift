import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import SlashCommands
import TestKit
import TextEditing

// The pieces of typing that need no view: what arguments are, what a command line is (where lines
// end included, which is `NSString`'s to say), and the list's model: when a `/` opens it, what
// closes it, what it lists, and the order.

private let idA = ShapeID(UUID(uuidString: "7C1E0B8A-2F4D-4A6B-9C3E-5D2F1A0B9C8D")!)
private let idB = ShapeID(UUID(uuidString: "0A1B2C3D-4E5F-4061-8293-A4B5C6D7E8F9")!)

@MainActor private func line(_ text: String, caret: Int? = nil) -> SlashCommandLine? {
    SlashCommandLine(in: text as NSString, caret: caret ?? (text as NSString).length)
}

private func substring(_ text: String, _ range: NSRange) -> String { (text as NSString).substring(with: range) }

private func rowText(_ row: CaretListRow) -> String {
    switch row {
    case .item(let item): item.detail.map { "\(item.title) (\($0))" } ?? item.title
    case .header(let words): "# \(words)"
    case .empty(let words): "- \(words)"
    }
}

@MainActor let slashArgumentsTests = Suite("Slash arguments", [
    test("text is trimmed at both ends, adjacent runs merge and empty ones go; whitespace between runs stays") {
        expectEqual(SlashArguments("  hello  ").runs, [.text("hello")])
        expectEqual(SlashArguments("\n\t hi there \u{00A0}").runs, [.text("hi there")])
        expect(SlashArguments("   ").isEmpty && SlashArguments("").isEmpty && SlashArguments([]).isEmpty)
        expectEqual(SlashArguments([.text("a"), .text(""), .text(" b")]).runs, [.text("a b")])
        expectEqual(SlashArguments([.text(" near "), .shape(idA, label: "Groceries"), .text(" ")]).runs,
                    [.text("near "), .shape(idA, label: "Groceries")])
        expectEqual(SlashArguments([.text("  "), .shape(idA, label: "A"), .text(" and "), .shape(idB, label: "B")]).runs,
                    [.shape(idA, label: "A"), .text(" and "), .shape(idB, label: "B")])
        expect(!SlashArguments([.shape(idA, label: "A")]).isEmpty, "a shape alone is something")
    },

    test("as text each shape is an @ and the name it shows; its shapes are in order, each once") {
        let arguments = SlashArguments([.text("near "), .shape(idA, label: "Groceries"), .text(" or "), .shape(idB, label: "Grocery List"),
                                        .text(" or "), .shape(idA, label: "Groceries")])
        expectEqual(arguments.text, "near @Groceries or @Grocery List or @Groceries")
        expectEqual(arguments.shapes, [idA, idB])
        expectEqual(SlashArguments("plain").text, "plain")
        expectEqual(SlashArguments("plain").shapes, [])
    },

    test("it is made from a string, a string literal, or runs, and is equal when its runs are") {
        let literal: SlashArguments = "caption"
        expectEqual(literal, SlashArguments("caption"))
        expectEqual(literal, SlashArguments([.text("caption")]))
        expect(literal != SlashArguments("other"))
        expect(SlashArguments([.shape(idA, label: "A")]) != SlashArguments([.shape(idA, label: "B")]), "the name shown is part of it")
    },
])

@MainActor let slashLineTests = Suite("Slash command lines", [
    test("a line is a slash, a name ended by whitespace or the line's end, then the arguments: ranges, the name folded") {
        let command = try require(line("/lock"))
        expectEqual(command.range, NSRange(location: 0, length: 5))
        expectEqual(command.nameRange, NSRange(location: 0, length: 5), "the slash and the name")
        expectEqual(command.name, "lock")
        expectEqual(command.arguments, NSRange(location: 5, length: 0))

        let text = "/Set-Title  Hello  world \t"
        let titled = try require(line(text))
        expectEqual(titled.name, "set-title")
        expectEqual(titled.range, NSRange(location: 0, length: 26))
        expectEqual(substring(text, titled.nameRange), "/Set-Title", "as typed, not folded")
        expectEqual(substring(text, titled.arguments), "Hello  world", "after the whitespace that follows the name, less what trails")

        let blank = try require(line("/lock   "))
        expectEqual(blank.arguments, NSRange(location: 8, length: 0), "nothing but whitespace after the name is no arguments")
        expectEqual(try require(line("/h2 x")).name, "h2")
    },

    test("it is the line the caret is on, after the slash, and the line without its break") {
        let text = "first\n/grow 5\nlast"
        let second = try require(line(text, caret: 9))
        expectEqual(second.range, NSRange(location: 6, length: 7))
        expectEqual(second.name, "grow")
        expectEqual(substring(text, second.arguments), "5")
        expectEqual(line(text, caret: 6), nil, "the caret before the slash")
        expectEqual(line(text, caret: 7)?.name, "grow", "right after it")
        expectEqual(line(text, caret: 13)?.range, NSRange(location: 6, length: 7), "at the line's end")
        expectEqual(line(text, caret: 3), nil, "on the first line")
        expectEqual(line(text, caret: 15), nil, "on the last")
        expectEqual(line("/grow\n"), nil, "the caret at the end of text that ends in a line break is on the empty last line")
        expectEqual(line("/grow\n", caret: 5)?.range, NSRange(location: 0, length: 5))
        expectEqual(line("", caret: 0), nil)
        expectEqual(line("/grow", caret: 6), nil, "past the end")
        expectEqual(line("/grow", caret: -1), nil)
    },

    test("a line ends at \\n, \\r, \\r\\n, U+0085, U+2028 and U+2029, none of which is in its range") {
        for breakText in ["\n", "\r", "\r\n", "\u{85}", "\u{2028}", "\u{2029}"] {
            let after = "ab\(breakText)/up 1"
            let found = try require(line(after), "after \(breakText.debugDescription)")
            expectEqual(found.name, "up")
            expectEqual(found.range, NSRange(location: 2 + (breakText as NSString).length, length: 5))
            let before = "/up 1\(breakText)ab"
            let first = try require(line(before, caret: 3), "before \(breakText.debugDescription)")
            expectEqual(first.range, NSRange(location: 0, length: 5), "without the break")
            expectEqual(substring(before, first.arguments), "1")
            expectEqual(line(before, caret: (before as NSString).length), nil, "the line after isn't a command")
        }
    },

    test("anything else is no command line: no slash at the start, no name, a name with something else in it") {
        for text in ["lock", " /lock", "x /lock", "/", "/ lock", "//", "/!", "/lock!", "/lock\u{FFFC}", "/lo\u{FFFC}ck", "/lock,x", "/café", "/lo.ck", "\u{FFFC}/lock"] {
            expectEqual(line(text), nil, text.debugDescription)
        }
        expectEqual(line("/lock\u{00A0}x")?.arguments, NSRange(location: 6, length: 1), "a no-break space ends the name")
        expectEqual(line("/lock\u{3000}x")?.name, "lock", "so does an ideographic space")
        expectEqual(line("/a\u{FFFC}"), nil, "a pill is no whitespace")
        expectEqual(line("/lock \u{FFFC}")?.arguments, NSRange(location: 6, length: 1), "after the name, anything goes")
        expectEqual(line("/-")?.name, "-", "a line reads what's typed; the registry decides what is a name")
    },

    test("a name is lowercase letters and digits, words joined by single hyphens; a name character is an ASCII letter, a digit or a hyphen") {
        for name in ["a", "lock", "set-title", "h2", "2d", "a-b-c", "move-into"] { expect(SlashCommandLine.isName(name), name) }
        for name in ["", "-", "-a", "a-", "a--b", "A", "Lock", "a b", "a_b", "a.b", "é", "a/b", "a\n"] { expect(!SlashCommandLine.isName(name), name.debugDescription) }
        for unit in "aZ09-".utf16 { expect(SlashCommandLine.isNameCharacter(unit), "\(unit)") }
        for unit in " /_.é\u{FFFC}\n:@".utf16 { expect(!SlashCommandLine.isNameCharacter(unit), "\(unit)") }
    },
])

@MainActor let slashPickerTests = Suite("Slash command picker", [
    test("a slash opens the list on an empty line: at the start of the text or after a line break, with nothing after it") {
        for text in ["/", "a\n/", "a\r\n/", "a\r/", "a\u{2028}/", "a\u{85}/", "\n/", "ab\n\n/"] {
            expect(SlashCommandPicker.opens(in: text as NSString, at: (text as NSString).length - 1), "\(text.debugDescription) opens")
        }
        for text in ["a/", " /", "a /", "a\n /", "(/", "\u{FFFC}/", "1/"] {
            expect(!SlashCommandPicker.opens(in: text as NSString, at: (text as NSString).length - 1), "\(text.debugDescription) doesn't")
        }
        expect(SlashCommandPicker.opens(in: "/\nb" as NSString, at: 0), "nothing after it on its line, though more text follows")
        expect(!SlashCommandPicker.opens(in: "/b" as NSString, at: 0), "text after it on its line")
        expect(!SlashCommandPicker.opens(in: "/ b" as NSString, at: 0))
        expect(!SlashCommandPicker.opens(in: "a\n/b" as NSString, at: 2))
        expect(!SlashCommandPicker.opens(in: "ab" as NSString, at: 1), "not a slash")
        expect(!SlashCommandPicker.opens(in: "/" as NSString, at: 1), "past the end")
        expect(!SlashCommandPicker.opens(in: "/" as NSString, at: -1))
    },

    test("the query is the name typed after the slash, to the caret; each rule closes it") {
        let picker = try cardPicker()
        let read = { (text: String, caret: Int, isEdit: Bool, length: Int) in
            picker.read(text as NSString, selection: NSRange(location: caret, length: length), isEdit: isEdit)
        }
        expectEqual(read("/gr", 3, true, 0), nil)
        expectEqual(picker.query, "gr")
        expectEqual(read("/gr", 2, false, 0), nil, "back within it")
        expectEqual(picker.query, "g")
        expectEqual(read("/gr", 3, false, 0), nil, "forward to its end")
        expectEqual(picker.query, "gr")
        expectEqual(read("/gr more", 8, false, 0), .caretLeft, "past what was typed")
        expectEqual(read("/gr", 0, false, 0), .caretLeft, "before the slash")
        expectEqual(read("/gr", 1, false, 2), .caretLeft, "a selection")
        expectEqual(read("gr", 2, true, 0), .slashDeleted)
        expectEqual(read("", 0, true, 0), .slashDeleted)
        expectEqual(read("/gr ", 4, true, 0), .nameEnded, "whitespace")
        expectEqual(read("/gr\n", 4, true, 0), .nameEnded, "a line break")
        expectEqual(read("/gr\u{FFFC}", 4, true, 0), .nameEnded, "a pill")
        expectEqual(read("/gr.", 4, true, 0), .nameEnded, "punctuation")
        expectEqual(read("/gr_", 4, true, 0), .nameEnded)
        expectEqual(read("/Gr-1", 5, true, 0), nil, "letters in either case, digits and hyphens")
        let long = "/" + String(repeating: "g", count: 80)
        expectEqual(read(long, 81, true, 0), nil, "a query of the longest length, a title's")
        expectEqual(read(long + "g", 82, true, 0), .tooLong)
    },

    test("an empty query lists every command as it was offered, name and hint; the first is highlighted") {
        let picker = try cardPicker()
        expectEqual(picker.query, "")
        expectEqual(picker.listed.map(\.name), ["grow", "width", "log", "ping", "stack", "any"])
        expectEqual(picker.rows.map(rowText), ["grow", "width (points)", "log (text)", "ping", "stack (@shape)", "any (anything)"])
        expectEqual(picker.highlighted, 0)
        expectEqual(picker.highlightedCommand?.name, "grow")
        expectEqual(picker.nameRange, NSRange(location: 0, length: 1))
    },

    test("a typed query lists the names it matches, best tier first, then as offered; what's typed is matched in the row") {
        let picker = try cardPicker()
        _ = picker.read("/w" as NSString, selection: NSRange(location: 2, length: 0), isEdit: true)
        expectEqual(picker.listed.map(\.name), ["width", "grow"], "a prefix before a substring")
        expectEqual(picker.rows.compactMap(\.item?.matched), [[0..<1], [3..<4]])
        expectEqual(picker.highlighted, 0)
        picker.moveHighlight(by: 1)
        expectEqual(picker.highlightedCommand?.name, "grow")
        _ = picker.read("/w" as NSString, selection: NSRange(location: 2, length: 0), isEdit: false)
        expectEqual(picker.highlightedCommand?.name, "grow", "the same query keeps the highlight")
        _ = picker.read("/wi" as NSString, selection: NSRange(location: 3, length: 0), isEdit: true)
        expectEqual(picker.listed.map(\.name), ["width"])
        expectEqual(picker.highlighted, 0, "a changed query highlights its first row")
        _ = picker.read("/LOG" as NSString, selection: NSRange(location: 4, length: 0), isEdit: true)
        expectEqual(picker.listed.map(\.name), ["log"], "case is ignored")
        _ = picker.read("/p" as NSString, selection: NSRange(location: 2, length: 0), isEdit: true)
        expectEqual(picker.listed.map(\.name), ["ping"])
        _ = picker.read("/" as NSString, selection: NSRange(location: 1, length: 0), isEdit: true)
        expectEqual(picker.listed.count, 6, "an empty query again lists them all")
    },

    test("when nothing matches the list is the one row that says so, with nothing to highlight") {
        let picker = try cardPicker()
        _ = picker.read("/zzz" as NSString, selection: NSRange(location: 4, length: 0), isEdit: true)
        expectEqual(picker.listed.count, 0)
        expectEqual(picker.rows, [.empty("No matches")])
        expectEqual(picker.highlighted, nil)
        expectEqual(picker.highlightedCommand?.name, nil)
        picker.moveHighlight(by: 1)
        picker.highlight(row: 0)
        expectEqual(picker.highlighted, nil)
    },

    test("the name a pick replaces is the slash and the name there, past the caret too when it's in the middle of one") {
        let picker = try cardPicker()
        _ = picker.read("/gr" as NSString, selection: NSRange(location: 3, length: 0), isEdit: true)
        expectEqual(picker.nameRange, NSRange(location: 0, length: 3))
        _ = picker.read("/grow" as NSString, selection: NSRange(location: 3, length: 0), isEdit: false)
        expectEqual(picker.nameRange, NSRange(location: 0, length: 5), "the caret in the middle of the name")
        expectEqual(picker.query, "gr")
        let later = try cardPicker(at: 2)
        _ = later.read("a\n/grow  x" as NSString, selection: NSRange(location: 4, length: 0), isEdit: true)
        expectEqual(later.nameRange, NSRange(location: 2, length: 5), "wherever the slash is")
    },

    test("the highlight moves a row at a time, wrapping, and a page at a time, stopping at the ends") {
        let picker = try cardPicker()
        picker.moveHighlight(by: -1)
        expectEqual(picker.highlightedCommand?.name, "any")
        picker.moveHighlight(by: 1)
        expectEqual(picker.highlighted, 0)
        picker.moveHighlight(by: 8)
        expectEqual(picker.highlighted, 5)
        picker.highlight(row: 1)
        expectEqual(picker.highlightedCommand?.name, "width")
        picker.highlight(row: 9)
        expectEqual(picker.highlighted, 1, "no such row")
    },
])

/// A picker for the `/` at `location`, offering a card's commands as a shape offers them (`wide`
/// isn't: the card is narrow).
@MainActor private func cardPicker(at location: Int = 0) throws -> SlashCommandPicker {
    let h = try slashHarness([CardCommandsPlugin(log: CommandLog())])
    let card = h.add(Card(CGRect(x: 0, y: 0, width: 100, height: 60)))
    return SlashCommandPicker(at: location, offering: try require(h.editor.slashCommands).commands(for: card))
}
