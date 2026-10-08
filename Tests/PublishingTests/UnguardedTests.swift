@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import DetailPanel
import Publishing
import TestKit
import Topology

// The paths that make a shape private with no guard (undo, redo, a paste, a board edited by hand,
// `canvas draw`) write it, and everything follows: the stand-ins drop it in that commit, the count
// goes, the tab with it, the chip reads Private as it does for any shape that goes private; making
// it public again heals them.

@MainActor let unguardedTests = Suite("Private by a path with no guard", [
    test("written, whatever stands for the shape: the stand-in lets it go in that commit, and making it public again heals") {
        let h = try publishingHarness()
        let plaque = h.add(Plaque(plaqueFrame))
        h.publish(plaque)
        let holder = h.hold([plaque]), lens = h.lens("what", answering: [plaque])
        let topology = try require(h.editor.topology)
        h.editor.transact { $0.update(plaque) { $0[PublicProperty.self] = nil } }          // a hand-edited board, draw
        expectEqual(h.editor.document[plaque]?[PublicProperty.self], nil, "written")
        expectEqual(topology.forwards(of: holder), [], "the stand-in lets go of it in that commit")
        expectEqual(topology.forwards(of: lens), [], "the answer too")
        expectEqual(topology.standIns(for: plaque), [])
        expectEqual(h.chipText(of: plaque), "Private", "the chip reads Private for a moment, as for any")
        let panel = try require(h.editor.detailPanel)
        expect(!panel.layout(for: h.editor.document[plaque]!).tabs.contains(.of(ReferencedInTab.self)), "no tab")
        h.publish(plaque)
        expectEqual(topology.forwards(of: holder), [plaque], "healed")
        expectEqual(topology.forwards(of: lens), [plaque])
        expectEqual(h.chipText(of: plaque), "Public · 2")
    },
    test("undo and redo go private and public with no question asked, and no refusal") {
        let log = RefusalLog()
        let h = try publishingHarness([FreezingPlugin(log: log)])
        let plaque = h.add(Plaque(plaqueFrame))
        h.publish(plaque)
        let holder = h.hold([plaque])
        h.editor.undo()                                                                  // the stand-in goes
        h.editor.undo()                                                                  // then the shape is private
        expectEqual(h.editor.document[plaque]?[PublicProperty.self], nil)
        expectEqual(h.chipText(of: plaque), "Private")
        h.editor.redo()
        h.editor.redo()
        expectEqual(h.editor.document[plaque]?[PublicProperty.self], true)
        expectEqual(try require(h.editor.topology).standIns(for: plaque), [holder])
        expectEqual(h.chipText(of: plaque), "Public · 1")
        expectEqual(log.refusals, [], "nothing was refused")
    },
    test("a pasted copy of a public shape is public, as every added property's value is, and one of a private shape is private") {
        let h = try publishingHarness()
        let plaque = h.add(Plaque(plaqueFrame)), other = h.add(Plaque(CGRect(x: 400, y: 100, width: 100, height: 100)))
        h.publish(plaque)
        let publicCopy = ShapeID(), privateCopy = ShapeID()
        h.editor.transact { transaction in
            transaction.insert(h.editor.document[plaque]!.copy(as: publicCopy))
            transaction.insert(h.editor.document[other]!.copy(as: privateCopy))
        }
        expectEqual(h.editor.document[publicCopy]?[PublicProperty.self], true)
        expectEqual(h.editor.document[privateCopy]?[PublicProperty.self], nil)
        expectEqual(h.chipText(of: publicCopy), "Public")
        expectEqual(h.chip(of: privateCopy), nil, "no Private chip for a shape that arrived private")
    },
    test("deleting a shape takes its Private chip with it") {
        let h = try publishingHarness()
        let plaque = h.add(Plaque(plaqueFrame))
        h.publish(plaque)
        h.editor.makePrivate([plaque])
        expectEqual(h.chipText(of: plaque), "Private")
        h.editor.transact { $0.delete([plaque]) }
        h.editor.undo()
        expectEqual(h.chip(of: plaque), nil, "back, private, with no chip: the fade went with the shape")
    },
    test("Make Public on a lingering Private stops the fade; a shape made private twice lingers once") {
        let h = try publishingHarness()
        let plaque = h.add(Plaque(plaqueFrame))
        h.publish(plaque)
        h.editor.makePrivate([plaque])
        h.wait(1000)
        h.editor.makePublic([plaque])
        expectEqual(h.chipText(of: plaque), "Public")
        h.wait(3000)
        expectEqual(h.chipText(of: plaque), "Public", "the old fade didn't take it away")
        h.editor.makePrivate([plaque])
        h.wait(1700)
        expect(h.chip(of: plaque) != nil, "a new linger of its own")
        h.wait(300)
        expectEqual(h.chip(of: plaque), nil)
    },
])

@MainActor let publishingBoardTests = Suite("Publishing across boards", [
    test("going back to a board takes back what Publishing kept of it; a board that changed is looked through again") {
        let pocket = ShapeRecord(Pocket(CGRect(x: 600, y: 600, width: 100, height: 100)))
        let plaque = ShapeRecord(Plaque(plaqueFrame))
        let file = CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(pocket), AnyShapeRecord(plaque)]),
                              children: [pocket.id: CanvasDocument(shapes: [])])
        let h = try publishingHarness([PocketsPlugin()], file: file)
        h.publish(plaque.id)
        #if DEBUG
        let scanned = h.editor.boardsScannedForPublic
        #endif
        expect(h.enter(pocket.id))
        #if DEBUG
        let afterEntering = h.editor.boardsScannedForPublic
        expectEqual(afterEntering, scanned + 1, "the pocket's board looked through")
        #endif
        expect(h.editor.showBoard(.root))
        #if DEBUG
        expectEqual(h.editor.boardsScannedForPublic, afterEntering, "the root as it was left")
        #endif
        h.editor.makePrivate([plaque.id])
        expectEqual(h.chipText(of: plaque.id), "Private", "known to be public: it went private")
    },
    test("the Private chip stops with its board: it isn't there when the board is shown again") {
        let pocket = ShapeRecord(Pocket(CGRect(x: 600, y: 600, width: 100, height: 100)))
        let plaque = ShapeRecord(Plaque(plaqueFrame))
        let file = CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(pocket), AnyShapeRecord(plaque)]),
                              children: [pocket.id: CanvasDocument(shapes: [])])
        let h = try publishingHarness([PocketsPlugin()], file: file)
        h.publish(plaque.id)
        h.editor.makePrivate([plaque.id])
        expect(h.enter(pocket.id))
        expect(h.editor.showBoard(.root))
        expectEqual(h.chip(of: plaque.id), nil, "the fade stopped with the board")
    },
])
