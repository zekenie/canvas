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
    test("a container in a path is called by its title, else as its board is, else by its kind: containerName(of:)") {
        let nest = Nest()
        let h = try nestHarness(nest)
        let registry = h.editor.registry
        @MainActor func name(_ id: ShapeID) throws -> ContainerName { registry.containerName(of: try require(h.editor.file.record(id))) }
        expectEqual(try name(nest.d), ContainerName(title: nil, placeholder: "Untitled Drawer", opensBoard: true))
        expectEqual(try name(nest.d).text, "Untitled Drawer")
        expect(try name(nest.d).isPlaceholder)
        expectEqual(try name(nest.p).text, "Untitled Pocket", "on a board that isn't shown")
        rename(nest.d, on: .root, "Pantry", in: h)
        expectEqual(try name(nest.d), ContainerName(title: "Pantry", placeholder: "Untitled Drawer", opensBoard: true))
        expectEqual(try name(nest.d).text, "Pantry")
        expect(!(try name(nest.d).isPlaceholder))
        expectEqual(try name(nest.d).text, h.editor.name(of: nest.dBoard, root: ""), "as the path over the canvas calls its board")
        // A kind that opens no board (a frame, to a path) is called by its kind's label.
        expectEqual(try name(nest.a), ContainerName(title: nil, placeholder: registry.label(of: Box.kind).name))
        // Whether going into it opens a board: a drawer and a pocket do, a box does not.
        expect(try name(nest.d).opensBoard)
        expect(try name(nest.p).opensBoard)
        expect(!(try name(nest.a)).opensBoard)
    },
])
