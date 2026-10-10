import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import SlashCommands
import TestKit
import TextEditing

// Commands that take one choice (`SlashCommand`'s `choices:` form), typed in the same text view as
// TypingTests', over fixture commands on cards: when the list opens, what it lists and how a typed
// query narrows it, picking, and closing. Nothing goes on screen.

@MainActor private func session(_ text: String = "") throws -> SlashSession {
    let log = CommandLog()
    return try SlashSession(text, plugins: [ChoicePlugin(log: log)], log: log)
}

@MainActor let slashChoiceListTests = Suite("Slash command choices: the list", [
    test("Tab on a partly typed name completes it and the list becomes the choices") {
        let s = try session()
        s.type("/pic")
        s.window.settle()
        s.tab()
        expectEqual(s.string, "/pick ")
        expect(s.list == nil && s.choiceList != nil)
        expectEqual(s.choiceRows, ["Alpha", "Beta", "— Gamma"])
        expectEqual(s.caret, NSRange(location: 6, length: 0))
        let window = try require(s.view.slashCommands?.window)
        expect(s.view.caretListWindow === window && s.view.holdsKeys)
        expectEqual(window.frame.height, 3 * 28 + 10, "three rows of 28, and the list's insets")
    },

    test("a space typed after a complete name opens it, and only a space") {
        let s = try session()
        s.type("/pick")
        expect(s.list != nil && s.choiceList == nil)
        s.type(" ")
        expect(s.list == nil && s.choiceList != nil)
        expectEqual(s.choiceRows, ["Alpha", "Beta", "— Gamma"])

        let name = try session()
        name.type("/pick")
        name.returnKey()
        expectEqual(name.string, "/pick ", "Return in the names' list completes, as it does for a command that takes an argument")
        expect(name.choiceList != nil)
        expectEqual(name.log.runs, [])

        let other = try session()
        other.type("/grow ")
        expect(other.choiceList == nil, "a command that takes no choice")
        let title = try session()
        title.type("/log ")
        expect(title.choiceList == nil, "nor one that takes an argument")
        let partial = try session()
        partial.type("/pic ")
        expect(partial.choiceList == nil && partial.list == nil, "a name that isn't a command's")
    },

    test("a click on the name in the names' list opens it, and a space that already follows the name is stepped over") {
        let s = try session()
        s.type("/pick")
        s.view.slashCommands?.window?.pickHighlighted()
        expectEqual(s.string, "/pick ")
        expect(s.choiceList != nil)

        let spaced = try session()
        spaced.type("/pick")
        spaced.left()
        spaced.view.textStorage?.replaceCharacters(in: NSRange(location: 5, length: 0), with: " x")
        spaced.tab()
        expectEqual(spaced.string, "/pick x")
        expectEqual(spaced.caret, NSRange(location: 6, length: 0), "after the space that was there")
        expect(spaced.choiceList != nil)
        expectEqual(spaced.choiceList?.start, 6)
    },

    test("what's typed narrows the rows: matched letters, best match first and then the command's order") {
        let s = try session()
        s.type("/pick ")
        s.type("a")
        expectEqual(s.choiceList?.listed.map(\.id), ["alpha", "beta", "gamma"], "the prefix, then the substrings in the command's order")
        expectEqual(s.highlightedChoice, "alpha")
        s.type("m")
        expectEqual(s.choiceList?.listed.map(\.id), ["gamma"])
        expectEqual(s.choiceRows, ["Gamma"], "a lone row has no line")
        let item = try require(s.choiceList?.rows.first?.item)
        expectEqual(item.matched, [1..<3])
        expectEqual(item.symbol, "star")
        expectEqual(item.detail, "last")
        expectEqual(item.spoken, "Gamma, last")

    },

    test("rows of one group have no line between them, also narrowed") {
        let s = try session()
        s.type("/pick ")
        expectEqual(s.choiceRows, ["Alpha", "Beta", "— Gamma"])
        s.type("a")
        expectEqual(s.choiceRows, ["Alpha", "Beta", "— Gamma"], "the line stays where the group changes, as narrowed")
    },

    test("the highlight starts on the first preferred row, else the first, and on the best match once something is typed") {
        let s = try session()
        s.type("/pick ")
        expectEqual(s.highlightedChoice, "beta", "preferred")
        s.type("g")
        expectEqual(s.highlightedChoice, "gamma")

        let none = try session()
        none.type("/pick-else ")
        expectEqual(none.highlightedChoice, "one", "the first when none is preferred")
    },

    test("nothing matches: No matches, nothing highlighted, and Return is a new line that closes it; an empty list says None") {
        let s = try session()
        s.type("/pick zz")
        expectEqual(s.choiceRows, ["- No matches"])
        expectEqual(s.highlightedChoice, nil)
        s.returnKey()
        expectEqual(s.string, "/pick zz\n")
        expect(s.choiceList == nil)
        expectEqual(s.log.runs, [])

        let empty = try session()
        empty.type("/pick-none ")
        expectEqual(empty.choiceRows, ["- None"])
        empty.type("x")
        expectEqual(empty.choiceRows, ["- No matches"])
    },

    test("a choice command's argument shows in the names' list, and two plugins offering its name are a conflict, as for every command") {
        let s = try session()
        s.type("/pick")
        expectEqual(s.rows.first, "pick (item)")

        let log = CommandLog()
        expectThrows(RegistryError.conflict(point: "ShapeSlashCommands", key: "card /pick", plugins: ["choices", "again"])) {
            _ = try Registry(plugins: slashPlugins([ChoicePlugin(log: log), Contributor(id: "again") { registrar in
                registrar.slashCommands(Card.self) { SlashCommand("pick", argument: "x", choices: { _, _ in [] }) { _, _, _ in } }
            }]))
        }
    },

    test("the rows are asked for once while the list is open, however much is typed") {
        let s = try session()
        s.type("/pick ")
        expectEqual(s.log.choicesAsked, 1)
        s.type("gam")
        s.window.pressDelete()
        s.left()
        expectEqual(s.log.choicesAsked, 1)
    },
])

@MainActor let slashChoicePickTests = Suite("Slash command choices: picking", [
    test("Return runs the highlighted row at once: the line goes, editing goes on, one undo step named for the row") {
        let s = try session("keep")
        s.newLine()
        s.type("/pick ")
        let width = s.width
        s.returnKey()
        expectEqual(s.string, "keep\n")
        expectEqual(s.cardText, "keep\n", "the host heard it go")
        expectEqual(s.caret, NSRange(location: 5, length: 0))
        expectEqual(s.log.runs, ["pick beta"])
        expectEqual(s.width, width + 1)
        expect(s.choiceList == nil && s.view.slashCommands?.window == nil)
        expectEqual(s.h.editor.undoHistory.undoName, "Pick Beta", "the row's step")
        expect(s.h.editor.editingShapeID == s.card, "editing goes on")
    },

    test("a row with no step of its own is a step named for the command") {
        let s = try session()
        s.type("/pick al")
        s.returnKey()
        expectEqual(s.log.runs, ["pick alpha"])
        expectEqual(s.h.editor.undoHistory.undoName, "Pick")
    },

    test("Tab and a click do the same") {
        let tab = try session()
        tab.type("/pick g")
        tab.tab()
        expectEqual(tab.log.runs, ["pick gamma"])
        expectEqual(tab.string, "")

        let click = try session()
        click.type("/pick ")
        click.down()
        click.view.slashCommands?.window?.pickHighlighted()
        expectEqual(click.log.runs, ["pick gamma"])
        expectEqual(click.string, "")
    },

    test("the text's undo and the board's are apart: the line stays gone after the text's, and the pick is undone by the board's alone") {
        let s = try session("x\n")
        s.type("/pick al")
        s.returnKey()
        let width = s.width
        s.window.settle()
        s.view.undoManager?.undo()
        expectEqual(s.width, width, "the text's undo doesn't take the pick back")
        expect(s.log.runs == ["pick alpha"])
        s.h.editor.undo()
        expectEqual(s.width, width - 1)
    },

    test("when nothing matches, the command's own row is the one row, highlighted, and runs with its id and step") {
        let s = try session()
        s.type("/pick-else zeta")
        expectEqual(s.choiceRows, ["Else zeta"])
        expectEqual(s.highlightedChoice, "else:zeta")
        s.returnKey()
        expectEqual(s.log.runs, ["pick else:zeta"])
        expectEqual(s.h.editor.undoHistory.undoName, "Make Else")

        let nope = try session()
        nope.type("/pick-else nope")
        expectEqual(nope.choiceRows, ["- No matches"], "a nil leaves No matches")
        let matching = try session()
        matching.type("/pick-else on")
        expectEqual(matching.choiceRows, ["One"], "it isn't offered while something matches")
    },

    test("the pick of a shape that is gone does nothing") {
        let s = try session()
        s.type("/pick al")
        s.h.editor.transact { $0.delete([s.card]) }
        s.returnKey()
        expectEqual(s.log.runs, [])
    },
])

@MainActor let slashChoiceClosingTests = Suite("Slash command choices: closing and the closed line", [
    test("Escape closes it and typing more doesn't reopen it; a space does") {
        let s = try session()
        s.type("/pick ")
        s.pressEscapeKey()
        expect(s.choiceList == nil)
        s.type("be")
        expect(s.choiceList == nil)
        s.set("/pick ")
        s.type(" ")
        expect(s.choiceList != nil, "the next space")
    },

    test("the caret left of what's typed, a line break, and deleting the space or the name close it; arrows move the highlight and don't") {
        let left = try session()
        left.type("/pick x")
        left.left()
        left.left()
        expect(left.choiceList == nil, "before the argument")

        let broke = try session()
        broke.type("/pick ")
        broke.set("/pick \n", caret: 7)
        broke.view.slashCommands?.didChange(isEdit: true)
        expect(broke.choiceList == nil)

        let space = try session()
        space.type("/pick ")
        space.window.pressDelete()
        expect(space.choiceList == nil, "the space")

        let name = try session()
        name.type("/pick ")
        name.view.textStorage?.replaceCharacters(in: NSRange(location: 1, length: 1), with: "x")
        expect(name.choiceList == nil, "the name changed")

        let arrows = try session()
        arrows.type("/pick ")
        arrows.down()
        expectEqual(arrows.highlightedChoice, "gamma")
        arrows.up()
        expectEqual(arrows.highlightedChoice, "beta")
        expect(arrows.choiceList != nil)
    },

    test("a shape the command isn't offered for, or can't be written, offers no list") {
        let s = try session()
        s.type("/pick-wide ")
        expect(s.list == nil && s.choiceList == nil, "the card is narrow: nothing is offered")
        expectEqual(s.string, "/pick-wide ")

        let readOnly = try session()
        readOnly.set("/pick ")
        readOnly.view.isEditable = false
        readOnly.view.slashCommands?.didType(" ")
        expect(readOnly.choiceList == nil)
    },

    test("the text's substitutions are off while it's open and back after") {
        let s = try session()
        s.view.isAutomaticQuoteSubstitutionEnabled = true
        s.type("/pick ")
        expect(!s.view.isAutomaticQuoteSubstitutionEnabled)
        s.pressEscapeKey()
        expect(s.view.isAutomaticQuoteSubstitutionEnabled)
    },

    test("with the list closed, Return on the line typed whole runs the row of that title; on anything else it is a new line; the rows are asked for at Return only") {
        let s = try session()
        s.type("/pick ")
        s.pressEscapeKey()
        s.type("bEta")
        expectEqual(s.log.choicesAsked, 1, "once, when it opened")
        s.returnKey()
        expectEqual(s.log.runs, ["pick beta"])
        expectEqual(s.string, "")
        expectEqual(s.log.choicesAsked, 2, "and once at Return")

        let no = try session()
        no.type("/pick ")
        no.pressEscapeKey()
        no.type("bet")
        no.returnKey()
        expectEqual(no.string, "/pick bet\n")
        expectEqual(no.log.runs, [])
    },

    test("a closed line marks its name alone, and asks nothing at a keystroke or a move of the caret") {
        let s = try session()
        s.type("/pick ")
        s.pressEscapeKey()
        let asked = s.log.choicesAsked
        s.type("beta")
        s.left()
        expectEqual(s.log.choicesAsked, asked)
        expectEqual(s.view.highlights.map(\.range), [NSRange(location: 0, length: 5)], "the name alone")
    },

    test("listsChoices(at:) is true on a choice command's line and nowhere else") {
        let s = try session("one\n/pick @")
        let commands = try require(s.view.slashCommands)
        expect(commands.listsChoices(at: 10))
        expect(!commands.listsChoices(at: 2), "a plain line")
        s.set("/log @")
        expect(!commands.listsChoices(at: 5), "a command that takes an argument")
        s.set("/pick-wide @")
        expect(!commands.listsChoices(at: 11), "one the shape isn't offered")
    },
])
