import AppKit
import Boards
import Canvas
import CanvasTesting
import DetailPanel
import Keyboard
import Selection
import SwiftUI
import TestKit

@MainActor let openingTests = Suite("Opening a board", [
    test("a drawer opens onto its board with a double-click, Return and ⌘↓, from its kind's one line") {
        let nest = Nest()
        let h = try nestHarness(nest)
        h.click(at: nest.dPoint)
        h.click(at: nest.dPoint, clickCount: 2)
        expectEqual(h.editor.board, nest.dBoard, "double-click")
        expectEqual(h.editor.selectedShapeIDs, [], "nothing selected on arrival")

        h.editor.goBack()
        expectEqual(h.editor.board, .root)
        expectEqual(h.editor.selection, nest.d)
        expect(h.key("\r"))
        expectEqual(h.editor.board, nest.dBoard, "Return")

        h.editor.goBack()
        h.hold(.command)
        expect(h.key(String(KeyChord.downArrow.key)))
        h.hold([])
        expectEqual(h.editor.board, nest.dBoard, "⌘↓")
    },
    test("a pocket opens onto its board from the form for another plugin's kind") {
        let nest = Nest()
        let h = try nestHarness(nest)
        expect(h.enter(nest.d))
        h.editor.selection = nest.p
        expect(h.editor.canOpen(nest.p))
        expect(h.key("\r"))
        expectEqual(h.editor.board, nest.pBoard)
        expectEqual(h.editor.boardPath, [.root, nest.dBoard, nest.pBoard])
    },
    test("Open comes first in the menu of a shape that owns a board, and opens it") {
        let nest = Nest()
        let h = try nestHarness(nest)
        let menu = try require(h.secondaryClick(at: nest.dPoint))
        expectEqual(menu.outline.first, "Open")
        expectEqual(h.editor.selection, nest.d, "the right-click selected it")
        try menu.choose("Open")
        expectEqual(h.editor.board, nest.dBoard)

        expect(h.enter(nest.p))
        expect(h.secondaryClick(at: CGPoint(x: 50, y: 50))?.outline.contains("Open") != true, "a box's menu has none")
    },
    test("with several shapes that own boards selected, Open opens the first of them") {
        let nest = Nest()
        let other = ShapeID()
        var file = nest.file
        file = CanvasFile(root: CanvasDocument(shapes: file.root.shapes + [record(other, Drawer(CGRect(x: 400, y: 0, width: 100, height: 100)))]),
                          children: file.children)
        let h = try EditorHarness(plugins: boardsPlugins(), file: file)
        h.editor.selectedShapeIDs = [other, nest.d]
        let menu = try require(h.secondaryClick(at: nest.dPoint))
        try menu.choose("Open")
        expectEqual(h.editor.board, BoardID(owner: other))
    },
    test("its panel has no tab for it: opening a board is the canvas's, the menu's and the keys'") {
        let nest = Nest()
        let editor = try CanvasEditor(registry: Registry(plugins: boardsPlugins()), file: nest.file, scheduler: TaskScheduler())
        let drawer = try require(editor.document[nest.d])
        let layout = try require(editor.detailPanel?.layout(for: drawer))
        expectEqual(layout.tabs.map(\.title), [])
    },
    test("only a kind that owns boards may open one: a plugin naming another refuses the plugin list") {
        expectThrows(RegistryError.invalid(point: "BoardKinds", reason: "box-boards opens the boards of box, whose definition isn't BoardOwning")) {
            _ = try Registry(plugins: boardsPlugins([Contributor(id: "box-boards") { r in
                r.opensBoard(Box.self, placeholder: "Box", systemImage: "square")
            }]))
        }
    },
    test("two plugins opening one kind's boards conflict, and the report names each kind") {
        let registry = try Registry(plugins: boardsPlugins())
        let line = try require(registry.report.split(separator: "\n").first { $0.hasPrefix("drawers") })
        expect(line.contains("board → drawer \"Untitled Drawer\""), "\(line)")
        do {
            _ = try Registry(plugins: boardsPlugins([Contributor(id: "twice") { r in
                r.opensBoard(Drawer.self, placeholder: "Again", systemImage: "square")
            }]))
            expect(false, "a second opener for drawers")
        } catch RegistryError.conflict(let point, _, let plugins) {
            expectEqual(point, "BoardKinds")
            expectEqual(plugins, ["drawers", "twice"])
        }
    },
])
