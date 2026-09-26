@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import TestKit

/// What willDelete handlers saw. (Recorded, not asserted in the handler: a failed precondition
/// would take the whole test executable down, and hide every other result.)
final class DeleteLog {
    var calls: [Set<ShapeID>] = []
    var allPresent = true
}

struct Cleaner: CanvasPlugin {
    let log: DeleteLog
    var id: PluginID { "cleaner" }
    func register(into registrar: inout PluginRegistrar) {
        // Moves every tag off a shape that's being deleted, in the same transaction.
        registrar.willDelete { [log] ids, tx in
            log.calls.append(ids)
            log.allPresent = log.allPresent && ids.allSatisfy { tx.document[$0] != nil }
            for record in tx.document.shapes where record.kind == Tag.kind {
                tx.update(record.id, as: Tag.self) { if let t = $0.props.target, ids.contains(t) { $0.props.target = nil } }
            }
        }
    }
}

/// Deletes every tag whose target is being deleted, which deletes its dependents in turn.
struct Cascade: CanvasPlugin {
    let log: DeleteLog
    var id: PluginID { "cascade" }
    func register(into registrar: inout PluginRegistrar) {
        registrar.willDelete { [log] ids, tx in
            log.calls.append(ids)
            guard log.calls.count < 10 else { return }                 // a runaway cascade fails, not crashes
            let dependents = tx.document.shapes.filter { $0.typed(as: Tag.self)?.props.target.map(ids.contains) ?? false }
            tx.delete(Set(dependents.map(\.id)))
        }
    }
}

@MainActor let documentTests = Suite("Document", [
    test("a transaction commits once and bumps the revision only if something changed") {
        let h = try EditorHarness(plugins: [FixturesPlugin()])
        let box = h.add(Box(CGRect(x: 0, y: 0, width: 10, height: 10)))
        let revision = h.editor.revision
        h.editor.transact { $0.update(box, as: Box.self) { $0.frame.origin.x = 0 } }
        expectEqual(h.editor.revision, revision)
        h.editor.transact { tx in
            tx.update(box, as: Box.self) { $0.frame.origin.x = 5 }
            tx.update(box, as: Box.self) { $0.frame.origin.y = 5 }
        }
        expectEqual(h.editor.revision, revision + 1)
        expectEqual(h.editor.document[box]?.box, CGRect(x: 5, y: 5, width: 10, height: 10))
    },
    test("bringing the front shape to front changes nothing") {
        let h = try EditorHarness(plugins: [FixturesPlugin()])
        h.add(Box(.zero)); let top = h.add(Box(.zero))
        let revision = h.editor.revision
        h.editor.transact { $0.bringToFront(top) }
        expectEqual(h.editor.revision, revision)
    },
    test("willDelete handlers see the shapes and can change others in the same transaction") {
        let log = DeleteLog()
        let h = try EditorHarness(plugins: [FixturesPlugin(), Cleaner(log: log)])
        let box = h.add(Box(.zero))
        let tag = h.add(Tag(target: box))
        let revision = h.editor.revision
        h.editor.transact { $0.delete([box]) }
        expectEqual(log.calls, [[box]])
        expect(log.allPresent, "willDelete runs while the shapes still exist")
        expectEqual(h.editor.revision, revision + 1)
        expectEqual(h.editor.document[tag]?.typed(as: Tag.self)?.props.target, nil)
        expectEqual(h.editor.document[box], nil)
    },
    test("a willDelete cascade between two shapes that each depend on the other runs once per shape and removes both") {
        let log = DeleteLog()
        let h = try EditorHarness(plugins: [FixturesPlugin(), Cascade(log: log)])
        let first = ShapeID(), second = ShapeID()
        h.add(Tag(target: second), id: first)
        h.add(Tag(target: first), id: second)
        let bystander = h.add(Box(.zero))
        h.editor.transact { $0.delete([first]) }
        expectEqual(log.calls, [[first], [second]])
        expectEqual(h.editor.document.shapes.map(\.id), [bystander])
    },
    test("the document finds every shape, and its index, by id through inserts, bring-to-front and deletes") {
        let h = try EditorHarness(plugins: [FixturesPlugin()])
        let ids = (0..<6).map { i in h.add(Box(CGRect(x: CGFloat(i) * 10, y: 0, width: 5, height: 5))) }
        h.editor.transact { $0.bringToFront(ids[1]) }
        h.editor.transact { $0.delete([ids[0], ids[4]]) }
        let document = h.editor.document
        expectEqual(document.shapes.map(\.id), [ids[2], ids[3], ids[5], ids[1]])
        for (index, record) in document.shapes.enumerated() {
            expectEqual(document.index(of: record.id), index)
            expectEqual(document[record.id]?.id, record.id)
        }
        expectEqual(document[ids[0]], nil)
        expectEqual(document.index(of: ids[4]), nil)
    },
    test("records compare by props") {
        let id = ShapeID()
        expect(AnyShapeRecord(ShapeRecord(id: id, Box(.zero))) == AnyShapeRecord(ShapeRecord(id: id, Box(.zero))))
        expect(AnyShapeRecord(ShapeRecord(id: id, Box(.zero))) != AnyShapeRecord(ShapeRecord(id: id, Disc(.zero))))
    },
])
