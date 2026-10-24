import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CanvasUI
import Colors
import CoreGraphics
import Foundation
import Frames
import Geometry
import LanguageModels
import Mentions
import Palette
import References
import Selection
import ShippedTesting
import SlashCommands
import StickyNotes
import Subboards
import TestKit
import TextEditing
import Titles
import Types

// Colors as shipped: which kinds have one, `/color` typed in a note's editor in the app's canvas
// view, Color ▸ in a shape's menu, a color drawn and queried through `canvas` over a socket of
// its own, and a type's color on the notes and arrows of it.

@MainActor let colorsShippedTests = Suite("Colors, as shipped", [
    test("a note, a subboard, a frame and an arrow have a color, a reference has none; a note is yellow and a subboard indigo without one") {
        let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
        expect(registry.isColorable(StickyNote.kind) && registry.isColorable(Subboard.kind) && registry.isColorable(Frame.kind) && registry.isColorable(Arrow.kind))
        expect(!registry.isColorable(Reference.kind))
        expectEqual(registry.defaultColor(of: StickyNote.kind), .yellow)
        expectEqual(registry.defaultColor(of: Subboard.kind), .indigo)
        expectEqual(registry.defaultColor(of: Frame.kind), nil)
        expectEqual(registry.defaultColor(of: Arrow.kind), nil)
        expectEqual(registry.declaredFileProperties, ["colors"])
    },
    test("/color typed on a new line of a note lists the named colors; a pick colors the note in one step, Change Color, takes the line out, and editing goes on") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), pasteboard: pasteboard, model: ScriptedLanguageModel())
        let (window, _) = windowed(editor)
        let note = editor.add(StickyNote(frame: CGRect(x: 100, y: 100, width: 200, height: 200), text: "keep"))
        @MainActor func text() -> String? { editor.document[note]?.typed(as: StickyNote.self)?.props.text.plainText() }
        editor.selection = note
        expect(editor.beginEditing(note))
        let editing = try require(window.firstResponder as? MentionTextView<AnyMentionable>, "the note's editor has the keyboard")
        editing.setSelectedRange(NSRange(location: 4, length: 0))
        window.pressReturn()
        window.type("/")
        let picker = try require(editing.slashCommands?.picker, "the list is open")
        expect(picker.listed.map(\.name).contains("color"), "\(picker.listed.map(\.name))")
        window.type("color ")
        let choices = try require(editing.slashCommands?.choices, "the colors are listed")
        expectEqual(choices.listed.map(\.title), ["gray", "red", "orange", "yellow", "green", "teal", "blue", "indigo", "purple", "pink", "Edit Colors…"])
        window.type("pu")
        expectEqual(choices.highlightedChoice?.title, "purple")
        window.settle()
        window.pressReturn()
        window.settle()
        expectEqual(editor.document[note]?.ownColor, .purple)
        expectEqual(editor.undoHistory.undoName, "Change Color")
        expectEqual(text(), "keep\n", "the command's line is gone")
        expectEqual(editor.editingShapeID, note, "editing goes on")
        editor.endEditing()
        // Undo steps back through the color and then the typing.
        var names: [String] = []
        while let name = editor.undoHistory.undoName {
            names.append(name)
            editor.undo()
        }
        expect(names.contains("Change Color"), "\(names)")
        expectEqual(editor.document[note]?.ownColor, nil)
        expectEqual(text(), "keep")
    },
    test("/color for two notes and a frame selected lists the colors once and a pick colors all three in one step, Change Color; a reference selected too is left out, `3 of 4`; one undo takes it all back") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), pasteboard: pasteboard, model: ScriptedLanguageModel())
        let ann = editor.add(StickyNote(frame: CGRect(x: 100, y: 100, width: 200, height: 200), text: "Ann"))
        let bo = editor.add(StickyNote(frame: CGRect(x: 400, y: 100, width: 200, height: 200), text: "Bo"))
        let group = editor.add(Frame(frame: CGRect(x: 100, y: 400, width: 500, height: 300)), title: "Group")
        let reference = editor.add(Reference(frame: CGRect(x: 700, y: 100, width: 120, height: 32)))
        let state = try require(editor.slashCommands)
        let three = [ann, bo, group]
        @MainActor func owns() -> [ShapeColor?] { three.map { editor.document[$0]?.ownColor } }

        editor.selectedShapeIDs = three
        let command = try require(state.command(named: "color", for: .selection(editor.selectedShapeIDs)))
        expectEqual(command.shapes, three)
        expect(!command.isPartial)
        expectEqual(command.choices().map(\.title), ["gray", "red", "orange", "yellow", "green", "teal", "blue", "indigo", "purple", "pink", "Edit Colors…"])
        expect(state.run(command, choosing: try require(command.choices().first { $0.title == "teal" })))
        expectEqual(owns(), [.teal, .teal, .teal])
        expectEqual(editor.undoHistory.undoName, "Change Color")
        editor.undo()
        expectEqual(owns(), [nil, nil, nil], "one step")
        editor.redo()
        expectEqual(owns(), [.teal, .teal, .teal])

        editor.selectedShapeIDs = three + [reference]
        let withReference = try require(state.command(named: "color", for: .selection(editor.selectedShapeIDs)))
        expectEqual(withReference.shapes, three, "a reference has no color")
        expectEqual(withReference.targetCount, 4)
        expect(withReference.isPartial)
        expect(withReference.choices().map(\.title).contains("None"), "they hold one now")
        expect(state.run(withReference, choosing: try require(withReference.choices().first { $0.title == "None" })))
        expectEqual(owns(), [nil, nil, nil])
        expectEqual(editor.undoHistory.undoName, "Change Color")
        expectEqual(editor.document[reference]?.ownColor, nil)
    },
    test("Color ▸ is in the menu of a note, a frame and an arrow, after Is a ▸ where there is one, and not in a reference's; choosing a color colors the shape") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), pasteboard: pasteboard, model: ScriptedLanguageModel())
        let (window, canvas) = windowed(editor)
        let note = editor.add(StickyNote(frame: CGRect(x: 100, y: 100, width: 200, height: 200), text: "Ann"))
        _ = editor.add(Arrow(start: .free(CGPoint(x: 40, y: 500)), end: .free(CGPoint(x: 340, y: 500))))
        _ = editor.add(Frame(frame: CGRect(x: 40, y: 560, width: 300, height: 200)), title: "Group")
        _ = editor.add(Reference(frame: CGRect(x: 500, y: 100, width: 120, height: 32)))
        @MainActor func menu(at point: CGPoint, _ time: TimeInterval) -> NSMenu? {
            canvas.menu(for: window.mouse(.rightMouseDown, at: point, time: time))
        }
        let noteMenu = try require(menu(at: CGPoint(x: 200, y: 200), 1))
        let outline = noteMenu.outline
        let isA = try require(outline.firstIndex(of: "Is a ▸"), "\(outline)")
        let color = try require(outline.firstIndex(of: "Color ▸"), "\(outline)")
        expect(color > isA, "after Is a ▸: \(outline)")
        expectEqual(Array(outline[(color + 1)...].prefix(14)),
                    ["  Gray", "  Red", "  Orange", "  Yellow", "  Green", "  Teal", "  Blue", "  Indigo", "  Purple", "  Pink", "  —", "  ✓ None", "  —", "  Edit Colors…"])
        expect(menu(at: CGPoint(x: 190, y: 500), 2)?.outline.contains("Color ▸") == true, "an arrow's")
        expect(menu(at: CGPoint(x: 200, y: 700), 3)?.outline.contains("Color ▸") == true, "a frame's")
        expect(menu(at: CGPoint(x: 560, y: 116), 4)?.outline.contains("Color ▸") == false, "a reference has no color")
        try noteMenu.choose("Color", "Teal")
        expectEqual(editor.document[note]?.ownColor, .teal)
        expectEqual(editor.undoHistory.undoName, "Change Color")
    },
    test("canvas draw takes color: on a note, a frame, a subboard and an edge, a name or a hex; a name the file lacks is refused with the names; canvas query finds them") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = newBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let script = ##"""
        sticky-note "Risk" color: RED
        sticky-note "Fix" right of "Risk" color: "#46e"
        frame "Sprint" below "Risk" color: teal
        subboard "Payments" right of "Sprint" color: green
        edge "Risk" -> "Fix" color: purple
        """##
        let made = try canvas(server, ["draw", "-"], input: script)
        expectEqual(made.status, 0, made.error)
        let editor = board.editor
        @MainActor func own(_ title: String) -> ShapeColor? { editor.document.shapes.first { editor.registry.title(of: $0) == title }?.ownColor }
        expectEqual(own("Risk"), .red, "a name is kept as its list spells it")
        expectEqual(own("Fix"), .value(RGB(hex: 0x4466EE)))
        expectEqual(own("Sprint"), .teal)
        expectEqual(own("Payments"), .green)
        expectEqual(editor.document.shapes.first { $0.kind == Arrow.kind }?.ownColor, .purple)
        expectEqual(editor.undoHistory.undoName, "Draw")

        let refused = try canvas(server, ["draw", #"sticky-note "Brand" color: brand"#])
        expect(refused.status != 0)
        expect(refused.error.contains("isn't a color") && refused.error.contains("gray, red, orange, yellow, green, teal, blue, indigo, purple, pink"), refused.error)

        for (query, count) in [(#"[color="red"]"#, 1), (##"[color="#4466EE"]"##, 1), ("sticky-note[color]", 2), ("[color]", 5), (#"frame[color="teal"]"#, 1), ("sticky-note:not([color])", 0)] {
            let found = try JSON(text: canvas(server, ["query", "--brief", query]).output)
            expectEqual(found["count"], .number(Double(count)), query)
        }
        let rows = try JSON(text: canvas(server, ["query", "--fields", "color", #"sticky-note"Fix""#]).output)
        expectEqual(rows["rows"]?.arrayValue?.first?["properties"]?["color"], "#4466EE")

        let cleared = try canvas(server, ["draw", #"sticky-note "Risk" color: null"#])
        expectEqual(cleared.status, 0, cleared.error)
        expectEqual(own("Risk"), nil, "null takes the color away")
        let kinds = try JSON(text: canvas(server, ["kinds"]).output)
        let note = kinds.arrayValue?.first { $0["kind"]?.stringValue == "sticky-note" }
        expectEqual(note?["attributes"]?["color"], "text (a color's name or #RRGGBB)")
    },
    test("a note of a type is drawn in the color its type was given, its own color winning, and an arrow of a relationship type in its; a type with none set leaves its notes yellow") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = newBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let script = ##"""
        sticky-note "Person" schema: "{\"type\": \"object\"}" text: "A person" color: blue
        sticky-note "Company" right of "Person" schema: "{\"type\": \"object\"}" text: "A company"
        sticky-note "Employment" right of "Company" relationship: true schema: "{\"type\": \"object\"}" text: "A job" color: green
        edge "Person" -> "Employment" text: "jobs"
        edge "Employment" -> "Company" text: "staff"
        sticky-note "Ann" below "Person" is: "Person"
        sticky-note "Bo" right of "Ann" is: "Person" color: red
        sticky-note "Acme" below "Ann" is: "Company"
        edge "Ann" -> "Acme" is: "Employment"
        """##
        let made = try canvas(server, ["draw", "-"], input: script)
        expectEqual(made.status, 0, made.error)
        let editor = board.editor, book = try require(editor.colors)
        @MainActor func shape(_ title: String) throws -> AnyShapeRecord {
            try require(editor.document.shapes.first { editor.registry.title(of: $0) == title }, title)
        }
        expectEqual(book.color(of: try shape("Ann")), .blue)
        expectEqual(try shape("Ann").ownColor, nil, "nothing is written to the note")
        expectEqual(book.color(of: try shape("Bo")), .red, "its own wins")
        expectEqual(book.color(of: try shape("Acme")), .yellow, "Company holds no color: a note's yellow")
        let job = try require(editor.document.shapes.first { $0.kind == Arrow.kind && $0[IsAProperty.self]?.isEmpty == false })
        expectEqual(book.color(of: job), .green, "a relationship's arrow is its relationship type's")
        // The paper, where the note leaves it bare, under its words and anything over it.
        @MainActor func paper(_ title: String) throws -> [Int] {
            let frame = try require(editor.shapeContext.frame(of: try shape(title).id))
            editor.camera = Camera(origin: CGPoint(x: frame.minX - 20, y: frame.minY - 20))
            let bitmap = renderBitmap(editor, size: CGSize(width: frame.width + 40, height: frame.height + 40))
            return pixel(bitmap, at: CGPoint(x: 20 + frame.width / 2, y: 20 + frame.height - 24))
        }
        @MainActor func expectPaper(_ title: String, _ color: RGB) throws {
            let found = try paper(title), wanted = [color.red, color.green, color.blue].map { Int(($0 * 255).rounded()) }
            let off = zip(found.prefix(3), wanted).map { abs($0 - $1) }.max() ?? 255
            expect(off <= 2, "\(title): \(Array(found.prefix(3))) isn't \(wanted) (\(color.hexString))")
        }
        try expectPaper("Ann", BuiltInColors.blue.swatch.paper.light)
        try expectPaper("Bo", BuiltInColors.red.swatch.paper.light)
        try expectPaper("Acme", BuiltInColors.notePaper)
        try expectPaper("Person", RGB(white: 1))
        // Zoomed out, the note's skeleton is the same paper.
        let ann = try require(editor.shapeContext.frame(of: try shape("Ann").id))
        editor.camera = Camera(origin: CGPoint(x: ann.minX - 20, y: ann.minY - 20), zoom: 0.3)
        let small = pixel(renderBitmap(editor, size: CGSize(width: 200, height: 150)),
                          at: CGPoint(x: (20 + ann.width / 2) * 0.3, y: (20 + ann.height - 24) * 0.3))
        let blue = BuiltInColors.blue.swatch.paper.light
        let wanted = [blue.red, blue.green, blue.blue].map { Int(($0 * 255).rounded()) }
        expect(zip(small.prefix(3), wanted).allSatisfy { abs($0 - $1) <= 2 }, "Ann at 30%: \(Array(small.prefix(3))) isn't \(wanted)")
    },
])
