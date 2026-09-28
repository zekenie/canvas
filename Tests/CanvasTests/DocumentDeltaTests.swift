@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import TestKit

/// Every commit of an editor, collected into a `DocumentDelta.Builder` as undo collects a step.
@MainActor final class DeltaRecorder {
    var builder = DocumentDelta.Builder()
    var last: CanvasFile
    init(editor: CanvasEditor) { last = editor.file }
}

extension DeltaRecorder: EditorService {
    func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) {
        builder.willCommit(changes, from: last)
        last = editor.file
    }
}

@MainActor func recordingDeltas() -> Contributor {
    Contributor(id: "deltas") { r in r.service { DeltaRecorder(editor: $0) } }
}

/// What `body` did to the editor's document, as one delta, and the document before it.
@MainActor func step(_ editor: CanvasEditor, _ body: () -> Void) throws -> (before: CanvasDocument, delta: DocumentDelta) {
    let recorder = try require(editor.service(DeltaRecorder.self))
    recorder.builder = DocumentDelta.Builder(board: editor.board)
    recorder.last = editor.file
    let before = editor.document
    body()
    return (before, recorder.builder.delta(now: editor.file))
}

/// The delta takes `before` to the editor's document, and its inverse takes that back to `before`,
/// record for record (keys, meta, added and kept values, opaque records) and byte for byte.
@MainActor func expectRoundTrip(_ editor: CanvasEditor, from before: CanvasDocument, by delta: DocumentDelta,
                                file: StaticString = #fileID, line: UInt = #line) throws {
    let after = editor.document
    var document = after
    document.apply(delta.inverted)
    expectEqual(document, before, "undone", file: file, line: line)
    expectEqual(document.shapes.map(\.stackingKey), before.shapes.map(\.stackingKey), file: file, line: line)
    let codec = BoardCodec(registry: editor.registry)
    expectEqual(try codec.encode(document), try codec.encode(before), "undone, as a board", file: file, line: line)
    document.apply(delta)
    expectEqual(document, after, "redone", file: file, line: line)
    expectEqual(try codec.encode(document), try codec.encode(after), "redone, as a board", file: file, line: line)
}

private func uuid(_ n: Int) -> ShapeID { ShapeID(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!) }

/// Boxes with metadata (a member no plugin knows included), added values and a kept one, a shape
/// kept aside (its kind isn't installed), and a tag that names a box.
@MainActor func mixedBoard(registry: Registry) throws -> CanvasDocument {
    func box(_ n: Int, _ index: String, _ extra: String = "") -> String {
        #"{ "id" : "\#(uuid(n))", "kind" : "box", "index" : "\#(index)", "props" : { "frame" : [[\#(n * 20), 0], [10, 10]] }\#(extra) }"#
    }
    let shapes = [
        box(1, "a0", #", "meta" : { "someone" : { "else" : [1, 2] } }, "added" : { "stars" : 2, "confetti" : true }"#),
        #"{ "id" : "\#(uuid(2))", "kind" : "gadget", "index" : "a1", "v" : 4, "props" : { "gears" : [1, 2.5] } }"#,
        box(3, "a2", #", "added" : { "sticker" : "gold" }"#),
        #"{ "id" : "\#(uuid(4))", "kind" : "tag", "index" : "a3", "props" : { "target" : "\#(uuid(3))" } }"#,
        box(5, "a4"),
        box(6, "a5", #", "meta" : { "x" : 1 }"#),
    ]
    let json = #"{ "format" : 3, "versions" : { "kinds" : { "box" : 0, "tag" : 0 }, "added" : { "stars" : 0, "sticker" : 0 } }, "shapes" : [\#(shapes.joined(separator: ", "))] }"#
    let loaded = try BoardCodec(registry: registry).decode(Data(json.utf8))
    expect(loaded.document[uuid(2)]?.isOpaque == true)
    expectEqual(loaded.document[uuid(1)]?.keptProperties, ["confetti"])
    return loaded.document
}

@MainActor private func mixedHarness(_ more: [any CanvasPlugin] = []) throws -> EditorHarness {
    let registry = try Registry(plugins: [FixturesPlugin(), ratings(), recordingDeltas()] + more)
    let document = try mixedBoard(registry: registry)
    return EditorHarness { CanvasEditor(registry: registry, document: document, scheduler: $0, stackingKeys: .sequential) }
}

@MainActor let documentDeltaTests = Suite("Document deltas", [
    test("a builder keeps each shape's first record before and its last after, and leaves out what ends where it began") {
        let h = try EditorHarness(plugins: [FixturesPlugin(), recordingDeltas()])
        let a = h.add(Box(.zero)), b = h.add(Box(.zero)), c = h.add(Box(.zero))
        let original = try require(h.editor.document[c])
        let added = ShapeRecord(Box(CGRect(x: 1, y: 1, width: 1, height: 1))), gone = ShapeRecord(Box(.zero))
        let (before, delta) = try step(h.editor) {
            h.editor.transact { $0.insert(added) }
            h.editor.transact { $0.update(added.id, as: Box.self) { $0.frame.origin.x = 9 } }       // added, then changed: added
            h.editor.transact { $0.insert(gone) }
            h.editor.transact { $0.delete([gone.id]) }                                                 // added, then removed: nothing
            h.editor.transact { $0.update(a, as: Box.self) { $0.frame.origin.x = 5 } }
            h.editor.transact { $0.update(a, as: Box.self) { $0.frame.origin.x = 0 } }               // changed back: nothing
            h.editor.transact { $0.update(c, as: Box.self) { $0.frame.origin.x = 5 } }
            h.editor.transact { $0.delete([c]) }                                                       // changed, then removed
            h.editor.transact { $0.bringToFront(b) }
        }
        expectEqual(delta.shapeIDs, [added.id, c, b])
        expectEqual(delta.changes[added.id]?.before, nil)
        expectEqual(delta.changes[added.id]?.after, h.editor.document[added.id])
        expectEqual(delta.changes[c]?.before, original, "removed from what it first was")
        expectEqual(delta.changes[c]?.after, nil)
        expect(delta.changes[b]?.before?.stackingKey != delta.changes[b]?.after?.stackingKey)
        try expectRoundTrip(h.editor, from: before, by: delta)
        let (_, nothing) = try step(h.editor) {
            h.editor.transact { $0.update(a, as: Box.self) { $0.frame.origin.x = 5 } }
            h.editor.transact { $0.update(a, as: Box.self) { $0.frame.origin.x = 0 } }
        }
        expect(nothing.isEmpty)
    },
    test("a step that takes a shape with boards under it holds them whole, and puts the file back and forth with them") {
        let a = ShapeID(), p = ShapeID(), b = ShapeID(), q = ShapeID(), c = ShapeID()
        let unit = CGRect(x: 0, y: 0, width: 10, height: 10)
        func box(_ id: ShapeID) -> AnyShapeRecord { AnyShapeRecord(ShapeRecord(id: id, Box(unit))) }
        func pocket(_ id: ShapeID) -> AnyShapeRecord { AnyShapeRecord(ShapeRecord(id: id, Pocket(unit))) }
        let h = try EditorHarness(plugins: [FixturesPlugin(), PocketsPlugin(), recordingDeltas()],
                                  file: CanvasFile(root: CanvasDocument(shapes: [box(a), pocket(p)]),
                                                   children: [p: CanvasDocument(shapes: [box(b), pocket(q)]),
                                                              q: CanvasDocument(shapes: [box(c)])]))
        let before = h.file
        let (_, delta) = try step(h.editor) { h.editor.transact { $0.delete([p]) } }
        let after = h.file
        expectEqual(after.children, [:])
        expectEqual(delta.shapeIDs, [p])
        expectEqual(Set(delta.boards.keys), [BoardID(owner: p), BoardID(owner: q)])
        var file = after
        file.apply(delta.inverted)
        expectEqual(file, before, "every board back, every id")
        expectEqual(file.board(containing: c), BoardID(owner: q))
        file.apply(delta)
        expectEqual(file, after)
    },
    test("inverting twice is the delta itself, and a change whose records are equal isn't one") {
        let a = AnyShapeRecord(ShapeRecord(Box(.zero))), b = AnyShapeRecord(ShapeRecord(Box(CGRect(x: 1, y: 1, width: 1, height: 1))))
        let delta = DocumentDelta([a.id: .init(before: nil, after: a), b.id: .init(before: b, after: nil)])
        expectEqual(delta.inverted.inverted, delta)
        expectEqual(delta.inverted.changes[a.id]?.before, a)
        expect(DocumentDelta([a.id: .init(before: a, after: a)]).isEmpty)
    },
    test("undone and redone, a step restores every record exactly: ids, kinds, props, keys, meta, added and kept values, opaque records") {
        let h = try mixedHarness()
        let (before, delta) = try step(h.editor) {
            h.editor.transact { tx in
                tx.update(uuid(1)) { $0.meta = ShapeMeta(json: ["mine": 1]); $0[Stars.self] = 4 }
                tx.translate([uuid(1), uuid(5)], by: CGPoint(x: 3, y: 4))
                tx.delete([uuid(2), uuid(3)])                                // the opaque shape, and the box the tag names
                tx.insert(ShapeRecord(Box(CGRect(x: 0, y: 0, width: 2, height: 2))))
                tx.sendToBack(uuid(6))
            }
        }
        expectEqual(h.editor.document[uuid(4)]?.typed(as: Tag.self)?.props.target, nil, "the tag let go")
        expectEqual(delta.shapeIDs.count, 7)
        try expectRoundTrip(h.editor, from: before, by: delta)
    },
    test("a delta that keeps every shape and its key replaces records in place, as the merge would") {
        let h = try mixedHarness()
        let (before, moved) = try step(h.editor) {
            h.editor.transact { $0.translate([uuid(1), uuid(3), uuid(6)], by: CGPoint(x: 1, y: 1)) }
        }
        let expected = CanvasDocument(shapes: before.shapes.map { moved.changes[$0.id]?.after ?? $0 })
        var inPlace = before
        inPlace.apply(moved)
        expectEqual(inPlace, expected)
        // With a shape added on top too, the stack is merged, and ends the same.
        var extra = AnyShapeRecord(ShapeRecord(Box(.zero)))
        extra.meta = ShapeMeta(json: ["n": 1])
        let record = try require(CanvasDocument(shapes: before.shapes + [extra]).shapes.last)
        expect(try require(record.stackingKey) > require(before.shapes.last?.stackingKey))
        var changes = moved.changes
        changes[record.id] = .init(before: nil, after: record)
        var merged = before
        merged.apply(DocumentDelta(changes))
        expectEqual(merged, CanvasDocument(shapes: expected.shapes + [record]))
    },
    test("the change set of a delta names what it adds, changes and removes, and a stack change only when keys change") {
        let h = try mixedHarness()
        let (_, edit) = try step(h.editor) { h.editor.transact { $0.update(uuid(3)) { $0[Stars.self] = 1 } } }
        let props = ChangeSet(edit)
        expectEqual(props.changed, [uuid(3)])
        expect(props.added.isEmpty && props.removed.isEmpty)
        expect(!props.reordered)
        let inserted = ShapeRecord(Box(.zero))
        let (_, mixed) = try step(h.editor) {
            h.editor.transact { tx in
                tx.insert(inserted)
                tx.delete([uuid(5)])
                tx.bringToFront(uuid(1))
            }
        }
        let changes = ChangeSet(mixed)
        expectEqual(changes.added, [inserted.id])
        expectEqual(changes.removed, [uuid(5)])
        expectEqual(changes.changed, [uuid(1)])
        expect(changes.reordered)
        expectEqual(ChangeSet(mixed.inverted).added, [uuid(5)])
        let (_, restacked) = try step(h.editor) { h.editor.transact { $0.sendToBack(uuid(6)) } }
        expect(ChangeSet(restacked).reordered)
    },
    test("undoing restores the order after bringing to front, sending to back, moving above and below, and deleting from the middle") {
        let h = try mixedHarness()
        let edits: [(String, @MainActor (inout Transaction) -> Void)] = [
            ("bring to front", { $0.bringToFront(uuid(1)) }),
            ("send to back", { $0.sendToBack(uuid(5)) }),
            ("move above", { $0.move(uuid(1), above: uuid(5)) }),
            ("move below", { $0.move(uuid(6), below: uuid(3)) }),
            ("delete from the middle", { $0.delete([uuid(3), uuid(5)]) }),
            ("all of them", { tx in
                tx.bringToFront(uuid(1)); tx.sendToBack(uuid(6)); tx.move(uuid(5), below: uuid(1)); tx.delete([uuid(3)])
            }),
        ]
        for (name, edit) in edits {
            let (before, delta) = try step(h.editor) { h.editor.transact { edit(&$0) } }
            expect(!delta.isEmpty, name)
            try expectRoundTrip(h.editor, from: before, by: delta)
            var back = h.editor.document
            back.apply(delta.inverted)
            h.editor.replaceDocument(with: back)                 // start the next from where this began
            expectEqual(h.editor.document.shapes.map(\.id), before.shapes.map(\.id), name)
        }
    },
])
