@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import TestKit

// The editor holds every board of a file and edits the one it shows (the root, here): deleting a
// shape takes the boards under it in the same commit, and a shape can go in with its boards.

private let frame = CGRect(x: 0, y: 0, width: 100, height: 100)

private func box(_ id: ShapeID = ShapeID()) -> AnyShapeRecord { AnyShapeRecord(ShapeRecord(id: id, Box(frame))) }
private func pocket(_ id: ShapeID = ShapeID(), frame: CGRect = frame) -> AnyShapeRecord {
    AnyShapeRecord(ShapeRecord(id: id, Pocket(frame)))
}
private func board(_ records: AnyShapeRecord...) -> CanvasDocument { CanvasDocument(shapes: records) }
private func ids(_ document: CanvasDocument) -> [ShapeID] { document.shapes.map(\.id) }

/// A root holding box A and pocket P; P's board holds box B and pocket Q; Q's holds box C and
/// pocket R; R's holds box D. Three levels of boards under P.
private struct Nest {
    let a = ShapeID(), p = ShapeID(), b = ShapeID(), q = ShapeID(), c = ShapeID(), r = ShapeID(), d = ShapeID()
    var file: CanvasFile {
        CanvasFile(root: board(box(a), pocket(p)),
                   children: [p: board(box(b), pocket(q)), q: board(box(c), pocket(r)), r: board(box(d))])
    }
    var boards: Set<BoardID> { [BoardID(owner: p), BoardID(owner: q), BoardID(owner: r)] }
}

@MainActor private func harness(_ file: CanvasFile, _ more: [any CanvasPlugin] = []) throws -> EditorHarness {
    try EditorHarness(plugins: [FixturesPlugin(), PocketsPlugin()] + more, file: file)
}

/// A session that notes it was cancelled, and answers `answer`.
private final class NotingSession {
    var cancelled = 0
    let answer: Bool
    init(answer: Bool) { self.answer = answer }
}

extension NotingSession: Session {
    func drag(_ pointer: Pointer, in editor: CanvasEditor) {}
    func cancel(in editor: CanvasEditor) -> Bool {
        cancelled += 1
        return answer
    }
}

/// A press that, cancelled, puts a box back where it was, in a transaction, as a drag's does.
private final class RestoringSession {
    let id: ShapeID
    init(id: ShapeID) { self.id = id }
}

extension RestoringSession: Session {
    func drag(_ pointer: Pointer, in editor: CanvasEditor) {}
    func cancel(in editor: CanvasEditor) -> Bool {
        editor.transact { $0.update(id, as: Box.self) { $0.frame.origin = .zero } }
        return true
    }
}

private func uuid(_ n: Int) -> String { String(format: "00000000-0000-0000-0000-%012d", n) }
private func id(_ n: Int) -> ShapeID { ShapeID(UUID(uuidString: uuid(n))!) }

@MainActor let cascadeTests = Suite("Boards under a shape", [
    test("an editor holds every board of its file, shows the root, and finds any board's shapes and owner") {
        let nest = Nest()
        let h = try harness(nest.file)
        expectEqual(h.editor.board, .root)
        expectEqual(h.file, nest.file)
        expectEqual(ids(h.editor.document), [nest.a, nest.p])
        expectEqual(ids(h.editor.contents(of: .root)), [nest.a, nest.p])
        expectEqual(ids(h.editor.contents(of: BoardID(owner: nest.q))), [nest.c, nest.r])
        expectEqual(h.editor.contents(of: BoardID(owner: nest.a)), CanvasDocument(), "a board with no shapes is empty")
        expectEqual(h.editor.owner(of: BoardID(owner: nest.r))?.id, nest.r)
        expectEqual(h.editor.owner(of: .root), nil)
        expectEqual(h.editor.owner(of: BoardID(owner: ShapeID())), nil)
        h.editor.transact { expectEqual($0.board, .root) }
    },
    test("an editor fills in defaults on every board, and a board's own document makes a file of it alone") {
        let nest = Nest()
        let stars = Contributor(id: "stars") { r in
            r.declare(Stars.self)
            r.optIn(Box.self, to: Stars.self)
        }
        let h = try harness(nest.file, [stars])
        expectEqual(h.file.record(nest.d)?[Stars.self], 0, "deep down too")
        expectEqual(h.file.record(nest.a)?[Stars.self], 0)
        let alone = try EditorHarness(plugins: [FixturesPlugin(), PocketsPlugin()], document: board(box(), pocket()))
        expectEqual(alone.file.children, [:])
        expectEqual(alone.file.root, alone.editor.document)
    },
    test("a commit writes the shown board through to the file, and moves only the shapes it names") {
        let nest = Nest()
        let h = try harness(nest.file)
        let before = h.file.revision(of: .root), inside = h.file.revision(of: BoardID(owner: nest.q))
        let e = h.add(Box(frame))
        h.editor.transact { $0.update(nest.a, as: Box.self) { $0.frame.origin.x = 50 } }
        expectEqual(h.file.root, h.editor.document)
        expectEqual(h.file.board(containing: e), .root)
        expectEqual(h.file.record(nest.a)?.box?.minX, 50)
        expect(h.file.revision(of: .root) > before)
        expectEqual(h.file.revision(of: BoardID(owner: nest.q)), inside, "a board the commit didn't touch keeps its revision")
        expectEqual(h.file.shapeCount, 8)
    },
    test("deleting a shape takes the board it owns, and every board under that, in the same commit") {
        let nest = Nest(), log = ChangeLog(), commits = StepCount()
        let h = try harness(nest.file, [recordingChanges(log)])
        h.editor.undoHistory.didChange = { if $0 == .began { commits.count += 1 } }
        let deep = h.file[BoardID(owner: nest.r)]
        h.editor.transact { $0.delete([nest.p]) }
        expectEqual(commits.count, 1, "one step")
        expectEqual(log.changes.last?.removed, [nest.p])
        expectEqual(log.changes.last?.boardsRemoved, nest.boards)
        expectEqual(log.changes.last?.boardsAdded, [])
        expectEqual(h.file.children, [:])
        expectEqual(h.file.shapeCount, 1)
        for id in [nest.b, nest.q, nest.c, nest.r, nest.d] { expectEqual(h.file.board(containing: id), nil) }
        expectEqual(h.editor.undoHistory.undoName, nil, "unnamed, but a step that holds the boards it took")
        h.editor.undo()
        expectEqual(h.file[BoardID(owner: nest.r)], deep, "back, every id as it was")
        h.editor.redo()
        expect(h.file.revision(of: BoardID(owner: nest.r)) > 0, "a removed board's revision doesn't go back to one it had")

        h.editor.transact { $0.delete([nest.a]) }
        expectEqual(log.changes.last?.boardsRemoved, [], "a shape with no board takes none")
    },
    test("a board goes with its owner however the owner goes: deleted by a plugin's handler too") {
        let nest = Nest(), log = ChangeLog()
        let dependents = Contributor(id: "dependents") { r in
            r.willDelete { ids, tx in if ids.contains(nest.a) { tx.delete([nest.p]) } }
        }
        let h = try harness(nest.file, [dependents, recordingChanges(log)])
        h.editor.transact { $0.delete([nest.a]) }
        expectEqual(log.changes.last?.removed, [nest.a, nest.p])
        expectEqual(log.changes.last?.boardsRemoved, nest.boards)
        expectEqual(h.file.children, [:])
    },
    test("a shape whose board, or a board under it, holds a read-only shape isn't deleted, and services hear it was refused") {
        let nest = Nest(), refusals = RefusalLog()
        let h = try harness(nest.file, [FreezingPlugin(log: refusals)])
        var file = h.file
        var frozen = try require(file.record(nest.d))
        frozen[Frozen.self] = true
        file.set(board(frozen), for: BoardID(owner: nest.r))
        h.editor.replaceFile(with: file)

        h.editor.transact { $0.delete([nest.p, nest.a]) }
        expectEqual(ids(h.editor.document), [nest.p], "the rest of the delete stands")
        expectEqual(h.file.children.count, 3, "and every board under P stays")
        expectEqual(refusals.refusals, [[nest.p]])

        // A read-only shape's board is only read when a plugin has read-only rules at all.
        let free = try harness(nest.file)
        free.editor.transact { $0.delete([nest.p]) }
        expectEqual(free.file.children, [:])
    },
    test("what a deletion's handlers delete goes, boards and all, whatever read-only shapes the boards hold") {
        let nest = Nest(), refusals = RefusalLog()
        let dependents = Contributor(id: "dependents") { r in
            r.willDelete { ids, tx in if ids.contains(nest.a) { tx.delete([nest.p]) } }
        }
        let h = try harness(nest.file, [FreezingPlugin(log: refusals), dependents])
        var file = h.file
        var frozen = try require(file.record(nest.d))
        frozen[Frozen.self] = true
        file.set(board(frozen), for: BoardID(owner: nest.r))
        h.editor.replaceFile(with: file)

        h.editor.transact { $0.delete([nest.a]) }
        expectEqual(ids(h.editor.document), [], "P went with A, as its dependent")
        expectEqual(h.file.children, [:])
        expectEqual(refusals.refusals, [])
    },
    test("a shape goes in with its board and the boards under it, which the commit adds to the file") {
        let log = ChangeLog()
        let h = try harness(CanvasFile(), [recordingChanges(log)])
        let p = ShapeID(), q = ShapeID(), b = ShapeID(), c = ShapeID()
        let contents = [p: board(box(b), pocket(q)), q: board(box(c))]
        h.editor.transact { tx in
            tx.insert(pocket(p), contents: contents)
            expectEqual(ids(tx.contents(ofBoardOwnedBy: q)), [c], "a transaction sees the boards it brings")
        }
        expectEqual(ids(h.editor.document), [p])
        expectEqual(ids(h.file[BoardID(owner: p)]), [b, q])
        expectEqual(ids(h.file[BoardID(owner: q)]), [c])
        expectEqual(h.file.board(containing: c), BoardID(owner: q))
        expectEqual(log.changes.last?.added, [p])
        expectEqual(log.changes.last?.boardsAdded, [BoardID(owner: p), BoardID(owner: q)])
        h.editor.transact { tx in
            expectEqual(ids(tx.contents(ofBoardOwnedBy: p)), [b, q], "and the file's")
            tx.delete([p])
            expectEqual(tx.contents(ofBoardOwnedBy: p), CanvasDocument(), "none for a board going with its owner")
        }
        expectEqual(h.file.shapeCount, 0)
    },
    test("an insert that's dropped drops its boards, as does deleting the shape in the same transaction") {
        let log = ChangeLog()
        let h = try harness(CanvasFile(), [recordingChanges(log)])
        let p = ShapeID()
        let nowhere = CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10)
        h.editor.transact { $0.insert(pocket(p, frame: nowhere), contents: [p: board(box())]) }
        expectEqual(h.file.shapeCount, 0, "a frame that isn't finite never gets in, nor its board")
        expectEqual(log.changes.count, 0)

        let kept = h.add(Box(frame))
        h.editor.transact { tx in
            tx.insert(pocket(p), contents: [p: board(box())])
            tx.delete([p])
        }
        expectEqual(h.file.shapeCount, 1)
        expectEqual(h.file.children, [:])
        expectEqual(log.changes.last?.boardsAdded, [])
        expectEqual(log.changes.last?.added, [], "added and deleted here: never seen")
        expect(h.editor.document[kept] != nil)
    },
    test("boards in an insert's contents its shape doesn't reach, or whose owner can't go in, are left out") {
        let h = try harness(CanvasFile())
        let p = ShapeID(), q = ShapeID(), stray = ShapeID()
        let nowhere = CGRect(x: 0, y: CGFloat.infinity, width: 10, height: 10)
        let b = ShapeID()
        h.editor.transact {
            $0.insert(pocket(p), contents: [p: board(box(b), pocket(q, frame: nowhere)), q: board(box()), stray: board(box())])
        }
        expectEqual(Set(h.file.children.keys), [p], "Q's frame isn't finite, so neither Q nor its board goes in; nothing reaches the stray")
        expectEqual(ids(h.file[BoardID(owner: p)]), [b])
        expectEqual(h.file.shapeCount, 2)
    },
    test("a shape deleted from the board can go back in, id and all, in the same transaction") {
        let nest = Nest()
        let h = try harness(nest.file)
        h.editor.transact { tx in
            tx.delete([nest.a])
            tx.insert(box(nest.a))
        }
        expectEqual(ids(h.editor.document), [nest.p, nest.a])
        expectEqual(h.file.board(containing: nest.a), .root)
    },
    test("replacing the file stays on the root, restamps every board, fills in defaults, and doesn't edit the file") {
        let nest = Nest(), commits = StepCount()
        let stars = Contributor(id: "stars") { r in
            r.declare(Stars.self)
            r.optIn(Box.self, to: Stars.self)
        }
        let h = try harness(CanvasFile(root: board(box())), [stars])
        h.editor.undoHistory.didChange = { if $0 == .began { commits.count += 1 } }
        let old = h.file.revision(of: .root)
        h.editor.replaceFile(with: nest.file)
        expectEqual(commits.count, 0)
        expect(!h.editor.canUndo, "no step, and none from before")
        expectEqual(h.editor.board, .root)
        expectEqual(ids(h.editor.document), [nest.a, nest.p])
        expectEqual(h.file.record(nest.d)?[Stars.self], 0)
        for board in [BoardID.root] + nest.boards { expect(h.file.revision(of: board) > old) }

        h.editor.replaceDocument(with: board(box(nest.a)))
        expectEqual(h.file.children, [:], "a document alone is a file of one board")
        expectEqual(ids(h.editor.document), [nest.a])
    },
    test("replacing the file cancels a running session, whatever it answers") {
        let h = try harness(CanvasFile())
        for answer in [true, false] {
            let session = NotingSession(answer: answer)
            h.editor.session = session
            h.editor.replaceFile(with: CanvasFile(root: board(box())))
            expectEqual(session.cancelled, 1)
            expect(h.editor.session == nil)
        }
        h.editor.replaceFile(with: CanvasFile())                  // nothing running: nothing to cancel
    },
    test("what the press commits as it's cancelled goes to the file replaced, and doesn't edit the file") {
        let a = ShapeID(), log = ChangeLog(), commits = StepCount()
        let h = try harness(CanvasFile(root: board(box(a))), [recordingChanges(log)])
        h.editor.transact { $0.update(a, as: Box.self) { $0.frame.origin.x = 50 } }
        h.editor.undoHistory.didChange = { if $0 == .began { commits.count += 1 } }
        h.editor.session = RestoringSession(id: a)
        let moved = CanvasFile(root: board(AnyShapeRecord(ShapeRecord(id: a, Box(frame.offsetBy(dx: 300, dy: 0))))))
        let heard = log.changes.count
        h.editor.replaceFile(with: moved)
        expectEqual(log.changes.count, heard + 2, "the press put the box back, then the file came")
        expectEqual(commits.count, 0, "neither is an undo step, so neither edits the file")
        expect(!h.editor.canUndo)
        expectEqual(h.file.record(a)?.box?.minX, 300, "the new file's box")
        expect(h.editor.session == nil)

        h.editor.transact { $0.update(a, as: Box.self) { $0.frame.origin.x = 0 } }
        expectEqual(commits.count, 1, "and then commits edit it again")
    },
    test("discarding what's kept aside deletes it on every board, with the boards it owns, and the boards kept") {
        let pocketKey = "ABCDEF00-0000-0000-0000-000000000002", pocketID = ShapeID(UUID(uuidString: pocketKey)!)
        let json = """
        { "format" : 4, "versions" : { "kinds" : { "box" : 0, "pocket" : 0 } },
          "shapes" : [ { "id" : "\(uuid(1))", "kind" : "gadget", "index" : "a0", "props" : { } },
                       { "id" : "\(pocketKey)", "kind" : "pocket", "index" : "a1", "props" : { "frame" : [[0, 0], [10, 10]] } } ],
          "boards" : {
            "\(uuid(1))" : { "shapes" : [ { "id" : "\(uuid(3))", "kind" : "box", "index" : "a0", "props" : { "frame" : [[0, 0], [1, 1]] } } ] },
            "\(pocketKey)" : { "shapes" : [ { "id" : "\(uuid(4))", "kind" : "gadget", "index" : "a0", "props" : { } },
                                          { "id" : "\(uuid(5))", "kind" : "box", "index" : "a1", "props" : { "frame" : [[0, 0], [1, 1]] } } ] },
            "\(uuid(50))" : { "shapes" : [ { "id" : "\(uuid(6))", "kind" : "box", "index" : "a0", "props" : { "frame" : [[0, 0], [1, 1]] } } ] },
            "nope" : 7
          } }
        """
        let registry = try Registry(plugins: [FixturesPlugin(), PocketsPlugin()])
        let loaded = try BoardCodec(registry: registry).decode(Data(json.utf8))
        expectEqual(Set(loaded.report.keptAside.map(\.id)), [id(1), id(4)])
        expectEqual(Set(loaded.report.keptBoards.map(\.key)), [uuid(1), uuid(50), "nope"])
        let h = try harness(loaded.file)
        let commits = StepCount(), before = h.file
        h.editor.undoHistory.didChange = { if $0 == .began { commits.count += 1 } }
        h.editor.discardKeptAside(shapes: Set(loaded.report.keptAside.map(\.id)), boards: Set(loaded.report.keptBoards.map(\.key)))
        expectEqual(ids(h.editor.document), [pocketID])
        expectEqual(Set(h.file.children.keys), [pocketID], "the gadget's board went with it, and the orphan by its key")
        expectEqual(ids(h.file[BoardID(owner: pocketID)]), [id(5)])
        expectEqual(h.file.unreadableBoards, [:])
        expectEqual(commits.count, 1, "the file is edited")
        expectEqual(h.editor.undoHistory.undoName, "Delete Hidden Shapes")
        let after = h.file, codec = BoardCodec(registry: registry)
        h.editor.undo()
        expectEqual(h.file, before, "every board, and every entry, as it was")
        expectEqual(try codec.encode(h.file), try codec.encode(before))
        h.editor.redo()
        expectEqual(h.file, after)

        h.editor.discardKeptAside(shapes: [pocketID, ShapeID()], boards: [pocketKey.lowercased()])
        expectEqual(commits.count, 1, "nothing kept aside, nor kept: nothing happens")
        expectEqual(h.file.shapeCount, 2)
    },
    test("discarding a board kept unreadable leaves the board that has taken its key since, shown or not") {
        let pocketKey = "ABCDEF00-0000-0000-0000-000000000002", pocketID = ShapeID(UUID(uuidString: pocketKey)!)
        let json = """
        { "format" : 4, "versions" : { "kinds" : { "box" : 0, "pocket" : 0 } },
          "shapes" : [ { "id" : "\(pocketKey)", "kind" : "pocket", "index" : "a0", "props" : { "frame" : [[0, 0], [10, 10]] } } ],
          "boards" : { "\(pocketKey)" : { "shapes" : "nope" } } }
        """
        let registry = try Registry(plugins: [FixturesPlugin(), PocketsPlugin()])
        let loaded = try BoardCodec(registry: registry).decode(Data(json.utf8))
        expectEqual(loaded.report.keptBoards.map(\.key), [pocketKey])
        let pocket = BoardID(owner: pocketID)
        for shown in [true, false] {
            let h = try harness(loaded.file)
            expect(h.editor.showBoard(pocket), "its board reads as empty, and can be shown")
            let box = ShapeID()
            h.editor.transact { $0.insert(ShapeRecord(id: box, Box(CGRect(x: 0, y: 0, width: 10, height: 10)))) }
            expectEqual(h.file.unreadableBoards, [:], "the board took its key")
            if !shown { expect(h.editor.showBoard(.root)) }
            h.editor.discardKeptAside(shapes: [], boards: [pocketKey])
            expectEqual(ids(h.file[pocket]), [box], "a board that can be shown isn't hidden, whatever the report said")
            expectEqual(h.editor.board, shown ? pocket : .root)
        }
    },
    test("discarding a shape kept aside takes its board, whatever read-only shapes it holds") {
        let json = """
        { "format" : 4, "versions" : { "added" : { "frozen" : 0 }, "kinds" : { "box" : 0 } },
          "shapes" : [ { "id" : "\(uuid(1))", "kind" : "gadget", "index" : "a0", "props" : { } } ],
          "boards" : {
            "\(uuid(1))" : { "shapes" : [ { "added" : { "frozen" : true }, "id" : "\(uuid(2))", "kind" : "box", "index" : "a0",
                                           "props" : { "frame" : [[0, 0], [1, 1]] } } ] }
          } }
        """
        let refusals = RefusalLog()
        let registry = try Registry(plugins: [FixturesPlugin(), PocketsPlugin(), FreezingPlugin(log: refusals)])
        let loaded = try BoardCodec(registry: registry).decode(Data(json.utf8))
        let h = try harness(loaded.file, [FreezingPlugin(log: refusals)])
        expect(h.editor.registry.isReadOnly(try require(h.file.record(id(2)))))
        h.editor.discardKeptAside(shapes: [id(1)], boards: [])
        expectEqual(h.file.shapeCount, 0)
        expectEqual(h.file.children, [:])
        expectEqual(refusals.refusals, [])
    },
])

@MainActor private final class StepCount {
    var count = 0
}
