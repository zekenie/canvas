@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import Geometry
import TestKit

// Containers within a board (`ShapeContaining`), with CanvasTesting's corrals standing in for
// frames: what a shape is in, on disk and in the document, and what follows (moving, deleting,
// read-only, the stack). Settling and drops are in SettlingTests.swift.

private func id(_ n: Int) -> ShapeID { ShapeID(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!) }

private func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

@MainActor private func containerRegistry(_ more: [any CanvasPlugin] = []) throws -> Registry {
    try Registry(plugins: [FixturesPlugin(), CorralsPlugin(), PocketsPlugin()] + more)
}

@MainActor private func corralHarness(_ more: [any CanvasPlugin] = []) throws -> EditorHarness {
    try EditorHarness(plugins: [FixturesPlugin(), CorralsPlugin()] + more)
}

private func corral(_ n: Int, _ frame: CGRect, in container: Int? = nil) -> AnyShapeRecord {
    AnyShapeRecord(ShapeRecord(id: id(n), Corral(frame))).copy(as: id(n), container: container.map(id))
}

private func box(_ n: Int, _ frame: CGRect, in container: Int? = nil) -> AnyShapeRecord {
    AnyShapeRecord(ShapeRecord(id: id(n), Box(frame))).copy(as: id(n), container: container.map(id))
}

extension EditorHarness {
    /// The ids on the board, back to front.
    fileprivate var stack: [ShapeID] { editor.document.shapes.map(\.id) }
    fileprivate func contents(of container: ShapeID) -> [ShapeID] {
        editor.document.contents(of: container, containingKinds: editor.registry.containingKinds)
    }
    fileprivate func frame(of shape: ShapeID) -> CGRect? { editor.document[shape]?.box }
}

/// The index the document keeps as it changes is the one it would build from its shapes afresh.
@MainActor private func expectIndexWhole(_ document: CanvasDocument, kinds: Set<ShapeKind>, file: StaticString = #fileID, line: UInt = #line) {
    let fresh = CanvasDocument(shapes: document.shapes)
    for record in document.shapes {
        expectEqual(document.contents(of: record.id, containingKinds: kinds), fresh.contents(of: record.id, containingKinds: kinds),
                    "what \(record.id) holds", file: file, line: line)
    }
}

@MainActor let containersOnDiskTests = Suite("Containers on disk", [
    test("a shape in a container is written at format 5, its container beside its props, and reads back as it was") {
        let codec = BoardCodec(registry: try containerRegistry())
        let document = CanvasDocument(shapes: [corral(1, CGRect(x: 0, y: 0, width: 400, height: 300)),
                                               box(2, CGRect(x: 20, y: 20, width: 50, height: 50), in: 1)])
        let written = text(try codec.encode(document))
        expect(written.contains(#""format" : 5"#), written)
        expect(written.contains(#""container" : "00000000-0000-0000-0000-000000000001""#), written)
        let loaded = try codec.decode(Data(written.utf8))
        expectEqual(loaded.document, document)
        expect(loaded.report.isEmpty, "\(loaded.report)")
        expectEqual(loaded.document.contents(of: id(1), containingKinds: [Corral.kind]), [id(2)])
    },
    test("a file with no shape in a container is written in the format it always was, byte for byte") {
        let codec = BoardCodec(registry: try containerRegistry())
        let pocket = AnyShapeRecord(ShapeRecord(id: id(10), Pocket(CGRect(x: 0, y: 0, width: 40, height: 30))))
        let held = CanvasFile(root: CanvasDocument(shapes: [pocket, corral(1, CGRect(x: 0, y: 0, width: 400, height: 300))]),
                              children: [id(10): CanvasDocument(shapes: [corral(3, CGRect(x: 0, y: 0, width: 100, height: 100)),
                                                                         box(4, CGRect(x: 10, y: 10, width: 20, height: 20), in: 3)])])
        let loose = CanvasFile(root: held.root,
                               children: [id(10): CanvasDocument(shapes: [corral(3, CGRect(x: 0, y: 0, width: 100, height: 100)),
                                                                          box(4, CGRect(x: 10, y: 10, width: 20, height: 20))])])
        expect(text(try codec.encode(held)).contains(#""format" : 5"#), "a container on a board under the root needs 5")
        let plain = text(try codec.encode(loose))
        expect(plain.contains(#""format" : 4"#), plain)
        expect(!plain.contains("container"), plain)
        expectEqual(text(try codec.encode(CanvasFile(root: loose.root))), text(try codec.encode(loose.root)))
        expect(text(try codec.encode(loose.root)).contains(#""format" : 1"#))
        // The same shapes, taken out of their container in an editor, write the old bytes again.
        let h = try EditorHarness(plugins: [FixturesPlugin(), CorralsPlugin(), PocketsPlugin()], file: held)
        h.enter(id(10))
        h.editor.put([id(4)], in: nil)
        expectEqual(text(try codec.encode(h.editor.file)), plain)
    },
    test("reading keeps a container only on the shape's own board, breaks a loop, and keeps one that can't hold as written") {
        func record(_ n: Int, _ kind: String, _ index: String, container: String? = nil) -> String {
            let holder = container.map { #", "container" : "\#($0)""# } ?? ""
            return #"{ "id" : "\#(id(n))", "kind" : "\#(kind)", "index" : "\#(index)", "props" : { "frame" : [[0, 0], [10, 10]] }\#(holder) }"#
        }
        let shapes = [
            record(1, "corral", "a0"),
            record(2, "box", "a1", container: id(1).description),          // in corral 1
            record(3, "box", "a2", container: id(90).description),         // not on the board
            record(4, "box", "a3", container: id(5).description),          // 4 and 5 name each other
            record(5, "box", "a4", container: id(4).description),
            record(6, "box", "a5", container: id(6).description),          // itself
            record(7, "box", "a6", container: "not an id"),
            record(8, "gadget", "a7"),                                      // kept aside
            record(9, "box", "a8", container: id(8).description),          // in a container kept aside
            record(11, "pocket", "a9", container: id(1).description),
        ]
        let json = #"{ "format" : 5, "versions" : { "kinds" : { "box" : 0, "corral" : 0, "pocket" : 0 } }, "shapes" : [\#(shapes.joined(separator: ", "))], "#
            + #""boards" : { "\#(id(11))" : { "shapes" : [\#(record(12, "box", "a0", container: id(1).description))] } } }"#
        let loaded = try BoardCodec(registry: try containerRegistry()).decode(Data(json.utf8))
        let root = loaded.document
        expectEqual(root[id(2)]?.container, id(1))
        expectEqual(root[id(3)]?.container, nil)
        expectEqual(root[id(4)]?.container, nil, "the first of a loop in the stack is on the board directly")
        expectEqual(root[id(5)]?.container, id(4), "kept as written, though a box holds nothing")
        expectEqual(root[id(6)]?.container, nil)
        expectEqual(root[id(7)]?.container, nil)
        expectEqual(root[id(9)]?.container, id(8), "kept as written: its container is kept aside")
        expectEqual(root[id(11)]?.container, id(1))
        expectEqual(loaded.file[BoardID(owner: id(11))][id(12)]?.container, nil, "corral 1 isn't on that board")
        let kinds: Set<ShapeKind> = [Corral.kind]
        expectEqual(root.container(of: id(5), containingKinds: kinds), nil, "a box isn't a container")
        expectEqual(root.container(of: id(9), containingKinds: kinds), nil, "nor one kept aside")
        expectEqual(root.contents(of: id(1), containingKinds: kinds), [id(2), id(11)])
        expectEqual(loaded.report.repairs, [.droppedContainer(id(7)), .droppedContainer(id(3)), .droppedContainer(id(6)),
                                            .droppedContainer(id(4)), .droppedContainer(id(12))])
        // Saved, what's kept is written back as it was.
        let again = try BoardCodec(registry: try containerRegistry()).decode(try BoardCodec(registry: try containerRegistry()).encode(loaded.file))
        expectEqual(again.file, loaded.file)
        expect(again.report.repairs.isEmpty, "\(again.report)")
    },
    test("before format 5, a container member isn't read") {
        let json = #"{ "format" : 4, "versions" : { "kinds" : { "box" : 0, "corral" : 0 } }, "shapes" : ["#
            + #"{ "id" : "\#(id(1))", "kind" : "corral", "index" : "a0", "props" : { "frame" : [[0, 0], [100, 100]] } }, "#
            + #"{ "id" : "\#(id(2))", "kind" : "box", "index" : "a1", "container" : "\#(id(1))", "props" : { "frame" : [[0, 0], [10, 10]] } } ] }"#
        let loaded = try BoardCodec(registry: try containerRegistry()).decode(Data(json.utf8))
        expectEqual(loaded.document[id(2)]?.container, nil)
        expect(loaded.report.isEmpty, "\(loaded.report)")
    },
])

@MainActor let containerIndexTests = Suite("Containers in the document", [
    test("what a container holds, and what's under it, follow every change: joining, leaving, a deletion, undo and redo") {
        let h = try corralHarness()
        let kinds = h.editor.registry.containingKinds
        let outer = h.add(Corral(CGRect(x: 0, y: 0, width: 600, height: 400)))
        let inner = h.add(Corral(CGRect(x: 20, y: 20, width: 300, height: 200)))
        let a = h.add(Box(CGRect(x: 40, y: 40, width: 50, height: 50)))
        let b = h.add(Box(CGRect(x: 400, y: 40, width: 50, height: 50)))
        h.editor.put([inner, b], in: outer)
        h.editor.put([a], in: inner)
        let document = h.editor.document
        expectEqual(h.contents(of: outer), [inner, b])
        expectEqual(h.contents(of: inner), [a])
        expectEqual(document.descendants(of: outer, containingKinds: kinds), [inner, a, b])
        expectEqual(document.containers(of: a, containingKinds: kinds), [inner, outer])
        expect(document.hasContents(outer, containingKinds: kinds))
        expect(!document.hasContents(a, containingKinds: kinds), "a box holds nothing")
        expectEqual(h.editor.shapeContext.contents(of: inner), [a])
        expect(h.editor.shapeContext.hasContents(inner))
        expectEqual(h.editor.shapeContext.container(of: a), inner)
        expectEqual(h.editor.registry.container(of: document[b]!, in: document), outer)
        expectIndexWhole(h.editor.document, kinds: kinds)
        h.editor.undo()
        expectEqual(h.contents(of: inner), [])
        expect(!h.editor.document.hasContents(inner, containingKinds: kinds))
        h.editor.redo()
        expectEqual(h.contents(of: inner), [a])
        h.editor.transact { $0.delete([inner]) }
        expectEqual(h.editor.holder(of: a), outer, "let go into the container's own")
        expectEqual(h.contents(of: outer), [a, b])
        expectIndexWhole(h.editor.document, kinds: kinds)
        h.editor.undo()
        expectEqual(h.contents(of: inner), [a])
        expectEqual(h.contents(of: outer), [inner, b])
        expectEqual(h.editor.document, document)
        expectIndexWhole(h.editor.document, kinds: kinds)
    },
    test("a shape is in a container only as far as the core can use it: a box, in a container of a kind that holds") {
        let h = try corralHarness([PocketsPlugin()])
        let held = h.add(Corral(CGRect(x: 0, y: 0, width: 600, height: 400)))
        let pocket = h.add(Pocket(CGRect(x: 10, y: 10, width: 50, height: 50)))
        let note = h.add(Box(CGRect(x: 100, y: 10, width: 50, height: 50)))
        let tag = h.add(Tag(target: note))
        h.editor.put([note], in: pocket)
        expectEqual(h.editor.document[note]?.container, nil, "a pocket holds nothing on its board")
        h.editor.put([tag], in: held)
        expectEqual(h.editor.document[tag]?.container, nil, "only a box is in a container")
        h.editor.put([held], in: held)
        expectEqual(h.editor.document[held]?.container, nil, "nor in itself")
        h.editor.put([pocket], in: held)
        expectEqual(h.editor.holder(of: pocket), held, "a pocket is in one")
        let inner = h.add(Corral(CGRect(x: 200, y: 200, width: 100, height: 100)))
        h.editor.put([inner], in: held)
        h.editor.put([held], in: inner)
        expectEqual(h.editor.document[held]?.container, nil, "never in what it holds")
    },
    test("an insert takes the container a record comes with if it's a container on the board by then; a board going in, one below it there") {
        let log = RefusalLog()
        let h = try corralHarness([PocketsPlugin(), FreezingPlugin(log: log)])
        let held = h.add(Corral(CGRect(x: 0, y: 0, width: 600, height: 400)))
        let note = h.add(Box(CGRect(x: 0, y: 0, width: 10, height: 10)))
        let original = h.editor.document[note]!
        expectEqual(original.copy(as: ShapeID()).container, nil)
        let into = original.copy(as: ShapeID(), container: held)
        let intoBox = original.copy(as: ShapeID(), container: note)
        let intoNothing = original.copy(as: ShapeID(), container: ShapeID())
        h.editor.transact { tx in
            tx.insert(into)
            tx.insert(intoBox)
            tx.insert(intoNothing)
        }
        expectEqual(h.editor.holder(of: into.id), held)
        expectEqual(h.editor.document[intoBox.id]?.container, nil)
        expectEqual(h.editor.document[intoNothing.id]?.container, nil)
        expectEqual(h.contents(of: held), [into.id])
        // A container and what it holds, pasted together: the container first, as back to front has it.
        let copy = AnyShapeRecord(ShapeRecord(Corral(CGRect(x: 700, y: 0, width: 100, height: 100))))
        let member = original.copy(as: ShapeID(), container: copy.id)
        h.editor.transact { tx in
            tx.insert(copy)
            tx.insert(member)
        }
        expectEqual(h.editor.holder(of: member.id), copy.id)
        // A board going in with a pocket keeps a container below the shape on it.
        let pocket = AnyShapeRecord(ShapeRecord(Pocket(CGRect(x: 900, y: 0, width: 50, height: 50))))
        let pen = AnyShapeRecord(ShapeRecord(Corral(CGRect(x: 0, y: 0, width: 100, height: 100))))
        let kept = original.copy(as: ShapeID(), container: pen.id)
        let below = original.copy(as: ShapeID(), container: ShapeID())
        let pens = AnyShapeRecord(ShapeRecord(Corral(CGRect(x: 0, y: 0, width: 100, height: 100))))
        let above = original.copy(as: ShapeID(), container: pens.id)
        h.editor.transact { $0.insert(pocket, contents: [pocket.id: CanvasDocument(shapes: [pen, kept, below, above, pens])]) }
        let board = h.file[BoardID(owner: pocket.id)]
        expectEqual(board[kept.id]?.container, pen.id)
        expectEqual(board[below.id]?.container, nil, "not on its board")
        expectEqual(board[above.id]?.container, nil, "its container comes after it")
        // A read-only container takes nothing new: the shape goes in on the board directly.
        h.editor.freeze([held])
        let refused = original.copy(as: ShapeID(), container: held)
        h.editor.transact { $0.insert(refused) }
        expectEqual(h.editor.document[refused.id]?.container, nil)
        expectEqual(log.refusals, [[held]])
    },
])

@MainActor let containerMovingTests = Suite("Moving containers", [
    test("translate moves what a container holds with it, at any depth, each shape once however it's asked for") {
        let h = try corralHarness()
        let outer = h.add(Corral(CGRect(x: 0, y: 0, width: 600, height: 400)))
        let inner = h.add(Corral(CGRect(x: 20, y: 20, width: 300, height: 200)))
        let a = h.add(Box(CGRect(x: 40, y: 40, width: 50, height: 50)))
        let b = h.add(Box(CGRect(x: 400, y: 40, width: 50, height: 50)))
        let c = h.add(Box(CGRect(x: 700, y: 40, width: 50, height: 50)))
        h.editor.put([inner, b], in: outer)
        h.editor.put([a], in: inner)
        h.editor.transact { $0.translate([outer], by: CGPoint(x: 10, y: 5)) }
        expectEqual(h.frame(of: outer)?.origin, CGPoint(x: 10, y: 5))
        expectEqual(h.frame(of: inner)?.origin, CGPoint(x: 30, y: 25))
        expectEqual(h.frame(of: a)?.origin, CGPoint(x: 50, y: 45))
        expectEqual(h.frame(of: b)?.origin, CGPoint(x: 410, y: 45))
        expectEqual(h.frame(of: c)?.origin, CGPoint(x: 700, y: 40), "not in it")
        h.editor.transact { $0.translate([outer, a, inner], by: CGPoint(x: 10, y: 0)) }
        expectEqual(h.frame(of: a)?.origin, CGPoint(x: 60, y: 45), "once")
        h.editor.transact { $0.translate([inner], by: CGPoint(x: 0, y: 10)) }
        expectEqual(h.frame(of: a)?.origin, CGPoint(x: 60, y: 55))
        expectEqual(h.frame(of: outer)?.origin, CGPoint(x: 20, y: 5), "what holds it stays")
        expectEqual(h.editor.holder(of: a), inner, "moving never changes what's in what")
    },
    test("read-only shapes ride along with their container; a read-only container holds what's in it") {
        let log = RefusalLog()
        let h = try corralHarness([FreezingPlugin(log: log)])
        let pen = h.add(Corral(CGRect(x: 0, y: 0, width: 600, height: 400)))
        let a = h.add(Box(CGRect(x: 40, y: 40, width: 50, height: 50)))
        let b = h.add(Box(CGRect(x: 140, y: 40, width: 50, height: 50)))
        h.editor.put([a, b], in: pen)
        h.editor.freeze([a])
        h.editor.transact { $0.translate([pen], by: CGPoint(x: 10, y: 0)) }
        expectEqual(h.frame(of: a)?.origin, CGPoint(x: 50, y: 40), "carried, locked on its own")
        expectEqual(log.refusals, [])
        h.editor.freeze([pen])
        h.editor.transact { $0.translate([pen, b], by: CGPoint(x: 10, y: 0)) }
        h.editor.transact { $0.translate([b], by: CGPoint(x: 10, y: 0)) }
        expectEqual(h.frame(of: pen)?.origin, CGPoint(x: 10, y: 0))
        expectEqual(h.frame(of: b)?.origin, CGPoint(x: 150, y: 40))
        expectEqual(log.refusals, [[pen, b], [b]])
    },
    test("a drag moves what a container holds with it, read-only or not, which the translation adjuster is given, and Escape puts it all back") {
        let log = RefusalLog(), starts = StartLog()
        let h = try corralHarness([FreezingPlugin(log: log), startsPlugin(starts), dragPlugin()])
        let pen = h.add(Corral(CGRect(x: 0, y: 0, width: 300, height: 200)))
        let a = h.add(Box(CGRect(x: 40, y: 40, width: 50, height: 50)))
        let b = h.add(Box(CGRect(x: 140, y: 40, width: 50, height: 50)))
        h.editor.put([a, b], in: pen)
        h.editor.freeze([a])
        h.press(at: CGPoint(x: 20, y: 150))
        h.drag(to: CGPoint(x: 70, y: 170))
        expectEqual(h.frame(of: pen)?.origin, CGPoint(x: 50, y: 20))
        expectEqual(h.frame(of: a)?.origin, CGPoint(x: 90, y: 60))
        expectEqual(h.frame(of: b)?.origin, CGPoint(x: 190, y: 60))
        expectEqual(Set(starts.ids.last ?? []), [pen, a, b], "what's carried isn't a snap target")
        h.escape()
        expectEqual(h.frame(of: a)?.origin, CGPoint(x: 40, y: 40))
        expectEqual(h.frame(of: pen)?.origin, .zero)
        h.release()
        expectEqual(log.refusals, [])
    },
])

@MainActor let containerDeletingTests = Suite("Deleting containers", [
    test("deleting a container lets go of what it holds into its own container, the nearest that stays; undo puts it back") {
        let h = try corralHarness()
        let outer = h.add(Corral(CGRect(x: 0, y: 0, width: 600, height: 400)))
        let middle = h.add(Corral(CGRect(x: 10, y: 10, width: 400, height: 300)))
        let inner = h.add(Corral(CGRect(x: 20, y: 20, width: 200, height: 200)))
        let a = h.add(Box(CGRect(x: 40, y: 40, width: 50, height: 50)))
        let b = h.add(Box(CGRect(x: 300, y: 40, width: 50, height: 50)))
        h.editor.put([middle], in: outer)
        h.editor.put([inner, b], in: middle)
        h.editor.put([a], in: inner)
        let before = h.editor.document
        h.editor.transact { $0.delete([middle, inner]) }
        expectEqual(h.editor.holder(of: a), outer)
        expectEqual(h.editor.holder(of: b), outer)
        expectEqual(h.frame(of: a)?.origin, CGPoint(x: 40, y: 40), "where it was")
        expectEqual(h.stack, [outer, a, b], "in its place in the stack")
        h.editor.undo()
        expectEqual(h.editor.document, before)
        h.editor.transact { $0.delete([outer]) }
        expectEqual(h.editor.holder(of: middle), nil)
        expectEqual(h.editor.holder(of: inner), middle)
        h.editor.undo()
        expectEqual(h.editor.document, before)
    },
    test("a container holding a read-only shape is deleted, and the shape stays, let go; a shape in a read-only container isn't") {
        let log = RefusalLog()
        let h = try corralHarness([FreezingPlugin(log: log)])
        let pen = h.add(Corral(CGRect(x: 0, y: 0, width: 600, height: 400)))
        let locked = h.add(Box(CGRect(x: 40, y: 40, width: 50, height: 50)))
        let other = h.add(Corral(CGRect(x: 700, y: 0, width: 300, height: 300)))
        let inside = h.add(Box(CGRect(x: 740, y: 40, width: 50, height: 50)))
        h.editor.put([locked], in: pen)
        h.editor.put([inside], in: other)
        h.editor.freeze([locked, other])
        h.editor.transact { $0.delete([pen, locked]) }
        expectEqual(h.editor.document[pen], nil)
        expectEqual(h.editor.holder(of: locked), nil, "let go")
        expectEqual(log.refusals, [[locked]])
        h.editor.transact { $0.delete([inside]) }
        h.editor.transact { $0.delete([other]) }
        expect(h.editor.document[inside] != nil && h.editor.document[other] != nil)
        expectEqual(log.refusals, [[locked], [inside], [other]])
    },
])

@MainActor let containerReadOnlyTests = Suite("Read-only containers", [
    test("a shape in a read-only container is read-only, at any depth, while the rules say nothing of it") {
        let h = try corralHarness([FreezingPlugin()])
        let outer = h.add(Corral(CGRect(x: 0, y: 0, width: 600, height: 400)))
        let inner = h.add(Corral(CGRect(x: 20, y: 20, width: 300, height: 200)))
        let a = h.add(Box(CGRect(x: 40, y: 40, width: 50, height: 50)))
        h.editor.put([inner], in: outer)
        h.editor.put([a], in: inner)
        h.editor.freeze([outer])
        let record = try require(h.editor.document[a])
        expect(h.editor.isReadOnly(a))
        expect(h.editor.isReadOnly(inner))
        expect(!h.editor.registry.isReadOnly(record), "the rules read the record alone")
        expect(h.editor.registry.isReadOnly(record, in: h.editor.document))
        h.editor.freeze([outer], false)
        expect(!h.editor.isReadOnly(a))
    },
    test("it changes not at all: not moved, edited, restacked, deleted, let out or unlocked; nothing joins the container") {
        let log = RefusalLog()
        let h = try corralHarness([FreezingPlugin(log: log)])
        let pen = h.add(Corral(CGRect(x: 0, y: 0, width: 600, height: 400)))
        let a = h.add(Box(CGRect(x: 40, y: 40, width: 50, height: 50)))
        let b = h.add(Box(CGRect(x: 140, y: 40, width: 50, height: 50)))
        let outside = h.add(Box(CGRect(x: 700, y: 40, width: 50, height: 50)))
        h.editor.put([a, b], in: pen)
        h.editor.freeze([b])
        h.editor.freeze([pen])
        let before = h.editor.document
        h.editor.transact { tx in
            tx.update(a) { $0.box = CGRect(x: 0, y: 0, width: 5, height: 5) }
            tx.moveBox(a, to: .zero)
            tx.sendToBack(a)
            tx.setContainer(a, to: nil)
            tx.delete([a])
        }
        h.editor.freeze([b], false)
        expectEqual(h.editor.document, before)
        expectEqual(log.refusals, [[a], [b]])
        h.editor.put([outside], in: pen)
        expectEqual(h.editor.holder(of: outside), nil)
        expectEqual(log.refusals, [[a], [b], [pen]], "the container is the one refused")
        h.editor.freeze([pen], false)
        h.editor.put([outside], in: pen)
        h.editor.put([a], in: nil)
        expectEqual(h.contents(of: pen), [b, outside])
    },
    test("a shape whose container becomes read-only stops being edited, and isn't edited after") {
        let log = RefusalLog()
        let h = try EditorHarness(plugins: [CardsPlugin(), CorralsPlugin(), FreezingPlugin(log: log)])
        let pen = h.add(Corral(CGRect(x: 0, y: 0, width: 600, height: 400)))
        let card = h.add(Card(CGRect(x: 40, y: 40, width: 100, height: 60)))
        h.editor.put([card], in: pen)
        expect(h.editor.beginEditing(card))
        h.editor.freeze([pen])
        expectEqual(h.editor.editingShapeID, nil)
        expect(!h.editor.beginEditing(card))
        expectEqual(log.refusals, [[card]])
    },
])

/// A reproducible stream of choices for the seeded runs.
private struct Choices: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state >> 11 | state << 53
    }
}

@MainActor let containerRunTests = Suite("Containers, seeded", [
    test("whatever joins, leaves, moves, restacks, is deleted, put down, undone and redone, the index is whole, what's in a container paints above it, and nothing is in itself") {
        for seed: UInt64 in [1, 2, 3, 7, 42, 99] { try containerRun(seed: seed) }
    },
])

/// 400 steps chosen by `seed` over 8 corrals and 16 boxes, some frozen as it goes, each held to the
/// invariants; then every step undone and done again.
@MainActor private func containerRun(seed: UInt64) throws {
    let h = try corralHarness([FreezingPlugin()])
    let kinds = h.editor.registry.containingKinds
    var random = Choices(state: seed)
    for n in 0..<8 { h.add(Corral(CGRect(x: CGFloat(n % 4) * 300, y: CGFloat(n / 4) * 300, width: 280, height: 280))) }
    for n in 0..<16 { h.add(Box(CGRect(x: CGFloat(n % 8) * 140 + 20, y: CGFloat(n / 8) * 300 + 40, width: 60, height: 60))) }
    func check(_ step: Int) {
        let document = h.editor.document
        expectIndexWhole(document, kinds: kinds)
        expect(keysRise(document), "seed \(seed), step \(step): keys rise")
        for record in document.shapes {
            guard let holder = document.container(of: record, containingKinds: kinds) else { continue }
            expect((document.index(of: holder) ?? .max) < (document.index(of: record.id) ?? -1), "seed \(seed), step \(step): above its container")
            expect(!document.containers(of: record.id, containingKinds: kinds).contains(record.id), "seed \(seed), step \(step): in itself")
        }
    }
    for step in 0..<400 {
        let live = h.editor.document.shapes.map(\.id)
        guard let a = live.randomElement(using: &random), let b = live.randomElement(using: &random) else { break }
        let offset = CGPoint(x: CGFloat(Int.random(in: -120...120, using: &random)), y: CGFloat(Int.random(in: -120...120, using: &random)))
        let corrals = h.editor.document.shapes.filter { $0.kind == Corral.kind }.map(\.id)
        switch Int.random(in: 0..<14, using: &random) {
        case 0, 1: h.editor.put([a], in: h.editor.document[b]?.kind == Corral.kind ? b : nil)
        case 12:
            // Several joining one corral one at a time, in one transaction, and some leaving.
            guard let pen = corrals.randomElement(using: &random) else { break }
            let some = (0..<4).compactMap { _ in live.randomElement(using: &random) }
            h.editor.transact { tx in
                for (n, id) in some.enumerated() { tx.setContainer(id, to: n == 2 ? nil : pen) }
            }
        case 13:
            guard let pen = corrals.randomElement(using: &random) else { break }
            h.editor.transact { $0.setContainer((0..<4).compactMap { _ in live.randomElement(using: &random) }, to: pen) }
        case 2: h.editor.transact { $0.translate([a, b], by: offset) }
        case 3: h.editor.transact { tx in
            tx.translate([a], by: offset)
            _ = tx.settle([a])
        }
        case 4: h.editor.transact { $0.bringToFront(a) }
        case 5: h.editor.transact { $0.sendToBack(a) }
        case 6: h.editor.transact { $0.move(a, above: b) }
        case 7: h.editor.transact { $0.move(a, below: b) }
        case 8: if live.count > 10 { h.editor.transact { $0.delete([a]) } }
        case 9: h.editor.freeze([a], Bool.random(using: &random))
        case 10: h.editor.undo()
        default: h.editor.redo()
        }
        check(step)
    }
    // Every step undone, and every step done again (those undone along the way too), is exactly as
    // it was.
    while h.editor.canRedo { h.editor.redo() }
    let end = h.editor.document
    while h.editor.canUndo { h.editor.undo() }
    check(-1)
    while h.editor.canRedo { h.editor.redo() }
    expectEqual(h.editor.document, end, "seed \(seed)")
}

@MainActor let containerStackTests = Suite("Containers in the stack", [
    test("shapes joining a container together rise together, in their order, as joining one at a time would put them") {
        @MainActor func board() throws -> (EditorHarness, [ShapeID]) {
            let h = try corralHarness()
            let low = h.add(Box(CGRect(x: 40, y: 40, width: 50, height: 50)))
            let lower = h.add(Box(CGRect(x: 140, y: 40, width: 50, height: 50)))
            let pen = h.add(Corral(CGRect(x: 0, y: 0, width: 600, height: 400)))
            let member = h.add(Box(CGRect(x: 240, y: 40, width: 50, height: 50)))
            let high = h.add(Box(CGRect(x: 340, y: 40, width: 50, height: 50)))
            h.editor.put([member], in: pen)
            return (h, [low, lower, pen, member, high])
        }
        let (together, ids) = try board()
        together.editor.transact { $0.setContainer([ids[0], ids[1], ids[4]], to: ids[2]) }
        expectEqual(together.stack, [ids[2], ids[3], ids[0], ids[1], ids[4]])
        let (apart, same) = try board()
        apart.editor.transact { tx in
            for id in [same[0], same[1], same[4]] { tx.setContainer(id, to: same[2]) }
        }
        expectEqual(apart.stack.compactMap(same.firstIndex), together.stack.compactMap(ids.firstIndex))
        expectEqual(apart.contents(of: same[2]), [same[3], same[0], same[1], same[4]])
    },
    test("joining raises a shape, with what it holds, just above what the container holds, if it's below; leaving keeps its place") {
        let h = try corralHarness()
        let low = h.add(Box(CGRect(x: 40, y: 40, width: 50, height: 50)))
        let nested = h.add(Corral(CGRect(x: 300, y: 20, width: 200, height: 200)))
        let inNested = h.add(Box(CGRect(x: 320, y: 40, width: 50, height: 50)))
        let pen = h.add(Corral(CGRect(x: 0, y: 0, width: 600, height: 400)))
        let held = h.add(Box(CGRect(x: 140, y: 40, width: 50, height: 50)))
        let top = h.add(Box(CGRect(x: 240, y: 40, width: 50, height: 50)))
        h.editor.put([inNested], in: nested)
        h.editor.put([held], in: pen)
        h.editor.put([low], in: pen)
        expectEqual(h.stack, [nested, inNested, pen, held, low, top])
        h.editor.put([top], in: pen)
        expectEqual(h.stack, [nested, inNested, pen, held, low, top], "above already")
        h.editor.put([nested], in: pen)
        expectEqual(h.stack, [pen, held, low, top, nested, inNested])
        h.editor.put([held], in: nil)
        expectEqual(h.stack, [pen, held, low, top, nested, inNested])
        expect(keysRise(h.editor.document))
    },
    test("bringing to front and sending to back take what a container holds along; a shape in one goes no lower than just above it") {
        let h = try corralHarness()
        let x = h.add(Box(CGRect(x: 700, y: 40, width: 50, height: 50)))
        let pen = h.add(Corral(CGRect(x: 0, y: 0, width: 600, height: 400)))
        let a = h.add(Box(CGRect(x: 40, y: 40, width: 50, height: 50)))
        let b = h.add(Box(CGRect(x: 140, y: 40, width: 50, height: 50)))
        let y = h.add(Box(CGRect(x: 800, y: 40, width: 50, height: 50)))
        h.editor.put([a, b], in: pen)
        h.editor.transact { $0.bringToFront(pen) }
        expectEqual(h.stack, [x, y, pen, a, b])
        h.editor.transact { $0.sendToBack(pen) }
        expectEqual(h.stack, [pen, a, b, x, y])
        h.editor.transact { $0.sendToBack(b) }
        expectEqual(h.stack, [pen, b, a, x, y])
        h.editor.transact { $0.sendToBack(b) }
        expectEqual(h.stack, [pen, b, a, x, y], "there already")
        h.editor.transact { $0.bringToFront(b) }
        expectEqual(h.stack, [pen, a, x, y, b])
        h.editor.transact { $0.bringToFront(pen) }
        expectEqual(h.stack, [x, y, pen, a, b])
        h.editor.transact { $0.bringToFront(pen) }
        expectEqual(h.stack, [x, y, pen, a, b], "on top already, with all it holds")
        expect(keysRise(h.editor.document))
        h.editor.undo()
        h.editor.undo()
        expectEqual(h.stack, [pen, b, a, x, y])
    },
    test("a step forward or back moves a container with what it holds, and a shape in one never past it") {
        let h = try corralHarness()
        let x = h.add(Box(CGRect(x: 700, y: 40, width: 50, height: 50)))
        let pen = h.add(Corral(CGRect(x: 0, y: 0, width: 600, height: 400)))
        let a = h.add(Box(CGRect(x: 40, y: 40, width: 50, height: 50)))
        let b = h.add(Box(CGRect(x: 140, y: 40, width: 50, height: 50)))
        let y = h.add(Box(CGRect(x: 800, y: 40, width: 50, height: 50)))
        h.editor.put([a, b], in: pen)
        h.editor.transact { $0.move(pen, above: y) }
        expectEqual(h.stack, [x, y, pen, a, b])
        h.editor.transact { $0.move(pen, below: x) }
        expectEqual(h.stack, [pen, a, b, x, y])
        h.editor.transact { $0.move(b, below: a) }
        expectEqual(h.stack, [pen, b, a, x, y])
        h.editor.transact { $0.move(b, below: pen) }
        expectEqual(h.stack, [pen, b, a, x, y], "no lower than just above its container")
        h.editor.transact { $0.move(a, above: y) }
        expectEqual(h.stack, [pen, b, x, y, a])
        h.editor.transact { $0.bringToFront(pen) }
        h.editor.transact { $0.move(b, above: x) }
        expectEqual(h.stack, [x, y, pen, b, a], "just above its container, below which it can't go")
        h.editor.transact { $0.move(pen, above: a) }
        expectEqual(h.stack, [x, y, pen, b, a], "not past what it holds")
        expect(keysRise(h.editor.document))
    },
    test("restacked with its container, a read-only shape goes along; one in a read-only container isn't restacked") {
        let log = RefusalLog()
        let h = try corralHarness([FreezingPlugin(log: log)])
        let pen = h.add(Corral(CGRect(x: 0, y: 0, width: 600, height: 400)))
        let a = h.add(Box(CGRect(x: 40, y: 40, width: 50, height: 50)))
        let b = h.add(Box(CGRect(x: 140, y: 40, width: 50, height: 50)))
        let x = h.add(Box(CGRect(x: 700, y: 40, width: 50, height: 50)))
        h.editor.put([a, b], in: pen)
        h.editor.freeze([a])
        h.editor.transact { $0.bringToFront(pen) }
        expectEqual(h.stack, [x, pen, a, b])
        expectEqual(log.refusals, [])
        h.editor.freeze([a], false)
        h.editor.freeze([pen])
        h.editor.transact { $0.bringToFront(a) }
        h.editor.transact { $0.sendToBack(pen) }
        expectEqual(h.stack, [x, pen, a, b])
        expectEqual(log.refusals, [[a], [pen]])
    },
])

// MARK: Fixtures

/// Whether every shape's stacking key is above the one before it.
func keysRise(_ document: CanvasDocument) -> Bool {
    zip(document.shapes, document.shapes.dropFirst()).allSatisfy { pair in
        guard let low = pair.0.stackingKey, let high = pair.1.stackingKey else { return false }
        return low < high
    }
}

/// What the translation adjuster was given as each drag began.
@MainActor
final class StartLog {
    var ids: [[ShapeID]] = []
}

/// An adjuster that only listens: what moves follows the pointer.
@MainActor
private final class ListeningAdjuster: TranslationAdjuster {
    func adjust(_ delta: CGPoint, along axis: TranslationAxis?, for pointer: Pointer, in editor: CanvasEditor) -> CGPoint { delta }
    func draw(in context: OverlayContext) {}
}

@MainActor func startsPlugin(_ log: StartLog) -> Contributor {
    Contributor(id: "starts") { r in
        r.translationAdjuster { _, start in
            log.ids.append(start.ids)
            return ListeningAdjuster()
        }
    }
}

/// What the drag tool drags: the shapes a test names, or else the shape pressed.
@MainActor
final class Picks {
    var ids: [ShapeID] = []
}

/// The select tool's lone box, without Selection (which CanvasTests can't use): a press on a shape
/// starts a `TranslatingSession` of what `picks` names, or of that shape, from the press, with no
/// drag threshold.
final class DragTool {
    let picks: Picks
    init(picks: Picks) { self.picks = picks }
}

extension DragTool: Tool {
    func pointerDown(_ pointer: Pointer, in editor: CanvasEditor) {
        guard let id = editor.shape(at: pointer.world) else { return }
        editor.session = TranslatingSession(ids: picks.ids.isEmpty ? [id] : picks.ids, from: pointer.world, in: editor)
    }
}

/// The drag tool, as the default tool.
@MainActor func dragPlugin(_ picks: Picks = Picks()) -> Contributor {
    Contributor(id: "dragging") { r in
        r.tool(ToolDescriptor(id: "drag", label: "Drag", systemImage: "hand.point.up")) { _ in DragTool(picks: picks) }
        r.defaultTool("drag")
    }
}
