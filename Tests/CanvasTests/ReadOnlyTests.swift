@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import TestKit

// Read-only shapes (`registrar.readOnlyShapes`), with CanvasTesting's `Frozen` flag standing in for
// Locking's lock. The core has no Selection here, so tests start drags and edits themselves.

@MainActor let readOnlyTests = Suite("Read-only shapes", [
    test("a transaction doesn't change, restack, move or delete a read-only shape, and the rest of it stands") {
        let log = RefusalLog()
        let h = try EditorHarness(plugins: [FixturesPlugin(), FreezingPlugin(log: log)])
        let frozen = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let free = h.add(Box(CGRect(x: 200, y: 0, width: 100, height: 100)))
        h.editor.freeze([frozen])
        expect(h.editor.isReadOnly(frozen))
        expect(!h.editor.isReadOnly(free))
        let before = try require(h.editor.document[frozen])
        h.editor.transact { tx in
            tx.update(frozen) { $0.box = CGRect(x: 10, y: 10, width: 50, height: 50) }
            tx.update(free) { $0.box = CGRect(x: 210, y: 0, width: 100, height: 100) }
            tx.bringToFront(frozen)
            tx.translate([frozen, free], by: CGPoint(x: 5, y: 5))
            tx.delete([frozen])
        }
        expectEqual(h.editor.document[frozen], before)
        expectEqual(h.editor.document.shapes.map(\.id), [frozen, free], "not restacked")
        expectEqual(h.editor.document[free]?.box, CGRect(x: 215, y: 5, width: 100, height: 100), "the rest of it stands")
        expectEqual(log.refusals, [[frozen]], "once, when it's done")
    },
    test("a transaction that changes nothing read-only refuses nothing, and says nothing") {
        let log = RefusalLog()
        let h = try EditorHarness(plugins: [FixturesPlugin(), FreezingPlugin(log: log)])
        let frozen = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let free = h.add(Box(CGRect(x: 200, y: 0, width: 100, height: 100)))
        h.editor.freeze([frozen])
        h.editor.transact { tx in
            tx.update(frozen) { _ in }                          // no change: no try
            tx.bringToFront(free)                               // already in front
            tx.update(free) { $0.box = CGRect(x: 0, y: 200, width: 10, height: 10) }
        }
        h.editor.freeze([frozen])                               // already frozen
        expectEqual(log.refusals, [])
    },
    test("the change that leaves a shape no longer read-only goes through, with whatever else it changes; one that makes it read-only too") {
        let log = RefusalLog()
        let h = try EditorHarness(plugins: [FixturesPlugin(), FreezingPlugin(log: log)])
        let box = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        h.editor.transact { tx in
            tx.update(box) { $0.box = CGRect(x: 0, y: 0, width: 80, height: 80) }
            tx.update(box) { $0[Frozen.self] = true }
            tx.update(box) { $0.box = CGRect(x: 0, y: 0, width: 60, height: 60) }   // frozen by now
        }
        expectEqual(h.editor.document[box]?.box, CGRect(x: 0, y: 0, width: 80, height: 80))
        expectEqual(log.refusals, [[box]])
        h.editor.transact { tx in
            tx.update(box) {
                $0[Frozen.self] = nil
                $0.box = CGRect(x: 40, y: 40, width: 80, height: 80)
            }
        }
        expect(!h.editor.isReadOnly(box))
        expectEqual(h.editor.document[box]?.box, CGRect(x: 40, y: 40, width: 80, height: 80))
        expectEqual(log.refusals, [[box]], "nothing more refused")
    },
    test("a shape put in by the transaction changes as usual in it, read-only or not: from the next one on, it's refused") {
        let log = RefusalLog()
        let h = try EditorHarness(plugins: [FixturesPlugin(), FreezingPlugin(log: log)])
        var record = AnyShapeRecord(ShapeRecord(Box(CGRect(x: 0, y: 0, width: 100, height: 100))))
        record[Frozen.self] = true
        h.editor.transact { tx in
            tx.insert(record)                                   // a paste of a frozen shape, say
            tx.translate([record.id], by: CGPoint(x: 30, y: 0))
        }
        expectEqual(h.editor.document[record.id]?.box?.origin, CGPoint(x: 30, y: 0))
        expectEqual(log.refusals, [])
        h.editor.transact { $0.translate([record.id], by: CGPoint(x: 30, y: 0)) }
        expectEqual(h.editor.document[record.id]?.box?.origin, CGPoint(x: 30, y: 0))
        expectEqual(log.refusals, [[record.id]])
    },
    test("a read-only shape still lets go of a shape it names as that one is deleted, which isn't a try to change it") {
        let log = RefusalLog()
        let h = try EditorHarness(plugins: [FixturesPlugin(), FreezingPlugin(log: log)])
        let box = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let tag = h.add(Tag(target: box))
        h.editor.freeze([tag])
        h.editor.transact { $0.delete([box]) }
        expectEqual(h.editor.document[tag]?.typed(as: Tag.self)?.props.target, nil, "it doesn't go on naming a shape that's gone")
        expect(h.editor.isReadOnly(tag))
        expectEqual(log.refusals, [])
    },
    test("what a deletion's handlers do goes through read-only shapes: a read-only dependent goes with the shape it depends on") {
        let log = RefusalLog()
        // Deletes every tag on a shape that's deleted: a dependent, as a container's contents would be.
        let dependents = Contributor(id: "dependents") { r in
            r.willDelete { ids, tx in
                let tags = tx.document.shapes.compactMap { record -> ShapeID? in
                    guard let target = record.typed(as: Tag.self)?.props.target, ids.contains(target) else { return nil }
                    return record.id
                }
                tx.delete(Set(tags))
            }
        }
        let h = try EditorHarness(plugins: [FixturesPlugin(), FreezingPlugin(log: log), dependents])
        let box = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let tag = h.add(Tag(target: box))
        h.editor.freeze([tag])
        h.editor.transact { $0.delete([tag]) }
        expect(h.editor.document[tag] != nil, "asked for itself, it stays")
        expectEqual(log.refusals, [[tag]])
        h.editor.transact { $0.delete([box]) }
        expectEqual(h.editor.document.shapes, [], "with the shape it depends on, it goes")
        expectEqual(log.refusals, [[tag]], "and that's no try to delete it")
    },
    test("a read-only editable shape isn't edited, and services hear the try; one that becomes read-only while it's edited stops") {
        let log = RefusalLog()
        let h = try EditorHarness(plugins: [CardsPlugin(), FreezingPlugin(log: log)])
        let card = h.add(Card(CGRect(x: 0, y: 0, width: 100, height: 60)))
        let other = h.add(Card(CGRect(x: 200, y: 0, width: 100, height: 60)))
        h.editor.freeze([card])
        expect(!h.editor.beginEditing(card))
        expectEqual(h.editor.editingShapeID, nil)
        expectEqual(log.refusals, [[card]])
        expect(h.editor.beginEditing(other))
        h.editor.freeze([other])
        expectEqual(h.editor.editingShapeID, nil)
        expectEqual(log.refusals, [[card]], "freezing it isn't a refusal")
    },
    test("a drag leaves read-only shapes where they are and moves the rest; services hear it once the pointer is past the drag threshold, once") {
        let log = RefusalLog()
        let h = try EditorHarness(plugins: [FixturesPlugin(), FreezingPlugin(log: log)])
        let frozen = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let free = h.add(Box(CGRect(x: 200, y: 0, width: 100, height: 100)))
        h.editor.freeze([frozen])
        h.move(to: CGPoint(x: 50, y: 50))
        h.editor.session = TranslatingSession(ids: [frozen, free], from: CGPoint(x: 50, y: 50), in: h.editor)
        h.drag(to: CGPoint(x: 53, y: 50))                      // 3 points: a click's jitter
        expectEqual(log.refusals, [])
        expectEqual(h.editor.document[free]?.box?.origin, CGPoint(x: 203, y: 0), "the rest follow from the start")
        h.drag(to: CGPoint(x: 80, y: 70))
        h.drag(to: CGPoint(x: 90, y: 90))
        expectEqual(h.editor.document[frozen]?.box?.origin, .zero)
        expectEqual(h.editor.document[free]?.box?.origin, CGPoint(x: 240, y: 40))
        expectEqual(log.refusals, [[frozen]])
        h.escape()
        expectEqual(h.editor.document[free]?.box?.origin, CGPoint(x: 200, y: 0))
        expectEqual(log.refusals, [[frozen]], "putting the rest back isn't a try")
    },
    test("without a rule nothing is read-only, and the report says who has one") {
        let h = try EditorHarness(plugins: [FixturesPlugin()])
        let box = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        expect(!h.editor.isReadOnly(box))
        expect(!h.editor.isReadOnly(ShapeID()))
        let report = try Registry(plugins: [FixturesPlugin(), FreezingPlugin()]).report
        expect(report.contains("freezing      property frozen · property frozen → every shape · read-only shapes · service RefusalListener"), report)
    },
])

@MainActor let drawingOffsetTests = Suite("Drawing offsets", [
    test("a shape drawn away from where it is: its render and outline move, and nothing else does") {
        let box = Box(CGRect(x: 100, y: 100, width: 100, height: 100))
        let id = ShapeID()
        let h = try EditorHarness(plugins: [FixturesPlugin(), Contributor(id: "outline") { $0.outlines { _ in Outlines(shapes: [id]) } }])
        h.add(box, id: id)
        let still = renderBitmap(h.editor, size: CGSize(width: 300, height: 300))
        h.editor.setDrawingOffset(CGPoint(x: 30, y: 0), for: id)
        expectEqual(h.editor.drawingOffset(of: id), CGPoint(x: 30, y: 0))
        let moved = renderBitmap(h.editor, size: CGSize(width: 300, height: 300))
        expect(changedPixels(still, moved, in: CGRect(x: 90, y: 110, width: 30, height: 80)) > 1000, "its left side is empty")
        expect(changedPixels(still, moved, in: CGRect(x: 205, y: 110, width: 20, height: 80)) > 1000, "and it's past its right side")
        expectEqual(pixel(moved, at: CGPoint(x: 229, y: 150)), pixel(still, at: CGPoint(x: 199, y: 150)), "its outline too")
        expectEqual(h.editor.shape(at: CGPoint(x: 110, y: 150)), id, "hit where it is")
        expectEqual(h.editor.shape(at: CGPoint(x: 220, y: 150)), nil)
        expectEqual(h.editor.document[id]?.box, box.frame, "unchanged")
        h.editor.setDrawingOffset(.zero, for: id)
        expectEqual(changedPixels(still, renderBitmap(h.editor, size: CGSize(width: 300, height: 300)), in: CGRect(x: 0, y: 0, width: 300, height: 300)), 0)
    },
    test("an offset is in view points, whatever the zoom, and goes with its shape") {
        let h = try EditorHarness(plugins: [FixturesPlugin()])
        let id = h.add(Box(CGRect(x: 50, y: 50, width: 50, height: 50)))
        h.editor.camera = Camera(origin: .zero, zoom: 2)       // the box from (100, 100) to (200, 200) on screen
        let still = renderBitmap(h.editor, size: CGSize(width: 300, height: 300))
        h.editor.setDrawingOffset(CGPoint(x: 30, y: 0), for: id)
        let moved = renderBitmap(h.editor, size: CGSize(width: 300, height: 300))
        let fill = pixel(still, at: CGPoint(x: 150, y: 150))
        expectEqual(pixel(moved, at: CGPoint(x: 228, y: 150)), fill, "from 130 to 230 on screen: 30 points, not 60")
        expect(pixel(moved, at: CGPoint(x: 233, y: 150)) != fill)
        expect(pixel(moved, at: CGPoint(x: 110, y: 150)) != fill)
        h.editor.transact { $0.delete([id]) }
        expectEqual(h.editor.drawingOffset(of: id), .zero)
        h.editor.setDrawingOffset(CGPoint(x: 30, y: 0), for: id)
        expectEqual(h.editor.drawingOffset(of: id), .zero, "a shape that isn't there has none")
    },
])
