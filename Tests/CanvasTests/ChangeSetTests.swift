@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import TestKit

/// Every change set the editor hands services.
@MainActor final class ChangeLog {
    var changes: [ChangeSet] = []
}

final class ChangeRecorder {
    let log: ChangeLog
    init(log: ChangeLog) { self.log = log }
}

extension ChangeRecorder: EditorService {
    func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) { log.changes.append(changes) }
}

@MainActor func recordingChanges(_ log: ChangeLog) -> Contributor {
    Contributor(id: "changes") { r in r.service { _ in ChangeRecorder(log: log) } }
}

@MainActor let changeSetTests = Suite("Change sets", [
    test("each commit names the shapes it added, changed and removed, and whether the stack changed") {
        let log = ChangeLog()
        let h = try EditorHarness(plugins: [FixturesPlugin(), recordingChanges(log)])
        let a = ShapeRecord(Box(CGRect(x: 0, y: 0, width: 10, height: 10))), b = ShapeRecord(Box(.zero))
        h.editor.transact { $0.insert(a); $0.insert(b) }
        h.editor.transact { $0.update(a.id, as: Box.self) { $0.frame.origin.x = 5 } }
        h.editor.transact { $0.bringToFront(a.id) }
        h.editor.transact { $0.delete([b.id]) }
        expectEqual(log.changes.map(\.added), [[a.id, b.id], [], [], []])
        expectEqual(log.changes.map(\.changed), [[], [a.id], [a.id], []])
        expectEqual(log.changes.map(\.removed), [[], [], [], [b.id]])
        expectEqual(log.changes.map(\.reordered), [true, false, true, true])
    },
    test("in one transaction, a shape added stays added however it changes, and one added and deleted isn't named") {
        let log = ChangeLog()
        let h = try EditorHarness(plugins: [FixturesPlugin(), recordingChanges(log)])
        let a = h.add(Box(.zero))
        let b = ShapeRecord(Box(.zero)), c = ShapeRecord(Box(.zero))
        h.editor.transact { tx in
            tx.insert(b)
            tx.update(b.id, as: Box.self) { $0.frame.size.width = 5 }
            tx.bringToFront(a)
            tx.insert(c)
            tx.delete([c.id])
        }
        expectEqual(log.changes.last?.added, [b.id])
        expectEqual(log.changes.last?.changed, [a])
        expectEqual(log.changes.last?.removed, [])
        h.editor.transact { tx in
            tx.update(a, as: Box.self) { $0.frame.size.width = 5 }
            tx.delete([a])
        }
        expectEqual(log.changes.last?.changed, [], "a shape changed and then removed is only removed")
        expectEqual(log.changes.last?.removed, [a])
    },
    test("replacing the document names what differs from the one it replaces") {
        let log = ChangeLog()
        let h = try EditorHarness(plugins: [FixturesPlugin(), recordingChanges(log)])
        let a = h.add(Box(.zero)), b = h.add(Box(.zero)), c = h.add(Box(.zero))
        let before = h.editor.document
        let d = ShapeRecord(Box(.zero))
        h.editor.transact { tx in
            tx.update(b, as: Box.self) { $0.frame.origin.x = 20 }
            tx.delete([c])
            tx.insert(d)
        }
        let after = h.editor.document
        h.editor.replaceDocument(with: before)
        h.editor.replaceDocument(with: after)
        expectEqual(log.changes.last?.added, [d.id])
        expectEqual(log.changes.last?.changed, [b])
        expectEqual(log.changes.last?.removed, [c])
        expectEqual(log.changes.last?.reordered, true)
        expectEqual(log.changes.last?.shapeIDs.contains(a), false)
    },
])
