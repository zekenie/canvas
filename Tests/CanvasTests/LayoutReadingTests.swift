import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import TestKit

// The file as a context reads it (`ShapeContext.reading`), what in it is changed (`isChanged`), what a
// transaction has done so far (`pending`), a context over another board (`over(_:)`) and
// what a context lays out lays in (`layingOut(with:removing:)`).

@MainActor let layoutReadingTests = Suite("Layout reading", [
    test("a transaction says what it has done so far as its commit would: what it added, changed, only moved and removed, and what it wrote elsewhere; a part of it is about a few shapes alone") {
        let pocket = ShapeRecord(Pocket(CGRect(x: 0, y: 300, width: 200, height: 100)))
        let far = ShapeRecord(Box(CGRect(x: 0, y: 0, width: 10, height: 10)))
        let file = CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(pocket)]), children: [pocket.id: CanvasDocument(shapes: [AnyShapeRecord(far)])])
        let h = try EditorHarness(plugins: [FixturesPlugin(), PocketsPlugin()], file: file)
        let moved = h.add(Box(CGRect(x: 0, y: 50, width: 10, height: 10)))
        let changed = h.add(Box(CGRect(x: 0, y: 100, width: 10, height: 10)))
        let deleted = h.add(Box(CGRect(x: 0, y: 150, width: 10, height: 10)))
        var pending: ChangeSet?
        var added = ShapeID()
        var none: ChangeSet?
        h.editor.transact { transaction in
            none = transaction.pending
            added = transaction.insert(Box(CGRect(x: 0, y: 200, width: 10, height: 10)))
            transaction.moveBox(moved, to: CGPoint(x: 5, y: 50))
            transaction.update(changed, as: Box.self) { $0.frame.size.width = 20 }
            transaction.delete([deleted])
            transaction.update(inFile: far.id) { $0 = AnyShapeRecord(ShapeRecord(id: far.id, Box(CGRect(x: 0, y: 0, width: 30, height: 10)))) }
            pending = transaction.pending
        }
        expectEqual(none?.shapeIDs, [], "nothing yet")
        expectEqual(none?.elsewhere, [])
        let said = try require(pending)
        expectEqual(said.added, [added])
        expectEqual(said.changed, [moved, changed])
        expectEqual(said.moved, [moved])
        expectEqual(said.removed, [deleted])
        expectEqual(said.elsewhere, [far.id], "the write on the pocket's board, which is not this transaction's")
        let part = said.restricted(to: [moved, deleted, far.id, ShapeID()])
        expectEqual(part.added, [])
        expectEqual(part.changed, [moved])
        expectEqual(part.moved, [moved])
        expectEqual(part.removed, [deleted])
        expectEqual(part.elsewhere, [far.id])
    },
    test("a transaction that deletes a shape owning a board says, as its commit would, that every shape of the board went with it") {
        let pocket = ShapeRecord(Pocket(CGRect(x: 0, y: 300, width: 200, height: 100)))
        let far = ShapeRecord(Box(CGRect(x: 0, y: 0, width: 10, height: 10)))
        let file = CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(pocket)]), children: [pocket.id: CanvasDocument(shapes: [AnyShapeRecord(far)])])
        let h = try EditorHarness(plugins: [FixturesPlugin(), PocketsPlugin()], file: file)
        var pending: ChangeSet?
        h.editor.transact { transaction in
            transaction.delete([pocket.id])
            pending = transaction.pending
        }
        let said = try require(pending)
        expectEqual(said.removed, [pocket.id])
        expectEqual(said.elsewhere, [far.id], "the board's shape is gone though no record of it was written")
    },
    test("a context over another board's shapes keeps its reading: the file as a transaction has it, and lookups in that board") {
        let pocket = ShapeRecord(Pocket(CGRect(x: 0, y: 300, width: 200, height: 100)))
        let far = ShapeRecord(Box(CGRect(x: 0, y: 0, width: 10, height: 10)))
        let file = CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(pocket)]), children: [pocket.id: CanvasDocument(shapes: [AnyShapeRecord(far)])])
        let h = try EditorHarness(plugins: [FixturesPlugin(), PocketsPlugin()], file: file)
        let near = h.add(Box(CGRect(x: 0, y: 50, width: 10, height: 10)))
        let board = BoardID(owner: pocket.id)
        let committed = h.editor.shapeContext.over(h.editor.contents(of: board))
        expect(committed.shape(far.id) != nil && committed.shape(near) == nil, "its lookups are the other board's")
        expectEqual(committed.reading?.isCommitted, true)
        expectEqual(committed.bounds(of: [far.id]), CGRect(x: 0, y: 0, width: 10, height: 10))
        var seen: (far: Bool, near: Bool, committed: Bool?, changed: Bool?, width: CGFloat?)?
        h.editor.transact { transaction in
            transaction.update(inFile: far.id) { $0 = AnyShapeRecord(ShapeRecord(id: far.id, Box(CGRect(x: 0, y: 0, width: 30, height: 10)))) }
            let there = transaction.shapes.over(transaction.contents(of: board))
            seen = (there.shape(far.id) != nil, there.shape(near) != nil, there.reading?.isCommitted, there.reading?.isChanged(far.id), there.bounds(of: [far.id])?.width)
        }
        expectEqual(seen?.far, true)
        expectEqual(seen?.near, false)
        expectEqual(seen?.committed, false)
        expectEqual(seen?.changed, true)
        expectEqual(seen?.width, 30)
    },
    test("a plain context has no reading, the editor's is the committed file, a transaction's is the transaction's") {
        let h = try EditorHarness(plugins: [FixturesPlugin()])
        let box = h.add(Box(CGRect(x: 0, y: 0, width: 10, height: 10)))
        let plain = ShapeContext(document: h.editor.document, registry: h.editor.registry)
        expect(plain.reading == nil, "a plain context lays nothing out")
        let committed = try require(h.editor.shapeContext.reading)
        expect(committed.isCommitted, "the editor's reads the committed file")
        expect(committed.shape(inFile: box) != nil)
        var inside: (committed: Bool?, inserted: Bool, deleted: Bool)?
        h.editor.transact { transaction in
            let added = transaction.insert(Box(CGRect(x: 0, y: 50, width: 10, height: 10)))
            transaction.delete([box])
            let reading = transaction.shapes.reading
            inside = (reading?.isCommitted, reading?.shape(inFile: added) != nil, reading?.shape(inFile: box) == nil)
        }
        expectEqual(inside?.committed, false, "a transaction's reading isn't the committed file")
        expectEqual(inside?.inserted, true, "a shape it inserted is readable")
        expectEqual(inside?.deleted, true, "and one it deleted is not")
        expect(h.editor.shapeContext.reading?.shape(inFile: box) == nil, "committed: the box went")
    },
    test("a shape is changed in a reading that added it, changed it, deleted it or never had it, and not in one that only read or moved it") {
        let h = try EditorHarness(plugins: [FixturesPlugin()])
        let still = h.add(Box(CGRect(x: 0, y: 0, width: 10, height: 10)))
        let moved = h.add(Box(CGRect(x: 0, y: 50, width: 10, height: 10)))
        let changed = h.add(Box(CGRect(x: 0, y: 100, width: 10, height: 10)))
        let deleted = h.add(Box(CGRect(x: 0, y: 150, width: 10, height: 10)))
        let never = ShapeID()
        let committed = try require(h.editor.shapeContext.reading)
        expectEqual([still, moved, changed, deleted, never].map(committed.isChanged), [false, false, false, false, false],
                    "the committed file is as the editor keeps it, whatever it lacks")
        var seen: [Bool] = []
        var added = ShapeID()
        h.editor.transact { transaction in
            added = transaction.insert(Box(CGRect(x: 0, y: 200, width: 10, height: 10)))
            transaction.moveBox(moved, to: CGPoint(x: 5, y: 50))
            transaction.update(changed, as: Box.self) { $0.frame.size.width = 20 }
            transaction.delete([deleted])
            if let reading = transaction.shapes.reading { seen = [still, moved, changed, deleted, added, never].map(reading.isChanged) }
        }
        expectEqual(seen, [false, false, true, true, true, true], "read, moved, changed, deleted, inserted, never there")
    },
    test("a reading's log has the writes that are not moves, in order, as many as the set says, and a reading taken later begins with an earlier one's") {
        let h = try EditorHarness(plugins: [FixturesPlugin()])
        let still = h.add(Box(CGRect(x: 0, y: 0, width: 10, height: 10)))
        let moved = h.add(Box(CGRect(x: 0, y: 50, width: 10, height: 10)))
        let changed = h.add(Box(CGRect(x: 0, y: 100, width: 10, height: 10)))
        let deleted = h.add(Box(CGRect(x: 0, y: 150, width: 10, height: 10)))
        let committed = try require(h.editor.shapeContext.reading)
        expectEqual(committed.changes, [], "the editor's reading has written nothing")
        expectEqual(committed.writeCount, 0)
        expectEqual(committed.runID, 0, "and belongs to no run")
        var early: (log: [ShapeID], count: Int, run: Int)?
        var late: (log: [ShapeID], count: Int, run: Int)?
        var added = ShapeID()
        var laid: (log: [ShapeID], run: Int)?
        let fresh = AnyShapeRecord(ShapeRecord(id: ShapeID(), Box(CGRect(x: 0, y: 300, width: 10, height: 10))))
        h.editor.transact { transaction in
            transaction.moveBox(moved, to: CGPoint(x: 5, y: 50))
            let first = transaction.shapes.reading
            early = first.map { ($0.changes, $0.writeCount, $0.runID) }
            added = transaction.insert(Box(CGRect(x: 0, y: 200, width: 10, height: 10)))
            transaction.update(changed, as: Box.self) { $0.frame.size.width = 20 }
            transaction.moveBox(changed, to: CGPoint(x: 5, y: 100))
            transaction.update(changed, as: Box.self) { $0.frame.size.width = 30 }
            transaction.delete([deleted])
            let second = transaction.shapes.reading
            late = second.map { ($0.changes, $0.writeCount, $0.runID) }
            laid = transaction.shapes.layingOut(with: [fresh]).reading.map { ($0.changes, $0.runID) }
        }
        expectEqual(early?.log, [], "a move is no write")
        expectEqual(early?.count, 0)
        expectEqual(late?.log, [added, changed, changed, changed, deleted], "the insert, the change, a move of the changed shape (it is changed already, so it is one), the change again, the delete; the move of another shape is in none")
        expectEqual(late?.count, late?.log.count, "writeCount is the log's count")
        expect(still != added && late?.log.contains(still) == false && late?.log.contains(moved) == false, "a shape only read or moved is in no entry")
        expectEqual(early?.run, late?.run, "two readings of one transaction are of one run")
        expect(early?.run != 0, "which is not the editor's")
        expect(laid?.log.prefix(late?.log.count ?? 0).elementsEqual(late?.log ?? []) == true && laid?.log.last == fresh.id,
               "a reading that lays a record in has the log of the reader it lays over, then the record")
        expect(laid?.run != late?.run, "and is a run of its own")
        var next: Int?
        h.editor.transact { transaction in next = transaction.shapes.reading?.runID }
        expect(next != nil && next != late?.run, "the next transaction is another run")
    },
    test("a context laying out with records reads them as changed, and one it removes as changed too") {
        let h = try EditorHarness(plugins: [FixturesPlugin()])
        let onBoard = h.add(Box(CGRect(x: 0, y: 0, width: 10, height: 10)))
        let gone = h.add(Box(CGRect(x: 0, y: 50, width: 10, height: 10)))
        let restated = AnyShapeRecord(ShapeRecord(id: onBoard, Box(CGRect(x: 0, y: 0, width: 30, height: 10))))
        let fresh = AnyShapeRecord(ShapeRecord(id: ShapeID(), Box(CGRect(x: 0, y: 90, width: 10, height: 10))))
        let reading = try require(h.editor.shapeContext.layingOut(with: [restated, fresh], removing: [gone]).reading)
        expect(!reading.isCommitted, "a run's reading isn't the committed file")
        expect(reading.isChanged(onBoard) && reading.isChanged(fresh.id) && reading.isChanged(gone), "restated, laid in, removed")
        expectEqual(reading.shape(inFile: onBoard)?.box?.width, 30, "the record laid in, not the file's")
        expect(reading.shape(inFile: gone) == nil, "removed is not there")
    },
    test("a shape changed on another board, and one deleted there, are in the log and changed in the reading of the transaction that did it") {
        let p = ShapeID(), far = ShapeID(), gone = ShapeID(), here = ShapeID()
        func box(_ id: ShapeID, x: CGFloat = 0) -> AnyShapeRecord { AnyShapeRecord(ShapeRecord(id: id, Box(CGRect(x: x, y: 0, width: 40, height: 30)))) }
        let file = CanvasFile(root: CanvasDocument(shapes: [box(here), AnyShapeRecord(ShapeRecord(id: p, Pocket(CGRect(x: 0, y: 200, width: 100, height: 100))))]),
                              children: [p: CanvasDocument(shapes: [box(far), box(gone, x: 100)])])
        let h = try EditorHarness(plugins: [FixturesPlugin(), PocketsPlugin()], file: file)
        let board = BoardID(owner: p)
        var log: [ShapeID] = []
        var changed: [Bool] = []
        var read: (width: CGFloat?, gone: Bool)?
        h.editor.transact("Write") { tx in
            tx.update(far, on: board, as: Box.self) { $0.props.frame.size.width = 77 }
            tx.delete([gone], on: board)
            guard let reading = tx.shapes.reading else { return }
            log = reading.changes
            changed = [far, gone].map(reading.isChanged)
            read = (reading.shape(inFile: far)?.box?.width, reading.shape(inFile: gone) == nil)
        }
        expectEqual(read?.width, 77, "the reading has the far shape as the transaction left it")
        expectEqual(read?.gone, true, "and the deleted one gone")
        expectEqual(changed, [true, true], "isChanged: the far shape changed other than by moving it, and the one deleted")
        expect(log.contains(far), "the log has the shape changed on the other board: \(log.count) entries")
        expect(log.contains(gone), "the log has the shape deleted on the other board: \(log.count) entries")
    },
])
