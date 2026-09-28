import AppKit
import Boards
import Canvas
import CanvasTesting
import CanvasUI
import DetailPanel
import Selection
import Subboards
import TestKit

@MainActor let panelWindowTests = Suite("The panel, in a window", [
    test("typing in the header renames it, as one step, and B there is a letter, not the tool") {
        let nest = Nest()
        let editor = try CanvasEditor(registry: Registry(plugins: subboardPlugins()), file: nest.file(), scheduler: TaskScheduler())
        editor.selection = nest.s
        let w = PanelWindow(editor)
        w.window.spin { w.titleField != nil }
        let field = try require(w.titleField)
        expectEqual(field.stringValue, "")
        expectEqual(field.placeholderString, "Untitled Subboard")

        w.window.focus(field)
        w.window.type("Cupboard")
        expectEqual(editor.name(nest.s), "Cupboard")
        expectEqual(editor.document.shapes.count, 2, "no subboard placed")
        expectEqual(editor.currentToolID, .select)

        editor.undo()
        expectEqual(editor.name(nest.s), nil, "one undo takes the whole name back")
        expect(!editor.canUndo)
    },
    test("the Board tab's Open enters it") {
        let nest = Nest()
        let editor = try CanvasEditor(registry: Registry(plugins: subboardPlugins()), file: nest.file(), scheduler: TaskScheduler())
        editor.selection = nest.s
        let w = PanelWindow(editor)
        try require(editor.detailPanel).choose(.of(BoardTab.self), for: Subboard.kind)
        w.window.spin { !w.buttons.isEmpty }
        let open = try require(w.buttons.first)
        expect(open.isEnabled)
        open.performClick(nil)
        expectEqual(editor.board, nest.sBoard)
    },
    test("the Board tab's Open is enabled once the click that selected it is let go, and once one is placed") {
        let nest = Nest()
        let editor = try CanvasEditor(registry: Registry(plugins: subboardPlugins()), file: nest.file(), scheduler: TaskScheduler())
        let w = PanelWindow(editor)
        try require(editor.detailPanel).choose(.of(BoardTab.self), for: Subboard.kind)
        // As AppKit delivers a click: the panel redraws while the press (a lone box following the
        // pointer) is under way, when the subboard can't be opened.
        w.window.makeFirstResponder(w.canvas)
        w.canvas.mouseDown(with: w.window.mouse(.leftMouseDown, at: nest.sPoint, time: 1))
        w.window.spin { !w.buttons.isEmpty }
        expect(editor.session != nil && !editor.canPerform(.openSelection), "mid-press")
        w.canvas.mouseUp(with: w.window.mouse(.leftMouseUp, at: nest.sPoint, time: 1.05))
        expect(editor.canPerform(.openSelection))
        w.window.spin { w.buttons.first?.isEnabled == true }

        // Placing one with B is a press, then the new card following the pointer.
        w.window.press("b")
        let point = CGPoint(x: 460, y: 400)
        w.canvas.mouseDown(with: w.window.mouse(.leftMouseDown, at: point, time: 2))
        w.window.settle()
        w.canvas.mouseUp(with: w.window.mouse(.leftMouseUp, at: point, time: 2.05))
        let placed = try require(editor.selection)
        expect(placed != nest.s && editor.document[placed]?.kind == Subboard.kind, "B, then a click, places a subboard, selected")
        w.window.spin { w.buttons.first?.isEnabled == true }
        try require(w.buttons.first).performClick(nil)
        expectEqual(editor.board, BoardID(owner: placed))
    },
    test("a locked subboard's Open works, as every other way in does") {
        let nest = Nest()
        let editor = try CanvasEditor(registry: Registry(plugins: subboardPlugins() + [FreezingPlugin()]), file: nest.file(), scheduler: TaskScheduler())
        editor.freeze([nest.s])
        editor.selection = nest.s
        expect(editor.canPerform(.openSelection))
        let w = PanelWindow(editor)
        try require(editor.detailPanel).choose(.of(BoardTab.self), for: Subboard.kind)
        w.window.spin { !w.buttons.isEmpty }
        let open = try require(w.buttons.first)
        expect(open.isEnabled, "not dimmed with the shape's other controls")
        open.performClick(nil)
        expectEqual(editor.board, nest.sBoard)
    },
])
