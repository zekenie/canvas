import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import Selection
import TestKit
import TextEditing

// View › Focus Inspector (⌥⌘I) in the app's window, over the nested file (two notes and an arrow on
// the root, a subboard): the inspector shown if it's hidden, and given the keyboard.

extension NestedWindow {
    /// The table of contents' list, while the panel shows it.
    var list: NSTableView? { window.contentView?.descendants(NSTableView.self).first { $0.isTableOfContents } }

    /// Whether the keyboard is in the inspector: the list, or a view in the panel (not the canvas or what it hosts).
    var inspectorHasKeyboard: Bool {
        guard let view = window.firstResponder as? NSView else { return false }
        return !isCanvas(view) && view.isDescendant(of: window.contentView!)
    }

    /// The first responder is the list's, or a view in it (a field editor is a view in the field).
    func firstResponder(isIn view: NSView?) -> Bool {
        guard let view, let responder = window.firstResponder as? NSView else { return false }
        return responder === view || responder.isDescendant(of: view)
    }
}

@MainActor let inspectorFocusShippedTests = Suite("Focus Inspector, shipped", [
    test("with nothing selected it gives the keyboard to the table of contents' list, and Escape gives it back to the canvas") {
        let w = try NestedWindow()
        w.window.spin { w.list != nil }
        expect(w.canvasHasKeyboard)
        w.controller.focusInspector(nil)
        expect(w.firstResponder(isIn: w.list), "the list has the keyboard: \(String(describing: w.window.firstResponder))")
        w.window.pressEscape()
        w.window.spin { w.canvasHasKeyboard }
        expect(w.canvasHasKeyboard, "Escape in the list: \(String(describing: w.window.firstResponder))")
        expectEqual(w.editor.selectedShapeIDs, [], "and isn't Escape on the canvas")
    },
    test("with a shape selected it gives the keyboard to the panel's first field, its title, not the back button above it; Escape gives it back with the shape still selected") {
        let w = try NestedWindow()
        let note = w.nest.notes(on: 1).0
        w.editor.selection = note
        w.window.spin { w.titleField != nil }
        w.controller.focusInspector(nil)
        expect(w.firstResponder(isIn: w.titleField), "the title field has the keyboard: \(String(describing: w.window.firstResponder))")
        w.window.pressEscape()
        w.window.spin { w.canvasHasKeyboard }
        expect(w.canvasHasKeyboard, "Escape in the field: \(String(describing: w.window.firstResponder))")
        expectEqual(w.editor.selectedShapeIDs, [note])
    },
    test("from a note being edited it ends the editing first, as Find does, and gives the note's title field the keyboard") {
        let w = try NestedWindow()
        let note = w.nest.notes(on: 1).0
        w.editor.selection = note
        expect(w.editor.beginEditing(note))
        w.window.spin { w.window.firstResponder is EditingTextView }
        w.controller.focusInspector(nil)
        expectEqual(w.editor.editingShapeID, nil, "no editing view left up while the keyboard is in the panel")
        w.window.spin { w.firstResponder(isIn: w.titleField) }
        expect(w.firstResponder(isIn: w.titleField))
        expectEqual(w.editor.selectedShapeIDs, [note])
    },
    test("with the inspector hidden it shows it first, and gives it the keyboard once it has views") {
        let w = try NestedWindow()
        w.window.spin { w.list != nil }
        w.board.viewState.showsDetails = false
        w.window.settle()
        expect(!w.inspectorHasKeyboard)
        w.controller.focusInspector(nil)
        expect(w.board.viewState.showsDetails)
        w.window.spin { w.firstResponder(isIn: w.list) }
        expect(w.firstResponder(isIn: w.list), "\(String(describing: w.window.firstResponder))")
        w.window.pressEscape()
        w.window.spin { w.canvasHasKeyboard }
        expect(w.canvasHasKeyboard)
    },
    test("it's in the View menu after Show Inspector, on ⌥⌘I, enabled with an inspector; from a panel field it still runs") {
        let w = try NestedWindow()
        let menus = BoardMenus.make(appName: "Infinite Canvas")
        let view = try require(menus.main.item(withTitle: "View")?.submenu)
        let titles = view.items.map(\.title)
        let show = try require(titles.firstIndex(of: "Show Inspector")), focus = try require(view.items.first { $0.title == "Focus Inspector" })
        expectEqual(titles[show + 1], "Focus Inspector")
        expectEqual(KeyboardShortcutSection.key(of: focus), "⌥⌘I")
        expectEqual(focus.action, #selector(BoardWindowController.focusInspector(_:)))
        expect(w.controller.validateMenuItem(focus))
        w.editor.selection = w.nest.notes(on: 1).0
        w.window.spin { w.titleField != nil }
        w.window.focus(try require(w.titleField))
        expect(!w.canvasHasKeyboard)
        w.window.settle()
        let responder = try require(w.window.firstResponder)
        expect(responder.tryToPerform(try require(focus.action), with: nil), "the chain from a field reaches the controller")
        expect(w.firstResponder(isIn: w.titleField))
    },
])
