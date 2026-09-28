@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import TestKit
import Validation

/// A file whose root holds an empty box and a pocket, and whose pocket's board holds another empty
/// box: each box has an issue, on its own board.
@MainActor private func twoBoards(_ rules: Rules) throws -> (h: EditorHarness, pocket: ShapeID, outer: ShapeID, inner: ShapeID) {
    let pocket = ShapeRecord(Pocket(CGRect(x: 0, y: 0, width: 200, height: 100)))
    let outer = ShapeRecord(Box(.zero)), inner = ShapeRecord(Box(.zero))
    let file = CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(outer), AnyShapeRecord(pocket)]),
                          children: [pocket.id: CanvasDocument(shapes: [AnyShapeRecord(inner)])])
    let h = try EditorHarness(plugins: [FixturesPlugin(), PocketsPlugin(), ValidationPlugin(), rules], file: file)
    return (h, pocket.id, outer.id, inner.id)
}

/// Counts every check of a box: empty ones have an issue.
@MainActor private var countingRules: Rules {
    Rules { r in
        r.validate(Box.self) { box, _ in
            calls += 1
            return box.frame.isEmpty ? [.warning("empty")] : []
        }
    }
}

@MainActor let boardValidationTests = Suite("Validation across boards", [
    test("only the board shown is checked, and its issues are the ones found") {
        calls = 0
        let (h, pocket, outer, inner) = try twoBoards(countingRules)
        let engine = try require(h.editor.validation)
        expectEqual(Array(engine.results.keys), [outer])
        expectEqual(calls, 1, "the pocket's box isn't checked from the root")
        h.enter(pocket)
        expectEqual(Array(engine.results.keys), [inner])
        expectEqual(calls, 2)
    },
    test("going back to a board as it was left takes back what was found there, checking nothing") {
        calls = 0
        let (h, pocket, outer, inner) = try twoBoards(countingRules)
        let engine = try require(h.editor.validation)
        _ = engine.results
        h.enter(pocket)
        _ = engine.results
        expectEqual(calls, 2)
        h.editor.showBoard(.root)
        expectEqual(Array(engine.results.keys), [outer])
        h.enter(pocket)
        expectEqual(Array(engine.results.keys), [inner])
        expectEqual(calls, 2, "neither board is checked again")
    },
    test("a shape changed but not yet checked again when its board was left is checked on the way back") {
        calls = 0
        let (h, pocket, outer, _) = try twoBoards(countingRules)
        let engine = try require(h.editor.validation)
        _ = engine.results
        h.editor.transact { $0.update(outer, as: Box.self) { $0.frame.size = CGSize(width: 5, height: 5) } }
        h.enter(pocket)
        h.editor.showBoard(.root)
        expect(engine.results.isEmpty, "the box that was fixed has no issue")
        expectEqual(calls, 2, "the root's first check, then the fixed box's (the pocket's was never read)")
    },
    test("undo follows the board it shows: a fix on the pocket's board undone from the root, and a board a deletion took, put back and checked") {
        calls = 0
        let (h, pocket, outer, inner) = try twoBoards(countingRules)
        let engine = try require(h.editor.validation)
        h.enter(pocket)
        h.editor.transact("Fix") { $0.update(inner, as: Box.self) { $0.frame.size = CGSize(width: 5, height: 5) } }
        expect(engine.results.isEmpty)
        h.editor.showBoard(.root)
        _ = engine.results
        h.editor.undo()
        expectEqual(h.editor.board, BoardID(owner: pocket))
        expectEqual(Array(engine.results.keys), [inner], "the box is empty again, and has its issue")

        h.editor.showBoard(.root)
        h.editor.transact("Delete") { $0.delete([pocket]) }
        h.editor.undo()
        expectEqual(Array(engine.results.keys), [outer])
        let checked = calls
        h.enter(pocket)
        expectEqual(Array(engine.results.keys), [inner])
        expectEqual(calls, checked + 1, "a board put back has a new revision: it's checked again")
    },
    test("what a rule looked up is kept with its board: changing it checks the rule's shape again") {
        // A tag is in error while the shape it's on is empty; its rule looks that shape up.
        let (h, pocket, outer, _) = try twoBoards(Rules { r in
            r.validate(Tag.self) { tag, context in
                tag.props.target.flatMap { context.shape($0) }?.box?.isEmpty == false ? [] : [.error("empty target")]
            }
        })
        let tag = h.add(Tag(target: outer))
        let engine = try require(h.editor.validation)
        expectEqual(engine.results[tag]?.issues.map(\.message), ["empty target"])
        h.enter(pocket)
        _ = engine.results
        h.editor.showBoard(.root)
        expectEqual(engine.dependents(of: [outer]), [tag])
        h.editor.transact { $0.update(outer, as: Box.self) { $0.frame.size = CGSize(width: 5, height: 5) } }
        expect(engine.results[tag] == nil, "the tag is checked again with the shape it looked up")
    },
    test("a board changed since it was left is checked again: nothing kept of a file put in place is taken for the new one") {
        calls = 0
        let (h, pocket, _, inner) = try twoBoards(countingRules)
        let engine = try require(h.editor.validation)
        _ = engine.results
        h.enter(pocket)
        _ = engine.results
        let fixed = ShapeRecord(Box(CGRect(x: 0, y: 0, width: 5, height: 5)))
        h.editor.replaceFile(with: CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(fixed), h.file.root.shapes.last!]),
                                              children: [pocket: h.file[BoardID(owner: pocket)]]))
        expectEqual(Array(engine.results.keys), [inner])
        h.editor.showBoard(.root)
        expect(engine.results.isEmpty, "the root the file put in place is checked, not the one left")
        expectEqual(calls, 3, "the root, the pocket's box, then the root the file put in place")
    },
])
