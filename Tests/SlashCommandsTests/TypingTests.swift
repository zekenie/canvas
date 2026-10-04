import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import SlashCommands
import TestKit
import TextEditing

// Slash commands typed in a text view (an `EditingTextView` of this target's own that forwards to
// `SlashCommandTyping` as a mention text view does), in an unshown window: when the list opens, its
// keys, completing, and running a command line, over a card being edited on an `EditorHarness`
// board. Nothing goes on screen.

private let idA = ShapeID(UUID(uuidString: "7C1E0B8A-2F4D-4A6B-9C3E-5D2F1A0B9C8D")!)

@MainActor let slashTypingTests = Suite("Slash command typing", [
    // MARK: Opening

    test("a slash on an empty line lists what the shape offers, under the slash; the view holds its keys and shows the list as its own") {
        let s = try SlashSession()
        s.type("/")
        expectEqual(s.string, "/")
        expectEqual(s.listed, ["grow", "width", "log", "ping", "any"])
        expectEqual(s.rows, ["grow", "width (points)", "log (text)", "ping", "any (anything)"])
        expectEqual(s.highlighted, "grow")
        let window = try require(s.view.slashCommands?.window)
        expect(s.view.caretListWindow === window)
        expect(s.view.holdsKeys)
        expectEqual(window.frame.width, 240)
        expectEqual(window.frame.height, 5 * 24 + 10, "five rows of 24, and the list's insets")
        s.pressEscapeKey()
        expect(s.view.caretListWindow == nil && !s.view.holdsKeys)
    },

    test("a slash opens it on a later line too, after any line break, and at the start of the text") {
        let s = try SlashSession("one")
        s.newLine()
        s.type("/")
        expect(s.list != nil)
        expectEqual(s.list?.location, 4)
        s.pressEscapeKey()
        s.set("one\r\ntwo\u{2028}", caret: 9)
        s.type("/")
        expectEqual(s.list?.location, 9)
    },

    test("anywhere else a slash is a slash: mid-line, before text on its line, with no command offered, read-only, pasted, undone, composed") {
        let s = try SlashSession("")
        s.type("a/")
        expect(s.list == nil, "mid-line")
        s.set("abc", caret: 0)
        s.type("/")
        expectEqual(s.string, "/abc")
        expect(s.list == nil, "the start of a line that has text")
        s.set("x\nabc", caret: 2)
        s.type("/")
        expect(s.list == nil, "a later line that has text")
        s.set(" ", caret: 1)
        s.type("/")
        expect(s.list == nil, "after whitespace on the line")

        let none = try SlashSession("", offering: false)
        none.type("/")
        expectEqual(none.string, "/")
        expect(none.list == nil, "nothing offered")

        let readOnly = try SlashSession("")
        readOnly.set("/")
        readOnly.view.isEditable = false
        readOnly.view.slashCommands?.didType("/")
        expect(readOnly.list == nil, "a view that can't be written")
        readOnly.view.isEditable = true
        readOnly.view.slashCommands?.didType("/")
        expect(readOnly.list != nil, "and it can")

        let pasted = try SlashSession("")
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.declareTypes([.string], owner: nil)
        board.setString("/", forType: .string)
        expect(pasted.view.readSelection(from: board))
        expectEqual(pasted.string, "/")
        expect(pasted.list == nil, "pasted")

        let undone = try SlashSession("")
        undone.type("/")
        undone.pressEscapeKey()
        undone.window.settle()
        undone.view.breakUndoCoalescing()
        undone.window.pressDelete()
        undone.window.settle()
        expectEqual(undone.string, "")
        undone.view.undoManager?.undo()
        expectEqual(undone.string, "/")
        expect(undone.list == nil, "undone")

        let composing = try SlashSession("")
        composing.view.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        composing.view.insertText("/", replacementRange: NSRange(location: NSNotFound, length: 0))
        expect(composing.list == nil, "while an input method composes")

        let two = try SlashSession("")
        two.type("//")
        expect(two.list == nil, "the second of two slashes is mid-line")
    },

    // MARK: Narrowing and closing

    test("what's typed after it narrows the list; ↓ and ↑ move the highlight, wrapping") {
        let s = try SlashSession()
        s.type("/w")
        expectEqual(s.listed, ["width", "grow"])
        expectEqual(s.highlighted, "width")
        s.down()
        expectEqual(s.highlighted, "grow")
        s.down()
        expectEqual(s.highlighted, "width", "wraps")
        s.up()
        expectEqual(s.highlighted, "grow")
        s.type("x")
        expectEqual(s.rows, ["- No matches"])
        expectEqual(s.highlighted, nil)
        s.window.pressDelete()
        expectEqual(s.listed, ["width", "grow"])
        expectEqual(s.string, "/w")
    },

    test("a space, the slash deleted, the caret leaving the name, Escape, and a view that loses the keyboard close it") {
        let space = try SlashSession()
        space.type("/gr ")
        expect(space.list == nil && space.view.caretListWindow == nil)
        expectEqual(space.string, "/gr ")

        let deleted = try SlashSession()
        deleted.type("/")
        deleted.window.pressDelete()
        expect(deleted.list == nil)
        expectEqual(deleted.string, "")

        let left = try SlashSession()
        left.type("/gr")
        left.left()
        expectEqual(left.list?.query, "g", "within the name it stays")
        left.left()
        expectEqual(left.list?.query, "")
        expect(left.list != nil)
        left.left()
        expect(left.list == nil, "before the slash")
        expectEqual(left.string, "/gr")

        let escaped = try SlashSession()
        escaped.type("/gr")
        escaped.pressEscapeKey()
        expect(escaped.list == nil)
        expectEqual(escaped.string, "/gr", "its text stays")
        escaped.type("o")
        expect(escaped.list == nil, "and typing on doesn't open it again")

        let punctuation = try SlashSession()
        punctuation.type("/gr.")
        expect(punctuation.list == nil)

        let blurred = try SlashSession()
        blurred.type("/")
        expect(blurred.window.makeFirstResponder(nil))
        expect(blurred.list == nil && blurred.view.caretListWindow == nil)

        let locked = try SlashSession()
        locked.type("/")
        locked.view.isEditable = false
        expect(locked.list == nil, "made read-only")
    },

    test("Tab and Return with nothing highlighted are the text's: a tab character, a new line") {
        let s = try SlashSession()
        s.type("/zz")
        expectEqual(s.rows, ["- No matches"])
        s.tab()
        expectEqual(s.string, "/zz\t")
        expect(s.list == nil, "a character that can't be in a name closes it")
    },

    test("the text's substitutions are off while the list is open and back as it closes") {
        let s = try SlashSession()
        let view = s.view
        view.isAutomaticSpellingCorrectionEnabled = true
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticQuoteSubstitutionEnabled = true
        view.isAutomaticDashSubstitutionEnabled = false
        s.type("/")
        expect(!view.isAutomaticSpellingCorrectionEnabled && !view.isAutomaticTextReplacementEnabled)
        expect(!view.isAutomaticQuoteSubstitutionEnabled && !view.isAutomaticDashSubstitutionEnabled)
        s.pressEscapeKey()
        expect(view.isAutomaticSpellingCorrectionEnabled)
        expect(!view.isAutomaticTextReplacementEnabled)
        expect(view.isAutomaticQuoteSubstitutionEnabled)
        expect(!view.isAutomaticDashSubstitutionEnabled)
        s.newLine()
        s.type("/")
        expect(!view.isAutomaticSpellingCorrectionEnabled && !view.isAutomaticQuoteSubstitutionEnabled)
        s.type(" ")
        expect(view.isAutomaticSpellingCorrectionEnabled && view.isAutomaticQuoteSubstitutionEnabled, "a space closes it, and they come back")
        expect(!view.isAutomaticTextReplacementEnabled && !view.isAutomaticDashSubstitutionEnabled)
    },

    // MARK: Completing

    test("Tab completes: the name typed becomes the command's, with a space if it takes an argument; one step of the text's undo") {
        let s = try SlashSession()
        s.type("/gr")
        s.window.settle()
        s.tab()
        expectEqual(s.string, "/grow")
        expect(s.list == nil)
        expectEqual(s.caret, NSRange(location: 5, length: 0))
        s.window.settle()
        s.view.undoManager?.undo()
        expectEqual(s.string, "/gr", "one step, which gives back what was typed")
        s.window.settle()
        s.view.undoManager?.redo()
        expectEqual(s.string, "/grow")

        let argument = try SlashSession()
        argument.type("/wi")
        argument.tab()
        expectEqual(argument.string, "/width ")
        expectEqual(argument.caret, NSRange(location: 7, length: 0))
        expect(argument.list == nil)
        expectEqual(argument.cardText, "/width ", "the host heard it")
    },

    test("completing adds no space where whitespace follows on the line, and replaces the rest of a name the caret is in") {
        let s = try SlashSession()
        s.set("/\nbar", caret: 1)
        s.view.slashCommands?.didType("/")
        expect(s.list != nil)
        s.type("wi")
        expectEqual(s.string, "/wi\nbar")
        s.tab()
        expectEqual(s.string, "/width \nbar", "a line break follows, which is no whitespace on the line")
        expectEqual(s.caret, NSRange(location: 7, length: 0))

        let spaced = try SlashSession()
        spaced.type("/wi")
        spaced.left()
        spaced.view.textStorage?.replaceCharacters(in: NSRange(location: 3, length: 0), with: " x")
        expectEqual(spaced.list?.nameRange, NSRange(location: 0, length: 3), "the list is open over the name, a space after it")
        spaced.tab()
        expectEqual(spaced.string, "/width x", "a space follows, and none is added")
        expectEqual(spaced.caret, NSRange(location: 6, length: 0))

        let middle = try SlashSession()
        middle.type("/grow")
        middle.left()
        middle.left()
        expectEqual(middle.list?.query, "gr")
        expectEqual(middle.list?.nameRange, NSRange(location: 0, length: 5))
        middle.tab()
        expectEqual(middle.string, "/grow", "the whole name is replaced, not added to")
    },

    test("completing a command that takes an argument on an empty line above another line adds the space: a line break isn't whitespace on its line") {
        let s = try SlashSession()
        s.set("a\n/\nb", caret: 3)
        s.view.slashCommands?.didType("/")
        expect(s.list != nil)
        s.type("wi")
        expectEqual(s.string, "a\n/wi\nb")
        s.tab()
        expectEqual(s.string, "a\n/width \nb", "the argument doesn't run into the line below")
        expectEqual(s.caret, NSRange(location: 9, length: 0))

        for lineBreak in ["\r", "\u{2028}", "\u{2029}", "\u{85}"] {
            let other = try SlashSession()
            other.set("/\(lineBreak)b", caret: 1)
            other.view.slashCommands?.didType("/")
            other.type("wi")
            other.tab()
            expectEqual(other.string, "/width \(lineBreak)b", "\(lineBreak.unicodeScalars.map(\.value))")
        }
    },

    test("a click on a row completes it as Tab does") {
        let s = try SlashSession()
        s.type("/")
        s.down()
        s.down()
        s.down()
        expectEqual(s.highlighted, "ping")
        s.view.slashCommands?.window?.pickHighlighted()
        expectEqual(s.string, "/ping")
        expect(s.list == nil)
        expectEqual(s.log.runs, [], "completing runs nothing")
    },

    // MARK: Running

    test("Return runs a highlighted command that takes nothing at once: its line goes, the other lines stay, and the command is one undo step named for it") {
        let s = try SlashSession("keep")
        s.newLine()
        s.type("/gr")
        expectEqual(s.highlighted, "grow")
        let width = s.width
        s.returnKey()
        expectEqual(s.string, "keep\n", "the line is gone, its break is not")
        expectEqual(s.caret, NSRange(location: 5, length: 0), "the caret on the now empty line")
        expectEqual(s.cardText, "keep\n", "and the host heard it go")
        expectEqual(s.width, width + 10)
        expect(s.list == nil)
        expectEqual(s.h.editor.undoHistory.undoName, "Grow")
    },

    test("Return in the list on a command that takes an argument completes it, so the argument can be typed; Return then runs it") {
        let s = try SlashSession()
        s.type("/wi")
        s.returnKey()
        expectEqual(s.string, "/width ")
        expectEqual(s.width, 100, "nothing ran")
        s.type("150")
        s.returnKey()
        expectEqual(s.string, "")
        expectEqual(s.width, 150)
        expectEqual(s.h.editor.undoHistory.undoName, "Width")
    },

    test("Return on a whole line runs it with what's typed after its name; the other lines stay") {
        let s = try SlashSession("")
        s.type("/log hello there")
        s.returnKey()
        expectEqual(s.log.runs, ["log hello there"])
        expectEqual(s.string, "")
        expectEqual(s.caret, NSRange(location: 0, length: 0))

        s.set("above\n/PING\nbelow", caret: 11)
        s.returnKey()
        expectEqual(s.log.runs, ["log hello there", "ping"], "the name folded")
        expectEqual(s.string, "above\n\nbelow")
        expectEqual(s.caret, NSRange(location: 6, length: 0), "at the line's start")
        expectEqual(s.h.editor.undoHistory.undoName, "Typing", "a command that commits nothing makes no step of its own")

        s.set("/log   spaced   out  ", caret: 4)
        s.returnKey()
        expectEqual(s.log.runs.last, "log spaced   out", "the caret anywhere after the slash; whitespace at both ends trimmed")
        expectEqual(s.string, "")

        s.set("/any")
        s.type(" ")
        s.returnKey()
        expectEqual(s.log.runs.last, "any \"\"", "a command that accepts nothing runs with nothing")
    },

    test("what isn't a command is Return as ever: /unknown, a command that takes nothing given something, one that needs something given none, one not offered") {
        for text in ["/unknown", "/grow foo", "/width ", "/wide ", "/ping now", "/ ", "/log"] {
            let s = try SlashSession("")
            s.type(text)
            if s.list != nil { s.pressEscapeKey() }
            let width = s.width
            s.returnKey()
            expectEqual(s.string, text + "\n", text)
            expectEqual(s.log.runs, [], text)
            expectEqual(s.width, width, text)
            expectEqual(s.h.editor.undoHistory.undoName, "Typing", text)
        }
        // With the list open and nothing highlighted: a new line, which closes the list.
        let open = try SlashSession("")
        open.type("/unknown")
        expect(open.list != nil)
        open.returnKey()
        expectEqual(open.string, "/unknown\n")
        expect(open.list == nil)
    },

    test("⇧↩ is not Return: it doesn't run a command line, nor pick from the list") {
        let s = try SlashSession("")
        s.type("/ping")
        s.returnKey(.shift)
        expectEqual(s.log.runs, [])
        expect(s.string.hasPrefix("/ping"))
        let line = try SlashSession("")
        line.type("/ping ")
        line.returnKey(.shift)
        expectEqual(line.log.runs, [])
        line.returnKey(.option)
        expectEqual(line.log.runs, [])
        expect(line.string.hasPrefix("/ping"), "the text stays")
    },

    test("a selection, the caret before the slash, or text being composed make Return a new line") {
        let selected = try SlashSession("")
        selected.set("/ping")
        selected.view.setSelectedRange(NSRange(location: 1, length: 4))
        expect(selected.view.slashCommands?.takesReturn() == false)
        selected.returnKey()
        expectEqual(selected.log.runs, [])

        let before = try SlashSession("")
        before.set("/ping", caret: 0)
        expect(before.view.slashCommands?.takesReturn() == false)

        let composing = try SlashSession("")
        composing.set("/ping")
        composing.view.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        expect(composing.view.hasMarkedText())
        expect(composing.view.slashCommands?.takesReturn() == false)
        expectEqual(composing.log.runs, [])

        let plain = try SlashSession("")
        plain.set("/ping")
        expect(plain.view.slashCommands?.takesReturn() == true, "and with none of that, it runs")
        expectEqual(plain.log.runs, ["ping"])
    },

    test("the text's own undo brings the line back and leaves the command done; the board's undo undoes the command by its name, the typing before it next") {
        let s = try SlashSession("keep")
        s.newLine()
        s.type("/grow")
        s.window.settle()
        s.returnKey()
        s.window.settle()
        expectEqual(s.string, "keep\n")
        expectEqual(s.width, 110)
        s.view.undoManager?.undo()
        expectEqual(s.string, "keep\n/grow", "the line is back")
        expectEqual(s.width, 110, "the command isn't undone: text undo is the text's")
        s.window.settle()
        s.view.undoManager?.redo()
        expectEqual(s.string, "keep\n")

        let history = s.h.editor.undoHistory
        expectEqual(history.undoName, "Grow")
        s.h.editor.undo()
        expectEqual(s.width, 100)
        expectEqual(history.undoName, "Typing", "the step before the command is the typing")
        s.h.editor.undo()
        expectEqual(s.cardText, "keep")
        expectEqual(history.undoName, nil)
        s.h.editor.redo()
        s.h.editor.redo()
        expectEqual(s.width, 110)
    },

    test("the command's step closes the editing session's, so more typing after it is a step of its own") {
        let s = try SlashSession("keep")
        s.newLine()
        s.type("/grow")
        s.returnKey()
        s.type("more")
        let history = s.h.editor.undoHistory
        expectEqual(history.undoName, "Typing")
        s.h.editor.undo()
        expectEqual(s.width, 110, "that was the typing after")
        expectEqual(s.cardText, "keep\n")
        expectEqual(history.undoName, "Grow")
    },

    test("in a box that commits on Return, a command line runs and doesn't commit; Return anywhere else commits as it does") {
        let s = try SlashSession("")
        s.view.onCommit = { [host = s.host] in host.commit() }
        s.view.commitsOnReturn = true
        s.type("/ping ")
        s.returnKey()
        expectEqual(s.log.runs, ["ping"])
        expectEqual(s.host.commits, 0, "it ran, it didn't commit")
        s.type("plain")
        s.returnKey()
        expectEqual(s.host.commits, 1)
        expectEqual(s.string, "plain", "and added no line")
        s.set("")
        s.type("/pi")
        s.returnKey()
        expectEqual(s.log.runs, ["ping", "ping"], "from the list too")
        expectEqual(s.host.commits, 1)
        s.type("/unknown")
        s.returnKey()
        expectEqual(s.host.commits, 1, "the list's Return with nothing to pick is a new line, not a commit")
        s.returnKey()
        expectEqual(s.host.commits, 2, "with the list closed it commits")
    },

    test("the arguments are read by the host's reader: runs of text and shapes") {
        let s = try SlashSession("", arguments: { _ in SlashArguments([.text("near "), .shape(idA, label: "Groceries")]) })
        s.type("/log x ")
        s.returnKey()
        expectEqual(s.log.runs, ["log near @Groceries"])
    },

    test("a command that is no longer offered when its line is entered is left as text, and one that's offered runs after the line is gone") {
        let s = try SlashSession("")
        s.type("/wide ")
        s.returnKey()
        expectEqual(s.string, "/wide \n")
        expectEqual(s.width, 100)
        s.set("")
        s.type("/grow")
        s.returnKey()
        s.type("/wide")
        s.returnKey()
        expectEqual(s.width, 100, "once the card is wide, /wide is offered, and narrows it")
        expectEqual(s.string, "")
        expectEqual(s.h.editor.undoHistory.undoName, "Wide")
    },

    test("a command that is offered only while the text isn't blank runs when its line is the text's only one, and its line goes") {
        let s = try SlashSession("", plugins: [FilledCommandPlugin()])
        s.type("/filled")
        expectEqual(s.cardText, "/filled", "the host has the line, so the card's text isn't blank as Return is pressed")
        let width = s.width
        s.returnKey()
        expectEqual(s.string, "", "the line is gone")
        expectEqual(s.cardText, "")
        expectEqual(s.width, width + 5, "and the command ran, though the text it reads is blank now")
        expectEqual(s.h.editor.undoHistory.undoName, "Filled")

        let blank = try SlashSession("", plugins: [FilledCommandPlugin()])
        expect(blank.h.editor.slashCommands?.command(named: "filled", for: blank.card) == nil, "offered only while there's text")
        expect(blank.h.editor.slashCommands?.run("filled", on: blank.card, with: SlashArguments([])) == false, "and by name it is asked")
    },

    // MARK: Marking the command

    test("while the list is open the slash and the name typed are marked, so long as it lists something") {
        let s = try SlashSession()
        expectEqual(s.marked, [])
        s.type("/")
        expectEqual(s.marked, [NSRange(location: 0, length: 1)], "the slash alone")
        s.type("wid")
        expectEqual(s.marked, [NSRange(location: 0, length: 4)], "and as much of the name as is typed")
        s.type("zz")
        expectEqual(s.rows, ["- No matches"])
        expectEqual(s.marked, [], "no command is no mark")
        s.window.pressDelete()
        s.window.pressDelete()
        expectEqual(s.marked, [NSRange(location: 0, length: 4)], "and back once it lists one")

        let middle = try SlashSession()
        middle.type("/grow")
        middle.left()
        middle.left()
        expectEqual(middle.marked, [NSRange(location: 0, length: 5)], "the whole name, past the caret too")
    },

    test("with the list closed a line the shape offers a command on is marked: the name, and what it takes in a lighter shade") {
        let s = try SlashSession()
        s.type("/width")
        s.type(" 50")
        expect(s.list == nil)
        expectEqual(s.marked, [NSRange(location: 0, length: 6), NSRange(location: 7, length: 2)])
        let name = try require(s.view.highlights.first), arguments = try require(s.view.highlights.last)
        expect(s.alpha(of: name) > s.alpha(of: arguments), "the command firmly, what it's given lighter")
        expect(s.alpha(of: arguments) > 0)

        s.type(" and more")
        expectEqual(s.marked, [NSRange(location: 0, length: 6), NSRange(location: 7, length: 11)], "to the line's end")
        s.window.pressDelete()
        expectEqual(s.marked, [NSRange(location: 0, length: 6), NSRange(location: 7, length: 10)], "following what's typed")

        let bare = try SlashSession()
        bare.type("/ping")
        bare.pressEscapeKey()
        expect(bare.list == nil)
        expectEqual(bare.marked, [NSRange(location: 0, length: 5)], "Escape closes the list; the line is still a command's")
        bare.type(" ")
        expectEqual(bare.marked, [NSRange(location: 0, length: 5)], "trailing whitespace is nothing it takes")
    },

    test("arguments the command doesn't accept are text and unmarked; one that accepts anything marks them") {
        let s = try SlashSession()
        s.type("/ping now")
        expectEqual(s.marked, [NSRange(location: 0, length: 5)], "/ping takes nothing, so \"now\" stays text")
        s.set("/any x")
        expectEqual(s.marked, [NSRange(location: 0, length: 4), NSRange(location: 5, length: 1)])
        s.set("/width")
        expectEqual(s.marked, [NSRange(location: 0, length: 6)], "/width given nothing is not accepted, and there is nothing to mark")
    },

    test("only a line the shape offers a command on, with the caret on it after the slash, is marked") {
        let s = try SlashSession()
        s.set("/nope here")
        expectEqual(s.marked, [], "not a command it offers")
        s.set("/wide")
        expectEqual(s.marked, [], "/wide is offered only while the card is wide")

        s.set("/ping\nplain", caret: 3)
        expectEqual(s.marked, [NSRange(location: 0, length: 5)])
        s.set("/ping\nplain", caret: 8)
        expectEqual(s.marked, [], "the caret on another line")
        s.set("/ping\nplain", caret: 0)
        expectEqual(s.marked, [], "the caret before the slash")
        s.set("a\n/log x", caret: 4)
        expectEqual(s.marked, [NSRange(location: 2, length: 4), NSRange(location: 7, length: 1)], "on a later line")
        s.view.setSelectedRange(NSRange(location: 2, length: 4))
        expectEqual(s.marked, [], "a selection")
        s.set("/PING")
        expectEqual(s.marked, [NSRange(location: 0, length: 5)], "the name folded, as Return reads it")
    },

    test("Tab marks what it completes, and Return, which takes the line out, marks nothing") {
        let s = try SlashSession()
        s.type("/wi")
        s.tab()
        expectEqual(s.string, "/width ")
        expectEqual(s.marked, [NSRange(location: 0, length: 6)])

        let grow = try SlashSession()
        grow.type("/gr")
        grow.tab()
        expectEqual(grow.marked, [NSRange(location: 0, length: 5)])
        grow.returnKey()
        expectEqual(grow.string, "")
        expectEqual(grow.marked, [], "the line is gone")

        let list = try SlashSession()
        list.type("/gr")
        expectEqual(list.marked, [NSRange(location: 0, length: 3)])
        list.returnKey()
        expectEqual(list.marked, [])
    },

    test("nothing is marked in a view that can't be written, and a mark is taken away as one is made read-only") {
        let s = try SlashSession()
        s.type("/ping")
        expect(!s.marked.isEmpty)
        s.view.isEditable = false
        expectEqual(s.marked, [], "taken away")
        s.view.slashCommands?.didChange(isEdit: false)
        expectEqual(s.marked, [], "and not made while it can't be written")
        s.view.isEditable = true
        s.view.slashCommands?.didChange(isEdit: false)
        expectEqual(s.marked, [NSRange(location: 0, length: 5)])
    },
])

extension SlashSession {
    /// The ranges the view marks as a command, in order.
    var marked: [NSRange] { view.highlights.map(\.range) }

    /// How strong a mark's fill is: the alpha of the text's color it was made from.
    func alpha(of highlight: TextHighlight) -> CGFloat {
        highlight.fill.usingColorSpace(.deviceRGB)?.alphaComponent ?? 0
    }
}

extension SlashSession {
    func pressEscapeKey() { window.pressEscape() }
}
