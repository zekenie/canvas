import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import Colors
import Frames
import Geometry
import LanguageModels
import Mentions
import Selection
import ShippedTesting
import StickyNotes
import TestKit

// Making things with the keys alone, as the app ships it, on a new board: a placing tool's letter then
// Return puts its shape down at the pointer or the view's middle and edits it, ⇧Return (Insert › Note) puts
// a note beside the selection or, with none, in the view's middle, and the first minute (a note, its words, a
// second, the two connected, a frame around them) takes no more presses than clicks (keyboard navigation's
// principle 12).

/// A new board's window as the app makes one (`makeWindowControllers`, unshown): an empty board, the canvas
/// with the keyboard.
@MainActor
final class EmptyBoardWindow {
    let board: BoardDocument
    let window: NSWindow
    let canvas: CanvasView
    var editor: CanvasEditor { board.editor }

    /// `model`: what the boards' plugins ask (a type's sync), scripted.
    init(model: ScriptedLanguageModel = ScriptedLanguageModel()) throws {
        try configureBoards(model: model)
        board = BoardDocument()
        board.makeWindowControllers()
        let controller = try require(board.windowControllers.first as? BoardWindowController)
        window = try require(controller.window)
        window.settle()
        canvas = try require(board.focus.canvas, "the window's content made the canvas")
        window.makeFirstResponder(canvas)
    }

    /// A walk of the canvas's keyboard, the selection named by `names`.
    func walk(names: [ShapeID: String] = [:]) -> KeyWalk {
        window.makeFirstResponder(canvas)
        return KeyWalk(window, editor: editor, readers: [.canvas(canvas, editor: editor, names: names), .panel(of: canvas)])
    }

    /// The pointer moved over the canvas to `point` (view points), as AppKit tells the canvas.
    func move(to point: CGPoint) {
        let event = NSEvent.mouseEvent(with: .mouseMoved, location: canvas.convert(point, to: nil), modifierFlags: [], timestamp: 1,
                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 1)!
        canvas.mouseMoved(with: event)
    }

    /// Types `text` into what has the keyboard, key by key as a keyboard sends it; not counted as presses.
    func type(_ text: String, with walk: KeyWalk) {
        for character in text {
            walk.driver.send(Chord(character))
            window.settle()
        }
    }

    var notes: [AnyShapeRecord] { editor.document.shapes.filter { $0.kind == StickyNote.kind } }
}

@MainActor let keyboardCreationShippedTests = Suite("Making things by the keys, shipped", [
    test("on an empty board N then Return puts a note in the middle of the view and edits it; with the pointer over the canvas, at the pointer") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        let walk = w.walk()
        walk.press(Chord("n"))
        expectEqual(w.editor.currentToolID, ToolID(placing: StickyNote.kind))
        // The view as Return is pressed: the inspector slides in over the note after.
        let view = w.editor.unobscuredViewport
        walk.press(.return)
        let note = try require(w.notes.first)
        let middle = w.editor.camera.toWorld(CGPoint(x: view.midX, y: view.midY))
        expectEqual(note.box.map { CGPoint(x: $0.midX, y: $0.midY) }, middle)
        expectEqual(w.editor.editingShapeID, note.id, "edited at once")
        expectEqual(w.editor.currentToolID, .select, "the tool done, the select tool back")
        w.type("Plan", with: walk)
        walk.press(.escape)
        expectEqual(w.editor.editingShapeID, nil)
        expectEqual(w.editor.selectedShapeIDs, [note.id], "Escape keeps what was typed, the note selected")
        expectEqual(w.notes.first?.typed(as: StickyNote.self)?.props.text.plainText(), "Plan")
        expectEqual(w.editor.undoHistory.undoName, "Add Note", "placed and typed into: one step")
        // With the pointer over the canvas, the note goes there.
        let pointer = CGPoint(x: view.minX + 150, y: view.minY + 200)
        w.move(to: pointer)
        expect(w.editor.isPointerOverCanvas)
        w.window.makeFirstResponder(w.canvas)
        walk.press(Chord("n"))
        walk.press(.return)
        let second = try require(w.notes.first { $0.id != note.id })
        expectEqual(second.box.map { CGPoint(x: $0.midX, y: $0.midY) }, w.editor.camera.toWorld(pointer))
        expectEqual(w.editor.editingShapeID, second.id)
    },
    test("Return with the Frame tool puts a frame down in the middle of the view; with the select tool, Return still opens the selection") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        let walk = w.walk()
        walk.press(Chord("f"))
        let view = w.editor.unobscuredViewport
        walk.press(.return)
        let frame = try require(w.editor.document.shapes.first { $0.kind == Frame.kind })
        expectEqual(frame.box.map { CGPoint(x: $0.midX, y: $0.midY) }, w.editor.camera.toWorld(CGPoint(x: view.midX, y: view.midY)))
        expectEqual(w.editor.currentToolID, .select)
        let note = w.editor.add(StickyNote(frame: CGRect(x: 2000, y: 2000, width: 200, height: 200)))
        w.editor.selection = note
        walk.press(.return)
        expectEqual(w.editor.editingShapeID, note, "the select tool: Return edits the note, as ever")
        expectEqual(w.editor.document.shapes.count, 2, "nothing placed")
    },
    test("⇧Return on the canvas is Insert › Note: with nothing selected a note in the middle of the view, edited; with one shape selected, beside it in its color; with several, beside them") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        let walk = w.walk()
        let view = w.editor.unobscuredViewport
        walk.press(Chord(Key.return, .shift))
        let first = try require(w.notes.first)
        expectEqual(first.box.map { CGPoint(x: $0.midX, y: $0.midY) }, w.editor.camera.toWorld(CGPoint(x: view.midX, y: view.midY)),
                    "nothing selected: the middle of the view")
        expectEqual(w.editor.editingShapeID, first.id, "edited at once")
        w.type("First", with: walk)
        walk.press(.escape)
        expectEqual(w.editor.undoHistory.undoName, "Add Note", "placed and typed into: one step")
        expectEqual(w.editor.selectedShapeIDs, [first.id])
        w.editor.transact("Color") { $0.update(first.id) { $0[ColorProperty.self] = .blue } }
        walk.press(Chord(Key.return, .shift))
        let beside = try require(w.notes.first { $0.id != first.id })
        let firstBox = try require(w.editor.document[first.id]?.box), box = try require(beside.box)
        expect(box.minX > firstBox.maxX && box.minY < firstBox.maxY && box.maxY > firstBox.minY, "to its right: \(box)")
        expectEqual(beside[ColorProperty.self], .blue, "in the color of the note it's beside")
        expectEqual(w.editor.editingShapeID, beside.id)
        walk.press(.escape)
        w.editor.selectedShapeIDs = [first.id, beside.id]
        walk.press(Chord(Key.return, .shift))
        expectEqual(w.notes.count, 3, "two selected: a note beside them")
        let third = try require(w.notes.last?.box)
        let both = firstBox.union(box)
        expect(!third.intersects(firstBox) && !third.intersects(box), "clear of both: \(third) beside \(both)")
        expectEqual(w.notes.last?[ColorProperty.self], nil, "beside two, none of their colors")
    },
    test("keys through the menu bar, as the app routes them: ⇧Return runs Insert › Note, and Return alone, which AppKit's own matching would hand that item, edits the selected note") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        let menus = BoardMenus.make(appName: "Infinite Canvas", registry: w.editor.registry, editor: { w.editor })
        w.window.makeFirstResponder(w.canvas)
        let walk = KeyWalk(w.window, editor: w.editor, menu: menus.main, readers: [.canvas(w.canvas, editor: w.editor, names: [:]), .panel(of: w.canvas)])
        walk.press(Chord(Key.return, .shift))
        let note = try require(w.notes.first, "Insert › Note ran: \(walk.traceText)")
        expectEqual(w.editor.editingShapeID, note.id)
        walk.press(.escape)
        expectEqual(w.editor.selectedShapeIDs, [note.id])
        walk.press(.return)
        expectEqual(w.notes.count, 1, "Return made no note: \(walk.traceText)")
        expectEqual(w.editor.editingShapeID, note.id, "Return edits the selected note")
    },
    test("Insert › Frame puts an empty frame in the middle of the view, in one step") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        let view = w.editor.unobscuredViewport
        expect(w.editor.perform(.insert(ToolID(placing: Frame.kind))))
        let frame = try require(w.editor.document.shapes.first { $0.kind == Frame.kind })
        expectEqual(frame.box.map { CGPoint(x: $0.midX, y: $0.midY) }, w.editor.camera.toWorld(CGPoint(x: view.midX, y: view.midY)))
        expectEqual(w.editor.undoHistory.undoName, "Add Frame")
    },
    test("the first minute by the keys (a note, its words, a second note, the two connected, a frame around them) takes no more presses than clicks") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        let walk = w.walk()
        walk.press(Chord(Key.return, .shift))
        w.type("Plan", with: walk)
        walk.press(Chord(Key.return, .shift))
        w.type("Ship", with: walk)
        walk.press(.escape)
        walk.press(Chord("a", .command))
        walk.press(Chord("l", .command))
        walk.press(Chord("f", [.command, .shift]))
        let notes = w.notes
        expectEqual(notes.compactMap { $0.typed(as: StickyNote.self)?.props.text.plainText() }.sorted(), ["Plan", "Ship"])
        let frame = try require(w.editor.document.shapes.first { $0.kind == Frame.kind }, "a frame: \(walk.traceText)")
        for note in notes { expectEqual(w.editor.holder(of: note.id), frame.id, "in the frame") }
        let joining = w.editor.document.shapes.filter { $0.kind != StickyNote.kind && $0.kind != Frame.kind }
        expectEqual(joining.count, 1, "one arrow joins them")
        // By the pointer: the Note tool, the canvas, the Note tool, the canvas, a port's drag to the other note,
        // the Frame tool, and its drag around both.
        let clicks = 7
        expectEqual(walk.presses.count, 6, "⇧Return twice, Escape, ⌘A, ⌘L, ⇧⌘F: \(walk.traceText)")
        expect(walk.presses.count <= clicks, "\(walk.presses.count) presses: \(walk.traceText)")
    },
])
