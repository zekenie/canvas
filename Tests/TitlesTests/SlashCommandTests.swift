import Adornments
import Canvas
import CanvasTesting
import Keyboard
import Selection
import SlashCommands
import TestKit
import Titles

// `/title`, the slash command Titles offers: on the kinds that keep a title, one line of a shape's
// text names it. Typing it is the shipped app's (CompositionTests).

@MainActor let titleSlashTests = Suite("Titles and slash commands", [
    test("/title is offered on the kinds that keep a title: not on one with none, nor on one titled only by derivation") {
        let editor = try titleEditor([CardsPlugin(), CardTitlesPlugin()])
        let state = try require(editor.slashCommands)
        let plaque = editor.add(Plaque(plaqueFrame))
        let named = editor.add(Plaque(plaqueFrame), named: "Lobby")
        let box = editor.add(Box(plaqueFrame))
        let card = editor.add(Card(plaqueFrame, text: "Hello"))
        expectEqual(state.commands(for: plaque).map(\.name), ["title"])
        expectEqual(state.commands(for: named).map(\.name), ["title"], "named already: it renames")
        expectEqual(state.commands(for: plaque).first?.argument, "title", "it takes one")
        expectEqual(state.commands(for: box).map(\.name), [], "a box has no title to set")
        expectEqual(editor.title(card), "Hello")
        expectEqual(state.commands(for: card).map(\.name), [], "a card's title is derived from its text, and renamed there")
    },

    test("running it names the shape in one step called Title; undoing it puts the old name back, named or not") {
        let editor = try titleEditor()
        let state = try require(editor.slashCommands)
        let unnamed = editor.add(Plaque(plaqueFrame))
        let named = editor.add(Plaque(plaqueFrame), named: "Lobby")
        expect(state.run("title", on: unnamed, with: "Hall"))
        expectEqual(editor.name(unnamed), "Hall")
        expectEqual(editor.undoHistory.undoName, "Title")
        editor.undo()
        expectEqual(editor.name(unnamed), nil)
        expect(state.run("title", on: named, with: "Front desk"))
        expectEqual(editor.name(named), "Front desk")
        expectEqual(editor.undoHistory.undoName, "Title")
        editor.undo()
        expectEqual(editor.name(named), "Lobby")
        editor.redo()
        expectEqual(editor.name(named), "Front desk")
    },

    test("with nothing typed it isn't accepted: it doesn't run, and the title stays") {
        let editor = try titleEditor()
        let state = try require(editor.slashCommands)
        let id = editor.add(Plaque(plaqueFrame), named: "Lobby")
        let command = try require(state.command(named: "title", for: id))
        let undoName = editor.undoHistory.undoName
        let nothing: [SlashArguments] = ["", "   ", SlashArguments([])]
        for arguments in nothing {
            expect(!command.accepts(arguments))
            expect(!state.run(command, on: id, with: arguments))
        }
        expectEqual(editor.name(id), "Lobby")
        expectEqual(editor.undoHistory.undoName, undoName, "no step was made")
    },

    test("a pill in the line is part of the name, as \"@Label\" the way mention text reads plain") {
        let editor = try titleEditor()
        let state = try require(editor.slashCommands)
        let other = editor.add(Plaque(plaqueFrame), named: "Groceries")
        let id = editor.add(Plaque(plaqueFrame))
        expect(state.run("title", on: id, with: SlashArguments([.text("near "), .shape(other, label: "Groceries")])))
        expectEqual(editor.name(id), "near @Groceries")
        expect(state.run("title", on: id, with: SlashArguments([.shape(other, label: "Groceries")])))
        expectEqual(editor.name(id), "@Groceries")
    },

    test("Titles needs SlashCommands, which lists the command it offers, and the report shows it") {
        expectThrows(RegistryError.ownerNotInstalled(point: "ShapeSlashCommands", owner: .slashCommands, contributor: .titles)) {
            _ = try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), AdornmentsPlugin(), TitlesPlugin()])
        }
        let report = try titleEditor().registry.report
        let titles = try require(report.split(separator: "\n").first { $0.hasPrefix("titles") })
        // Titles' line goes on past `/title` (the cover overlay, `overlay TitleCoverOverlay`), whose whole line
        // TitlesTests' report test pins; here only that the three come one after another, so what Titles adds
        // after them doesn't make this test about something else.
        expect(String(titles).contains("property title · adornment TitlePill → every shape with a title pill · adornment TitleTab → every shape with a title tab · /title → every shape holding title"), report)
    },
])
