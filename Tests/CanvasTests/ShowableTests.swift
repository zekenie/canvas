@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import TestKit

// Which boards the app can show, asked of a file alone (`file.canShow(_:boardOwningKinds:)`, for
// code off the main actor): the editor's answer, whatever the file holds.

private let unit = CGRect(x: 0, y: 0, width: 100, height: 100)

private func box(_ id: ShapeID = ShapeID()) -> AnyShapeRecord { AnyShapeRecord(ShapeRecord(id: id, Box(unit))) }
private func pocket(_ id: ShapeID) -> AnyShapeRecord { AnyShapeRecord(ShapeRecord(id: id, Pocket(unit))) }
private func board(_ records: AnyShapeRecord...) -> CanvasDocument { CanvasDocument(shapes: records) }
private func uuid(_ n: Int) -> String { String(format: "00000000-0000-0000-0000-%012d", n) }
private func id(_ n: Int) -> ShapeID { ShapeID(UUID(uuidString: uuid(n))!) }

/// Every board anything could ask about in `file`: the root, one for each shape in it (a box's too)
/// and each board it keeps, and one of a shape that isn't there.
private func everyBoard(in file: CanvasFile) -> [BoardID] {
    let owners = file.root.shapes.map(\.id) + file.children.flatMap { [$0.key] + $0.value.shapes.map(\.id) }
    return [.root, BoardID(owner: ShapeID())] + Set(owners).map { BoardID(owner: $0) }
}

/// Holds `file.canShow` to the editor's `canShow` on every board of `file`, as the editor holds it
/// (defaults filled), and as given; returns the boards it can show.
@MainActor private func expectEditorsAnswers(_ file: CanvasFile, _ registry: Registry, _ context: String,
                                             line: UInt = #line) -> Set<BoardID> {
    let editor = CanvasEditor(registry: registry, file: file, scheduler: ManualScheduler())
    var shown: Set<BoardID> = []
    for board in everyBoard(in: file) {
        let answer = editor.canShow(board)
        expectEqual(editor.file.canShow(board, boardOwningKinds: registry.boardOwningKinds), answer, "\(context): \(board)", line: line)
        expectEqual(file.canShow(board, boardOwningKinds: registry.boardOwningKinds), answer, "\(context), as given: \(board)", line: line)
        if answer { shown.insert(board) }
    }
    return shown
}

@MainActor let showableTests = Suite("Which boards can be shown, from the file", [
    test("a file says what the editor says: nested boards, an empty one, a box's, an orphan and what's under it, and owners that hold each other's") {
        let registry = try Registry(plugins: [FixturesPlugin(), PocketsPlugin()])
        let a = ShapeID(), p = ShapeID(), e = ShapeID(), b = ShapeID(), q = ShapeID(), c = ShapeID()
        let stray = ShapeID(), under = ShapeID(), m = ShapeID(), n = ShapeID()
        let file = CanvasFile(root: board(box(a), pocket(p), pocket(e)),
                              children: [p: board(box(b), pocket(q)), q: board(box(c)),
                                         a: board(box()),                             // a box's "board": a box isn't BoardOwning
                                         stray: board(box(), pocket(under)), under: board(box()),   // no owner in the file, and under it
                                         m: board(pocket(n)), n: board(pocket(m))])   // each holds the other's owner
        let shown = expectEditorsAnswers(file, registry, "odd boards")
        expectEqual(shown, [.root, BoardID(owner: p), BoardID(owner: q), BoardID(owner: e)], "the root, the pockets' down from it, and an empty one")

        // Across a commit that takes a pocket and its board.
        let editor = CanvasEditor(registry: registry, file: file, scheduler: ManualScheduler())
        editor.transact { $0.delete([p]) }
        for board in everyBoard(in: file) {
            expectEqual(editor.file.canShow(board, boardOwningKinds: registry.boardOwningKinds), editor.canShow(board), "after a deletion: \(board)")
        }
        expect(!editor.file.canShow(BoardID(owner: q), boardOwningKinds: registry.boardOwningKinds), "the board under the deleted pocket")
    },

    test("a file says what the editor says under a shape kept aside, whose boards the app keeps and can't show") {
        let json = """
        { "format" : 4, "versions" : { "kinds" : { "box" : 0, "pocket" : 0 } },
          "shapes" : [ { "id" : "\(uuid(1))", "kind" : "gadget", "index" : "a0", "props" : { } },
                       { "id" : "\(uuid(4))", "kind" : "pocket", "index" : "a1", "props" : { "frame" : [[0, 0], [10, 10]] } } ],
          "boards" : { "\(uuid(1))" : { "shapes" : [ { "id" : "\(uuid(2))", "kind" : "pocket", "index" : "a0", "props" : { "frame" : [[0, 0], [10, 10]] } } ] },
                       "\(uuid(2))" : { "shapes" : [ { "id" : "\(uuid(3))", "kind" : "box", "index" : "a0", "props" : { "frame" : [[0, 0], [10, 10]] } } ] },
                       "\(uuid(4))" : { "shapes" : [ { "id" : "\(uuid(5))", "kind" : "box", "index" : "a0", "props" : { "frame" : [[0, 0], [10, 10]] } } ] } } }
        """
        let registry = try Registry(plugins: [FixturesPlugin(), PocketsPlugin()])
        let file = try BoardCodec(registry: registry).decode(Data(json.utf8)).file
        expect(file.record(id(1))?.isOpaque == true, "the gadget is kept aside")
        expect(file.children[id(2)] != nil, "the board under the gadget's is kept")
        let shown = expectEditorsAnswers(file, registry, "kept aside")
        expectEqual(shown, [.root, BoardID(owner: id(4))])
        expect(!file.canShow(BoardID(owner: id(4)), boardOwningKinds: []), "a pocket's board, where no kind owns boards")
    },
])
