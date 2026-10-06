@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Observation
import TestKit

// Read-only boards: a board whose owner can't change (a frozen pocket, a pocket in a frozen corral, a
// pocket on a read-only board), with CanvasTesting's `Frozen` flag standing in for Locking's lock and
// pockets for subboards. Entered as any board; every shape on it is read-only, and nothing goes on
// it, at any depth.

private let unit = CGRect(x: 0, y: 0, width: 100, height: 100)

private func box(_ id: ShapeID, x: CGFloat = 0, y: CGFloat = 0) -> AnyShapeRecord {
    AnyShapeRecord(ShapeRecord(id: id, Box(CGRect(x: x, y: y, width: 40, height: 30))))
}
private func pocket(_ id: ShapeID, _ frame: CGRect = unit, frozen: Bool = false, in container: ShapeID? = nil) -> AnyShapeRecord {
    var record = AnyShapeRecord(ShapeRecord(id: id, Pocket(frame))).copy(as: id, container: container)
    if frozen { record[Frozen.self] = true }
    return record
}
private func corral(_ id: ShapeID, _ frame: CGRect, frozen: Bool = false) -> AnyShapeRecord {
    var record = AnyShapeRecord(ShapeRecord(id: id, Corral(frame)))
    if frozen { record[Frozen.self] = true }
    return record
}
private func card(_ id: ShapeID) -> AnyShapeRecord {
    AnyShapeRecord(ShapeRecord(id: id, Card(CGRect(x: 0, y: 0, width: 100, height: 60))))
}
private func board(_ records: AnyShapeRecord...) -> CanvasDocument { CanvasDocument(shapes: records) }

@MainActor private func harness(_ file: CanvasFile, _ refusals: RefusalLog = RefusalLog()) throws -> EditorHarness {
    try EditorHarness(plugins: [FixturesPlugin(), PocketsPlugin(), CorralsPlugin(), CardsPlugin(), TilesPlugin(), FreezingPlugin(log: refusals)],
                      file: file)
}

/// Freezes shapes on a board, shown or not (or thaws them, with `false`), in one step.
@MainActor private func freeze(_ h: EditorHarness, _ shapes: [ShapeID], on board: BoardID, _ frozen: Bool = true) {
    h.editor.transact(on: board, "Freeze") { transaction in
        for id in shapes { transaction.update(id) { $0[Frozen.self] = frozen ? true : nil } }
    }
}

/// The root holds a frozen pocket `p`, a pocket `q`, and a frozen corral `k` holding a pocket `s`;
/// `p`'s board holds a box `a` and a pocket `r`, whose board holds a box `b`; `q`'s board holds a box
/// `c` and a card `n`; `s`'s board holds a box `d`.
@MainActor private struct LockedTree {
    let p = ShapeID(), q = ShapeID(), k = ShapeID(), s = ShapeID(), r = ShapeID()
    let a = ShapeID(), b = ShapeID(), c = ShapeID(), d = ShapeID(), n = ShapeID()
    var pBoard: BoardID { BoardID(owner: p) }
    var qBoard: BoardID { BoardID(owner: q) }
    var rBoard: BoardID { BoardID(owner: r) }
    var sBoard: BoardID { BoardID(owner: s) }

    var file: CanvasFile { file(pFrozen: true) }

    func file(pFrozen: Bool) -> CanvasFile {
        CanvasFile(root: board(pocket(p, frozen: pFrozen), pocket(q, CGRect(x: 200, y: 0, width: 100, height: 100)),
                               corral(k, CGRect(x: 400, y: 0, width: 300, height: 300), frozen: true),
                               pocket(s, CGRect(x: 420, y: 20, width: 100, height: 100), in: k)),
                   children: [p: board(box(a), pocket(r, CGRect(x: 100, y: 0, width: 100, height: 100))), r: board(box(b)),
                              q: board(box(c), card(n)), s: board(box(d))])
    }
}

@MainActor let readOnlyBoardTests = Suite("Read-only boards", [
    test("a frozen pocket's board is read-only, and every board under it; so is a board in a frozen corral; the root never is") {
        let t = LockedTree(), h = try harness(t.file)
        expect(!h.editor.isReadOnly(board: .root))
        expect(!h.editor.isBoardReadOnly)
        expect(h.editor.isReadOnly(board: t.pBoard))
        expect(h.editor.isReadOnly(board: t.rBoard), "a pocket on a read-only board, not frozen itself")
        expect(h.editor.isReadOnly(board: t.sBoard), "a pocket in a frozen corral")
        expect(!h.editor.isReadOnly(board: t.qBoard))
        expect(h.editor.isReadOnly(inFile: t.b) && h.editor.isReadOnly(inFile: t.r) && h.editor.isReadOnly(inFile: t.d))
        expect(!h.editor.isReadOnly(inFile: t.c) && !h.editor.isReadOnly(inFile: t.q))
        expect(!h.editor.isReadOnly(inFile: ShapeID()))
        let reading = try require(h.editor.reading(of: t.rBoard))
        expect(reading.isBoardReadOnly)
        expect(reading.isReadOnly(try require(reading.document[t.b])))
        expect(!(try require(h.editor.reading(of: t.qBoard))).isBoardReadOnly)

        expect(h.enter(t.p), "entered, as any board")
        expect(h.editor.isBoardReadOnly)
        expect(h.editor.isReadOnly(t.a) && h.editor.isReadOnly(t.r))
        expect(!h.editor.registry.isReadOnly(try require(h.editor.document[t.a])), "the rules read the record alone")
        expect(h.enter(t.r))
        expect(h.editor.isBoardReadOnly && h.editor.isReadOnly(t.b), "at any depth")
        expect(!h.editor.isReadOnly(inFile: t.c))
        expect(h.editor.showBoard(t.qBoard))
        expect(!h.editor.isBoardReadOnly && !h.editor.isReadOnly(t.c))
    },
    test("on a read-only board a transaction changes, restacks, moves, turns and deletes nothing that was there, and takes nothing new: services hear each shape, and the board's owner") {
        let t = LockedTree(), refusals = RefusalLog(), h = try harness(t.file, refusals)
        expect(h.enter(t.p))
        let before = h.file
        let added = box(ShapeID(), x: 300)
        let (boardReadOnly, aReadOnly, addedReadOnly, turned) = h.editor.transact("Try") { tx in
            tx.update(t.a) { $0.box = CGRect(x: 10, y: 10, width: 50, height: 50) }
            tx.update(t.r) { $0[Frozen.self] = true }                    // its own lock can't change either
            tx.bringToFront(t.a)
            tx.translate([t.a, t.r], by: CGPoint(x: 5, y: 5))
            let turned = tx.turn(t.a, into: Pocket(CGRect(x: 0, y: 0, width: 40, height: 30)))
            tx.delete([t.r])
            tx.insert(added)
            return (tx.isBoardReadOnly, tx.document[t.a].map(tx.isReadOnly) ?? false, tx.isReadOnly(added), turned)
        }
        expect(boardReadOnly && aReadOnly && addedReadOnly, "the transaction says so, of a shape it would add too")
        expect(!turned)
        expectEqual(h.file, before, "nothing changed, here or anywhere")
        expect(!h.editor.canUndo, "and no step")
        expectEqual(refusals.refusals, [[t.a, t.r, t.p]], "once, when it's done")
    },
    test("a move onto a read-only board is refused, at any depth: the board's owner is heard; from a read-only board nothing moves") {
        let t = LockedTree(), refusals = RefusalLog(), h = try harness(t.file, refusals)
        expect(h.editor.showBoard(t.qBoard))
        let before = h.file
        var moved = h.editor.transact("Move") { $0.move([t.c], to: t.rBoard) }
        expect(!moved)
        expectEqual(refusals.refusals, [[t.r]], "r isn't frozen, but its board is under a frozen pocket")
        moved = h.editor.transact("Move") { $0.move([t.c], to: t.sBoard) }
        expect(!moved)
        expectEqual(refusals.refusals.last, [t.s])
        expectEqual(h.file, before)
        expect(h.editor.showBoard(t.rBoard))
        moved = h.editor.transact("Move") { $0.move([t.b], to: .root) }
        expect(!moved, "a read-only board's shapes stay")
        expectEqual(refusals.refusals.last, [t.b])
        expectEqual(h.file, before)
        freeze(h, [t.p], on: .root, false)
        moved = h.editor.transact("Move") { $0.move([t.b], to: t.qBoard) }
        expect(moved, "thawed, it moves")
        expectEqual(h.file[t.qBoard].shapes.map(\.id), [t.c, t.n, t.b])
    },
    test("nothing is placed on a read-only board; no tool that places is enabled there, and one in use is left as the board becomes read-only") {
        let t = LockedTree(), refusals = RefusalLog(), h = try harness(t.file, refusals)
        let tile = ToolID(placing: Tile.kind), placement = try require(h.editor.registry.placement(for: Tile.kind))
        expect(h.editor.isToolEnabled(tile))
        expect(h.enter(t.p))
        expect(!h.editor.isToolEnabled(tile) && h.editor.isToolEnabled(.hand))
        h.editor.setTool(tile)
        expectEqual(h.editor.currentToolID, .hand, "not taken")
        let before = h.file
        h.editor.place(placement, at: CGPoint(x: 500, y: 500))
        h.editor.place(placement, in: CGRect(x: 500, y: 500, width: 120, height: 80))
        expectEqual(h.file, before, "nothing put down")
        expectEqual(refusals.refusals, [[t.p], [t.p]], "the board's owner, each time")
        expect(!h.editor.canUndo)

        expect(h.editor.showBoard(t.qBoard))
        expect(h.editor.isToolEnabled(tile))
        h.editor.setTool(tile)
        expectEqual(h.editor.currentToolID, tile)
        freeze(h, [t.q], on: .root)                                    // a lock above the board shown, committed there
        expect(h.editor.isBoardReadOnly)
        expectEqual(h.editor.currentToolID, h.editor.registry.defaultTool, "left for the default")
        freeze(h, [t.q], on: .root, false)
        expect(!h.editor.isBoardReadOnly)
        h.editor.setTool(tile)
        expectEqual(h.editor.currentToolID, tile)
    },
    test("a shape on a read-only board isn't edited, and services hear the try; one edited as its board becomes read-only stops") {
        let t = LockedTree(), refusals = RefusalLog(), h = try harness(t.file, refusals)
        expect(h.editor.showBoard(t.qBoard))
        expect(h.editor.beginEditing(t.n))
        freeze(h, [t.q], on: .root)
        expectEqual(h.editor.editingShapeID, nil)
        expectEqual(refusals.refusals, [], "freezing above it isn't a refusal")
        expect(!h.editor.beginEditing(t.n))
        expectEqual(refusals.refusals, [[t.n]])
    },
    test("a transaction on a read-only board that isn't shown changes nothing there, and shows no refusal") {
        let t = LockedTree(), refusals = RefusalLog(), h = try harness(t.file, refusals)
        let before = h.file
        let readOnly = h.editor.transact(on: t.rBoard, "Try") { tx -> Bool in
            tx.update(t.b) { $0.box = CGRect(x: 10, y: 10, width: 50, height: 50) }
            tx.insert(box(ShapeID(), x: 300))
            tx.delete([t.b])
            return tx.isBoardReadOnly
        }
        expectEqual(readOnly, true)
        expectEqual(h.file, before)
        expect(!h.editor.canUndo)
        expectEqual(refusals.refusals, [])
    },
    test("an editor opened on a read-only board is read-only from the start, and knows where its path turns read-only: the topmost lock") {
        let t = LockedTree(), h = try harness(t.file)
        let opened = CanvasEditor(registry: h.editor.registry, file: t.file, showing: t.rBoard, scheduler: ManualScheduler())
        expectEqual(opened.board, t.rBoard)
        expect(opened.isBoardReadOnly && opened.isReadOnly(t.b), "before any commit or switch")
        expectEqual(opened.readOnlyStart, t.pBoard, "p's board: r isn't frozen, p is")
        opened.transact { $0.insert(box(ShapeID(), x: 300)) }
        expectEqual(opened.document.shapes.map(\.id), [t.b], "nothing goes on it")
        let plain = CanvasEditor(registry: h.editor.registry, file: t.file, showing: t.qBoard, scheduler: ManualScheduler())
        expect(!plain.isBoardReadOnly)
        expectEqual(plain.readOnlyStart, nil)

        expect(h.enter(t.p) && h.enter(t.r))
        expectEqual(h.editor.readOnlyStart, t.pBoard)
        freeze(h, [t.r], on: t.pBoard)                              // can't: p's board is read-only
        expectEqual(h.editor.readOnlyStart, t.pBoard)
        freeze(h, [t.p], on: .root, false)
        expect(!h.editor.isBoardReadOnly)
        expectEqual(h.editor.readOnlyStart, nil)
        freeze(h, [t.r], on: t.pBoard)
        expectEqual(h.editor.readOnlyStart, t.rBoard, "r's own lock, now p's is gone")
        freeze(h, [t.p], on: .root)
        expectEqual(h.editor.readOnlyStart, t.pBoard, "the topmost, with both")
        expect(h.editor.showBoard(.root))
        expectEqual(h.editor.readOnlyStart, nil)
    },
    test("a default tool that places shapes gives way to the Hand on a read-only board, once the board is shown and heard; and from the start") {
        let t = LockedTree(), tile = ToolID(placing: Tile.kind)
        let placingDefault = Contributor(id: "placing-default") { $0.defaultTool(tile) }
        let plugins: [any CanvasPlugin] = [FixturesPlugin(), PocketsPlugin(), CorralsPlugin(), CardsPlugin(), TilesPlugin(), FreezingPlugin(), placingDefault]
        let h = try EditorHarness(plugins: plugins, file: t.file)
        expectEqual(h.editor.currentToolID, tile)
        expect(h.enter(t.p))
        expectEqual(h.editor.currentToolID, .hand, "the default isn't enabled here")
        expect(h.editor.showBoard(t.qBoard))
        expectEqual(h.editor.currentToolID, tile, "and comes back where it is")
        let opened = CanvasEditor(registry: h.editor.registry, file: t.file, showing: t.pBoard, scheduler: ManualScheduler())
        expectEqual(opened.currentToolID, .hand, "opened on one")
    },
    test("whether the board shown is read-only is observed apart from the document: it changes with a lock above it, a switch and a file put in place, not with a commit") {
        let t = LockedTree(), h = try harness(t.file)
        expect(h.editor.showBoard(t.qBoard))
        let commit = Flag()
        withObservationTracking { _ = h.editor.isBoardReadOnly } onChange: { commit.set() }
        h.editor.transact { $0.update(t.c) { $0.box = CGRect(x: 5, y: 5, width: 40, height: 30) } }
        expect(!commit.isSet, "a commit that changes nothing of it")
        freeze(h, [t.q], on: .root)
        expect(commit.isSet && h.editor.isBoardReadOnly)
        let switched = Flag()
        withObservationTracking { _ = h.editor.isBoardReadOnly } onChange: { switched.set() }
        expect(h.editor.showBoard(.root))
        expect(switched.isSet && !h.editor.isBoardReadOnly)
        expect(h.enter(t.p))
        h.editor.replaceFile(with: t.file(pFrozen: false))              // p thawed on disk, say
        expectEqual(h.editor.board, t.pBoard)
        expect(!h.editor.isBoardReadOnly, "the board stays, and takes shapes now")
        h.editor.transact { $0.insert(box(ShapeID(), x: 300)) }
        expectEqual(h.editor.document.shapes.count, 3)
    },
])
