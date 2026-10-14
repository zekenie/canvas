@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import TestKit

// A shape changing kind under its id (`Transaction.turn`), and shapes moving onto the board a shape
// owns, on the board below (`Transaction.move(_:toBoardOwnedBy:)`), with CanvasTesting's corrals and
// pockets standing in for a frame and a subboard: what the commit says, what a binding, a name or a
// lock does, and that undo and redo bring the file back exactly.

private let unit = CGRect(x: 0, y: 0, width: 100, height: 100)

private func box(_ id: ShapeID, x: CGFloat = 0, y: CGFloat = 0, in container: ShapeID? = nil) -> AnyShapeRecord {
    AnyShapeRecord(ShapeRecord(id: id, Box(CGRect(x: x, y: y, width: 40, height: 30)))).copy(as: id, container: container)
}
private func corral(_ id: ShapeID, _ frame: CGRect, in container: ShapeID? = nil) -> AnyShapeRecord {
    AnyShapeRecord(ShapeRecord(id: id, Corral(frame))).copy(as: id, container: container)
}
private func pocket(_ id: ShapeID, _ frame: CGRect = unit) -> AnyShapeRecord { AnyShapeRecord(ShapeRecord(id: id, Pocket(frame))) }
private func link(_ id: ShapeID, _ from: ShapeID?, _ to: ShapeID?) -> AnyShapeRecord {
    AnyShapeRecord(ShapeRecord(id: id, Link(from: from, to: to)))
}
private func board(_ records: AnyShapeRecord...) -> CanvasDocument { CanvasDocument(shapes: records) }
private func ids(_ document: CanvasDocument) -> [ShapeID] { document.shapes.map(\.id) }

/// A second kind that owns boards, for turning a pocket into one.
private struct Shelf: BoxShapeProps {
    static let kind: ShapeKind = "shelf"
    static let properties = Properties<Shelf> {
        Property("frame", \.frame).required()
    }
    var frame: CGRect
    init(_ frame: CGRect) { self.frame = frame }
}

extension Shelf {
    init() { self.init(.zero) }
}

private struct ShelfDefinition {}

extension ShelfDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Shelf>, in context: RenderContext) {}
}

extension ShelfDefinition: BoardOwning {}

/// Stars (0 until rated) on boxes, discs, corrals and pockets, a sticker on boxes and corrals, and a
/// temper on discs alone: what a shape turned between them keeps, drops and gets.
@MainActor private func marks() -> Contributor {
    Contributor(id: "marks") { r in
        r.declare(Stars.self)
        r.declare(Sticker.self)
        r.declare(Temper.self)
        r.optIn(Box.self, to: Stars.self)
        r.optIn(Disc.self, to: Stars.self)
        r.optIn(Corral.self, to: Stars.self)
        r.optIn(Pocket.self, to: Stars.self)
        r.optIn(Box.self, to: Sticker.self)
        r.optIn(Corral.self, to: Sticker.self)
        r.optIn(Disc.self, to: Temper.self)
    }
}

@MainActor private func plugins(_ log: ChangeLog, _ refusals: RefusalLog) -> [any CanvasPlugin] {
    [FixturesPlugin(), PocketsPlugin(), CorralsPlugin(), LinksPlugin(), NamingPlugin(), marks(),
     Contributor(id: "shelves") { $0.shape(ShelfDefinition()) }, FreezingPlugin(log: refusals), recordingChanges(log)]
}

/// An editor of `file`, with every change set and refusal services hear kept.
@MainActor private func harness(_ file: CanvasFile, _ log: ChangeLog = ChangeLog(), _ refusals: RefusalLog = RefusalLog()) throws -> EditorHarness {
    try EditorHarness(plugins: plugins(log, refusals), file: file)
}

/// The file, and the file as a board file's bytes: what a round trip must come back to.
@MainActor private func expectFile(_ h: EditorHarness, _ expected: CanvasFile, _ message: String,
                                   file: StaticString = #fileID, line: UInt = #line) throws {
    expectEqual(h.file, expected, message, file: file, line: line)
    let codec = BoardCodec(registry: h.editor.registry)
    expectEqual(try codec.encode(h.file), try codec.encode(expected), "\(message), as a file", file: file, line: line)
}

/// A shape's props, wherever it is in the file.
@MainActor private func props<P: ShapeProps>(_ h: EditorHarness, _ id: ShapeID, as _: P.Type) -> P? {
    h.file.record(id)?.typed(as: P.self)?.props
}

@MainActor let turningTests = Suite("Turning a shape into another kind", [
    test("a shape turned keeps its id, its place in the stack, its container and its metadata, and has the new kind's props") {
        let a = ShapeID(), k = ShapeID(), b = ShapeID(), c = ShapeID(), log = ChangeLog()
        let h = try harness(CanvasFile(root: board(box(a), corral(k, CGRect(x: 100, y: 100, width: 400, height: 300)),
                                                   box(b, x: 150, y: 120, in: k), box(c, x: 800))), log)
        h.editor.transact { transaction in
            transaction.update(b) {
                $0[Stars.self] = 3
                $0[Sticker.self] = "sale"
                $0.meta[Origin.self] = Origin.Value(source: "test", count: 2)
            }
        }
        let old = try require(h.editor.document[b]), before = h.file
        let disc = Disc(CGRect(x: 160, y: 130, width: 20, height: 20))
        let turned = h.editor.transact("Turn") { $0.turn(b, into: disc) }
        expect(turned)
        let record = try require(h.editor.document[b])
        expectEqual(record.typed(as: Disc.self)?.props, disc)
        expectEqual(record.stackingKey, old.stackingKey, "its place in the stack")
        expectEqual(ids(h.editor.document), [a, k, b, c])
        expectEqual(h.editor.holder(of: b), k)
        expectEqual(record.meta[Origin.self], Origin.Value(source: "test", count: 2))
        expectEqual(record[Stars.self], 3, "a property both kinds hold goes with it")
        expectEqual(record[Sticker.self], nil, "one the disc doesn't hold doesn't")
        expectEqual(record[Temper.self], "calm", "one only the disc holds has its default")
        let change = try require(log.changes.last)
        expectEqual(change.changed, [b])
        expectEqual(change.added, [])
        expectEqual(change.removed, [])
        expect(!change.reordered, "it's where it was in the stack")
        expect(change.moved.isEmpty && change.boardsReached.isEmpty && change.elsewhere.isEmpty)
        let after = h.file
        expectEqual(h.editor.undoHistory.undoName, "Turn")
        h.editor.undo()
        try expectFile(h, before, "the box as it was")
        expectEqual(h.editor.document[b]?.kind, Box.kind)
        h.editor.redo()
        try expectFile(h, after, "and the disc again")
    },
    test("the record it's turned into says its kind, props and added values to start from, not its id, place or container") {
        let a = ShapeID(), k = ShapeID()
        let h = try harness(CanvasFile(root: board(corral(k, CGRect(x: 100, y: 100, width: 400, height: 300)), box(a, x: 150, y: 120))))
        h.editor.transact { $0.update(a) { $0[Stars.self] = 2 } }
        let old = try require(h.editor.document[a])
        var made = AnyShapeRecord(ShapeRecord(id: ShapeID(), Disc(CGRect(x: 0, y: 0, width: 20, height: 20)))).copy(as: ShapeID(), container: k)
        made[Temper.self] = "fierce"
        made[Stars.self] = 9
        expect(h.editor.transact { $0.turn(a, into: made) })
        let record = try require(h.editor.document[a])
        expectEqual(record.kind, Disc.kind)
        expectEqual(record.stackingKey, old.stackingKey)
        expectEqual(h.editor.holder(of: a), nil, "on the board directly, as it was; the record's container isn't taken")
        expectEqual(record[Temper.self], "fierce", "what the record set, where the shape has none")
        expectEqual(record[Stars.self], 2, "the shape's own over the record's")
    },
    test("a value kept aside, one the app can't use, goes with the shape") {
        let json = """
        { "format" : 3, "versions" : { "kinds" : { "box" : 0 }, "added" : { "mystery" : 2 } }, "shapes" : [
          { "id" : "00000000-0000-0000-0000-000000000001", "kind" : "box", "index" : "a0", "props" : { "frame" : [[0, 0], [10, 10]] },
            "added" : { "mystery" : [1, 2] } }
        ] }
        """
        let codec = BoardCodec(registry: try Registry(plugins: plugins(ChangeLog(), RefusalLog())))
        let loaded = try codec.decode(Data(json.utf8))
        let a = try require(loaded.document.shapes.first).id
        let h = try harness(loaded.file)
        expectEqual(h.editor.document[a]?.keptProperties, ["mystery"])
        h.editor.transact { $0.turn(a, into: Disc(CGRect(x: 0, y: 0, width: 10, height: 10))) }
        expectEqual(h.editor.document[a]?.kind, Disc.kind)
        expectEqual(h.editor.document[a]?.keptProperties, ["mystery"])
        expect(String(decoding: try codec.encode(h.file), as: UTF8.self).contains("mystery"), "and it's saved back as it was")
    },
    test("whatever binds or names a shape goes on doing so: a link's end, a tag's target, a memo's name and a citing tag's both") {
        let a = ShapeID(), b = ShapeID(), l = ShapeID(), t = ShapeID(), m = ShapeID(), n = ShapeID()
        let h = try harness(CanvasFile(root: board(box(a), box(b, x: 100), link(l, a, b), AnyShapeRecord(ShapeRecord(id: t, Tag(target: b))),
                                                   AnyShapeRecord(ShapeRecord(id: m, Memo(lead: Citation(b)))),
                                                   AnyShapeRecord(ShapeRecord(id: n, CitingTag(target: b, cite: Citation(b)))))))
        let before = h.file
        h.editor.transact { $0.turn(b, into: Disc(CGRect(x: 100, y: 0, width: 40, height: 30))) }
        expectEqual(props(h, l, as: Link.self), Link(from: a, to: b))
        expectEqual(props(h, t, as: Tag.self), Tag(target: b))
        expectEqual(props(h, m, as: Memo.self)?.lead, Citation(b))
        expectEqual(props(h, n, as: CitingTag.self), CitingTag(target: b, cite: Citation(b)))
        h.editor.undo()
        try expectFile(h, before, "as it was")
    },
    test("a shape turned into a kind with no box is on the board directly: only a box shape is in a container") {
        let k = ShapeID(), b = ShapeID()
        let h = try harness(CanvasFile(root: board(corral(k, CGRect(x: 0, y: 0, width: 300, height: 200)), box(b, x: 20, y: 20, in: k))))
        let before = h.file
        h.editor.transact { $0.turn(b, into: Tag(target: nil)) }
        expectEqual(h.editor.document[b]?.kind, Tag.kind)
        expectEqual(h.editor.document[b]?.container, nil)
        expectEqual(h.editor.document.contents(of: k, containingKinds: h.editor.registry.containingKinds), [])
        h.editor.undo()
        try expectFile(h, before, "in its container again")
        expectEqual(h.editor.holder(of: b), k)
    },
    test("a container turned into a kind that holds nothing lets go of what it holds into its own container; into one that holds, it keeps it") {
        let o = ShapeID(), i = ShapeID(), x = ShapeID(), y = ShapeID(), z = ShapeID(), log = ChangeLog(), refusals = RefusalLog()
        let h = try harness(CanvasFile(root: board(corral(o, CGRect(x: 0, y: 0, width: 800, height: 600)),
                                                   corral(i, CGRect(x: 50, y: 50, width: 400, height: 300), in: o),
                                                   box(x, x: 100, y: 100, in: i), box(y, x: 600, y: 100, in: o), box(z, x: 900))), log, refusals)
        h.editor.transact("Turn") { $0.turn(i, into: Corral(CGRect(x: 60, y: 60, width: 300, height: 200))) }
        expectEqual(h.editor.holder(of: x), i, "a corral is a container still")
        expectEqual(log.changes.last?.changed, [i])
        h.editor.undo()

        h.editor.freeze([x])
        let before = h.file
        h.editor.transact("Turn") { $0.turn(i, into: Pocket(CGRect(x: 50, y: 50, width: 240, height: 160))) }
        expectEqual(h.editor.document[i]?.kind, Pocket.kind)
        expectEqual(h.editor.holder(of: i), o, "it's in its container still")
        expectEqual(h.editor.holder(of: x), o, "what it held, locked or not, is let go into that one")
        expectEqual(h.editor.holder(of: y), o)
        expectEqual(ids(h.editor.document), [o, i, x, y, z], "no shape moves in the stack")
        expectEqual(log.changes.last?.changed, [i, x])
        expectEqual(refusals.refusals, [], "letting go goes through a lock")
        h.editor.undo()
        try expectFile(h, before, "the corral holds it again")
        expectEqual(h.editor.holder(of: x), i)
    },
    test("a shape that owns a board keeps it, whole, turned into another kind that owns boards; one with no board may become any kind") {
        let p = ShapeID(), q = ShapeID(), x = ShapeID(), y = ShapeID()
        let h = try harness(CanvasFile(root: board(pocket(p), pocket(q, CGRect(x: 200, y: 0, width: 100, height: 100))),
                                       children: [p: board(box(x), box(y, x: 100))]))
        let before = h.file
        h.editor.transact { transaction in
            transaction.turn(p, into: Shelf(unit))
            transaction.turn(q, into: Disc(CGRect(x: 200, y: 0, width: 100, height: 100)))
        }
        expectEqual(h.editor.document[p]?.kind, Shelf.kind)
        expectEqual(h.editor.document[q]?.kind, Disc.kind)
        expectEqual(h.file[BoardID(owner: p)], before[BoardID(owner: p)], "its board is as it was")
        expectEqual(h.file.board(containing: x), BoardID(owner: p))
        expect(h.editor.canShow(BoardID(owner: p)), "and a shelf owns it")
        expect(h.enter(p))
        expectEqual(ids(h.editor.document), [x, y])
        h.editor.undo()
        try expectFile(h, before, "the pocket and its board")
    },
    test("it says no, and changes nothing, for a shape that isn't on the board or is kept aside or a frame that isn't finite; yes for what it is") {
        let json = """
        { "format" : 3, "versions" : { "kinds" : { "box" : 0 } }, "shapes" : [
          { "id" : "00000000-0000-0000-0000-000000000001", "kind" : "gadget", "index" : "a0", "props" : { } },
          { "id" : "00000000-0000-0000-0000-000000000002", "kind" : "box", "index" : "a1", "props" : { "frame" : [[0, 0], [10, 10]] } }
        ] }
        """
        let log = ChangeLog(), p = ShapeID(), x = ShapeID()
        let loaded = try BoardCodec(registry: try Registry(plugins: plugins(log, RefusalLog()))).decode(Data(json.utf8))
        let gadget = try require(loaded.document.shapes.first), a = try require(loaded.document.shapes.last)
        expect(gadget.isOpaque)
        let h = try harness(CanvasFile(root: CanvasDocument(shapes: loaded.document.shapes + [pocket(p)]), children: [p: board(box(x))]), log)
        let before = h.file
        h.editor.transact { transaction in
            expect(!transaction.turn(ShapeID(), into: Disc(unit)), "not in the file")
            expect(!transaction.turn(x, into: Disc(unit)), "on another board")
            expect(!transaction.turn(gadget.id, into: Disc(unit)), "kept aside")
            expect(!transaction.turn(a.id, into: Disc(CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10))), "its frame isn't finite")
            expect(transaction.turn(a.id, into: Box(CGRect(x: 0, y: 0, width: 10, height: 10))), "it's a box like that already")
            expectEqual(transaction.refusedShapes, [])
        }
        expectEqual(h.file, before)
        expectEqual(log.changes.count, 0, "nothing was committed")
        expect(!h.editor.canUndo, "and no step was made")
    },
    test("a read-only shape isn't turned, nor is one in a read-only container; services hear them refused, and the rest of the transaction stands") {
        let k = ShapeID(), b = ShapeID(), c = ShapeID(), log = ChangeLog(), refusals = RefusalLog()
        let h = try harness(CanvasFile(root: board(corral(k, CGRect(x: 0, y: 0, width: 300, height: 200)), box(b, x: 20, y: 20, in: k),
                                                   box(c, x: 400))), log, refusals)
        h.editor.freeze([c])
        let frozen = h.file, commits = log.changes.count
        var turned: [Bool] = []
        h.editor.transact("Turn") { transaction in
            turned.append(transaction.turn(c, into: Disc(CGRect(x: 400, y: 0, width: 40, height: 30))))
            expectEqual(transaction.refusedShapes, [c])
            turned.append(transaction.turn(b, into: Disc(CGRect(x: 20, y: 20, width: 40, height: 30))))
            expectEqual(transaction.refusedShapes, [c])
        }
        expectEqual(turned, [false, true], "the locked box stays; the other, in a corral that isn't locked, is turned")
        expectEqual(refusals.refusals, [[c]])
        expectEqual(h.editor.document[b]?.kind, Disc.kind)
        expectEqual(h.file.record(c), frozen.record(c))

        h.editor.freeze([k])
        let held = h.file
        h.editor.transact("Turn") { transaction in
            expect(!transaction.turn(b, into: Box(CGRect(x: 20, y: 20, width: 40, height: 30))), "in a locked corral")
            expect(!transaction.turn(k, into: Pocket(unit)), "a locked corral")
            expectEqual(transaction.refusedShapes, [b, k])
        }
        expectEqual(refusals.refusals, [[c], [b, k]])
        expectEqual(h.file, held)
        expectEqual(log.changes.count, commits + 2, "the turn and the lock are commits; the refused turns aren't")
    },
    test("a shape the same transaction added isn't held, however it's turned") {
        let a = ShapeID(), refusals = RefusalLog()
        let h = try harness(CanvasFile(), ChangeLog(), refusals)
        h.editor.transact { transaction in
            var frozen = box(a)
            frozen[Frozen.self] = true
            transaction.insert(frozen)
            expect(transaction.turn(a, into: Disc(unit)))
        }
        expectEqual(h.editor.document[a]?.kind, Disc.kind)
        expectEqual(refusals.refusals, [])
    },
    test("turning the shape being edited ends its editing, as its editing view is its old kind's; a change that keeps its kind doesn't") {
        let card = ShapeID()
        let h = try EditorHarness(plugins: [FixturesPlugin(), CardsPlugin()],
                                  file: CanvasFile(root: board(AnyShapeRecord(ShapeRecord(id: card, Card(CGRect(x: 0, y: 0, width: 100, height: 60)))))))
        expect(h.editor.beginEditing(card))
        h.editor.transact { $0.update(card, as: Card.self) { $0.props.frame.origin.x = 10 } }
        expectEqual(h.editor.editingShapeID, card, "still a card: still edited")
        h.editor.transact { $0.turn(card, into: Box(CGRect(x: 10, y: 0, width: 100, height: 60))) }
        expectEqual(h.editor.editingShapeID, nil)
        expectEqual(h.editor.document[card]?.kind, Box.kind)
    },
])

@MainActor let movingToBoardTests = Suite("Moving shapes onto the board below", [
    test("shapes move onto a board the owner didn't have, under their ids, in their order, where they were; the commit says so, and so does undo") {
        let p = ShapeID(), a = ShapeID(), b = ShapeID(), c = ShapeID(), d = ShapeID(), log = ChangeLog()
        let h = try harness(CanvasFile(root: board(pocket(p), box(a, x: 0), box(b, x: 100), box(c, x: 200), box(d, x: 300))), log)
        let before = h.file, pBoard = BoardID(owner: p)
        let moved = h.editor.transact("Move") { transaction -> Bool in
            let moved = transaction.move([c, a], toBoardOwnedBy: p)
            expectEqual(ids(transaction.contents(ofBoardOwnedBy: p)), [a, c], "the transaction sees them there")
            expectEqual(transaction.document[a], nil)
            expectEqual(Set(transaction.shapes.reading?.changes ?? []), [a, c], "a shape that went to another board is a write, as the set has it")
            return moved
        }
        expect(moved)
        expectEqual(ids(h.editor.document), [p, b, d])
        expectEqual(ids(h.file[pBoard]), [a, c], "in the order they were, not the order asked for")
        expectEqual(h.file.record(a)?.box, before.record(a)?.box, "where they were")
        expectEqual(h.file.record(c)?.box, before.record(c)?.box)
        expectEqual(h.file.board(containing: c), pBoard)
        expectEqual(h.file.record(p), before.record(p), "the owner isn't changed")
        let keys = h.file[pBoard].shapes.compactMap(\.stackingKey)
        expect(keys.count == 2 && keys[0] < keys[1], "on keys of their own, rising")
        let change = try require(log.changes.last)
        expectEqual(change.removed, [a, c])
        expectEqual(change.boardsAdded, [pBoard])
        expectEqual(change.elsewhere, [a, c])
        expect(change.added.isEmpty && change.changed.isEmpty && change.boardsChanged.isEmpty && change.boardsRemoved.isEmpty)
        expect(change.reordered)
        let after = h.file
        expectEqual(h.editor.undoHistory.undoName, "Move")

        h.editor.undo()
        try expectFile(h, before, "every shape where it was")
        expectEqual(log.changes.last?.added, [a, c])
        expectEqual(log.changes.last?.boardsRemoved, [pBoard], "the board the move made goes")
        expectEqual(log.changes.last?.elsewhere, [a, c])
        h.editor.redo()
        try expectFile(h, after, "and on the board again")
        expectEqual(log.changes.last?.removed, [a, c])
        expectEqual(log.changes.last?.boardsAdded, [pBoard])
    },
    test("a container moves with what it holds, at any depth; a shape stays in a container that moves with it, and is in none there otherwise") {
        let p = ShapeID(), k = ShapeID(), a = ShapeID(), l = ShapeID(), b = ShapeID(), c = ShapeID()
        let h = try harness(CanvasFile(root: board(pocket(p), corral(k, CGRect(x: 0, y: 200, width: 600, height: 400)), box(a, x: 20, y: 220, in: k),
                                                   corral(l, CGRect(x: 100, y: 250, width: 300, height: 200), in: k),
                                                   box(b, x: 120, y: 270, in: l), box(c, x: 800))))
        let before = h.file, pBoard = BoardID(owner: p), kinds = h.editor.registry.containingKinds

        h.editor.transact("Move") { $0.move([k], toBoardOwnedBy: p) }
        expectEqual(ids(h.editor.document), [p, c])
        expectEqual(ids(h.file[pBoard]), [k, a, l, b], "the corral, and what it holds, at any depth")
        let moved = h.file[pBoard]
        expectEqual(moved.shapes.map(\.container), [nil, k, k, l])
        expectEqual(moved.contents(of: k, containingKinds: kinds), [a, l])
        h.editor.undo()
        try expectFile(h, before, "all of it in the corral again")

        h.editor.transact("Move") { $0.move([b, a], toBoardOwnedBy: p) }
        expectEqual(ids(h.file[pBoard]), [a, b])
        expectEqual(h.file[pBoard].shapes.map(\.container), [nil, nil], "their corrals stay")
        expectEqual(h.editor.document.contents(of: k, containingKinds: kinds), [l])
        expectEqual(h.editor.document.contents(of: l, containingKinds: kinds), [])
        h.editor.undo()
        try expectFile(h, before, "and in them again")

        h.editor.transact("Move") { $0.move([l], toBoardOwnedBy: p) }
        expectEqual(ids(h.file[pBoard]), [l, b], "a nested corral takes what it holds")
        expectEqual(h.file[pBoard].shapes.map(\.container), [nil, l], "but isn't in the one it was in")
        expectEqual(h.editor.holder(of: a), k)
    },
    test("a pocket that moves takes its board along: what's on it stays there, and it's under the board it moved onto") {
        let p = ShapeID(), q = ShapeID(), d = ShapeID(), a = ShapeID(), log = ChangeLog()
        let h = try harness(CanvasFile(root: board(pocket(p), pocket(q, CGRect(x: 200, y: 0, width: 100, height: 100)), box(a)),
                                       children: [q: board(box(d))]), log)
        let before = h.file, pBoard = BoardID(owner: p), qBoard = BoardID(owner: q)
        h.editor.transact("Move") { $0.move([q], toBoardOwnedBy: p) }
        expectEqual(h.file.board(containing: q), pBoard)
        expectEqual(h.file[qBoard], before[qBoard], "its board is as it was")
        expectEqual(h.file.board(containing: d), qBoard)
        expectEqual(h.file.path(to: qBoard), [.root, pBoard, qBoard])
        let change = try require(log.changes.last)
        expectEqual(change.removed, [q])
        expectEqual(change.boardsAdded, [pBoard], "the board it owns isn't one the commit reached")
        expectEqual(change.elsewhere, [q])
        expect(h.enter(p) && h.enter(q))
        expectEqual(ids(h.editor.document), [d])
        h.editor.undo()
        try expectFile(h, before, "the pocket on the root, with its board")
        expectEqual(h.file.board(containing: q), .root)
    },
    test("onto a board that holds shapes already, they go above them, and the commit says the board changed") {
        let p = ShapeID(), x = ShapeID(), y = ShapeID(), a = ShapeID(), b = ShapeID(), log = ChangeLog()
        let h = try harness(CanvasFile(root: board(pocket(p), box(a, x: 0), box(b, x: 100)),
                                       children: [p: board(box(x, x: 300), box(y, x: 400))]), log)
        let before = h.file, pBoard = BoardID(owner: p), revision = h.file.revision(of: pBoard)
        h.editor.transact("Move") { $0.move([a, b], toBoardOwnedBy: p) }
        expectEqual(ids(h.file[pBoard]), [x, y, a, b], "on top, in their order")
        expectEqual(h.file[pBoard][x], before[pBoard][x], "what it held is as it was")
        expectEqual(h.file[pBoard][y], before[pBoard][y])
        let keys = h.file[pBoard].shapes.compactMap(\.stackingKey)
        expect(keys.count == 4 && keys == keys.sorted(), "on keys that rise")
        expect(h.file.revision(of: pBoard) > revision)
        expectEqual(h.file.board(containing: a), pBoard)
        expectEqual(h.file.board(containing: x), pBoard)
        let change = try require(log.changes.last)
        expectEqual(change.boardsChanged, [pBoard])
        expectEqual(change.boardsAdded, [])
        expectEqual(change.boardsRemoved, [])
        expectEqual(change.removed, [a, b])
        expectEqual(change.elsewhere, [a, b], "only what came")
        let after = h.file

        h.editor.undo()
        try expectFile(h, before, "the board as it was")
        expectEqual(log.changes.last?.boardsChanged, [pBoard])
        expectEqual(log.changes.last?.added, [a, b])
        h.editor.redo()
        try expectFile(h, after, "and with them again")
    },
    test("a binding between shapes that move is kept; one across the edge lets go of that end, whichever way, locked or not") {
        let p = ShapeID(), a = ShapeID(), b = ShapeID(), c = ShapeID(), l1 = ShapeID(), l2 = ShapeID(), l3 = ShapeID(), refusals = RefusalLog()
        let h = try harness(CanvasFile(root: board(pocket(p), box(a), box(b, x: 100), box(c, x: 200),
                                                   link(l1, a, b), link(l2, a, c), link(l3, c, b))), ChangeLog(), refusals)
        h.editor.freeze([l2])
        let before = h.file, pBoard = BoardID(owner: p)
        h.editor.transact("Move") { $0.move([a, b, l1, l3], toBoardOwnedBy: p) }
        expectEqual(h.file.board(containing: l1), pBoard)
        expectEqual(h.file.board(containing: l2), .root)
        expectEqual(props(h, l1, as: Link.self), Link(from: a, to: b), "between two that move")
        expectEqual(props(h, l3, as: Link.self), Link(from: nil, to: b), "a link that moves lets go of what stays")
        expectEqual(props(h, l2, as: Link.self), Link(from: nil, to: c), "and one that stays of what moves, though it's locked")
        expectEqual(refusals.refusals, [], "which is no refusal")
        h.editor.undo()
        try expectFile(h, before, "every end as it was")
    },
    test("a name of a shape, a mention, is kept whichever way it goes: of one that moves or one that stays, in a shape that moves or one that stays") {
        let p = ShapeID(), a = ShapeID(), c = ShapeID(), m1 = ShapeID(), m2 = ShapeID(), n = ShapeID(), t = ShapeID()
        let h = try harness(CanvasFile(root: board(pocket(p), box(a), box(c, x: 200),
                                                   AnyShapeRecord(ShapeRecord(id: m1, Memo(lead: Citation(a)))),
                                                   AnyShapeRecord(ShapeRecord(id: m2, Memo(lead: Citation(c)))),
                                                   AnyShapeRecord(ShapeRecord(id: n, CitingTag(target: a, cite: Citation(a)))),
                                                   AnyShapeRecord(ShapeRecord(id: t, CitingTag(target: nil, cite: Citation(a)))))))
        let before = h.file, pBoard = BoardID(owner: p)
        h.editor.transact("Move") { $0.move([a, m2], toBoardOwnedBy: p) }
        expectEqual(h.file.board(containing: m1), .root)
        expectEqual(h.file.board(containing: m2), pBoard)
        expectEqual(props(h, m1, as: Memo.self)?.lead, Citation(a), "it stays, and its shape is on another board")
        expectEqual(props(h, m2, as: Memo.self)?.lead, Citation(c), "it moves, and its shape stays")
        expectEqual(h.file.board(containing: n), pBoard, "a tag bound only to what moves moves with it")
        expectEqual(props(h, n, as: CitingTag.self), CitingTag(target: a, cite: Citation(a)), "bound still, and what it names isn't touched")
        expectEqual(h.file.board(containing: t), .root, "a tag bound to nothing stays")
        expectEqual(props(h, t, as: CitingTag.self), CitingTag(target: nil, cite: Citation(a)), "and what it names, on another board now, is kept")
        h.editor.undo()
        try expectFile(h, before, "as they were")
    },
    test("a read-only shape among those that move, or in a container among them, or the owner, refuses all: nothing moves, and services hear which") {
        let p = ShapeID(), a = ShapeID(), f = ShapeID(), k = ShapeID(), b = ShapeID(), log = ChangeLog(), refusals = RefusalLog()
        let h = try harness(CanvasFile(root: board(pocket(p), box(a), box(f, x: 100), corral(k, CGRect(x: 0, y: 200, width: 400, height: 300)),
                                                   box(b, x: 20, y: 220, in: k))), log, refusals)
        @MainActor func attempt(_ ids: Set<ShapeID>) -> (moved: Bool, refused: Set<ShapeID>) {
            var result = (moved: true, refused: Set<ShapeID>())
            h.editor.transact("Move") { transaction in
                result.moved = transaction.move(ids, toBoardOwnedBy: p)
                result.refused = transaction.refusedShapes
            }
            return result
        }
        h.editor.freeze([f])
        var held = h.file, commits = log.changes.count
        var result = attempt([a, f])
        expect(!result.moved)
        expectEqual(result.refused, [f], "a locked shape among them")
        expectEqual(refusals.refusals, [[f]])

        h.editor.freeze([f], false)
        h.editor.freeze([b])
        held = h.file
        commits = log.changes.count
        result = attempt([a, k])
        expect(!result.moved)
        expectEqual(result.refused, [b], "a locked shape in a corral among them")
        result = attempt([b])
        expectEqual(result.refused, [b], "in the corral that stays: held there")
        expectEqual(h.file, held)

        h.editor.freeze([b], false)
        h.editor.freeze([k])
        held = h.file
        result = attempt([k, a])
        expect(!result.moved)
        expectEqual(result.refused, [k, b], "a locked corral among them, and what it holds")
        expectEqual(h.file, held)

        h.editor.freeze([k], false)
        h.editor.freeze([p])
        held = h.file
        result = attempt([a])
        expect(!result.moved)
        expectEqual(result.refused, [p], "a locked owner takes nothing")
        expectEqual(h.file, held)
        expectEqual(refusals.refusals.last, [p])
        expect(h.file.board(containing: a) == .root && h.file.children.isEmpty, "no board was made")

        h.editor.freeze([p], false)
        result = attempt([a])
        expect(result.moved, "and unlocked it takes them")
        expectEqual(result.refused, [])
        expect(commits < log.changes.count)
    },
    test("a shape added earlier in the same transaction lands on the board, and was never on this one") {
        let p = ShapeID(), n = ShapeID(), log = ChangeLog()
        let h = try harness(CanvasFile(root: board(pocket(p))), log)
        let before = h.file, pBoard = BoardID(owner: p)
        h.editor.transact("Move") { transaction in
            transaction.insert(box(n, x: 5))
            expect(transaction.move([n], toBoardOwnedBy: p))
            expectEqual(transaction.document[n], nil)
            expectEqual(ids(transaction.contents(ofBoardOwnedBy: p)), [n])
        }
        let change = try require(log.changes.last)
        expectEqual(change.added, [])
        expectEqual(change.removed, [])
        expectEqual(change.boardsAdded, [pBoard])
        expectEqual(change.elsewhere, [n])
        expectEqual(h.file.board(containing: n), pBoard)
        let after = h.file
        h.editor.undo()
        try expectFile(h, before, "never there")
        h.editor.redo()
        try expectFile(h, after, "and there again")
    },
    test("a corral turned into a pocket and its contents moved onto its board, in one transaction, is a frame into a subboard; undo and redo keep every id") {
        let z = ShapeID(), k = ShapeID(), a = ShapeID(), l = ShapeID(), b = ShapeID(), c = ShapeID(), i = ShapeID(), o = ShapeID()
        let log = ChangeLog(), kBoard = BoardID(owner: k)
        let h = try harness(CanvasFile(root: board(box(z, x: 900), corral(k, CGRect(x: 100, y: 100, width: 400, height: 300)),
                                                   box(a, x: 120, y: 120, in: k), corral(l, CGRect(x: 200, y: 200, width: 200, height: 150), in: k),
                                                   box(b, x: 220, y: 220, in: l), box(c, x: 600), link(i, a, b), link(o, a, c))), log)
        h.editor.transact { $0.update(k) { $0[Stars.self] = 5 } }
        let before = h.file
        h.editor.transact("Turn into Pocket") { transaction in
            let origin = transaction.document[k]?.box?.origin ?? .zero
            transaction.turn(k, into: Pocket(CGRect(origin: origin, size: CGSize(width: 240, height: 160))))
            transaction.move([a, l, b, i], toBoardOwnedBy: k)
        }
        let record = try require(h.file.record(k))
        expectEqual(record.kind, Pocket.kind)
        expectEqual(record.box, CGRect(x: 100, y: 100, width: 240, height: 160))
        expectEqual(record[Stars.self], 5)
        expectEqual(ids(h.editor.document), [z, k, c, o])
        expectEqual(ids(h.file[kBoard]), [a, l, b, i])
        expectEqual(h.file[kBoard].shapes.map(\.container), [nil, nil, l, nil])
        expectEqual(props(h, i, as: Link.self), Link(from: a, to: b), "a link between what moved rode along")
        expectEqual(props(h, o, as: Link.self), Link(from: nil, to: c), "one across the edge let go of its end")
        let change = try require(log.changes.last)
        expectEqual(change.changed, [k, o], "the pocket, and the link that let go of an end")
        expectEqual(change.removed, [a, l, b, i])
        expectEqual(change.added, [])
        expectEqual(change.boardsAdded, [kBoard])
        expectEqual(change.elsewhere, [a, l, b, i])
        expectEqual(h.editor.undoHistory.undoName, "Turn into Pocket")
        let after = h.file

        h.editor.undo()
        try expectFile(h, before, "the corral, and everything in it")
        for id in [z, k, a, l, b, c, i, o] { expectEqual(h.file.board(containing: id), .root) }
        expectEqual(h.editor.document[k]?.kind, Corral.kind)
        expectEqual(h.editor.holder(of: b), l)
        h.editor.redo()
        try expectFile(h, after, "and the pocket again")
        expect(h.enter(k))
        expectEqual(ids(h.editor.document), [a, l, b, i])
        expectEqual(h.editor.holder(of: b), l)
    },
    test("nested corrals turned into pockets innermost first, each with its contents moved: the inner pocket moves with the board it just made") {
        let k = ShapeID(), a = ShapeID(), l = ShapeID(), b = ShapeID(), c = ShapeID(), z = ShapeID(), log = ChangeLog()
        let kBoard = BoardID(owner: k), lBoard = BoardID(owner: l)
        let h = try harness(CanvasFile(root: board(box(z, x: 900), corral(k, CGRect(x: 0, y: 0, width: 600, height: 400)), box(a, x: 20, y: 20, in: k),
                                                   corral(l, CGRect(x: 100, y: 100, width: 300, height: 200), in: k),
                                                   box(b, x: 120, y: 120, in: l), box(c, x: 200, y: 120, in: l))), log)
        let before = h.file
        h.editor.transact("Turn into Pocket") { transaction in
            transaction.turn(l, into: Pocket(CGRect(x: 100, y: 100, width: 240, height: 160)))
            transaction.move([b, c], toBoardOwnedBy: l)
            transaction.turn(k, into: Pocket(CGRect(x: 0, y: 0, width: 240, height: 160)))
            transaction.move([a, l], toBoardOwnedBy: k)
        }
        expectEqual(ids(h.editor.document), [z, k])
        expectEqual(ids(h.file[kBoard]), [a, l])
        expectEqual(ids(h.file[lBoard]), [b, c])
        expectEqual(h.file.board(containing: l), kBoard)
        expectEqual(h.file.board(containing: b), lBoard)
        expectEqual(h.file.path(to: lBoard), [.root, kBoard, lBoard])
        expectEqual(h.file[kBoard].shapes.map(\.container), [nil, nil], "the pocket isn't in the pocket it moved onto")
        let change = try require(log.changes.last)
        expectEqual(change.changed, [k])
        expectEqual(change.removed, [a, l, b, c])
        expectEqual(change.boardsAdded, [kBoard, lBoard])
        expectEqual(change.elsewhere, [a, l, b, c])
        let after = h.file
        h.editor.undo()
        try expectFile(h, before, "both corrals, and everything in them")
        for id in [z, k, a, l, b, c] { expectEqual(h.file.board(containing: id), .root) }
        h.editor.redo()
        try expectFile(h, after, "both pockets")
        expect(h.enter(k) && h.enter(l))
        expectEqual(ids(h.editor.document), [b, c])
    },
    test("two moves in one transaction onto one board are one commit: the board is made, or changed, once") {
        let p = ShapeID(), x = ShapeID(), a = ShapeID(), b = ShapeID(), c = ShapeID(), log = ChangeLog()
        let pBoard = BoardID(owner: p)
        let h = try harness(CanvasFile(root: board(pocket(p), box(a), box(b, x: 100), box(c, x: 200))), log)
        let before = h.file
        h.editor.transact("Move") { transaction in
            transaction.move([c], toBoardOwnedBy: p)
            transaction.move([a], toBoardOwnedBy: p)
        }
        expectEqual(ids(h.file[pBoard]), [c, a], "in the order they moved")
        expectEqual(log.changes.last?.boardsAdded, [pBoard])
        expectEqual(log.changes.last?.boardsChanged, [])
        h.editor.undo()
        try expectFile(h, before, "one step")

        let held = try harness(CanvasFile(root: board(pocket(p), box(a), box(b, x: 100), box(c, x: 200)), children: [p: board(box(x, x: 300))]), log)
        let first = held.file
        held.editor.transact("Move") { transaction in
            transaction.move([c], toBoardOwnedBy: p)
            transaction.move([a], toBoardOwnedBy: p)
        }
        expectEqual(ids(held.file[pBoard]), [x, c, a])
        expectEqual(log.changes.last?.boardsChanged, [pBoard])
        expectEqual(log.changes.last?.boardsAdded, [])
        expectEqual(log.changes.last?.elsewhere, [c, a])
        held.editor.undo()
        try expectFile(held, first, "one step")
    },
    test("a transaction on a board that isn't shown moves shapes onto the board below it: a step of its own on that board") {
        let p = ShapeID(), q = ShapeID(), a = ShapeID(), b = ShapeID(), c = ShapeID(), log = ChangeLog()
        let pBoard = BoardID(owner: p), qBoard = BoardID(owner: q)
        let h = try harness(CanvasFile(root: board(pocket(p)), children: [p: board(pocket(q), box(a), box(b, x: 100))]), log)
        let before = h.file, shown = h.editor.document
        let moved = h.editor.transact(on: pBoard, "Move") { $0.move([a], toBoardOwnedBy: q) }
        expectEqual(moved, true)
        expectEqual(h.editor.board, .root)
        expectEqual(h.editor.document, shown, "the board shown is as it was")
        expectEqual(ids(h.file[pBoard]), [q, b])
        expectEqual(ids(h.file[qBoard]), [a])
        let change = try require(log.changes.last)
        expectEqual(change.shapeIDs, [])
        expectEqual(change.boardsChanged, [pBoard])
        expectEqual(change.boardsAdded, [qBoard])
        expectEqual(change.elsewhere, [a])
        let after = h.file
        expectEqual(h.editor.undoHistory.undoName, "Move")
        h.editor.undo()
        expectEqual(h.editor.board, pBoard, "its board is shown for the step")
        try expectFile(h, before, "A back on P's board")
        h.editor.redo()
        try expectFile(h, after, "and on Q's")

        // Onto a board that holds shapes already: both boards changed.
        let tree = CanvasFile(root: board(pocket(p)), children: [p: board(pocket(q), box(a)), q: board(box(c))])
        let again = try harness(tree, log)
        again.editor.transact(on: pBoard, "Move") { $0.move([a], toBoardOwnedBy: q) }
        expectEqual(ids(again.file[qBoard]), [c, a])
        expectEqual(log.changes.last?.boardsChanged, [pBoard, qBoard])
        expectEqual(log.changes.last?.boardsAdded, [])
        expectEqual(log.changes.last?.elsewhere, [a])
    },
    test("a transaction on a board that isn't shown commits nothing if it reaches the board shown: its document would go stale") {
        let p = ShapeID(), q = ShapeID(), a = ShapeID(), x = ShapeID(), log = ChangeLog()
        let pBoard = BoardID(owner: p), qBoard = BoardID(owner: q)
        let h = try harness(CanvasFile(root: board(pocket(p), box(x)), children: [p: board(pocket(q), box(a))]), log)
        let before = h.file
        expect(h.enter(p) && h.enter(q))
        expectEqual(h.editor.board, qBoard)
        let heard = log.changes.count
        let moved = h.editor.transact(on: pBoard, "Move") { $0.move([a], toBoardOwnedBy: q) }
        expectEqual(moved, true, "the body's result comes back")
        expectEqual(h.file, before, "onto the board shown")
        expect(!h.editor.canUndo)

        expect(h.enter(p))
        let above = h.editor.transact(on: .root, "Move") { $0.move([x], toBoardOwnedBy: p) }
        expectEqual(above, true)
        expectEqual(h.file, before, "onto the board shown, from the board above it")
        expectEqual(log.changes.count, heard + 1, "services heard the board shown, and nothing else")
        expect(!h.editor.canUndo)
    },
    test("ids not on the board are passed over, and with nothing to move nothing changes") {
        let p = ShapeID(), x = ShapeID(), a = ShapeID(), log = ChangeLog()
        let h = try harness(CanvasFile(root: board(pocket(p), box(a)), children: [p: board(box(x))]), log)
        let before = h.file, pBoard = BoardID(owner: p)
        h.editor.transact { transaction in
            expect(transaction.move([ShapeID(), x], toBoardOwnedBy: p), "x is on P's board, not this one")
            expect(transaction.move([], toBoardOwnedBy: p))
            expectEqual(transaction.contents(ofBoardOwnedBy: p), before[pBoard])
        }
        expectEqual(h.file, before)
        expectEqual(log.changes.count, 0)
        expect(!h.editor.canUndo)
        h.editor.transact { $0.move([ShapeID(), a], toBoardOwnedBy: p) }
        expectEqual(ids(h.file[pBoard]), [x, a], "the one that's there goes")
    },
    test("onto a shape that owns no board, or isn't on the board, nothing moves, nothing is refused, and it says false") {
        let a = ShapeID(), b = ShapeID(), log = ChangeLog(), refusals = RefusalLog()
        let h = try harness(CanvasFile(root: board(box(a), box(b, x: 100))), log, refusals)
        let before = h.file, commits = log.changes.count
        h.editor.transact("Move In") { transaction in
            expect(!transaction.move([a], toBoardOwnedBy: b), "a box owns no board")
            expect(!transaction.move([a], toBoardOwnedBy: ShapeID()), "nor does a shape on no board")
            expectEqual(transaction.refusedShapes, [])
        }
        try expectFile(h, before, "nothing moved")
        expectEqual(log.changes.count, commits, "nothing committed")
        expectEqual(refusals.refusals, [])
        expectEqual(h.editor.undoHistory.undoName, nil)
    },
])
