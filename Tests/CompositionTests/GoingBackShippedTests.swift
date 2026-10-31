import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import CoreGraphics
import References
import Selection
import TestKit
import TextEditing

// Going back as shipped: a pill followed to its original on another board, then looked around and
// typed in there, is one ⌃- from where it was followed, as VS Code's Go Back is after a jump; and the
// keys work through the app's own menus wherever ⌘[ does, text being typed included.

extension NestedWindow {
    /// A direct reference on the root to `target`, right of the root's notes.
    func pill(to target: ShapeID, label: String) -> ShapeID {
        var props = Reference(frame: CGRect(origin: CGPoint(x: 720, y: 120), size: Reference.defaultSize))
        ReferenceEdits.pick(&props, ReferenceTarget(id: target, label: label))
        return editor.add(props)
    }

    /// A driver sending keys as NSApplication does, through the app's menus with Go's items, hidden
    /// ones too, sent to this window's controller.
    func goKeys() throws -> KeyDriver {
        let (menus, _, _) = try goItems()
        return KeyDriver(window, menu: menus.main)
    }
}

@MainActor let goingBackShippedTests = Suite("Going back, as shipped", [
    test("a pill followed to its original on another board, then a click and typing there: one ⌃- goes back to where it was followed from, its board, selection and view; ⌃⇧- comes back, from a note being typed in too") {
        let w = try NestedWindow()
        defer { w.board.close() }
        let (here, _) = w.nest.notes(on: 1)
        let (original, other) = w.nest.notes(on: 2)
        let pill = w.pill(to: original, label: "Plans, first")
        w.window.makeFirstResponder(w.canvas)
        w.editor.selection = here
        let view = w.editor.cameraTarget
        expect(w.editor.perform(.goToOriginal, on: [pill]), "the pill's Go to Original, as a click on its symbol goes")
        w.window.spin { w.editor.board == w.nest.sBoard }
        expectEqual(w.editor.selectedShapeIDs, [original])
        w.editor.selectedShapeIDs = [other]                         // a click on the note beside it, in view
        expect(w.editor.beginEditing(other))                        // and typing in it
        w.window.spin { w.window.firstResponder is EditingTextView }
        let keys = try w.goKeys()
        expectEqual(keys.send(Chord("-", .control)).menuItem?.title, "Back", "Go's hidden item for the key took it, as AppKit's menus answer it in text")
        w.window.settle()
        expectEqual(w.editor.board, .root, "one press, from the text being typed")
        expectEqual(w.editor.selectedShapeIDs, [here])
        expectEqual(w.editor.cameraTarget, view, "the view the pill was followed from")
        expectEqual(w.editor.editingShapeID, nil)

        expect(w.editor.beginEditing(here))
        w.window.spin { w.window.firstResponder is EditingTextView }
        expectEqual(keys.send(Chord("-", [.control, .shift])).menuItem?.title, "Forward", "its key ⌃_, typed with ⇧")
        w.window.settle()
        expectEqual(w.editor.board, w.nest.sBoard, "⌃⇧- forward, from a note being typed in")
        expectEqual(w.editor.selectedShapeIDs, [other], "to where the person had got to there")
    },
    test("on the canvas ⌃- and ⌃⇧- go back and forward as ⌘[ and ⌘] do, and do nothing where there's nowhere to go") {
        let w = try NestedWindow()
        defer { w.board.close() }
        w.window.makeFirstResponder(w.canvas)
        let keys = try w.goKeys()
        keys.send(Chord("-", .control))
        expectEqual(w.editor.board, .root, "nowhere to go back to")
        w.editor.selection = w.nest.s
        expect(w.editor.perform(.openSelection))
        expectEqual(w.editor.board, w.nest.sBoard)
        w.window.makeFirstResponder(w.canvas)
        keys.send(Chord("-", .control))
        expectEqual(w.editor.board, .root)
        expectEqual(w.editor.selectedShapeIDs, [w.nest.s], "the subboard opened, as ⌘[ would")
        keys.send(Chord("-", [.control, .shift]))
        expectEqual(w.editor.board, w.nest.sBoard)
        keys.send(Chord("-", [.control, .shift]))
        expectEqual(w.editor.board, w.nest.sBoard, "nowhere forward")
        keys.send(Chord("[", .command))
        expectEqual(w.editor.board, .root)
        keys.send(Chord("]", .command))
        expectEqual(w.editor.board, w.nest.sBoard)
    },
])
