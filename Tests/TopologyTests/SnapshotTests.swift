@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import Observation
import TestKit
import Topology

// A snapshot for other threads (`topology.snapshot()`): every question the index answers, answered
// alike, through seeded commits of every kind (shapes put in containers and taken out among them),
// and as the file was once commits land after it; the file in file order; containers; the filters
// over lists; the types' summaries; and what taking one costs.

/// What both the index and a snapshot answer.
@MainActor private protocol Answering {
    var types: EdgeTypeTree { get }
    var containerKinds: Set<ShapeKind> { get }
    func edges(of id: ShapeID, _ direction: EdgeDirection, types filter: EdgeTypeFilter) -> [Edge]
    func hasEdges(of id: ShapeID, _ direction: EdgeDirection, types filter: EdgeTypeFilter, where predicate: (Edge) -> Bool) -> Bool
    func neighbors(of id: ShapeID, _ direction: EdgeDirection, types filter: EdgeTypeFilter) -> [EdgeTypeID: [ShapeID]]
    func edges(ofType filter: EdgeTypeFilter) -> [Edge]
    func edges(carriedBy carrier: ShapeID) -> [Edge]
    func end(_ id: ShapeID) -> EdgeEnd
    func parent(of id: ShapeID) -> ShapeID?
    func children(of id: ShapeID) -> [ShapeID]
    func ancestors(of id: ShapeID) -> [ShapeID]
    func isInside(_ a: ShapeID, _ b: ShapeID) -> Bool
}

extension TopologyIndex: Answering {}
extension TopologySnapshot: Answering {}

/// The filters questions are asked with: every way one admits a type, and a type nobody declares.
private let filters: [(name: String, filter: EdgeTypeFilter)] = [
    ("all", .all), ("within wire", .within(WireEdge.id)), ("only wire", .only(WireEdge.id)),
    ("only hot-wire|quote", .only(HotWireEdge.id, QuoteEdge.id)), ("within cite|tether", .within([CiteEdge.id, tether])),
]

private let directions: [(name: String, direction: EdgeDirection)] = [("out", .outgoing), ("in", .incoming), ("either", .either)]

/// A shape as a failure names it: `#n` for the fixtures' numbered ids.
private func name(_ id: ShapeID) -> String {
    let text = id.description, numbered = "00000000-0000-0000-0000-"
    return text.hasPrefix(numbered) ? "#\(Int(text.dropFirst(numbered.count)) ?? 0)" : text
}

/// Every answer to every question about some shapes, by question.
private struct Answers {
    var edges: [String: [Edge]] = [:]
    var yes: [String: Bool] = [:]
    var neighbors: [String: [EdgeTypeID: [ShapeID]]] = [:]
    var shapes: [String: [ShapeID]] = [:]
    var ends: [String: EdgeEnd] = [:]
}

/// Asks every question of `reading` about `ids`: their edges each way through each filter, whether
/// they have any (and any another shape carries), their neighbors, what each carries, where each
/// is, its parent, children and ancestors, and whether each is inside each of `containers`; and the
/// file's edges through each filter.
@MainActor private func answers(_ reading: some Answering, about ids: [ShapeID], containers: [ShapeID]) -> Answers {
    var found = Answers()
    for (filterName, filter) in filters {
        found.edges["edges(ofType: \(filterName))"] = reading.edges(ofType: filter)
    }
    for id in ids {
        let shape = name(id)
        for (directionName, direction) in directions {
            for (filterName, filter) in filters where direction == .either || filter == .all || filterName == "within wire" {
                let question = "(\(shape), \(directionName), \(filterName))"
                found.edges["edges" + question] = reading.edges(of: id, direction, types: filter)
                found.yes["hasEdges" + question] = reading.hasEdges(of: id, direction, types: filter) { _ in true }
                found.yes["hasEdges, carried by another" + question] = reading.hasEdges(of: id, direction, types: filter) { $0.carrier != id }
                found.neighbors["neighbors(of:)" + question] = reading.neighbors(of: id, direction, types: filter)
            }
        }
        found.edges["edges(carriedBy: \(shape))"] = reading.edges(carriedBy: id)
        found.ends["end(\(shape))"] = reading.end(id)
        found.shapes["parent(of: \(shape))"] = reading.parent(of: id).map { [$0] } ?? []
        found.shapes["children(of: \(shape))"] = reading.children(of: id)
        found.shapes["ancestors(of: \(shape))"] = reading.ancestors(of: id)
        for container in containers {
            found.yes["isInside(\(shape), \(name(container)))"] = reading.isInside(id, container)
        }
    }
    return found
}

/// The first few questions two sets of answers answer differently, each with both answers.
private func differences(_ a: Answers, _ b: Answers) -> [String] {
    func differing<Value: Equatable>(_ a: [String: Value], _ b: [String: Value]) -> [String] {
        Set(a.keys).union(b.keys).filter { a[$0] != b[$0] }.sorted().prefix(3).map {
            "\($0): \(a[$0].map { "\($0)" } ?? "nothing") against \(b[$0].map { "\($0)" } ?? "nothing")"
        }
    }
    return differing(a.edges, b.edges) + differing(a.yes, b.yes) + differing(a.neighbors, b.neighbors) + differing(a.shapes, b.shapes)
        + differing(a.ends, b.ends)
}

/// Whether two sets of answers agree, failing with the first few questions they don't.
@MainActor @discardableResult
private func expectSame(_ expected: Answers, _ actual: Answers, _ context: String, file: StaticString = #fileID, line: UInt = #line) -> Bool {
    let problems = differences(expected, actual)
    expect(problems.isEmpty, "\(context): \(problems.joined(separator: "; "))", file: file, line: line)
    return problems.isEmpty
}

/// Every shape in the file, the root's first, then each other board's by its owner's id: a fixed
/// order to pick from.
private func everyShape(in file: CanvasFile) -> [AnyShapeRecord] {
    file.root.shapes + file.children.keys.sorted { $0.description < $1.description }.flatMap { file.children[$0]!.shapes }
}

/// File order as the index's containment has it: each shape, then everything inside it.
@MainActor private func preOrder(_ ids: [ShapeID], _ index: TopologyIndex) -> [ShapeID] {
    ids.flatMap { [$0] + preOrder(index.children(of: $0), index) }
}

/// Holds what only a snapshot answers to what the editor and the index say now: its shapes,
/// its top level, its present types, file order (and each shape's board and key in it), and each
/// shape's descendants and the containers it's in on its board; and each shape's parent to the
/// core's own reading of the board (the container it's in, else its board's owner). Whether it all
/// held.
@MainActor @discardableResult
private func expectFileOrder(_ snapshot: TopologySnapshot, _ h: EditorHarness, _ context: String,
                             file: StaticString = #fileID, line: UInt = #line) -> Bool {
    let index = h.topology, every = everyShape(in: h.file)
    var held = true
    func check(_ condition: Bool, _ message: @autoclosure () -> String) {
        if !condition { held = false }
        expect(condition, "\(message()), \(context)", file: file, line: line)
    }
    var order: [ShapeID] = [], boards: [BoardID] = [], records: [AnyShapeRecord] = []
    snapshot.forEachShape { record, board in
        order.append(record.id)
        boards.append(board)
        records.append(record)
    }
    let expectedOrder = preOrder(snapshot.topLevel, index)
    check(order == expectedOrder, "file order \(order.map(name)), not \(expectedOrder.map(name))")
    check(Set(order).count == order.count, "each shape once")
    check(zip(order, boards).allSatisfy { h.file.board(containing: $0) == $1 }, "each shape's board")
    check(zip(order, records).allSatisfy { h.editor.shape(inFile: $0) == $1 }, "each shape as the editor has it")
    check(Set(order) == Set(every.map(\.id).filter { h.editor.shape(inFile: $0) != nil }), "every shape it can show")
    let kinds = h.editor.registry.containingKinds, root = h.file.root
    check(snapshot.topLevel == root.shapes.filter { root.container(of: $0, containingKinds: kinds) == nil }.map(\.id), "top level")
    check(snapshot.presentTypes == Set(index.edges(ofType: .all).map(\.type)), "present types")
    for (id, (board, record)) in zip(order, zip(boards, records)) {
        check(index.parent(of: id) == (h.file[board].container(of: record, containingKinds: kinds) ?? board.owner), "parent(of: \(name(id)))")
        let parent = index.parent(of: id)
        check(snapshot.container(of: record, on: board) == (parent.flatMap { h.file.board(containing: $0) } == board ? parent : nil),
              "container(of: \(name(id)))")
        check(snapshot.isTopLevel(id) == (board == .root && index.parent(of: id) == nil), "isTopLevel(\(name(id)))")
    }

    let keys = order.map(snapshot.fileOrderKey(of:))
    check(!keys.contains(nil), "a key for every shape in file order")
    let sorted = keys.compactMap { $0 }
    check(zip(sorted, sorted.dropFirst()).allSatisfy { $0.lexicographicallyPrecedes($1) }, "keys rise in file order")
    for record in every {
        let shown = h.editor.shape(inFile: record.id)
        check(snapshot.shape(record.id) == shown, "shape(\(name(record.id)))")
        if shown == nil { check(snapshot.fileOrderKey(of: record.id) == nil, "no key for \(name(record.id))") }
        let descendants = snapshot.descendants(of: record.id), expected = preOrder(index.children(of: record.id), index)
        check(descendants == expected, "descendants(of: \(name(record.id))) \(descendants.map(name)), not \(expected.map(name))")
    }
    return held
}

/// A reproducible stream of choices.
private struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Seeded commits of every kind on the hidden file (box 1, link 2 to a missing shape 3, and the
/// gadget 10, kept aside, whose board the editor can't show), with pocket 100 put in first, whose
/// board holds pocket 103 (pockets two deep), whose board holds corral 107 holding box 104 and memo
/// 106; and corral 108 on the root, holding box 1. Each commit's new shapes are numbered from 110.
@MainActor private final class Churn {
    let h: EditorHarness
    private var random: SplitMix
    private var next = 110

    init(seed: UInt64) throws {
        h = try graph(try hiddenFile().file, more: [CorralsPlugin()])
        random = SplitMix(state: seed)
        h.editor.transact("Nest") { t in
            t.insert(pocket(id(100)), contents: [id(100): board(box(id(101)), link(id(102), id(101), id(1)), pocket(id(103))),
                                                 id(103): board(corral(id(107)), held(box(id(104)), in: id(107)), link(id(105), id(104), id(101)),
                                                                held(memo(id(106), lead: id(1)), in: id(107)))])
            t.insert(corral(id(108)))
            t.setContainer(id(1), to: id(108))
        }
    }

    /// Every shape in the file, and a missing one and one that never was: what questions are asked
    /// about.
    var questioned: [ShapeID] { everyShape(in: h.file).map(\.id) + [id(3), id(99)] }

    /// The shapes that can contain others (pockets and corrals), wherever they are, and two that can't.
    var containers: [ShapeID] {
        everyShape(in: h.file).filter { $0.kind == Pocket.kind || $0.kind == Corral.kind }.map(\.id) + [id(1), id(10)]
    }

    /// One commit, a switch or an undo, chosen at random; what it was.
    func step() -> String {
        let shown = h.editor.document.shapes
        switch Int.random(in: 0..<112, using: &random) {
        case 0..<30:
            let record = newShape()
            h.editor.transact("Add") { t in
                if record.kind == Pocket.kind, Bool.random(using: &random) {
                    t.insert(record, contents: [record.id: board(box(fresh()), link(fresh(), target(), target()))])
                } else {
                    t.insert(record)
                }
            }
            return "adding \(record.kind) \(name(record.id))"
        case 30..<45:
            guard let record = pick(shown.filter { $0.id != id(10) }) else { return "nothing" }
            h.editor.transact("Change") { rewire(record.id, in: &$0) }
            return "rewiring \(name(record.id))"
        case 45..<55:
            let doomed = Set((0..<Int.random(in: 1...2, using: &random)).compactMap { _ in pick(shown.filter { $0.id != id(10) })?.id })
            h.editor.transact("Delete") { $0.delete(doomed) }
            return "deleting \(doomed.map(name).sorted())"
        case 55..<62:
            guard let record = pick(shown.filter { $0.box != nil }) else { return "nothing" }
            let x = Int.random(in: 0...500, using: &random)
            if Bool.random(using: &random) {
                h.editor.transact("Move") { $0.moveBox(record.id, to: CGPoint(x: x, y: 0)) }
                return "moving \(name(record.id))"
            }
            // What a container holds moves with it.
            h.editor.transact("Move") { $0.translate([record.id], by: CGPoint(x: x, y: 1)) }
            return "moving \(name(record.id)) and what it holds"
        case 62..<67:
            guard let record = pick(Array(shown)) else { return "nothing" }
            let front = Bool.random(using: &random)
            h.editor.transact("Restack") { front ? $0.bringToFront(record.id) : $0.sendToBack(record.id) }
            return "restacking \(name(record.id))"
        case 67..<77:
            guard let board = pick(showableBoards().filter { $0 != h.editor.board }) else { return "nothing" }
            let there = Array(h.file[board].shapes), added = fresh(), from = target(), to = target()
            let rewired = pick(there)
            h.editor.transact(on: board, "Elsewhere") { t in
                if let rewired, Bool.random(using: &random) { rewire(rewired.id, in: &t) } else { t.insert(link(added, from, to)) }
            }
            return "a commit on \(board.owner.map(name) ?? "root")"
        case 77..<79:
            h.editor.transact(on: BoardID(owner: id(10)), "Hidden") { $0.insert(box(fresh())) }
            return "a commit refused on the gadget's board"
        case 79..<89:
            guard let board = pick(showableBoards()) else { return "nothing" }
            h.editor.showBoard(board)
            return "showing \(board.owner.map(name) ?? "root")"
        case 89..<95:
            h.editor.undo()
            return "undo"
        case 95..<100:
            h.editor.redo()
            return "redo"
        default:
            // A shape on the board shown put in a container there, or taken out of the one it's in.
            guard let record = pick(shown.filter { $0.box != nil && !$0.isOpaque }) else { return "nothing" }
            let into = Bool.random(using: &random) ? pick(shown.filter { $0.kind == Corral.kind })?.id : nil
            h.editor.transact("Put") { $0.setContainer(record.id, to: into) }
            return "putting \(name(record.id)) in \(into.map(name) ?? "nothing")"
        }
    }

    private func fresh() -> ShapeID {
        defer { next += 1 }
        return id(next)
    }

    private func pick<T>(_ choices: [T]) -> T? { choices.isEmpty ? nil : choices[Int.random(in: 0..<choices.count, using: &random)] }

    /// A shape an edge may name: any shape in the file, the gadget's too, one missing, or none.
    private func target() -> ShapeID? {
        let roll = Int.random(in: 0..<10, using: &random)
        return roll == 0 ? nil : roll == 1 ? id(3) : pick(everyShape(in: h.file).map(\.id))
    }

    private func newShape() -> AnyShapeRecord {
        let id = fresh()
        switch Int.random(in: 0..<7, using: &random) {
        case 0: return box(id)
        case 1: return pocket(id)
        case 6: return corral(id)
        case 2: return AnyShapeRecord(ShapeRecord(id: id, CitingTag(target: target())))
        case 3: return AnyShapeRecord(ShapeRecord(id: id, Tag(target: target())))
        case 4:
            var cited = memo(id, notes: [MemoNote("x", cites: [target(), target()].compactMap { $0 }.map(Citation.init))], lead: target())
            cited[CitationsProperty.self] = Set([target()].compactMap { $0 }.map(Citation.init))
            return cited
        default: return link(id, target(), target())
        }
    }

    /// Points what `id` names somewhere else, as its kind has it; a shape that names nothing gets a
    /// note in its metadata, a change that changes no edge.
    private func rewire(_ id: ShapeID, in t: inout Transaction) {
        let first = target(), second = target()
        switch t.document[id]?.kind {
        case Link.kind?: t.update(id, as: Link.self) { $0.props.from = first; $0.props.to = second }
        case Tag.kind?: t.update(id, as: Tag.self) { $0.props.target = first }
        case CitingTag.kind?: t.update(id, as: CitingTag.self) { $0.props.target = first }
        case Memo.kind?:
            t.update(id, as: Memo.self) { memo in
                memo.props.notes.reverse()
                memo.props.lead = first.map(Citation.init)
                memo[CitationsProperty.self] = second.map { [Citation($0)] as Set }
            }
        default: t.update(id) { $0.meta[Note.self] = "rewired" }
        }
    }

    /// Every board the editor can show: the root, and the board of every pocket on one.
    private func showableBoards() -> [BoardID] {
        [.root] + everyShape(in: h.file).filter { $0.kind == Pocket.kind }.map { BoardID(owner: $0.id) }.filter(h.editor.canShow)
    }
}

/// On the root, as Nest has it: boxes A and B, link L from A to B, pocket P, and box Z after it;
/// P's board holds box C, link M from C to A and pocket Q; Q's holds box D and link N from D to C.
/// File order goes into P's boards before Z, where a board at a time wouldn't.
private struct Tail {
    let tree = Nest(), z = ShapeID()
    var file: CanvasFile {
        CanvasFile(root: board(box(tree.a), box(tree.b), link(tree.l, tree.a, tree.b), pocket(tree.p), box(z)),
                   children: [tree.p: board(box(tree.c), link(tree.m, tree.c, tree.a), pocket(tree.q)),
                              tree.q: board(box(tree.d), link(tree.n, tree.d, tree.c))])
    }
}

@MainActor let snapshotTests = Suite("Snapshots", [
    test("a snapshot answers as the index does, every question, through seeded commits of every kind, and a snapshot held answers as then") {
        // Seeds whose runs go two boards down, put shapes in corrals and take them out, and delete
        // and bring back corrals and pockets with what they hold.
        for seed: UInt64 in [17, 32] {
            let churn = try Churn(seed: seed)
            var held: (snapshot: TopologySnapshot, ids: [ShapeID], containers: [ShapeID], answers: Answers)?
            var changed = 0, boardsShown: Set<BoardID> = []
            for step in 0..<60 {
                let what = churn.step(), context = "seed \(seed), step \(step), after \(what)"
                let index = churn.h.topology, snapshot = index.snapshot()
                let ids = churn.questioned, containers = churn.containers
                let live = answers(index, about: ids, containers: containers)
                guard expectSame(live, answers(snapshot, about: ids, containers: containers), context),
                      expectFileOrder(snapshot, churn.h, context) else { break }
                if let held {
                    guard expectSame(held.answers, answers(held.snapshot, about: held.ids, containers: held.containers),
                                     "a snapshot taken the step before, \(context)") else { break }
                    if !differences(held.answers, answers(index, about: held.ids, containers: held.containers)).isEmpty { changed += 1 }
                }
                held = (snapshot, ids, containers, live)
                boardsShown.insert(churn.h.editor.board)
            }
            expect(changed > 20, "commits changed what the index answers (\(changed) of 60)")
            expect(boardsShown.count > 2, "boards were shown other than the root (\(boardsShown.count))")
            expect(churn.h.file.shapeCount > 20, "the seed made shapes (\(churn.h.file.shapeCount))")
            expect(churn.h.file.children.count >= 3, "boards of pockets, and the gadget's")
            let file = churn.h.file
            let penned = everyShape(in: file).filter { record in churn.h.topology.parent(of: record.id).flatMap { file.record($0) }?.kind == Corral.kind }
            expect(penned.count >= 2, "shapes in corrals (\(penned.count))")
        }
    },

    test("file order: the root back to front, each owner followed at once by its board's shapes, two deep, whichever board is shown") {
        let tail = Tail(), tree = tail.tree
        let h = try graph(tail.file)
        for shown in [nil, tree.p, tree.q] {
            if let shown { expect(h.enter(shown)) }
            let snapshot = h.topology.snapshot()
            var order: [ShapeID] = [], boards: [BoardID] = []
            snapshot.forEachShape { record, board in
                order.append(record.id)
                boards.append(board)
            }
            expectEqual(order, [tree.a, tree.b, tree.l, tree.p, tree.c, tree.m, tree.q, tree.d, tree.n, tail.z])
            expectEqual(boards, [.root, .root, .root, .root, tree.pBoard, tree.pBoard, tree.pBoard, tree.qBoard, tree.qBoard, .root])
            expectEqual(snapshot.topLevel, [tree.a, tree.b, tree.l, tree.p, tail.z])
            expectEqual(snapshot.descendants(of: tree.p), [tree.c, tree.m, tree.q, tree.d, tree.n])
            expectEqual(snapshot.descendants(of: tree.q), [tree.d, tree.n])
            expectEqual(snapshot.descendants(of: tree.a), [], "a box holds nothing")
            expectEqual(snapshot.descendants(of: ShapeID()), [])
            expectEqual(snapshot.fileOrderKey(of: tree.a), [0])
            expectEqual(snapshot.fileOrderKey(of: tree.p), [3])
            expectEqual(snapshot.fileOrderKey(of: tree.c), [3, 0])
            expectEqual(snapshot.fileOrderKey(of: tree.q), [3, 2])
            expectEqual(snapshot.fileOrderKey(of: tree.n), [3, 2, 1])
            expectEqual(snapshot.fileOrderKey(of: tail.z), [4])
            expectEqual(snapshot.fileOrderKey(of: ShapeID()), nil)
            let keyed = order.shuffled().sorted { snapshot.fileOrderKey(of: $0)!.lexicographicallyPrecedes(snapshot.fileOrderKey(of: $1)!) }
            expectEqual(keyed, order, "sorting by key puts shapes in file order")
        }
    },

    test("what the app can't show is outside file order: a board under a shape kept aside, an orphan and owners that hold each other's boards") {
        let h = try graph(try hiddenFile().file)
        let snapshot = h.topology.snapshot()
        var order: [ShapeID] = []
        snapshot.forEachShape { record, _ in order.append(record.id) }
        expectEqual(order, [id(1), id(2), id(10)], "the gadget is on the root; its board isn't shown")
        expectEqual(snapshot.topLevel, [id(1), id(2), id(10)])
        expect(snapshot.shape(id(10))?.isOpaque == true, "a shape kept aside, on a board it can show")
        expectEqual(snapshot.shape(id(11)), nil)
        expectEqual(snapshot.fileOrderKey(of: id(10)), [2])
        expectEqual(snapshot.fileOrderKey(of: id(11)), nil)
        expectEqual(snapshot.descendants(of: id(10)), [])
        expectEqual(snapshot.children(of: id(10)), [])
        expectEqual(snapshot.end(id(11)), .unavailable)
        expectEqual(snapshot.end(id(10)), .live(.root))
        expectEqual(snapshot.end(id(3)), .missing)
        expectEqual(snapshot.edges(ofType: .all), [edge(WireEdge.id, id(1), id(3), by: id(2))], "the gadget's board carries nothing")

        let a = ShapeID(), p = ShapeID(), c = ShapeID(), stray = ShapeID(), s = ShapeID(), x = ShapeID(), y = ShapeID(), w = ShapeID()
        let odd = CanvasFile(root: board(box(a), pocket(p)),
                             children: [p: board(box(c)), stray: board(box(s)), x: board(pocket(y), link(w, y, a)), y: board(pocket(x))])
        let oddly = try graph(odd)
        let held = oddly.topology.snapshot()
        order = []
        held.forEachShape { record, _ in order.append(record.id) }
        expectEqual(order, [a, p, c])
        for id in [s, x, y, w] {
            expectEqual(held.shape(id), nil)
            expectEqual(held.fileOrderKey(of: id), nil, "going up from a loop stops")
            expectEqual(held.parent(of: id), nil)
            expectEqual(held.ancestors(of: id), [])
            expectEqual(held.descendants(of: id), [])
            expectEqual(held.end(id), .unavailable)
        }
        expectEqual(held.edges(of: a), [], "a link on a loop's board carries nothing")
        expectSame(answers(oddly.topology, about: [a, p, c, stray, s, x, y, w], containers: [p, x, y]),
                   answers(held, about: [a, p, c, stray, s, x, y, w], containers: [p, x, y]), "orphans and loops")
    },

    test("a chain of 2,000 boards is walked and keyed without recursing") {
        let owners = (0..<2_000).map { _ in ShapeID() }, last = ShapeID()
        var children: [ShapeID: CanvasDocument] = [:]
        for (index, owner) in owners.enumerated() {
            children[owner] = index + 1 < owners.count ? board(box(ShapeID()), pocket(owners[index + 1])) : board(box(last))
        }
        let h = try graph(CanvasFile(root: board(pocket(owners[0])), children: children))
        let snapshot = h.topology.snapshot()
        var count = 0
        snapshot.forEachShape { _, _ in count += 1 }
        expectEqual(count, 4_000)
        expectEqual(snapshot.fileOrderKey(of: last), [0] + Array(repeating: 1, count: 1_999) + [0])
        expectEqual(snapshot.descendants(of: owners[0]).count, 3_999)
        expectEqual(snapshot.ancestors(of: last).count, 2_000)
    },

    test("a walk in file order stops at the first error its body throws, which comes out as its own type") {
        let tail = Tail(), tree = tail.tree
        let h = try graph(tail.file)
        let snapshot = h.topology.snapshot()
        var visited: [ShapeID] = []
        // A caller that throws its own error type (a query's, stopping when it's cancelled) walks with it.
        func walk(stoppingAt stop: ShapeID) throws(Stopped) {
            try snapshot.forEachShape { record, _ throws(Stopped) in
                visited.append(record.id)
                if record.id == stop { throw Stopped(at: record.id) }
            }
        }
        do throws(Stopped) {
            try walk(stoppingAt: tree.q)
            expect(false, "the walk went on past its body's error")
        } catch {
            expectEqual(error.at, tree.q)
        }
        expectEqual(visited, [tree.a, tree.b, tree.l, tree.p, tree.c, tree.m, tree.q])
    },

    test("a snapshot is the file as it was: commits, a switch and undo after it change none of its answers") {
        let tree = Nest(), x = ShapeID()
        let h = try graph(tree.file)
        let snapshot = h.topology.snapshot()
        let before = answers(snapshot, about: [tree.a, tree.b, tree.c, tree.d, tree.p, tree.q, x], containers: [tree.p, tree.q])
        let all = snapshot.edges(ofType: .all)
        h.editor.transact { $0.insert(link(x, tree.a, tree.d)) }
        h.editor.transact("Delete") { $0.delete([tree.p]) }
        expectEqual(h.topology.end(tree.d), .missing)
        expectEqual(snapshot.end(tree.d), .live(tree.qBoard))
        expectEqual(h.topology.children(of: tree.p), [])
        expectEqual(snapshot.children(of: tree.p), [tree.c, tree.m, tree.q])
        expectEqual(snapshot.edges(ofType: .all), all)
        expectEqual(snapshot.edges(carriedBy: x), [])
        h.editor.undo()
        expect(h.enter(tree.p))
        h.editor.transact { $0.update(tree.m, as: Link.self) { $0.props.to = tree.b } }
        expectSame(before, answers(snapshot, about: [tree.a, tree.b, tree.c, tree.d, tree.p, tree.q, x], containers: [tree.p, tree.q]),
                   "a snapshot held through commits")
    },

    test("a snapshot answers off the main actor as the index does on it") {
        let tail = Tail(), tree = tail.tree
        let h = try graph(tail.file)
        let snapshot = h.topology.snapshot()
        let far = try require(offMain {
            var order: [ShapeID] = []
            snapshot.forEachShape { record, _ in order.append(record.id) }
            return (order, snapshot.edges(ofType: .all), snapshot.edges(of: tree.c), snapshot.ancestors(of: tree.d))
        })
        expectEqual(far.0, preOrder(h.file.root.shapes.map(\.id), h.topology))
        expectEqual(far.1, h.topology.edges(ofType: .all))
        expectEqual(far.2, h.topology.edges(of: tree.c))
        expectEqual(far.3, h.topology.ancestors(of: tree.d))
    },

    test("taking a snapshot reads no record and observes nothing") {
        let tree = Nest()
        let h = try graph(tree.file)
        let read = h.topology.recordsRead
        let heard = Handoff<Bool>()
        let snapshot = withObservationTracking { h.topology.snapshot() } onChange: { heard.value = true }
        expectEqual(h.topology.recordsRead, read)
        expectEqual(snapshot.edges(of: tree.a).count, 2)
        expectEqual(h.topology.recordsRead, read, "nor does reading it")
        h.editor.transact { $0.insert(link(ShapeID(), tree.a, tree.b)) }
        expectEqual(heard.value, nil, "a commit tells nothing that only took a snapshot")
    },

    test("containers are the kinds that own boards and those that hold shapes on theirs, on the registry, the index and a snapshot") {
        let h = try graph(more: [CorralsPlugin()])
        expectEqual(h.editor.registry.containerKinds, [Pocket.kind, Corral.kind])
        expectEqual(h.topology.containerKinds, [Pocket.kind, Corral.kind])
        expectEqual(h.topology.snapshot().containerKinds, [Pocket.kind, Corral.kind])
        let boards = try graph()
        expectEqual(boards.topology.containerKinds, [Pocket.kind])
        let flat = try Registry(plugins: [FixturesPlugin(), LinksPlugin(), TopologyPlugin()])
        expectEqual(flat.containerKinds, [])
        expectEqual(try Registry(plugins: [FixturesPlugin(), CorralsPlugin(), TopologyPlugin()]).containerKinds, [Corral.kind])
    },

    test("the filters over lists are the variadic ones: equal, admitting alike, and answering alike") {
        let types = try Registry(plugins: graphPlugins()).edgeTypes
        expectEqual(EdgeTypeFilter.within([WireEdge.id, QuoteEdge.id]), .within(WireEdge.id, QuoteEdge.id))
        expectEqual(EdgeTypeFilter.within(Set([tether])), .within(tether))
        expectEqual(EdgeTypeFilter.only([HotWireEdge.id]), .only(HotWireEdge.id))
        expectEqual(EdgeTypeFilter.only(types.descendants(of: WireEdge.id) + [WireEdge.id]), .only(HotWireEdge.id, WireEdge.id))
        expect(EdgeTypeFilter.within([WireEdge.id]) != .only(WireEdge.id))
        for type in types.declared + [tether] {
            expectEqual(EdgeTypeFilter.within([WireEdge.id]).admits(type, in: types), EdgeTypeFilter.within(WireEdge.id).admits(type, in: types))
            expectEqual(EdgeTypeFilter.only([] as [EdgeTypeID]).admits(type, in: types), false, "an empty list admits nothing")
            expectEqual(EdgeTypeFilter.within([] as [EdgeTypeID]).admits(type, in: types), false)
        }
        let tree = Nest()
        let h = try graph(tree.file)
        expectEqual(h.topology.edges(of: tree.c, types: .within([WireEdge.id])), h.topology.edges(of: tree.c, types: .within(WireEdge.id)))
        expectEqual(h.topology.edges(ofType: .only([WireEdge.id])), h.topology.edges(ofType: .only(WireEdge.id)))
    },

    test("summaries: a type's own, one declared by id (a channel's), none by default, and none for a type nobody declares") {
        let summaries = Contributor(id: "summaries") { r in
            r.edgeType(SparkEdge.self)
            r.edgeType("flare", parent: { _ in WireEdge.id }, summary: "a flare, from what sends it up to what it lights")
            r.edgeType("ember", parent: { _ in nil })
        }
        let registry = try Registry(plugins: graphPlugins(more: [summaries]))
        let h = try EditorHarness(plugins: graphPlugins(more: [summaries]))
        for types in [registry.edgeTypes, h.topology.types, h.topology.snapshot().types] {
            expectEqual(types.summary(of: SparkEdge.id), SparkEdge.summary)
            expectEqual(types.summary(of: "flare"), "a flare, from what sends it up to what it lights")
            expectEqual(types.parent(of: "flare"), WireEdge.id)
            expectEqual(types.summary(of: "ember"), nil)
            expectEqual(types.summary(of: WireEdge.id), nil)
            expectEqual(types.summary(of: tether), nil)
        }
        expectEqual(WireEdge.summary, nil, "an edge type says nothing by default")
    },
])

/// A fixture type with a summary of its own.
enum SparkEdge {}
extension SparkEdge: EdgeType {
    static let id: EdgeTypeID = "spark"
    static let summary: String? = "a spark, from the shape that strikes it to the shape it lands on"
}

/// What a walk's body throws to stop it, as its caller's own error type.
private struct Stopped: Error {
    let at: ShapeID
}
