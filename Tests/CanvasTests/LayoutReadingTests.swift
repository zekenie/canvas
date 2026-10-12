import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import TestKit

// The file as a context reads it (`ShapeContext.reading`), what in it is changed (`isChanged`) and the
// shapes a context may read beyond its file (`layingOut(with:alsoReading:)`).

@MainActor let layoutReadingTests = Suite("Layout reading", [
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
    test("a context also reading beyond its file reads that only where the records and the file have none, and never for one removed") {
        let h = try EditorHarness(plugins: [FixturesPlugin()])
        let onBoard = h.add(Box(CGRect(x: 0, y: 0, width: 10, height: 10)))
        let gone = h.add(Box(CGRect(x: 0, y: 50, width: 10, height: 10)))
        let laid = AnyShapeRecord(ShapeRecord(id: ShapeID(), Box(CGRect(x: 0, y: 90, width: 10, height: 10))))
        var asked: [ShapeID] = []
        let beyond: @MainActor (ShapeID) -> AnyShapeRecord? = { id in
            asked.append(id)
            // Every id is answered, so the test sees which ones are asked for at all.
            return AnyShapeRecord(ShapeRecord(id: id, Box(CGRect(x: 0, y: 130, width: 40, height: 10))))
        }
        let reading = try require(h.editor.shapeContext.layingOut(with: [laid], removing: [gone], alsoReading: beyond).reading)
        expectEqual(reading.shape(inFile: onBoard)?.box?.width, 10, "the file's own, not beyond's")
        expectEqual(reading.shape(inFile: laid.id)?.box?.width, 10, "a record laid in, not beyond's")
        expect(reading.shape(inFile: gone) == nil, "removed: nothing beyond either")
        expectEqual(asked, [], "none of those asked beyond")
        let other = ShapeID()
        expectEqual(reading.shape(inFile: other)?.box?.width, 40, "an id nobody has is read beyond")
        expect(reading.isChanged(other), "and is changed: it isn't the editor's")
        expect(!reading.isChanged(onBoard), "a shape of the file the run doesn't change is as the editor keeps it")
    },
])
