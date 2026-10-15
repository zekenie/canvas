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
])
