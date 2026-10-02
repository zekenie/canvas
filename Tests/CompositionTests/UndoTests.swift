import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import Composition
import DetailPanel
import Foundation
import Geometry
import LanguageModels
import Mentions
import Selection
import StickyNotes
import Subboards
import SwiftUI
import TableOfContents
import TestKit
import Titles
import Validation

/// A board as the app opens it, in its window (unshown, without the details, so the canvas is the
/// window's width), driven as someone would: presses and drags on the canvas, keys, menus.
@MainActor final class UndoBoard {
    let board: BoardDocument
    let window: BoardWindow
    let canvas: CanvasView
    let pasteboard = NSPasteboard.withUniqueName()
    var editor: CanvasEditor { board.editor }
    private var time: TimeInterval = 1

    /// The welcome board, or the board `data` holds.
    init(_ data: Data? = nil) throws {
        try configureBoards(pasteboard: pasteboard)
        board = BoardDocument()
        if let data { try board.read(from: data, ofType: boardType) } else { board.start(with: WelcomeBoard.document()) }
        board.viewState.showsDetails = false
        board.makeWindowControllers()
        window = try require(board.windowControllers.first?.window as? BoardWindow)
        window.settle()
        canvas = try require(board.focus.canvas)
        window.makeFirstResponder(canvas)
    }

    func close() {
        board.close()
        pasteboard.releaseGlobally()
    }

    /// A mouse event at a world point.
    func event(_ type: NSEvent.EventType, at world: CGPoint, clicks: Int = 1) -> NSEvent {
        time += 0.05
        return NSEvent.mouseEvent(with: type, location: canvas.convert(editor.camera.toView(world), to: nil), modifierFlags: [], timestamp: time,
                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
    }

    /// The pointer moved to `to`, no button down.
    func move(to: CGPoint) {
        window.makeFirstResponder(canvas)
        canvas.mouseMoved(with: event(.mouseMoved, at: to))
    }

    /// A press at `from`, dragged to `to` in a few moves, released there.
    func drag(from: CGPoint, to: CGPoint) {
        window.makeFirstResponder(canvas)
        canvas.mouseDown(with: event(.leftMouseDown, at: from))
        for i in 1...4 {
            let t = CGFloat(i) / 4
            canvas.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)))
        }
        canvas.mouseUp(with: event(.leftMouseUp, at: to))
    }

    func click(_ at: CGPoint, clicks: Int = 1) {
        window.makeFirstResponder(canvas)
        canvas.mouseDown(with: event(.leftMouseDown, at: at, clicks: clicks))
        canvas.mouseUp(with: event(.leftMouseUp, at: at, clicks: clicks))
    }

    /// A ⌘ key on the canvas, as AppKit offers it before the menus.
    @discardableResult
    func command(_ key: String, shift: Bool = false) -> Bool {
        window.makeFirstResponder(canvas)
        return canvas.performKeyEquivalent(with: window.keyEvent(shift ? key.uppercased() : key, ignoringModifiers: key,
                                                                 modifiers: shift ? [.command, .shift] : .command))
    }

    /// The context menu a right-click at a world point opens.
    func menu(at point: CGPoint) -> NSMenu? { canvas.menu(for: event(.rightMouseDown, at: point)) }

    /// Types into the note being edited, as its text view takes typing.
    func typeInNote(_ text: String) throws {
        let textView = try require(window.firstResponder as? NSTextView, "a note is being edited")
        textView.insertText(text, replacementRange: textView.selectedRange())
    }

    /// Escape in the note being edited: editing ends.
    func endEditing() { window.firstResponder?.doCommand(by: #selector(NSResponder.cancelOperation(_:))) }

    /// Edit › Undo or Redo, as the menu validates it now: its title, and whether it's enabled.
    func menuItem(_ action: String) -> String {
        let item = NSMenuItem(title: "", action: NSSelectorFromString(action), keyEquivalent: "")
        let enabled = window.validateMenuItem(item)
        return enabled ? item.title : "(\(item.title))"
    }
}

/// Who answers an action up the responder chain from `responder`, as AppKit looks for its target.
@MainActor func target(of action: String, from responder: NSResponder?) -> AnyObject? {
    let selector = NSSelectorFromString(action)
    var current = responder
    while let found = current {
        if found.responds(to: selector) { return found }
        current = found.nextResponder
    }
    return nil
}

/// Saves the board to `url` as File › Save does, and waits for it.
@MainActor func save(_ board: BoardDocument, to url: URL) throws {
    var done = false
    var failure: (any Error)?
    board.save(to: url, ofType: boardType, for: .saveOperation) { error in
        failure = error
        done = true
    }
    runLoop { done }
    expect(done, "the save finished")
    if let failure { throw failure }
}

/// A new note at a world point, placed with the note tool (N, then a click) and typed into; editing
/// ends. One step, Add Note.
@MainActor func placeNote(_ b: UndoBoard, at point: CGPoint, text: String) throws -> ShapeID {
    b.window.makeFirstResponder(b.canvas)
    b.window.press("n")
    b.click(point)
    let id = try require(b.editor.editingShapeID, "the note tool places a note to edit")
    try b.typeInNote(text)
    b.endEditing()
    return id
}

let welcomeNotes = [CGPoint(x: 180, y: 180), CGPoint(x: 560, y: 180), CGPoint(x: 940, y: 180),
                    CGPoint(x: 180, y: 520), CGPoint(x: 560, y: 520), CGPoint(x: 940, y: 520)]

// Undo and redo as the app has them: the board's window, its menus and keys, the document's count
// of its changes, and saves.
@MainActor let undoTests = Suite("Undo, as shipped", [
    test("the board's changes count by its steps: undoing to what was saved reads unedited, past it edited; a step that comes to nothing, as it was") {
        let b = try UndoBoard()
        defer { b.close() }
        let url = scratchURL("count.canvasboard")
        defer { try? FileManager.default.removeItem(at: url) }
        expect(!b.board.isDocumentEdited)
        let first = b.editor.add(StickyNote(frame: CGRect(x: 0, y: 700, width: 200, height: 200), text: "A"))
        expect(b.board.isDocumentEdited, "at once, with no turn of the run loop")
        try save(b.board, to: url)
        expect(!b.board.isDocumentEdited)
        b.editor.transact("Move") { $0.update(first, as: StickyNote.self) { $0.frame.origin.x = 300 } }
        expect(b.board.isDocumentEdited)
        b.editor.undo()
        expect(!b.board.isDocumentEdited, "back to what was saved")
        b.editor.undo()
        expect(b.board.isDocumentEdited, "past what was saved")
        b.editor.redo()
        expect(!b.board.isDocumentEdited)
        b.editor.redo()
        expect(b.board.isDocumentEdited)
        b.editor.undo()
        b.editor.undoHistory.group {
            b.editor.transact { $0.update(first, as: StickyNote.self) { $0.frame.origin.x += 50 } }
            b.editor.transact { $0.update(first, as: StickyNote.self) { $0.frame.origin.x -= 50 } }
        }
        expect(!b.board.isDocumentEdited, "a step that came to nothing")
        expect(!b.editor.canRedo, "though opening it cleared what there was to redo, as any step's opening does")
    },
    test("a save closes the step under way: undo goes back to exactly what was saved; an autosave waits for a press") {
        let b = try UndoBoard()
        defer { b.close() }
        let opened = b.editor.document
        // A press that drags a note: an autosave that can wait, waits; a save that can't splits it.
        b.window.makeFirstResponder(b.canvas)
        b.canvas.mouseDown(with: b.event(.leftMouseDown, at: welcomeNotes[2]))
        b.canvas.mouseDragged(with: b.event(.leftMouseDragged, at: CGPoint(x: 980, y: 200)))
        expect(b.editor.undoHistory.isPressing)
        do {
            _ = try b.board.snapshot(implicitlyCancellable: true)
            expect(false, "an autosave during a press gives way")
        } catch let error as CocoaError {
            expectEqual(error.code, .userCancelled)
        }
        let saved = try b.board.snapshot(implicitlyCancellable: false)
        b.canvas.mouseDragged(with: b.event(.leftMouseDragged, at: CGPoint(x: 1000, y: 260)))
        b.canvas.mouseUp(with: b.event(.leftMouseUp, at: CGPoint(x: 1000, y: 260)))
        expectEqual(b.editor.undoHistory.undoName, "Move")
        b.editor.undo()
        expectEqual(try b.board.data(ofType: boardType), saved, "undone to the save point, byte for byte")
        b.editor.undo()
        expectEqual(b.editor.document, opened)
        expect(!b.editor.canUndo)

        // Typing into a note, saved midway.
        b.editor.redo()
        b.editor.redo()
        b.window.press("n")
        b.click(CGPoint(x: 700, y: 750))
        let note = try require(b.editor.editingShapeID)
        try b.typeInNote("Hel")
        let midway = try b.board.snapshot(implicitlyCancellable: false)
        try b.typeInNote("lo")
        b.endEditing()
        expectEqual(b.editor.document[note]?.typed(as: StickyNote.self)?.props.text, "Hello")
        expectEqual(b.editor.undoHistory.undoName, "Typing", "what was typed after the save is a step of its own")
        b.editor.undo()
        expectEqual(try b.board.data(ofType: boardType), midway)
        expectEqual(b.editor.undoHistory.undoName, "Add Note")
    },
    test("a save while the step under way has come back to where it began leaves the saved board unedited") {
        let b = try UndoBoard()
        defer { b.close() }
        let url = scratchURL("netted.canvasboard")
        defer { try? FileManager.default.removeItem(at: url) }
        let note = b.editor.add(StickyNote(frame: CGRect(x: 0, y: 700, width: 200, height: 200), text: "A"))
        try save(b.board, to: url)
        expect(!b.board.isDocumentEdited)
        for text in ["AB", "A"] {
            b.editor.transact("Change Text", coalescing: "text") { $0.update(note, as: StickyNote.self) { $0.props.text = MentionText(plain: text) } }
        }
        expect(b.board.isDocumentEdited, "a run under way")
        try save(b.board, to: url)
        runLoop { false }
        expect(!b.board.isDocumentEdited, "what's saved is the board")
        b.editor.undo()
        expect(b.editor.document[note] == nil, "the run left nothing to undo: the note's the step before it")
    },
    test("an autosave that gave way to a press is scheduled again once the press is over, whether its step closed or came to nothing") {
        let b = try UndoBoard()
        defer { b.close() }
        /// How many more autosaves were scheduled as a drag of the third note, from where it is by
        /// `by`, was released: with an autosave that gave way midway, or none.
        @MainActor func scheduled(by: CGPoint, autosaveMidway: Bool) -> Int {
            let from = CGPoint(x: welcomeNotes[2].x, y: welcomeNotes[2].y)
            b.window.makeFirstResponder(b.canvas)
            b.canvas.mouseDown(with: b.event(.leftMouseDown, at: from))
            b.canvas.mouseDragged(with: b.event(.leftMouseDragged, at: CGPoint(x: from.x + 40, y: from.y + 30)))
            b.canvas.mouseDragged(with: b.event(.leftMouseDragged, at: CGPoint(x: from.x + by.x, y: from.y + by.y)))
            if autosaveMidway {
                expect((try? b.board.snapshot(implicitlyCancellable: true)) == nil, "an autosave during a press gives way")
            }
            let before = b.board.autosavesScheduled
            b.canvas.mouseUp(with: b.event(.leftMouseUp, at: CGPoint(x: from.x + by.x, y: from.y + by.y)))
            return b.board.autosavesScheduled - before
        }
        let closed = scheduled(by: CGPoint(x: 20, y: 10), autosaveMidway: false)
        expectEqual(scheduled(by: CGPoint(x: 20, y: 10), autosaveMidway: true), closed + 1, "a step that closed")
        let discarded = scheduled(by: .zero, autosaveMidway: false)
        expectEqual(scheduled(by: .zero, autosaveMidway: true), discarded + 1, "a step that came to nothing")
    },
    test("an autosave waits while an arrow key held on the canvas nudges the selection, and is scheduled again once it's let go: the nudges are one step") {
        let b = try UndoBoard()
        defer { b.close() }
        b.click(welcomeNotes[2])
        let note = try require(b.editor.selection)
        let start = try require(b.editor.document[note]?.box).origin
        @MainActor func right(_ type: NSEvent.EventType, isRepeat: Bool = false) -> NSEvent {
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [.function, .numericPad], timestamp: 1, windowNumber: b.window.windowNumber,
                             context: nil, characters: "\u{F703}", charactersIgnoringModifiers: "\u{F703}", isARepeat: isRepeat, keyCode: 124)!
        }
        b.window.makeFirstResponder(b.canvas)
        b.canvas.keyDown(with: right(.keyDown))
        b.canvas.keyDown(with: right(.keyDown, isRepeat: true))
        expect(b.editor.undoHistory.isKeyHolding)
        do {
            _ = try b.board.snapshot(implicitlyCancellable: true)
            expect(false, "an autosave while the key is held gives way")
        } catch let error as CocoaError {
            expectEqual(error.code, .userCancelled)
        }
        b.canvas.keyDown(with: right(.keyDown, isRepeat: true))
        let before = b.board.autosavesScheduled
        b.canvas.keyUp(with: right(.keyUp))
        expectEqual(b.board.autosavesScheduled, before + 1, "scheduled again as the key is let go, which closes its step")
        expectEqual(b.editor.document[note]?.box?.origin, CGPoint(x: start.x + 3, y: start.y))
        expectEqual(b.editor.undoHistory.undoName, "Move")
        b.editor.undo()
        expectEqual(b.editor.document[note]?.box?.origin, start, "every nudge, one step")
    },
    test("a new board and a reverted one have nothing to undo; a save after an undo writes the board undone") {
        let b = try UndoBoard()
        defer { b.close() }
        let url = scratchURL("revert-undo.canvasboard")
        defer { try? FileManager.default.removeItem(at: url) }
        expect(!b.editor.canUndo && !b.editor.canRedo)
        let welcome = try b.board.data(ofType: boardType)
        try welcome.write(to: url)
        b.board.fileURL = url
        _ = b.editor.add(StickyNote(frame: CGRect(x: 0, y: 700, width: 200, height: 200), text: "Unsaved"))
        b.editor.undo()
        expectEqual(try b.board.data(ofType: boardType), welcome)
        b.editor.redo()
        try b.board.revert(toContentsOf: url, ofType: boardType)
        expect(!b.editor.canUndo && !b.editor.canRedo)
        runLoop { false }
        expect(!b.board.isDocumentEdited)
    },
    test("Edit › Undo names the board's step and runs it, from the canvas's ⌘Z too; dimmed with nothing to undo") {
        let b = try UndoBoard()
        defer { b.close() }
        expectEqual(b.menuItem("undo:"), "(Undo)")
        expect(!b.command("z"), "⌘Z goes on to the menu, whose item is dimmed")
        let note = try placeNote(b, at: CGPoint(x: 700, y: 750), text: "Hi")
        expectEqual(b.menuItem("undo:"), "Undo Add Note")
        expect(target(of: "undo:", from: b.window.firstResponder) === b.window)
        expect(b.command("z"), "⌘Z on the canvas is Keyboard's, running the core's .undo")
        expect(b.editor.document[note] == nil)
        expectEqual(b.menuItem("redo:"), "Redo Add Note")
        expect(b.command("z", shift: true))
        expectEqual(b.editor.document[note]?.typed(as: StickyNote.self)?.props.text, "Hi")
        b.window.undo(nil)
        expect(b.editor.document[note] == nil, "Edit › Undo runs the same command")
        b.window.redo(nil)
        expect(b.editor.document[note] != nil)
    },
    test("while a note is being edited, Undo is the text's own; once editing is over, one Undo takes the note away, typing and all") {
        let b = try UndoBoard()
        defer { b.close() }
        b.window.press("n")
        b.click(CGPoint(x: 700, y: 750))
        let note = try require(b.editor.editingShapeID)
        try b.typeInNote("Hello")
        b.window.settle()
        expectEqual(b.menuItem("undo:"), "Undo Typing")
        b.window.undo(nil)
        expectEqual(b.editor.document[note]?.typed(as: StickyNote.self)?.props.text, "", "the text's undo")
        b.window.redo(nil)
        expectEqual(b.editor.document[note]?.typed(as: StickyNote.self)?.props.text, "Hello")
        b.endEditing()
        expect(!b.window.textUndo.canUndo, "the text's undo is forgotten once it loses the keyboard")
        expectEqual(b.menuItem("undo:"), "Undo Add Note")
        b.window.undo(nil)
        expect(b.editor.document[note] == nil)
        expectEqual(b.editor.document.shapes.count, 9)
        expect(!b.editor.canUndo)
    },
    test("Delete Hidden Shapes is one step, and undoing it writes the board as it was, byte for byte") {
        let b = try UndoBoard(try richWelcomeBoard())
        defer { b.close() }
        let before = try b.board.data(ofType: boardType)
        b.board.deleteHiddenShapes()
        expectEqual(b.editor.undoHistory.undoName, "Delete Hidden Shapes")
        expect(b.editor.document.shapes.allSatisfy { !$0.isOpaque })
        b.editor.undo()
        expectEqual(try b.board.data(ofType: boardType), before)
    },
    test("from the table of contents' list and a panel's button, Undo reaches the board's window; in a panel's field, it's the field's") {
        let w = try InspectorWindow()
        var shape = ShapeRecord(Subboard(frame: CGRect(x: 100, y: 100, width: 240, height: 160)))
        shape[TitleProperty.self] = "eggs"
        w.editor.transact("Add Subboard") { $0.insert(shape) }
        w.window.settle()
        let contents = try require(w.host.descendants(NSTableView.self).first { $0.isTableOfContents }, "the panel shows the table of contents")
        w.window.makeFirstResponder(contents)
        expect(target(of: "undo:", from: w.window.firstResponder) === w.window)
        w.click(CGPoint(x: 200, y: 180))
        w.window.spin { w.titleField != nil && !w.buttons.isEmpty }
        let open = try require(w.buttons.first, "the Board tab's Open")
        expect(target(of: "undo:", from: open) === w.window)
        let field = try require(w.titleField)
        w.window.focus(field)
        field.currentEditor()?.selectAll(nil)
        w.window.type("milk")
        w.window.settle()
        expectEqual(w.editor.document[shape.id]?[TitleProperty.self], "milk")
        let item = NSMenuItem(title: "", action: #selector(BoardWindow.undo(_:)), keyEquivalent: "")
        expect(w.window.validateMenuItem(item))
        expectEqual(item.title, "Undo Typing")
        w.window.undo(nil)
        w.window.settle()
        expect(w.editor.document[shape.id] != nil, "the board's Add Subboard wasn't undone")
        expectEqual(w.editor.document[shape.id]?[TitleProperty.self], "eggs", "the text's undo, written through")
        w.window.makeFirstResponder(w.canvas)
        expect(w.window.validateMenuItem(item))
        expectEqual(item.title, "Undo Add Subboard", "the field's run of writes came back to where it began: no step")
        w.window.focus(try require(w.titleField))
        w.window.type("ham")
        w.window.settle()
        w.window.makeFirstResponder(w.canvas)
        expect(w.window.validateMenuItem(item))
        expectEqual(item.title, "Undo Change Subboard")
        w.window.undo(nil)
        expectEqual(w.editor.document[shape.id]?[TitleProperty.self], "eggs", "the board's step for the field's typing")
    },
])

/// The welcome board with what a board may hold that the app can't use or doesn't know: a note with
/// metadata no plugin knows, a note with a value the app can't use, a shape of a kind it doesn't have.
@MainActor func richWelcomeBoard() throws -> Data {
    let codec = BoardCodec(registry: try ShippedPlugins.registry(model: ScriptedLanguageModel()))
    var json = try require(JSONSerialization.jsonObject(with: codec.encode(WelcomeBoard.document())) as? [String: Any])
    var shapes = try require(json["shapes"] as? [[String: Any]])
    shapes[0]["meta"] = ["someone": ["pinned": true]]
    var added = shapes[1]["added"] as? [String: Any] ?? [:]
    added["confetti"] = ["velocity": 240]
    shapes[1]["added"] = added
    let top = try require(shapes.compactMap { ($0["index"] as? String).flatMap(StackingKey.init) }.max())
    shapes.append(["id": ShapeID().description, "index": StackingKey.between(top, nil).rawValue, "kind": "gadget", "props": ["gears": 3]])
    json["shapes"] = shapes
    if json["format"] as? Int != 3 { json["format"] = 3 }
    return try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
}

/// What the table of contents lists, row by row, and what validation found, shape by shape.
@MainActor func listedAndFound(_ editor: CanvasEditor) -> (rows: [String], issues: [ShapeID: [String]]) {
    @MainActor func lines(_ entries: [ContentsEntry]) -> [String] {
        entries.flatMap { entry in
            ["\(entry.id) \(entry.label?.text ?? "<view>") \(entry.marks.map(\.help))"] + lines(entry.children ?? []).map { "  " + $0 }
        }
    }
    return (lines(editor.tableOfContents?.entries ?? []), (editor.validation?.results ?? [:]).mapValues { $0.issues.map(\.message) })
}

// Every kind of step the app makes, undone back to the board as it opened and redone again.
@MainActor let undoRoundTripTests = Suite("Undo, all the way back", [
    test("a session of every kind of step undoes to the board as it opened, byte for byte, and redoes to where it ended") {
        let b = try UndoBoard(try richWelcomeBoard())
        defer { b.close() }
        let e = b.editor
        expect(b.board.loadReport.repairs.isEmpty, "\(b.board.loadReport.repairs)")
        expectEqual(b.board.loadReport.keptAside.count, 1)
        expectEqual(b.board.loadReport.keptValues.count, 1)
        let notes = e.document.shapes.filter { $0.kind == StickyNote.kind }.map(\.id)
        var documents = [e.document]
        var bytes = [try b.board.data(ofType: boardType)]
        var names: [String?] = []
        @MainActor func step(_ what: String, _ body: () throws -> Void) throws {
            let before = e.document
            try body()
            expect(e.document != before, "\(what) changed the board")
            expect(!e.undoHistory.isPressing)
            names.append(e.undoHistory.undoName)
            documents.append(e.document)
            bytes.append(try! b.board.data(ofType: boardType))
        }
        try step("move") { b.drag(from: welcomeNotes[2], to: CGPoint(x: 1000, y: 240)) }
        try step("place and type") { _ = try placeNote(b, at: CGPoint(x: 700, y: 760), text: "New") }
        try step("rename in the panel") {
            let binding = try require(e.shapeBinding(notes[0], as: StickyNote.self))
            for text in ["F", "Fi", "First"] { binding[TitleProperty.self].wrappedValue = text }
            e.undoHistory.seal()
        }
        try step("lock") { try require(b.menu(at: welcomeNotes[1])).choose("Lock") }
        try step("copy and paste") {
            b.click(welcomeNotes[0])
            expect(b.command("c"))
            expect(b.command("v"))
        }
        try step("delete") {
            b.click(welcomeNotes[4])
            b.window.pressDelete()
        }
        try step("bring to front") { try require(b.menu(at: welcomeNotes[3])).choose("Arrange", "Bring to Front") }
        try step("connect two notes") {
            let leftDot = CGPoint(x: 588, y: 760)                           // the placed note's
            b.move(to: CGPoint(x: 700, y: 760))
            b.move(to: leftDot)
            b.drag(from: leftDot, to: welcomeNotes[3])
        }
        try step("delete hidden shapes") { b.board.deleteHiddenShapes() }
        expectEqual(names, ["Move", "Add Note", "Change Note", "Lock", "Paste", "Delete", "Bring to Front", "Add Arrow",
                            "Delete Hidden Shapes"])

        @MainActor func expectAsFresh(_ when: String) {
            e.selectedShapeIDs = []
            e.tableOfContents?.showAll()
            let fresh = CanvasEditor(registry: e.registry, document: e.document, scheduler: ManualScheduler())
            let (rows, issues) = listedAndFound(e), (freshRows, freshIssues) = listedAndFound(fresh)
            expectEqual(rows, freshRows, when)
            expectEqual(issues, freshIssues, when)
        }
        for (document, data) in zip(documents, bytes).dropLast().reversed() {
            expect(e.canUndo)
            b.window.undo(nil)
            expectEqual(e.document, document)
            expectEqual(try b.board.data(ofType: boardType), data)
        }
        expect(!e.canUndo)
        expect(!b.board.isDocumentEdited, "back to the board as it opened")
        expectAsFresh("undone")
        for document in documents.dropFirst() {
            b.window.redo(nil)
            expectEqual(e.document, document)
        }
        expect(!e.canRedo)
        expectEqual(try b.board.data(ofType: boardType), bytes.last)
        expectAsFresh("redone")
    },
])
