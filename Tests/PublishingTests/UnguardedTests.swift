@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Publishing
import TestKit
import Topology

// The paths that make a shape private with no guard (undo, redo, a paste, a board edited by hand,
// `canvas draw`) write it, and everything follows: the stand-ins drop it in that commit, and it wears
// the crossed eye as any private shape does; making it public again heals them, and the eye opens for
// a moment as for any shape that goes public.

@MainActor let unguardedTests = Suite("Private by a path with no guard", [
    test("written, whatever stands for the shape: the stand-in lets it go in that commit, and making it public again heals") {
        let h = try publishingHarness()
        let plaque = h.add(Plaque(plaqueFrame))
        let holder = h.hold([plaque]), lens = h.lens("what", answering: [plaque])
        let topology = try require(h.editor.topology)
        h.editor.transact { $0.update(plaque) { $0[PrivateProperty.self] = true } }        // a hand-edited board, draw
        expectEqual(h.editor.document[plaque]?[PrivateProperty.self], true, "written")
        expectEqual(topology.forwards(of: holder), [], "the stand-in lets go of it in that commit")
        expectEqual(topology.forwards(of: lens), [], "the answer too")
        expectEqual(topology.standIns(for: plaque), [])
        expectEqual(h.chipSymbol(of: plaque), "eye.slash", "it wears the crossed eye, as any private shape does")
        h.publish(plaque)
        expectEqual(topology.forwards(of: holder), [plaque], "healed")
        expectEqual(topology.forwards(of: lens), [plaque])
        expectEqual(h.chipSymbol(of: plaque), "eye", "the eye opens for a moment, as for any")
    },
    test("undo and redo go private and public with no question asked, and no refusal") {
        let log = RefusalLog()
        let h = try publishingHarness([FreezingPlugin(log: log)])
        let plaque = h.add(Plaque(plaqueFrame))
        h.conceal(plaque)
        h.publish(plaque)
        let holder = h.hold([plaque])
        h.editor.undo()                                                                  // the stand-in goes
        h.editor.undo()                                                                  // then the shape is private
        expectEqual(h.editor.document[plaque]?[PrivateProperty.self], true)
        expectEqual(h.chipSymbol(of: plaque), "eye.slash")
        h.editor.redo()
        h.editor.redo()
        expectEqual(h.editor.document[plaque]?[PrivateProperty.self], nil)
        expectEqual(try require(h.editor.topology).standIns(for: plaque), [holder])
        expectEqual(h.chipSymbol(of: plaque), "eye", "public again: the eye opens for a moment")
        expectEqual(log.refusals, [], "nothing was refused")
    },
    test("a pasted copy of a public shape is public, and one of a private shape is private, as every added property's value is") {
        let h = try publishingHarness()
        let plaque = h.add(Plaque(plaqueFrame)), other = h.add(Plaque(CGRect(x: 400, y: 100, width: 100, height: 100)))
        h.conceal(other)
        let publicCopy = ShapeID(), privateCopy = ShapeID()
        h.editor.transact { transaction in
            transaction.insert(h.editor.document[plaque]!.copy(as: publicCopy))
            transaction.insert(h.editor.document[other]!.copy(as: privateCopy))
        }
        expectEqual(h.editor.document[publicCopy]?[PrivateProperty.self], nil)
        expectEqual(h.editor.document[privateCopy]?[PrivateProperty.self], true)
        expectEqual(h.chip(of: publicCopy), nil, "no open eye for a shape that arrived public")
        expectEqual(h.chipSymbol(of: privateCopy), "eye.slash")
    },
    test("deleting a shape takes its open eye with it") {
        let h = try publishingHarness()
        let plaque = h.add(Plaque(plaqueFrame))
        h.conceal(plaque)
        h.publish(plaque)
        expectEqual(h.chipSymbol(of: plaque), "eye")
        h.editor.transact { $0.delete([plaque]) }
        h.editor.undo()
        expectEqual(h.chip(of: plaque), nil, "back, public, with no chip: the fade went with the shape")
    },
    test("Make Private on a lingering open eye stops the fade; a shape made public twice lingers once") {
        let h = try publishingHarness()
        let plaque = h.add(Plaque(plaqueFrame))
        h.conceal(plaque)
        h.publish(plaque)
        h.wait(1000)
        h.conceal(plaque)
        expectEqual(h.chipSymbol(of: plaque), "eye.slash")
        h.wait(3000)
        expectEqual(h.chipSymbol(of: plaque), "eye.slash", "the old fade didn't take it away")
        h.publish(plaque)
        h.wait(1700)
        expect(h.chip(of: plaque) != nil, "a new linger of its own")
        h.wait(300)
        expectEqual(h.chip(of: plaque), nil)
    },
])

@MainActor let publishingBoardTests = Suite("Publishing across boards", [
    test("going back to a board, a shape there that goes public shows it, as one on the board shown would") {
        let pocket = ShapeRecord(Pocket(CGRect(x: 600, y: 600, width: 100, height: 100)))
        var plaque = ShapeRecord(Plaque(plaqueFrame))
        plaque[PrivateProperty.self] = true
        let file = CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(pocket), AnyShapeRecord(plaque)]),
                              children: [pocket.id: CanvasDocument(shapes: [])])
        let h = try publishingHarness([PocketsPlugin()], file: file)
        expect(h.enter(pocket.id))
        expect(h.editor.showBoard(.root))
        h.publish(plaque.id)
        expectEqual(h.chipSymbol(of: plaque.id), "eye", "known to be private: it went public")
    },
    test("the open eye stops with its board: it isn't there when the board is shown again") {
        let pocket = ShapeRecord(Pocket(CGRect(x: 600, y: 600, width: 100, height: 100)))
        var plaque = ShapeRecord(Plaque(plaqueFrame))
        plaque[PrivateProperty.self] = true
        let file = CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(pocket), AnyShapeRecord(plaque)]),
                              children: [pocket.id: CanvasDocument(shapes: [])])
        let h = try publishingHarness([PocketsPlugin()], file: file)
        h.publish(plaque.id)
        expect(h.enter(pocket.id))
        expect(h.editor.showBoard(.root))
        expectEqual(h.chip(of: plaque.id), nil, "the fade stopped with the board")
    },
])
