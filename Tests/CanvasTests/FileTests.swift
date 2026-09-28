@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import TestKit

private let frame = CGRect(x: 0, y: 0, width: 100, height: 100)

private func box(_ id: ShapeID = ShapeID()) -> AnyShapeRecord { AnyShapeRecord(ShapeRecord(id: id, Box(frame))) }
private func pocket(_ id: ShapeID) -> AnyShapeRecord { AnyShapeRecord(ShapeRecord(id: id, Pocket(frame))) }
private func board(_ records: AnyShapeRecord...) -> CanvasDocument { CanvasDocument(shapes: records) }

/// A root holding a box, pocket P and an empty pocket R; P's board holds a box and pocket Q, whose
/// board holds a box.
private struct Nest {
    let a = ShapeID(), p = ShapeID(), r = ShapeID(), b = ShapeID(), q = ShapeID(), c = ShapeID()
    var file: CanvasFile {
        CanvasFile(root: board(box(a), pocket(p), pocket(r)),
                   children: [p: board(box(b), pocket(q)), q: board(box(c)), r: board()])
    }
    var pBoard: BoardID { BoardID(owner: p) }
    var qBoard: BoardID { BoardID(owner: q) }
    var rBoard: BoardID { BoardID(owner: r) }
}

/// `count` boards, each holding the owner of the next, from a pocket on the root down; the last
/// holds a box. Its owners, top down.
private func chain(_ count: Int) -> (file: CanvasFile, owners: [ShapeID]) {
    let owners = (0..<count).map { _ in ShapeID() }
    var children: [ShapeID: CanvasDocument] = [:]
    for (i, owner) in owners.enumerated() {
        children[owner] = board(i + 1 < count ? pocket(owners[i + 1]) : box())
    }
    return (CanvasFile(root: board(pocket(owners[0])), children: children), owners)
}

@MainActor let fileTests = Suite("Boards in a file", [
    test("a board is named root or by its owner's id, and written as either") {
        let id = ShapeID()
        expect(BoardID.root.isRoot)
        expect(!BoardID(owner: id).isRoot)
        expectEqual(BoardID.root.description, "root")
        expectEqual(BoardID(owner: id).description, id.rawValue.uuidString)
        expectEqual(BoardID("root"), .root)
        expectEqual(BoardID(id.rawValue.uuidString), BoardID(owner: id))
        expectEqual(BoardID("nope"), nil)
        let written = try JSONEncoder().encode([BoardID.root, BoardID(owner: id)])
        expectEqual(String(decoding: written, as: UTF8.self), "[\"root\",\"\(id.rawValue.uuidString)\"]")
        expectEqual(try JSONDecoder().decode([BoardID].self, from: written), [.root, BoardID(owner: id)])
        expect((try? JSONDecoder().decode([BoardID].self, from: Data("[\"nope\"]".utf8))) == nil, "anything else doesn't read")
    },
    test("a file finds any shape's board and record by its id, and keeps no empty board") {
        let nest = Nest(), file = nest.file
        expectEqual(Set(file.children.keys), [nest.p, nest.q], "R's board is empty, so it isn't kept")
        expectEqual(file[nest.rBoard], CanvasDocument())
        expectEqual(file[.root].shapes.map(\.id), [nest.a, nest.p, nest.r])
        expectEqual(file[nest.qBoard].shapes.map(\.id), [nest.c])
        expectEqual(file.board(containing: nest.a), .root)
        expectEqual(file.board(containing: nest.q), nest.pBoard)
        expectEqual(file.board(containing: nest.c), nest.qBoard)
        expectEqual(file.board(containing: ShapeID()), nil)
        expectEqual(file.record(nest.c)?.kind, Box.kind)
        expectEqual(file.record(nest.q)?.kind, Pocket.kind)
        expectEqual(file.record(ShapeID()), nil)
        expectEqual(file.shapeCount, 6)
    },
    test("a board's parent holds its owner; its path runs from the root, and none reaches an orphan or a cycle") {
        let nest = Nest(), file = nest.file
        expectEqual(file.parent(of: .root), nil)
        expectEqual(file.parent(of: nest.pBoard), .root)
        expectEqual(file.parent(of: nest.qBoard), nest.pBoard)
        expectEqual(file.path(to: .root), [.root])
        expectEqual(file.path(to: nest.qBoard), [.root, nest.pBoard, nest.qBoard])
        expectEqual(file.path(to: nest.rBoard), [.root, nest.rBoard], "an empty board has a path")

        let orphan = ShapeID(), m = ShapeID(), n = ShapeID()
        let odd = CanvasFile(root: board(box()), children: [orphan: board(box()), m: board(pocket(n)), n: board(pocket(m))])
        expectEqual(odd.parent(of: BoardID(owner: orphan)), nil)
        expectEqual(odd.path(to: BoardID(owner: orphan)), nil)
        expectEqual(odd.parent(of: BoardID(owner: m)), BoardID(owner: n))
        expectEqual(odd.path(to: BoardID(owner: m)), nil)
        expectEqual(odd.subtree(ownedBy: [m]), [BoardID(owner: m), BoardID(owner: n)], "a cycle's boards, once each")
    },
    test("the boards under shapes come breadth first, and only boards with shapes") {
        let nest = Nest()
        expectEqual(nest.file.subtree(ownedBy: [nest.a, nest.r, nest.p]), [nest.pBoard, nest.qBoard])
        expectEqual(nest.file.subtree(ownedBy: [nest.q]), [nest.qBoard])
        expectEqual(nest.file.subtree(ownedBy: [nest.a]), [])

        let p1 = ShapeID(), p2 = ShapeID(), p3 = ShapeID(), p4 = ShapeID()
        let wide = CanvasFile(root: board(pocket(p1), pocket(p2)),
                              children: [p1: board(pocket(p3)), p2: board(pocket(p4)), p3: board(box()), p4: board(box())])
        expectEqual(wide.subtree(ownedBy: [p1, p2]), [p1, p2, p3, p4].map { BoardID(owner: $0) })
    },
    test("a chain of 10,000 boards is walked in loops, up and down") {
        let (file, owners) = chain(10_000)
        let last = BoardID(owner: owners[owners.count - 1])
        expectEqual(file.path(to: last)?.count, 10_001)
        expectEqual(file.path(to: last)?.first, .root)
        expectEqual(file.subtree(ownedBy: [owners[0]]).count, 10_000)
        expectEqual(file.shapeCount, 10_001)
    },
    test("shapes' boards follow a board's changes, and a board that empties isn't kept") {
        let nest = Nest()
        var file = nest.file
        let d = ShapeID()
        file.set(board(box(nest.c), box(d)), for: nest.qBoard)
        expectEqual(file.board(containing: d), nest.qBoard)
        expectEqual(file.shapeCount, 7)
        let e = ShapeID()
        file.set(board(box(nest.a), pocket(nest.p), pocket(nest.r), box(e)), for: .root)
        expectEqual(file.board(containing: e), .root)
        expectEqual(file.shapeCount, 8)
        file.set(board(), for: nest.qBoard)
        expectEqual(file.children[nest.q], nil)
        expectEqual(file.board(containing: nest.c), nil)
        expectEqual(file.board(containing: d), nil)
        expectEqual(file.shapeCount, 6)
        expectEqual(file.path(to: nest.qBoard), [.root, nest.pBoard, nest.qBoard], "Q is still there, its board empty")
    },
    test("boards come with their shapes and go with them, and the root stays") {
        let nest = Nest()
        var file = nest.file
        let x = ShapeID(), y = ShapeID(), e = ShapeID()
        file.insertBoards([x: board(box(e)), y: board()])
        expectEqual(file.children[x]?.shapes.map(\.id), [e])
        expectEqual(file.children[y], nil, "an empty board isn't kept")
        expectEqual(file.board(containing: e), BoardID(owner: x))
        file.removeBoards(file.subtree(ownedBy: [nest.p]))
        expectEqual(Set(file.children.keys), [x])
        for id in [nest.b, nest.q, nest.c] { expectEqual(file.board(containing: id), nil) }
        expectEqual(file.board(containing: nest.p), .root, "the owner is the root's to delete")
        expectEqual(file.shapeCount, 4)
    },
    test("each change stamps its board with a revision the file never gave before") {
        let nest = Nest()
        var file = nest.file
        var seen: Set<Int> = []
        @MainActor func note(_ board: BoardID) -> Int {
            let revision = file.revision(of: board)
            expect(seen.insert(revision).inserted, "\(board)'s revision \(revision) came back")
            return revision
        }
        let root = note(.root), p = note(nest.pBoard), q = note(nest.qBoard)
        expectEqual(file.revision(of: nest.rBoard), 0, "a board that never had shapes")
        file.set(board(box(nest.c), box()), for: nest.qBoard)
        let q2 = note(nest.qBoard)
        expect(q2 > q)
        expectEqual(file.revision(of: .root), root)
        expectEqual(file.revision(of: nest.pBoard), p)
        file.set(board(), for: nest.qBoard)
        _ = note(nest.qBoard)
        file.set(board(box()), for: nest.rBoard)
        _ = note(nest.rBoard)
        file.removeBoards([nest.rBoard])
        _ = note(nest.rBoard)
        file.insertBoards([nest.q: board(box())])
        _ = note(nest.qBoard)

        var next = Nest().file
        next.restamp(after: file)
        let highest = try require(seen.max())
        for board in [BoardID.root, nest.pBoard, nest.qBoard, nest.rBoard] {
            expect(next.revision(of: board) > highest, "\(board): what's kept of the old file's boards is never taken for the new one's")
        }
    },
    test("restamped after a file, a board whose shapes are as that file has them keeps its revision there; the rest get new ones") {
        let nest = Nest()
        var file = nest.file
        file.set(board(box(nest.c), box()), for: nest.qBoard)
        var next = nest.file
        next.set(board(box(nest.c)), for: nest.qBoard)          // Q's board as it was before
        next.restamp(after: file)
        for board in [BoardID.root, nest.pBoard] {
            expectEqual(next.revision(of: board), file.revision(of: board), "\(board) is as it was")
        }
        let highest = [BoardID.root, nest.pBoard, nest.qBoard].map { file.revision(of: $0) }.max() ?? 0
        expect(next.revision(of: nest.qBoard) > highest, "Q's board changed: a revision the old file never had")
        var later = next
        later.set(board(box()), for: nest.pBoard)
        expect(later.revision(of: nest.pBoard) > highest, "and the next change gives one past them all")
    },
    test("files are equal when their boards are, whatever their history") {
        let nest = Nest()
        var file = nest.file
        let before = file
        let d = box()
        file.set(board(box(nest.c), d), for: nest.qBoard)
        expect(file != before)
        file.set(board(box(nest.c)), for: nest.qBoard)
        expectEqual(file, before)
        expect(file.revision(of: nest.qBoard) != before.revision(of: nest.qBoard))
    },
    test("the registry knows which kinds own boards, and fills in defaults on every board, stamping only those it changes") {
        let registry = try Registry(plugins: [FixturesPlugin(), PocketsPlugin(), ratings()])
        expectEqual(registry.boardOwningKinds, [Pocket.kind])
        let nest = Nest(), file = nest.file
        let filled = registry.fillingDefaults(file)
        for id in [nest.a, nest.b, nest.c] { expectEqual(filled.record(id)?[Stars.self], 0) }
        expectEqual(filled.record(nest.q)?[Stars.self], nil, "pockets don't opt in")
        expectEqual(filled.board(containing: nest.c), nest.qBoard)
        let again = registry.fillingDefaults(filled)
        expectEqual(again, filled)
        for board in [BoardID.root, nest.pBoard, nest.qBoard] {
            expect(filled.revision(of: board) != file.revision(of: board), "\(board)'s boxes were filled")
            expectEqual(again.revision(of: board), filled.revision(of: board), "filling what's filled stamps nothing")
        }
    },
    test("an id is unused while no shape on any board has it and nothing is kept under it: a board whose owner isn't here, or an entry under its key that isn't a board") {
        let nest = Nest()
        var file = nest.file
        for id in [nest.a, nest.p, nest.r, nest.b, nest.q, nest.c] { expect(!file.isUnused(id), "\(id) is a shape's") }
        expect(file.isUnused(ShapeID()))
        file.set(board(), for: nest.qBoard)
        expect(file.isUnused(nest.c), "its shape is gone")

        let orphan = ShapeID()
        expect(!CanvasFile(root: board(box()), children: [orphan: board(box())]).isUnused(orphan), "a board is kept under it")

        let kept = ShapeID(), lowercase = ShapeID()
        let json = """
        { "format" : 4, "shapes" : [], "boards" : { "\(kept)" : 7, "\(lowercase.description.lowercased())" : 7 } }
        """
        let loaded = try BoardCodec(registry: Registry(plugins: [FixturesPlugin(), PocketsPlugin()])).decode(Data(json.utf8))
        expectEqual(loaded.file.unreadableBoards.count, 2)
        expect(!loaded.file.isUnused(kept), "an entry is kept under the key its board would be written under")
        expect(loaded.file.isUnused(lowercase), "a key as this app never writes one is no shape's")
    },
])
