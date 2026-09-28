import Boards
import Canvas
import CanvasTesting
import CoreGraphics
import Keyboard
import Selection
import TestKit

@MainActor let goingUpTests = Suite("Going up", [
    test("⌘↑ shows the board above with the shape whose board it left selected, one step back") {
        let nest = Nest()
        let h = try nestHarness(nest)
        expect(h.enter(nest.d))
        expect(h.editor.showBoard(nest.pBoard, selecting: [nest.b]))
        expect(h.commandUp())
        expectEqual(h.editor.board, nest.dBoard)
        expectEqual(h.editor.selectedShapeIDs, [nest.p])
        expect(h.commandUp())
        expectEqual(h.editor.board, .root)
        expectEqual(h.editor.selectedShapeIDs, [nest.d])

        h.editor.goBack()
        expectEqual(h.editor.board, nest.dBoard, "Back returns to the board left")
        expectEqual(h.editor.selectedShapeIDs, [nest.p])
        h.editor.goBack()
        expectEqual(h.editor.board, nest.pBoard)
        expectEqual(h.editor.selectedShapeIDs, [nest.b], "with what was selected there")
    },
    test("⌘↑ on the root does nothing, and passes its key") {
        let h = try nestHarness(Nest())
        expect(!h.editor.canPerform(.enclosingBoard))
        expect(!h.commandUp())
        expectEqual(h.editor.board, .root)
    },
    test("⌘↑ waits for a press to end, and leaves the key to a shape being edited") {
        let nest = Nest()
        let h = try nestHarness(nest)
        expect(h.enter(nest.d))
        expect(h.editor.showBoard(nest.pBoard, selecting: []))
        expect(h.editor.canPerform(.enclosingBoard))
        h.press(at: CGPoint(x: 500, y: 500))
        expect(!h.editor.canPerform(.enclosingBoard), "mid-press")
        expect(!h.commandUp())
        h.release()
        expect(h.editor.beginEditing(nest.c))
        expect(!h.editor.canPerform(.enclosingBoard), "while editing")
        h.editor.endEditing()
        expect(h.editor.canPerform(.enclosingBoard))
        h.editor.perform(.enclosingBoard)
        expectEqual(h.editor.board, nest.dBoard)
    },
    test("goUp(to:) goes to any board above, selecting the owner of the board below it on the path") {
        let (h, ids) = try chainHarness(depth: 5)
        for id in ids { expect(h.enter(id)) }
        expect(!h.editor.goUp(to: BoardID(owner: ids[4])), "the board shown isn't above itself")
        expect(!h.editor.goUp(to: BoardID(owner: ShapeID())), "nor is a board off the path")
        expect(h.editor.goUp(to: BoardID(owner: ids[1])))
        expectEqual(h.editor.board, BoardID(owner: ids[1]))
        expectEqual(h.editor.selectedShapeIDs, [ids[2]])
        expect(h.editor.goUp(to: .root))
        expectEqual(h.editor.selectedShapeIDs, [ids[0]])
        h.editor.goBack()
        expectEqual(h.editor.board, BoardID(owner: ids[1]), "one step back")
    },
    test("a board is called by its owner's title, else its kind's placeholder, else what places the kind, else the kind") {
        let nest = Nest()
        let h = try nestHarness(nest)
        expectEqual(h.editor.name(of: .root, root: "Plans"), "Plans")
        expectEqual(h.editor.name(of: nest.dBoard, root: "Plans"), "Untitled Drawer")
        expectEqual(h.editor.name(of: nest.pBoard, root: "Plans"), "Untitled Pocket")
        h.name(nest.d, "Kitchen")
        expectEqual(h.editor.name(of: nest.dBoard, root: "Plans"), "Kitchen")
        h.name(nest.d, "   ")
        expectEqual(h.editor.name(of: nest.dBoard, root: "Plans"), "Untitled Drawer", "a blank title is none")
        expectEqual(h.editor.symbol(of: nest.dBoard), "archivebox")
        expectEqual(h.editor.symbol(of: nest.pBoard), "tray")
        expectEqual(h.editor.symbol(of: .root), nil)

        let pocket = ShapeID()
        let lone = CanvasFile(root: CanvasDocument(shapes: [record(pocket, Pocket(CGRect(x: 0, y: 0, width: 100, height: 100)))]))
        let bare = try EditorHarness(plugins: [KeyboardPlugin(), PocketsPlugin(), BoardsPlugin(), placingPockets()], file: lone)
        expectEqual(bare.editor.name(of: BoardID(owner: pocket), root: ""), "Pocket", "the tool's label")
        expectEqual(bare.editor.symbol(of: BoardID(owner: pocket)), "tray.full")
        let plain = try EditorHarness(plugins: [KeyboardPlugin(), PocketsPlugin(), BoardsPlugin()], file: lone)
        expectEqual(plain.editor.name(of: BoardID(owner: pocket), root: ""), Pocket.kind.rawValue)
        expectEqual(plain.editor.symbol(of: BoardID(owner: pocket)), nil)
    },
])

/// A tool placing pockets, and nothing else of Boards: what a board is called then.
@MainActor func placingPockets() -> Contributor {
    Contributor(id: "placing-pockets") { r in
        r.tool(ToolDescriptor(id: ToolID(placing: Pocket.kind), label: "Pocket", systemImage: "tray.full")) { _ in NoTool() }
    }
}
