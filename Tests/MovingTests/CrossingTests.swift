import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import ContextMenus
import Selection
import SlashCommands
import TableOfContents
import TestKit

// A move keeps the arrows that cross the edge: an arrow goes where its start goes, and its other end is a pill for what stays (or
// for what moved), beside the start; a pill already there is reused, and the shape itself if it is there. Fixtures only: links as
// the connector, relays as the pills (CrossingFixtures). Nothing is public that wasn't: a closed shape is not stood for.

@MainActor private func crossingHarness(_ file: CanvasFile, log: RefusalLog = RefusalLog()) throws -> EditorHarness {
    let h = try movingHarness(file, log: log, crossingPlugins())
    h.editor.viewportDidResize(to: crossingView)
    return h
}

@MainActor private func droppingCrossingHarness(_ file: CanvasFile) throws -> EditorHarness {
    let h = try droppingHarness(file, crossingPlugins())
    h.editor.viewportDidResize(to: crossingView)
    return h
}

/// Root: a pocket P, the boxes A (400, 0) and B (400, 300). A is moved onto P's board, where it lands at the view's middle (450, 300).
private struct Shoal {
    let p = ShapeID(), a = ShapeID(), b = ShapeID(), l = ShapeID()
    var pBoard: BoardID { BoardID(owner: p) }

    /// A link from A to B, or the other way round.
    func file(linking from: ShapeID? = nil, to: ShapeID? = nil, root extra: [AnyShapeRecord] = [], onPocket pocketShapes: [AnyShapeRecord] = [],
              b record: AnyShapeRecord? = nil) -> CanvasFile {
        CanvasFile(root: CanvasDocument(shapes: [pocket(p, 0, 0), box(a, 400, 0), record ?? box(b, 400, 300),
                                                 link(l, from ?? a, to ?? b)] + extra),
                   children: [p: CanvasDocument(shapes: pocketShapes)])
    }
}

@MainActor let crossingTests = Suite("Moving keeps the arrows that cross", [
    test("the start moves: the arrow goes with it, and its end is a relay for the shape that stays, right of the start where it lands; one Move, undone exactly on both boards") {
        let s = Shoal()
        let h = try crossingHarness(s.file())
        let before = h.file
        expect(h.run("move-to", on: s.a, with: s.p))
        expectEqual(h.file.board(containing: s.a), s.pBoard)
        expectEqual(h.file.board(containing: s.l), s.pBoard, "the arrow went with its start")
        expectEqual(h.file.board(containing: s.b), .root, "what stays stays")
        let pill = try require(h.relays(on: s.pBoard).first)
        expectEqual(h.relays(on: s.pBoard).count, 1)
        expectEqual(h.relays(on: .root).count, 0, "no pill is left on the origin")
        expectEqual(h.stands(pill.id), [s.b])
        expectEqual(h.ends(of: s.l).from, s.a)
        expectEqual(h.ends(of: s.l).to, pill.id, "the end is the relay")
        let landed = try require(h.frame(of: s.a))
        let said = try require(pill.box)
        expectEqual(said.minX, landed.maxX + 80, "a gap right of the start")
        expectEqual(said.midY, landed.midY, "centered on it")
        expectEqual(h.editor.undoHistory.undoName, "Move")
        let after = h.file
        h.editor.undo()
        try expectFile(h, before, "both boards as they were")
        h.editor.redo()
        try expectFile(h, after, "and as the move left them")
    },
    test("the end moves: the arrow stays, and its end is a relay for the shape that moved, right of the start that stays; one Move, undone exactly") {
        let s = Shoal()
        let h = try crossingHarness(s.file(linking: s.b, to: s.a))
        let before = h.file
        expect(h.run("move-to", on: s.a, with: s.p))
        expectEqual(h.file.board(containing: s.a), s.pBoard)
        expectEqual(h.file.board(containing: s.l), .root, "the arrow stays with its start")
        let pill = try require(h.relays(on: .root).first)
        expectEqual(h.relays(on: .root).count, 1)
        expectEqual(h.relays(on: s.pBoard).count, 0)
        expectEqual(h.stands(pill.id), [s.a])
        expectEqual(h.ends(of: s.l).from, s.b)
        expectEqual(h.ends(of: s.l).to, pill.id)
        expectEqual(pill.box, at(580, 330, 100, 40), "80 right of B, centered on it, clear of what is there")
        let after = h.file
        h.editor.undo()
        try expectFile(h, before, "both boards as they were")
        h.editor.redo()
        try expectFile(h, after, "and as the move left them")
    },
    test("a relay already on the destination for the same shape is reused, not made again, and the arrow ends at it") {
        let s = Shoal(), r = ShapeID()
        let h = try crossingHarness(s.file(onPocket: [relay(r, at(100, 100, 100, 40), stands: s.b)]))
        let before = h.file
        expect(h.run("move-to", on: s.a, with: s.p))
        expectEqual(h.relays(on: s.pBoard).map(\.id), [r], "the one that was there")
        expectEqual(h.ends(of: s.l).to, r)
        expectEqual(h.file.board(containing: s.l), s.pBoard)
        expectEqual(h.file.record(r)?.box, at(100, 100, 100, 40), "where it was")
        h.editor.undo()
        try expectFile(h, before, "both boards as they were")
    },
    test("a relay already on the origin for the moved shape is reused for an arrow that stays") {
        let s = Shoal(), r = ShapeID()
        let h = try crossingHarness(s.file(linking: s.b, to: s.a, root: [relay(r, at(900, 300, 100, 40), stands: s.a)]))
        expect(h.run("move-to", on: s.a, with: s.p))
        expectEqual(h.relays(on: .root).map(\.id), [r])
        expectEqual(h.ends(of: s.l).to, r)
        expectEqual(h.file.board(containing: s.l), .root)
    },
    test("an end that is a relay is the shape it stands for: moved to that shape's board, the arrow goes straight to the shape, and the relay stays") {
        let s = Shoal(), r = ShapeID(), far = ShapeID()
        let file = CanvasFile(root: CanvasDocument(shapes: [pocket(s.p, 0, 0), box(s.a, 400, 0), relay(r, at(400, 300, 100, 40), stands: far), link(s.l, s.a, r)]),
                              children: [s.p: CanvasDocument(shapes: [box(far, 100, 100)])])
        let h = try crossingHarness(file)
        let before = h.file
        expect(h.run("move-to", on: s.a, with: s.p))
        expectEqual(h.file.board(containing: s.l), s.pBoard)
        expectEqual(h.ends(of: s.l).from, s.a)
        expectEqual(h.ends(of: s.l).to, far, "straight to the shape, which is on the board now")
        expectEqual(h.relays(on: s.pBoard).count, 0, "no relay was made, none is left over")
        expectEqual(h.relays(on: .root).map(\.id), [r], "the old one stays where it was")
        h.editor.undo()
        try expectFile(h, before, "both boards as they were")
    },
    test("a read-only arrow lets go as it does without this: it stays, and its end is free; no relay is made") {
        let s = Shoal()
        let h = try crossingHarness(s.file())
        h.freeze([s.l])
        expect(h.run("move-to", on: s.a, with: s.p))
        expectEqual(h.file.board(containing: s.l), .root)
        expectEqual(h.ends(of: s.l).from, nil, "let go of the shape that moved")
        expectEqual(h.ends(of: s.l).to, s.b)
        expectEqual(h.relays(on: .root).count + h.relays(on: s.pBoard).count, 0)
    },
    test("an end no relay may stand for (a closed shape) lets go as it does without this: nothing is made public, no relay is made") {
        let s = Shoal()
        let h = try crossingHarness(s.file(b: closed(box(s.b, 400, 300))))
        let before = h.file
        expect(h.run("move-to", on: s.a, with: s.p))
        expectEqual(h.file.board(containing: s.l), .root, "the arrow stays")
        expectEqual(h.ends(of: s.l).from, nil)
        expectEqual(h.relays(on: .root).count + h.relays(on: s.pBoard).count, 0)
        expectEqual(h.file.record(s.b)?.meta[Closed.self], true, "still closed")
        h.editor.undo()
        try expectFile(h, before, "as it was")
    },
    test("both ends moving is as it was: the arrow rides, and no relay is made") {
        let s = Shoal()
        let h = try crossingHarness(s.file())
        expect(h.editor.slashCommands?.run("move-to", for: .selection([s.a, s.b]), with: SlashArguments([.shape(s.p, label: "P")])) ?? false)
        expectEqual(h.file.board(containing: s.l), s.pBoard)
        expectEqual(h.ends(of: s.l).from, s.a)
        expectEqual(h.ends(of: s.l).to, s.b)
        expectEqual(h.relays(on: s.pBoard).count + h.relays(on: .root).count, 0)
    },
    test("several arrows to one shape that stays share a relay; arrows to different shapes get relays that don't overlap") {
        let s = Shoal(), a2 = ShapeID(), l2 = ShapeID(), b2 = ShapeID(), l3 = ShapeID(), l4 = ShapeID()
        let h = try crossingHarness(s.file(root: [box(a2, 400, -200), box(b2, 700, 300), link(l2, a2, s.b), link(l3, s.a, b2), link(l4, s.a, s.b)]))
        let before = h.file
        expect(h.editor.slashCommands?.run("move-to", for: .selection([s.a, a2]), with: SlashArguments([.shape(s.p, label: "P")])) ?? false)
        let pills = h.relays(on: s.pBoard)
        expectEqual(pills.count, 2, "one for B however many arrows reach it, one for B2")
        let forB = try require(pills.first { h.stands($0.id) == [s.b] }), forB2 = try require(pills.first { h.stands($0.id) == [b2] })
        expectEqual(h.ends(of: s.l).to, forB.id)
        expectEqual(h.ends(of: l2).to, forB.id)
        expectEqual(h.ends(of: l4).to, forB.id)
        expectEqual(h.ends(of: l3).to, forB2.id)
        expect(!(forB.box ?? .zero).intersects(forB2.box ?? .zero), "clear of each other")
        for each in [s.l, l2, l3, l4] { expectEqual(h.file.board(containing: each), s.pBoard) }
        h.editor.undo()
        try expectFile(h, before, "everything as it was")
    },
    test("a shape a corral holds moves with it, and the corral's arrow to a shape outside goes through a relay") {
        let f = ShapeID(), s = Shoal()
        let file = CanvasFile(root: CanvasDocument(shapes: [pocket(s.p, 0, 0), corral(f, at(300, 0, 300, 300)), box(s.a, 340, 40, in: f), box(s.b, 700, 300),
                                                            link(s.l, s.a, s.b)]), children: [s.p: CanvasDocument()])
        let h = try crossingHarness(file)
        let before = h.file
        expect(h.run("move-to", on: f, with: s.p))
        expectEqual(h.file.board(containing: s.a), s.pBoard, "carried")
        expectEqual(h.file.board(containing: s.l), s.pBoard)
        let pill = try require(h.relays(on: s.pBoard).first)
        expectEqual(h.stands(pill.id), [s.b])
        expectEqual(h.ends(of: s.l).to, pill.id)
        h.editor.undo()
        try expectFile(h, before, "as it was")
    },
    test("an arrow from a shape on a board that isn't shown, dropped from that board's outline onto another: kept through a relay, and undone exactly") {
        let s = Shoal(), q = ShapeID()
        let file = CanvasFile(root: CanvasDocument(shapes: [pocket(s.p, 0, 0), pocket(q, 0, 400)]),
                              children: [s.p: CanvasDocument(shapes: [box(s.a, 400, 0), box(s.b, 400, 300), link(s.l, s.a, s.b)]), q: CanvasDocument()])
        let h = try droppingCrossingHarness(file)
        expectEqual(h.editor.board, .root)
        let before = h.file
        expect(h.drop([s.a], on: q, .on))
        expectEqual(h.file.board(containing: s.a), BoardID(owner: q))
        expectEqual(h.file.board(containing: s.l), BoardID(owner: q), "the arrow goes with its start")
        let pills = h.relays(on: BoardID(owner: q))
        expectEqual(pills.count, 1)
        expectEqual(h.stands(pills[0].id), [s.b])
        expectEqual(h.ends(of: s.l).to, pills[0].id)
        expectEqual(h.relays(on: s.pBoard).count, 0)
        expectEqual(h.relays(on: .root).count, 0, "the board shown has none of it")
        h.editor.undo()
        try expectFile(h, before, "the three boards as they were")
    },
    test("a drop in the table of contents and Move To ▸ take the same path: the arrow kept, one Move, the same relay in the same place") {
        let s = Shoal()
        let viaCommand = try crossingHarness(s.file())
        expect(viaCommand.run("move-to", on: s.a, with: s.p))
        let reference = try require(viaCommand.relays(on: s.pBoard).first)

        let viaDrop = try droppingCrossingHarness(s.file())
        expect(viaDrop.drop([s.a], on: s.p, .on))
        let dropped = try require(viaDrop.relays(on: s.pBoard).first)
        expectEqual(dropped.box, reference.box, "where the command puts it")
        expectEqual(viaDrop.stands(dropped.id), [s.b])
        expectEqual(viaDrop.ends(of: s.l).to, dropped.id)
        expectEqual(viaDrop.editor.undoHistory.undoName, "Move")

        let viaMenu = try droppingCrossingHarness(s.file())
        viaMenu.editor.selectedShapeIDs = [s.a]
        let frame = try require(viaMenu.frame(of: s.a))
        let menu = try require(viaMenu.secondaryClick(at: CGPoint(x: frame.midX, y: frame.midY)))
        let items = menu.outline
        let at = try require(items.firstIndex(of: "Move To ▸"))
        let target = try require(items[(at + 1)...].first { $0.hasPrefix("  ") }).trimmingCharacters(in: .whitespaces)
        try menu.choose("Move To", target)
        let chosen = try require(viaMenu.relays(on: s.pBoard).first)
        expectEqual(chosen.box, reference.box, "and Move To ▸ too")
        expectEqual(viaMenu.stands(chosen.id), [s.b])
        expectEqual(viaMenu.ends(of: s.l).to, chosen.id)
        expectEqual(viaMenu.editor.undoHistory.undoName, "Move")
    },
    test("a move that crosses no arrow makes nothing: a shape with no arrow moved, another pair's link stays as it was, and there is no relay") {
        let s = Shoal(), x = ShapeID()
        let h = try crossingHarness(s.file(root: [box(x, 700, 0)]))
        expect(h.run("move-to", on: x, with: s.p))
        expectEqual(h.file.board(containing: x), s.pBoard)
        expectEqual(h.file.board(containing: s.l), .root)
        expectEqual(h.ends(of: s.l).from, s.a)
        expectEqual(h.ends(of: s.l).to, s.b)
        expectEqual(h.relays(on: .root).count + h.relays(on: s.pBoard).count, 0)
    },
])
