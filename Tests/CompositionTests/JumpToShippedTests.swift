import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import Composition
import CoreGraphics
import Frames
import Geometry
import JumpTo
import Mentions
import Selection
import StickyNotes
import TestKit
import TextEditing
import Titles

// Jump To as the app wires it: the shipped list, the board's window with the chrome Composition puts
// round the canvas (the palette over it), Go › Jump To… and ⌘K, over the nested file (the root, Plans,
// and Plans' untitled subboard).

extension NestedWindow {
    /// The palette's field, while it's open.
    var paletteField: EditingTextView? { window.contentView?.descendants(EditingTextView.self).first { $0.placeholder == "Jump To" } }
    var paletteHasKeyboard: Bool { paletteField.map { window.firstResponder === $0 } ?? false }

    /// Go › Jump To…, in the app's menus with Go's items sent to this window's controller.
    func jumpItem() throws -> (menus: BoardMenus.Menus, item: NSMenuItem) {
        let menus = BoardMenus.make(appName: "Infinite Canvas")
        let item = try require(menus.main.item(withTitle: "Go")?.submenu?.item(withTitle: "Jump To…"))
        item.target = controller
        return (menus, item)
    }

    /// Names a shape on a board, as its header does.
    func name(_ id: ShapeID, _ title: String, on board: BoardID) {
        editor.transact(on: board, "Rename") { $0.update(id) { $0[TitleProperty.self] = title } }
    }

    /// Types into the palette and waits for the list to settle.
    func typeInPalette(_ text: String) {
        window.type(text)
        window.settle()
    }

    /// What the palette lists, by title.
    var listed: [String] { editor.jumpTo?.rows.compactMap { $0.candidate?.title } ?? [] }
}

@MainActor let jumpToShippedTests = Suite("Jump To, shipped", [
    test("Go › Jump To… is enabled with the shipped list, and ⌘K opens the palette from the canvas, a note being edited and a panel's field") {
        let w = try NestedWindow()
        defer { w.board.close() }
        let (menus, item) = try w.jumpItem()
        expect(w.controller.validateMenuItem(item), "claimed by JumpToPlugin")
        expectEqual(item.keyEquivalent, "k")
        let state = try require(w.editor.jumpTo)
        // From the canvas: the plugin's own shortcut answers, before the menu bar.
        w.window.makeFirstResponder(w.canvas)
        expect(w.canvas.performKeyEquivalent(with: w.window.keyEvent("k", code: 40, modifiers: .command)))
        w.window.spin { w.paletteHasKeyboard }
        expect(state.isOpen && w.paletteHasKeyboard)
        w.window.pressEscape()
        w.window.spin { w.paletteField == nil && w.window.firstResponder === w.canvas }
        expect(!state.isOpen && w.window.firstResponder === w.canvas, "closed, the canvas has the keyboard")
        // A note being edited: the menu bar's key, ending editing first.
        let (note, _) = w.nest.notes(on: 1)
        w.editor.selection = note
        expect(w.editor.beginEditing(note))
        w.window.spin { w.window.firstResponder is NSText }
        expect(w.window.firstResponder is NSText, "the note's text has the keyboard")
        expect(w.controller.validateMenuItem(item), "in text")
        expect(menus.main.performKeyEquivalent(with: w.window.keyEvent("k", code: 40, modifiers: .command)))
        w.window.spin { w.paletteHasKeyboard }
        expect(state.isOpen && w.paletteHasKeyboard)
        expectEqual(w.editor.editingShapeID, nil, "editing ended")
        w.window.pressEscape()
        w.window.spin { w.paletteField == nil }
        // A panel's field: the header's title, with a note selected on Plans' board.
        expect(w.editor.showBoard(w.nest.sBoard))
        let (inPlans, _) = w.nest.notes(on: 2)
        w.editor.selection = inPlans
        w.window.spin { w.titleField != nil }
        w.window.focus(try require(w.titleField))
        expect(w.window.firstResponder is NSText)
        expect(menus.main.performKeyEquivalent(with: w.window.keyEvent("k", code: 40, modifiers: .command)), "⌘K in a panel's field")
        w.window.spin { w.paletteHasKeyboard }
        expect(state.isOpen && w.paletteHasKeyboard, "the palette took the keyboard from the field")
        expect(w.editor.document[inPlans]?[TitleProperty.self] == nil, "nothing typed into the title")
        // The item, run as a click: it opens it again, or asks for the keyboard.
        expect(w.controller.validateMenuItem(item))
    },
    test("Cmd-K, then \"plans drafts checkout\": into a shape two boards down, selected there; one step back; the palette is gone and the canvas has the keyboard") {
        let w = try NestedWindow()
        defer { w.board.close() }
        let (a, _) = w.nest.notes(on: 3)
        w.name(w.nest.t, "Drafts", on: w.nest.sBoard)
        w.name(a, "Checkout", on: w.nest.tBoard)
        let (b, _) = w.nest.notes(on: 1)
        w.name(b, "Checkout", on: .root)
        w.window.makeFirstResponder(w.canvas)
        _ = w.canvas.performKeyEquivalent(with: w.window.keyEvent("k", code: 40, modifiers: .command))
        w.window.spin { w.paletteHasKeyboard }
        w.typeInPalette("plans drafts checkout")
        expectEqual(w.listed, ["Checkout"], "the one on Plans › Drafts, not the root's")
        let row = try require(w.editor.jumpTo?.rows.compactMap(\.candidate).first)
        expectEqual(row.pathText, "Plans › Drafts")
        expectEqual(row.path.map(\.matched), [[0..<5], [0..<6]])
        w.window.pressReturn()
        expectEqual(w.editor.board, w.nest.tBoard, "two levels down")
        expectEqual(w.editor.selectedShapeIDs, [a])
        w.window.spin { w.paletteField == nil && w.window.firstResponder === w.canvas }
        expect(w.paletteField == nil && w.window.firstResponder === w.canvas)
        w.editor.goBack()
        expectEqual(w.editor.board, .root, "one step back")
        expect(w.editor.selectedShapeIDs.isEmpty)
        // Typed loosely, and by one name: Plans is a subboard, so a pick goes into it.
        _ = w.canvas.performKeyEquivalent(with: w.window.keyEvent("k", code: 40, modifiers: .command))
        w.window.spin { w.paletteHasKeyboard }
        w.typeInPalette("plans")
        expectEqual(w.listed, ["Plans"])
        w.window.pressReturn()
        expectEqual(w.editor.board, w.nest.sBoard, "into Plans' board")
        expectEqual(w.editor.selectedShapeIDs, [])
    },
    test("a frame is picked and fitted, however big, and what it holds is found by it") {
        let w = try NestedWindow()
        defer { w.board.close() }
        w.name(w.nest.t, "Drafts", on: w.nest.sBoard)
        let big = CGRect(x: 0, y: 0, width: 4000, height: 3000)
        var sprint = AnyShapeRecord(ShapeRecord(id: ShapeID(), Frame(frame: big)))
        sprint[TitleProperty.self] = "Sprint"
        w.editor.transact(on: w.nest.sBoard, "Add Frame") { $0.insert(sprint) }
        var held = AnyShapeRecord(ShapeRecord(id: ShapeID(), StickyNote(frame: CGRect(x: 200, y: 200, width: 200, height: 200), text: "Plan")))
        held[TitleProperty.self] = "Retro"
        held = held.copy(as: held.id, container: sprint.id)
        w.editor.transact(on: w.nest.sBoard, "Add Note") { $0.insert(held) }
        // Plans' board is shown and left at 100% where the frame isn't whole.
        expect(w.editor.showBoard(w.nest.sBoard))
        w.editor.camera = Camera(origin: CGPoint(x: 5000, y: 5000), zoom: 1)
        expect(w.editor.showBoard(.root))
        w.window.makeFirstResponder(w.canvas)
        _ = w.canvas.performKeyEquivalent(with: w.window.keyEvent("k", code: 40, modifiers: .command))
        w.window.spin { w.paletteHasKeyboard }
        w.typeInPalette("sprint")
        expectEqual(w.listed, ["Sprint"])
        expectEqual(w.editor.jumpTo?.rows.compactMap(\.candidate).first?.pathText, "Plans")
        w.paletteField?.string = ""
        w.paletteField?.didChangeText()
        w.typeInPalette("plans sprint retro")
        expectEqual(w.listed, ["Retro"], "a note held in the frame: Plans › Sprint")
        expectEqual(w.editor.jumpTo?.rows.compactMap(\.candidate).first?.pathText, "Plans › Sprint")
        w.paletteField?.string = "sprint"
        w.paletteField?.didChangeText()
        w.window.pressReturn()
        expectEqual(w.editor.board, w.nest.sBoard)
        expectEqual(w.editor.selectedShapeIDs, [sprint.id])
        spinUntilCameraArrives(w.editor, in: w.window)
        let view = w.editor.unobscuredViewport
        expectEqual(w.editor.camera, Camera(fitting: big, in: view, inset: 100, maxZoom: 1.2), "fitted, not 70%")
        expect(w.editor.camera.zoom < 0.5)
    },
    test("the palette sits below the path over a subboard: its capsule is the path's covered height and a fixed offset down") {
        let w = try NestedWindow()
        defer { w.board.close() }
        expect(w.editor.showBoard(w.nest.sBoard))
        w.window.settle()
        _ = w.canvas.performKeyEquivalent(with: w.window.keyEvent("k", code: 40, modifiers: .command))
        w.window.spin { w.paletteHasKeyboard }
        let field = try require(w.paletteField)
        let frame = w.onCanvas(field)
        let covered = ShippedPlugins.coveredTop(on: w.nest.sBoard)
        expectClose(w.canvas.isFlipped ? frame.minY : w.canvas.bounds.height - frame.maxY, covered + 12, within: 1.5)
        expect(covered > 30, "the path's pill is there")
        let state = try require(w.editor.jumpTo)
        expectClose(state.top, covered + 12)
    },
    test("the catalog is read once and kept: closed and opened again, the palette has what was named in between") {
        let w = try NestedWindow()
        defer { w.board.close() }
        let state = try require(w.editor.jumpTo)
        w.window.makeFirstResponder(w.canvas)
        _ = w.canvas.performKeyEquivalent(with: w.window.keyEvent("k", code: 40, modifiers: .command))
        w.window.spin { w.paletteHasKeyboard }
        expect(state.isReady)
        let read = state.catalogCount
        w.window.pressEscape()
        w.window.spin { w.paletteField == nil }
        w.name(w.nest.t, "Drafts", on: w.nest.sBoard)
        _ = w.canvas.performKeyEquivalent(with: w.window.keyEvent("k", code: 40, modifiers: .command))
        w.window.spin { w.paletteHasKeyboard }
        expectEqual(state.catalogCount, read + 1, "T, named since")
    },
])

/// Runs the main run loop until the editor's camera has arrived where it's headed.
@MainActor private func spinUntilCameraArrives(_ editor: CanvasEditor, in window: NSWindow) {
    window.spin(until: { editor.camera == editor.cameraTarget })
}
