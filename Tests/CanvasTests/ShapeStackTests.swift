@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import TestKit

// How a board holds its shapes (ShapeStack, with the table of where each is; CanvasFile's table of which
// board each is on, ShapeMap): as a plain list would read, whatever commits and steps came before, and
// shared, a chunk at a time, with the board a commit started from. Debug builds chunk four shapes and spread
// a table over shards a few entries each, so these few shapes meet every edge between them.

/// A small seeded generator (SplitMix64), so the run is the same each time.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private func box(_ x: Int) -> AnyShapeRecord {
    AnyShapeRecord(ShapeRecord(Box(CGRect(x: x * 10, y: 0, width: 25, height: 25))))
}

/// Whether the document reads as the list of records it holds: every place, every lookup, every way of walking it.
@MainActor private func expectReadsAsList(_ document: CanvasDocument, _ note: String) {
    let list = Array(document.shapes)
    expectEqual(document.shapes.count, list.count, note)
    expectEqual(document.shapes.isEmpty, list.isEmpty, note)
    expectEqual(Set(list.map(\.id)).count, list.count, "\(note): each id once")
    for (place, record) in list.enumerated() {
        expectEqual(document.shapes[place], record, "\(note): the shape at \(place)")
        expectEqual(document.index(of: record.id), place, "\(note): where \(place) is")
        expectEqual(document[record.id], record, "\(note): the shape \(place) by its id")
    }
    expectEqual(document.shapes.first, list.first, note)
    expectEqual(document.shapes.last, list.last, note)
    expectEqual(Array(document.shapes.reversed()), Array(list.reversed()), "\(note): back to front")
    expectEqual(document.shapes.map(\.id), list.map(\.id), note)
    expectEqual(Array(document.shapes.indices), Array(list.indices), note)
    var walked: [AnyShapeRecord] = []
    for record in document.shapes { walked.append(record) }
    expectEqual(walked, list, "\(note): walked")
    if list.count > 2 {
        expectEqual(Array(document.shapes[1..<list.count - 1]), Array(list[1..<list.count - 1]), "\(note): a slice")
        expectEqual(Array(document.shapes.suffix(2)), Array(list.suffix(2)), note)
    }
    for (place, record) in list.dropFirst().enumerated() {
        guard let key = record.stackingKey, let before = list[place].stackingKey else { return expect(false, "\(note): a shape with no key") }
        expect(before < key, "\(note): keys rise at \(place + 1)")
    }
    // A document made from the list is the same document, with every shape in the same place.
    let made = CanvasDocument(shapes: list)
    expect(made == document, "\(note): made again")
    expect(document == made, "\(note): made again, the other way")
    for (place, record) in list.enumerated() { expectEqual(made.index(of: record.id), place, "\(note): made again, \(place)") }
}

@MainActor let shapeStackTests = Suite("Shape stack", [
    test("a board of any size, around the edges between chunks, reads as the list it was made from") {
        for count in 0...41 {
            let list = (0..<count).map(box)
            let document = CanvasDocument(shapes: list)
            expectEqual(document.shapes.map(\.id), list.map(\.id), "\(count) shapes")
            expectReadsAsList(document, "\(count) shapes")
            expectEqual(document.index(of: ShapeID()), nil)
            expectEqual(document[ShapeID()], nil)
            expect(document == CanvasDocument(shapes: list), "\(count) shapes, equal to another made of them")
            if count > 1 {
                var swapped = list
                swapped.swapAt(0, count - 1)
                expect(document != CanvasDocument(shapes: swapped), "\(count) shapes, not equal to a board in another order")
                expect(document != CanvasDocument(shapes: Array(list.dropLast())), "\(count) shapes, not equal to one with fewer")
            }
            if count > 0 {
                var changed = list
                changed[count / 2].box = CGRect(x: 1, y: 2, width: 3, height: 4)
                expect(document != CanvasDocument(shapes: changed), "\(count) shapes, not equal to one with a shape changed")
            }
            // The stack the document keeps, made again from itself, keeps its keys and its places.
            expectEqual(CanvasDocument(shapes: document.shapes), document, "\(count) shapes made from the stack")
        }
    },
    test("a random run of commits leaves the board a plain list, and each undo and redo puts it back exactly") {
        for (seed, start) in [(1, 0), (2, 1), (3, 4), (4, 5), (5, 9), (6, 30)] as [(UInt64, Int)] {
            var random = SeededGenerator(seed: seed)
            let h = try EditorHarness(plugins: [FixturesPlugin()], document: CanvasDocument(shapes: (0..<start).map(box)))
            var gone: Set<ShapeID> = []
            // The board after each step still to undo, the first being the board as it began; and after each undone.
            var done: [[AnyShapeRecord]] = [Array(h.editor.document.shapes)], undone: [[AnyShapeRecord]] = []
            @MainActor func records() -> [AnyShapeRecord] { Array(h.editor.document.shapes) }
            @MainActor func pick(_ count: Int = 1) -> [ShapeID] {
                let ids = records().map(\.id).shuffled(using: &random)
                return Array(ids.prefix(count))
            }
            for step in 0..<260 {
                let before = records()
                let note = "seed \(seed), step \(step)"
                var wasBurst = false
                switch Int.random(in: 0..<100, using: &random) {
                case 0..<26:
                    let count = Int.random(in: 1...6, using: &random)
                    h.editor.transact("Insert") { transaction in
                        for _ in 0..<count { transaction.insert(ShapeRecord(Box(CGRect(x: Int.random(in: 0..<300, using: &random), y: 0, width: 80, height: 80)))) }
                    }
                    expectEqual(h.editor.document.shapes.count, before.count + count, note)
                    expectEqual(Array(h.editor.document.shapes.prefix(before.count)), before, "\(note): what was there stays below")
                case 26..<42:
                    let ids = pick(Int.random(in: 1...5, using: &random))
                    h.editor.transact("Move") { transaction in
                        for id in ids { transaction.update(id, as: Box.self) { $0.props.frame.origin.x += 7 } }
                    }
                    expectEqual(records().map(\.id), before.map(\.id), "\(note): in place")
                case 42..<56:
                    let ids = pick(Int.random(in: 1...5, using: &random))
                    h.editor.transact("Delete") { $0.delete(Set(ids)) }
                    gone.formUnion(ids)
                    expectEqual(records().map(\.id), before.map(\.id).filter { !ids.contains($0) }, "\(note): the rest keep their order")
                case 56..<64:
                    if let id = pick().first {
                        h.editor.transact("Front") { $0.bringToFront(id) }
                        expectEqual(records().last?.id, id, note)
                    }
                case 64..<70:
                    if let id = pick().first {
                        h.editor.transact("Back") { $0.sendToBack(id) }
                        expectEqual(records().first?.id, id, note)
                    }
                case 70..<78:
                    let ids = pick(2)
                    if ids.count == 2 {
                        h.editor.transact("Above") { $0.move(ids[0], above: ids[1]) }
                        let ordered = records().map(\.id)
                        expectEqual(ordered.firstIndex(of: ids[0]), ordered.firstIndex(of: ids[1]).map { $0 + 1 }, "\(note): just above")
                    }
                case 78..<84:
                    let ids = pick(2)
                    if ids.count == 2 {
                        h.editor.transact("Below") { $0.move(ids[0], below: ids[1]) }
                        let ordered = records().map(\.id)
                        expectEqual(ordered.firstIndex(of: ids[0]), ordered.firstIndex(of: ids[1]).map { $0 - 1 }, "\(note): just below")
                    }
                case 84..<88:
                    let ids = pick(Int.random(in: 1...4, using: &random))
                    h.editor.transact("Several to the front") { $0.bringToFront(ids) }
                    expectEqual(Set(records().suffix(ids.count).map(\.id)), Set(ids), note)
                case 88..<91:
                    let ids = pick(Int.random(in: 1...4, using: &random))
                    h.editor.transact("Several to the back") { $0.sendToBack(ids) }
                    expectEqual(Set(records().prefix(ids.count).map(\.id)), Set(ids), note)
                case 91..<94:
                    h.editor.transact("Forward") { $0.bringForward(pick(Int.random(in: 1...3, using: &random))) }
                default:
                    // A burst of undos and then of redos, the board checked after each.
                    let back = Int.random(in: 1...7, using: &random)
                    for _ in 0..<back where h.editor.canUndo {
                        h.editor.undo()
                        undone.append(done.removeLast())
                        expectEqual(records(), done.last ?? [], "\(note): undone")
                        expectReadsAsList(h.editor.document, "\(note): undone")
                    }
                    for _ in 0..<Int.random(in: 0...back, using: &random) where h.editor.canRedo {
                        h.editor.redo()
                        done.append(undone.removeLast())
                        expectEqual(records(), done.last ?? [], "\(note): redone")
                        expectReadsAsList(h.editor.document, "\(note): redone")
                    }
                    wasBurst = true
                }
                if !wasBurst, records() != before {
                    // A commit that changed the board is a step of its own and ends what could be redone.
                    done.append(records())
                    undone = []
                }
                expectReadsAsList(h.editor.document, note)
                for id in gone where h.editor.document[id] == nil { expectEqual(h.editor.document.index(of: id), nil, "\(note): a deleted shape has no place") }
            }
            // Redo all the way, undo all the way and redo again: the board as it ended, as it began, as it ended.
            while h.editor.canRedo { h.editor.redo() }
            let last = records()
            expectEqual(last, (done + undone.reversed()).last ?? [], "seed \(seed): everything redone at first")
            while h.editor.canUndo { h.editor.undo() }
            expectEqual(records(), done.first ?? [], "seed \(seed): everything undone")
            while h.editor.canRedo { h.editor.redo() }
            expectEqual(records(), last, "seed \(seed): everything redone")
            expectReadsAsList(h.editor.document, "seed \(seed): the end")
        }
    },
    test("a copy of a board is not changed by a commit to the board, and holds the board as it was") {
        let h = try EditorHarness(plugins: [FixturesPlugin()], document: CanvasDocument(shapes: (0..<23).map(box)))
        let was = h.editor.document, list = Array(was.shapes)
        let ids = list.map(\.id)
        h.editor.transact("Move") { $0.update(ids[5], as: Box.self) { $0.props.frame.origin.x = 500 } }
        h.editor.transact("Insert") { $0.insert(ShapeRecord(Box(.zero))) }
        h.editor.transact("Delete") { $0.delete([ids[0], ids[11]]) }
        h.editor.transact("Front") { $0.bringToFront(ids[3]) }
        expectEqual(Array(was.shapes), list, "the board as it was")
        expectReadsAsList(was, "the board as it was")
        expectEqual(was[ids[0]]?.id, ids[0])
        expectEqual(was.index(of: ids[11]), 11)
        expect(was != h.editor.document)
        expectReadsAsList(h.editor.document, "the board now")
    },
    test("a commit shares the chunks it did not reach with the board it began from, and an undo does too") {
        // Enough shapes, and far enough apart, to fall in different chunks whatever their size.
        let count = 3000
        let h = try EditorHarness(plugins: [FixturesPlugin()], document: CanvasDocument(shapes: (0..<count).map(box)))
        let ids = h.editor.document.shapes.map(\.id)
        var shapes = h.editor.document.shapes
        let chunks = shapes.chunkCount
        expect(chunks > 20, "enough chunks to tell: \(chunks)")
        @MainActor func shared() -> Int {
            defer { shapes = h.editor.document.shapes }
            return h.editor.document.shapes.sharedChunkCount(with: shapes)
        }
        // A shape changed in place: one chunk copied.
        h.editor.transact("Move") { $0.update(ids[1000], as: Box.self) { $0.props.frame.origin.x = 9 } }
        expectEqual(shared(), chunks - 1, "a shape changed in place")
        // A few shapes far apart: a chunk each.
        h.editor.transact("Move") { transaction in
            for id in [ids[3], ids[1500], ids[2999]] { transaction.update(id, as: Box.self) { $0.props.frame.origin.y = 4 } }
        }
        expectEqual(shared(), chunks - 3, "three shapes far apart")
        // A shape put on top: the last chunk written, perhaps a new one begun.
        h.editor.transact("Insert") { $0.insert(ShapeRecord(Box(.zero))) }
        expect(shared() >= chunks - 1, "a shape put on top")
        let grown = h.editor.document.shapes.chunkCount
        // Undo and redo of that: the same.
        h.editor.undo()
        expect(shared() >= grown - 2, "that undone")
        h.editor.redo()
        expect(shared() >= grown - 2, "that redone")
        // Undo and redo of a change in place.
        h.editor.undo()
        h.editor.undo()
        h.editor.undo()
        _ = shared()
        h.editor.redo()
        expect(shared() >= grown - 3, "a change in place, redone")
        // A shape sent from near the top to the top: the chunks from there on.
        let near = h.editor.document.shapes[count - 3].id
        _ = shared()
        h.editor.transact("Front") { $0.bringToFront(near) }
        expect(shared() >= grown - 3, "a shape near the top brought to the top")
        // The first shape deleted: every chunk after it is made again, the board still reads as a list.
        h.editor.transact("Delete") { $0.delete([ids[0]]) }
        expectReadsAsList(h.editor.document, "the first shape deleted")
        // A shape deleted from near the top leaves what is below it shared.
        let top = h.editor.document.shapes[h.editor.document.shapes.count - 2].id
        _ = shared()
        h.editor.transact("Delete") { $0.delete([top]) }
        expect(shared() >= h.editor.document.shapes.chunkCount - 2, "a shape near the top deleted")
        expectReadsAsList(h.editor.document, "a shape near the top deleted")
    },
    test("a document put in place says what differs from the one it replaces, whether the two share their shapes or not") {
        let log = ChangeLog()
        let h = try EditorHarness(plugins: [FixturesPlugin(), recordingChanges(log)], document: CanvasDocument(shapes: (0..<50).map(box)))
        // Another editor starts from the same board and makes commits of its own, so its boards share shapes with h's.
        let other = try EditorHarness(plugins: [FixturesPlugin()], document: h.editor.document)
        var random = SeededGenerator(seed: 11)
        for round in 0..<60 {
            let before = h.editor.document
            for _ in 0..<Int.random(in: 1...3, using: &random) {
                let ids = other.editor.document.shapes.map(\.id).shuffled(using: &random)
                switch Int.random(in: 0..<6, using: &random) {
                case 0: other.editor.transact { for _ in 0..<Int.random(in: 1...4, using: &random) { $0.insert(ShapeRecord(Box(.zero))) } }
                case 1: other.editor.transact { for id in ids.prefix(3) { $0.update(id, as: Box.self) { $0.props.frame.origin.x += 1 } } }
                case 2: other.editor.transact { $0.delete(Set(ids.prefix(Int.random(in: 1...3, using: &random)))) }
                case 3: if let id = ids.first { other.editor.transact { $0.bringToFront(id) } }
                case 4: if let id = ids.first { other.editor.transact { $0.sendToBack(id) } }
                default: if ids.count > 1 { other.editor.transact { $0.move(ids[0], above: ids[1]) } }
                }
            }
            // The board it ends with, as the shapes it has in common with h's, and again as a board of its own.
            let shared = other.editor.document, unshared = CanvasDocument(shapes: Array(shared.shapes))
            let old = Array(before.shapes), new = Array(shared.shapes)
            let oldRecords = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0) }), newRecords = Dictionary(uniqueKeysWithValues: new.map { ($0.id, $0) })
            let added = Set(new.map(\.id)).subtracting(oldRecords.keys), removed = Set(old.map(\.id)).subtracting(newRecords.keys)
            let changed = Set(new.map(\.id).filter { oldRecords[$0] != nil && oldRecords[$0] != newRecords[$0] })
            for (kind, document) in [("sharing shapes", shared), ("sharing none", unshared)] {
                h.editor.replaceDocument(with: before)
                log.changes.removeAll()
                h.editor.replaceDocument(with: document)
                let change = try require(log.changes.last, "round \(round), \(kind)")
                expectEqual(change.added, added, "round \(round), \(kind): added")
                expectEqual(change.removed, removed, "round \(round), \(kind): removed")
                expectEqual(change.changed, changed, "round \(round), \(kind): changed")
                expectEqual(change.reordered, old.map(\.id) != new.map(\.id), "round \(round), \(kind): reordered")
                expect(change.replacedDocument, "round \(round), \(kind): a replacement")
                expectEqual(change.before(Array(removed).first ?? ShapeID())?.id, removed.first, "round \(round), \(kind): what was there")
                expect(h.editor.document == document, "round \(round), \(kind): put in place")
            }
        }
    },
    test("the file's table of which board each shape is on follows shapes put in, deleted and moved between boards") {
        let h = try EditorHarness(plugins: [FixturesPlugin(), PocketsPlugin()], document: CanvasDocument())
        var random = SeededGenerator(seed: 9)
        var pockets: [ShapeID] = []
        for _ in 0..<3 { pockets.append(h.add(Pocket(CGRect(x: 0, y: 0, width: 400, height: 300)))) }
        var model: [ShapeID: BoardID] = [:]
        for pocket in pockets { model[pocket] = .root }
        // Shapes put on each pocket's board, on the root, deleted and moved from board to board.
        var onBoard: [BoardID: [ShapeID]] = [.root: pockets]
        for pocket in pockets { onBoard[BoardID(owner: pocket)] = [] }
        for step in 0..<90 {
            let boards = Array(onBoard.keys)
            let from = boards.sorted { $0.description < $1.description }[Int.random(in: 0..<boards.count, using: &random)]
            switch Int.random(in: 0..<10, using: &random) {
            case 0..<6:
                let id = ShapeID()
                if h.editor.showBoard(from) {
                    h.editor.transact("Insert") { $0.insert(ShapeRecord(id: id, Box(CGRect(x: step, y: 0, width: 20, height: 20)))) }
                    onBoard[from, default: []].append(id)
                    model[id] = from
                }
            case 6..<8:
                guard h.editor.showBoard(from), let id = onBoard[from, default: []].filter({ !pockets.contains($0) }).randomElement(using: &random) else { continue }
                h.editor.transact("Delete") { $0.delete([id]) }
                onBoard[from]?.removeAll { $0 == id }
                model[id] = nil
            default:
                guard h.editor.showBoard(from), let id = onBoard[from, default: []].filter({ !pockets.contains($0) }).randomElement(using: &random),
                      let to = pockets.filter({ BoardID(owner: $0) != from }).randomElement(using: &random) else { continue }
                var moved = false
                h.editor.transact("Move") { moved = $0.move([id], to: BoardID(owner: to)) }
                if moved {
                    onBoard[from]?.removeAll { $0 == id }
                    onBoard[BoardID(owner: to), default: []].append(id)
                    model[id] = BoardID(owner: to)
                }
            }
            let file = h.editor.file
            expectEqual(file.shapeCount, model.count, "step \(step)")
            if step % 3 == 0 {
                for (id, board) in model { expectEqual(file.board(containing: id), board, "step \(step)") }
            }
        }
        // Undone all the way, and redone: the table follows each step.
        while h.editor.canUndo { h.editor.undo() }
        expectEqual(h.editor.file.shapeCount, 0)
        while h.editor.canRedo { h.editor.redo() }
        let file = h.editor.file
        expectEqual(file.shapeCount, model.count)
        for (id, board) in model { expectEqual(file.board(containing: id), board) }
        // A file made of its boards has the same table.
        let again = CanvasFile(root: file.root, children: file.children)
        expectEqual(again.shapeCount, model.count)
        for (id, board) in model { expectEqual(again.board(containing: id), board) }
        expect(again == file)
    },
])
