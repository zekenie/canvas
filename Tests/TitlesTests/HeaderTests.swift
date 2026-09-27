import AppKit
import Canvas
import CanvasTesting
import DetailPanel
import Selection
import TestKit
import Titles

@MainActor let headerTests = Suite("Title header", [
    test("a kind that puts TitleHeader in its header: the title, empty while there's none, over the subtitle") {
        let editor = try titleEditor()
        let panel = try require(editor.detailPanel)
        let namedID = editor.add(Plaque(plaqueFrame), named: "Lobby"), unnamedID = editor.add(Plaque(plaqueFrame))
        let named = try require(editor.document[namedID]), unnamed = try require(editor.document[unnamedID])
        let header = try require(panel.layout(for: named).header(as: TitleHeader.self))
        expectEqual(header.title, "Lobby")
        expectEqual(header.subtitle, "A plaque")
        expectEqual(header.placeholder, nil, "the kind's name")
        expectEqual(panel.layout(for: named).kindName, "Plaque")
        expectEqual(panel.layout(for: named).header, nil, "it isn't a DetailHeader")
        expectEqual(panel.layout(for: unnamed).header(as: TitleHeader.self)?.title, "")
    },
    test("typing in the header renames the shape, a transaction a keystroke, and never switches tools; clearing it leaves no title") {
        let editor = try titleEditor(scheduler: TaskScheduler())
        let id = editor.add(Plaque(plaqueFrame))
        editor.selection = id
        let w = HeaderWindow(editor)
        w.window.spin { w.titleField != nil }
        let field = try require(w.titleField)
        expectEqual(field.stringValue, "")
        expectEqual(field.placeholderString, "Plaque", "the kind's name, while untitled")

        w.window.focus(field)
        let revision = editor.revision
        w.window.type("pool")                 // P is the plaque tool's shortcut, on the canvas
        expectEqual(editor.name(id), "pool")
        expectEqual(editor.revision, revision + 4)
        expectEqual(editor.currentToolID, .select)
        expectEqual(editor.title(id), "pool")

        w.window.focus(field)                 // selects the text
        w.window.pressDelete()
        expectEqual(editor.name(id), nil, "cleared, it's untitled, not an empty title")
        w.window.type(" ")
        expectEqual(editor.name(id), nil, "a blank title is none, so none is kept")
        w.window.type("a")
        expectEqual(editor.name(id), " a", "kept as typed")
        expectEqual(editor.title(id), "a", "on one line, as the pill and the row show it")
    },
    test("Return, like Escape, gives the keyboard back to the canvas, keeping the title as typed, even before the panel redraws") {
        let editor = try titleEditor(scheduler: TaskScheduler())
        editor.selection = editor.add(Plaque(plaqueFrame), named: "Lobby")
        let w = HeaderWindow(editor)
        w.window.spin { w.titleField != nil }
        // Each key at once after the last, so the panel hasn't drawn the rename when Return comes:
        // the field reads back what it wrote, not the name the panel last drew.
        w.window.focus(try require(w.titleField))
        w.window.type("Hall")
        expect(!w.canvasHasKeyboard)
        w.window.pressReturn()
        w.window.spin { w.canvasHasKeyboard }
        expectEqual(editor.selection.flatMap(editor.name), "Hall")

        w.window.focus(try require(w.titleField))
        w.window.type("Stairs")
        w.window.pressEscape()
        w.window.spin { w.canvasHasKeyboard }
        expectEqual(editor.selection.flatMap(editor.name), "Stairs")
        w.window.type("p")
        expectEqual(editor.currentToolID, ToolID(placing: Plaque.kind), "the canvas has the keyboard")
    },
    test("a title that's blank while untitled stays blank, and shows the kind's placeholder of its own") {
        let editor = try titleEditor([CardsPlugin(), CardTitlesPlugin()], scheduler: TaskScheduler())
        let id = editor.add(Card(plaqueFrame, text: "Hello"))
        editor.selection = id
        let w = HeaderWindow(editor)
        w.window.spin { w.titleField != nil }
        let field = try require(w.titleField)
        expectEqual(field.stringValue, "Hello")
        expectEqual(field.placeholderString, "Untitled Card")
        w.window.focus(field)
        w.window.pressDelete()
        expectEqual(editor.document[id]?.typed(as: Card.self)?.props.text, "")
        expectEqual(editor.title(id), nil)
    },
])
