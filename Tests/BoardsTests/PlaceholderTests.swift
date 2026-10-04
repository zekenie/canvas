import Boards
import Canvas
import CanvasTesting
import CoreGraphics
import Keyboard
import TestKit
import Titles

/// Names a shape on its board, shown or not, through Titles.
@MainActor private func rename(_ id: ShapeID, on board: BoardID, _ title: String?, in h: EditorHarness) {
    h.editor.transact(on: board, "Rename") { $0.update(id) { $0[TitleProperty.self] = title } }
}

@MainActor let boardPlaceholderTests = Suite("A board's placeholder", [
    test("is its owner's kind's, from the kind's own sugar or another plugin; nil for a kind that doesn't open its boards") {
        let h = try nestHarness(Nest())
        let registry = h.editor.registry
        expectEqual(registry.boardPlaceholder(of: Drawer.kind), "Untitled Drawer")
        expectEqual(registry.boardPlaceholder(of: Pocket.kind), "Untitled Pocket")
        expectEqual(registry.boardPlaceholder(of: Box.kind), nil)
        expectEqual(registry.boardPlaceholder(of: "nothing"), nil)
    },
    test("is what a board is called while its owner has no title, as name(of:root:) says, and never once it has one") {
        let nest = Nest()
        let h = try nestHarness(nest)
        let registry = h.editor.registry
        // The drawer is on the root; the pocket on the drawer's board, named where it is.
        for (owner, board, on) in [(nest.d, nest.dBoard, BoardID.root), (nest.p, nest.pBoard, nest.dBoard)] {
            let kind = try require(h.editor.file.record(owner)).kind
            expectEqual(h.editor.name(of: board, root: "Plans"), registry.boardPlaceholder(of: kind), "\(kind)")
            rename(owner, on: on, "Pantry", in: h)
            expectEqual(h.editor.name(of: board, root: "Plans"), "Pantry")
            rename(owner, on: on, nil, in: h)
            expectEqual(h.editor.name(of: board, root: "Plans"), registry.boardPlaceholder(of: kind))
        }
        // Without `pocketBoards()`, a pocket has none, and its board is called by its kind.
        let pocket = ShapeID()
        let lone = CanvasFile(root: CanvasDocument(shapes: [record(pocket, Pocket(CGRect(x: 0, y: 0, width: 100, height: 100)))]))
        let plain = try EditorHarness(plugins: [KeyboardPlugin(), PocketsPlugin(), BoardsPlugin()], file: lone)
        expectEqual(plain.editor.registry.boardPlaceholder(of: Pocket.kind), nil)
        expectEqual(plain.editor.name(of: BoardID(owner: pocket), root: ""), Pocket.kind.rawValue)
    },
])
