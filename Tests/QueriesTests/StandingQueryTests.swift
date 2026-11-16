@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import Queries
import QueryLanguage
import TestKit
import Topology

// Standing queries (`queries.stand`): one stored query's matches kept over the whole file, asked
// again after each commit for the shapes it changed, and for the whole file only when the commit
// changed what the plan reads beyond a shape. Over the shelf, the yard, the wires and the relay, a
// fact of kin with a revision and one that can't say, and `:gated`, a word whose asks the test holds
// out until it lets them go. What was asked is read off the debug counters: `standingWholeAsks`,
// `standingShapeAsks`, `standingShapesAsked`, and `universeWalks`, which a whole file's answer makes
// (an ask of a commit's shapes that found an anchor moved answers the whole file too, and walks it).

/// Runs the main run loop until nothing the query asked is out.
@MainActor func settle(_ query: StandingQuery, file: StaticString = #fileID, line: UInt = #line) {
    spinRunLoop(until: { query.isSettled }, timeout: 5, file: file, line: line)
}

/// A standing query on `h`, its first answer landed, and what it tells kept in `told`.
@MainActor func standing(_ text: String, on h: EditorHarness, told: Box<[StandingQueryChange]>? = nil,
                         file: StaticString = #fileID, line: UInt = #line) throws -> StandingQuery {
    let queries = try require(h.editor.queries, file: file, line: line)
    let query: StandingQuery
    do throws(QueryError) {
        query = try queries.stand(text)
    } catch {
        expect(false, "\(text) is refused: \(error)", file: file, line: line)
        throw error
    }
    if let told { query.onChange = { told.value.append($0) } }
    settle(query, file: file, line: line)
    expect(query.isAnswered, "\(text) is answered", file: file, line: line)
    return query
}

/// What the standing queries of `h` have asked so far: the whole file, a commit's shapes, how many
/// shapes those named, and the walks of every shape.
@MainActor func asked(on h: EditorHarness) -> [Int] {
    guard let queries = h.editor.queries else { return [] }
    return [queries.standingWholeAsks, queries.standingShapeAsks, queries.standingShapesAsked, queries.universeWalks]
}

func ids(_ numbers: [Int]) -> Set<ShapeID> { Set(numbers.map(id)) }

/// What a query standing afresh on `h` matches: what one kept current must agree with.
@MainActor func afresh(_ text: String, on h: EditorHarness, file: StaticString = #fileID, line: UInt = #line) throws -> Set<ShapeID> {
    let query = try standing(text, on: h, file: file, line: line)
    defer { query.stop() }
    return query.matches
}

// MARK: Kin, a fact of the file

/// Who each shape is kin to directly, set by the test, with a revision that moves as it's set.
@MainActor final class Kin {
    var parents: [ShapeID: [ShapeID]] = [:] {
        didSet { revision += 1 }
    }
    private(set) var revision = 0
}

extension Kin: EditorService {}

/// Kin, with its revision.
struct KinFact: QueryFileFact {
    let parents: [ShapeID: [ShapeID]]

    static func current(in editor: CanvasEditor) -> KinFact { KinFact(parents: editor.service(Kin.self)?.parents ?? [:]) }
    static func revision(in editor: CanvasEditor) -> Int? { editor.service(Kin.self)?.revision }
}

/// Kin, without one: it can't say how far it has come.
struct VagueKinFact: QueryFileFact {
    let parents: [ShapeID: [ShapeID]]

    static func current(in editor: CanvasEditor) -> VagueKinFact { VagueKinFact(parents: editor.service(Kin.self)?.parents ?? [:]) }
}

/// `:kin-of(S)` over `KinFact` and `:vaguely-kin-of(S)` over `VagueKinFact`, both transitive.
func kinPlugin() -> Contributor {
    Contributor(id: "kin") { registrar in
        registrar.service { _ in Kin() }
        registrar.queryRelation("kin-of", "it is kin to a shape the query matches", example: #":kin-of("Ann")"#, reads: .file, transitive: true,
                                prepare: { (file: QueryFilePreparation) in file.fact(KinFact.self) },
                                seeds: { Set($0.parents.keys) },
                                related: { shape, fact in fact.parents[shape] ?? [] })
        registrar.queryRelation("vaguely-kin-of", "it is kin to a shape the query matches", example: #":vaguely-kin-of("Ann")"#, reads: .file,
                                transitive: true,
                                prepare: { (file: QueryFilePreparation) in file.fact(VagueKinFact.self) },
                                seeds: { Set($0.parents.keys) },
                                related: { shape, fact in fact.parents[shape] ?? [] })
    }
}

/// Chores 1 "Ann", 2 "Bea", 3 "Cat" and 4 "Dan"; Ann is kin to Bea.
@MainActor func kinHarness() throws -> EditorHarness {
    let shapes = ["Ann", "Bea", "Cat", "Dan"].enumerated().map { chore(id($0.offset + 1), caption: $0.element) }
    let h = try EditorHarness(plugins: queryPlugins(more: [kinPlugin()]), file: CanvasFile(root: CanvasDocument(shapes: shapes)))
    try require(h.editor.service(Kin.self)).parents = [id(1): [id(2)]]
    return h
}

// MARK: The gate

/// One ask of `:gated`, held or not, as it was taken up: held, each shape it asks waits until it's let go.
final class GateTicket: Sendable {
    let number: Int
    let held: Bool
    private let semaphore = DispatchSemaphore(value: 0)

    init(number: Int, held: Bool) {
        self.number = number
        self.held = held
    }

    /// Waits while it's held.
    func pass() {
        guard held else { return }
        semaphore.wait()
        semaphore.signal()
    }

    func open() { semaphore.signal() }
}

/// Holds the asks taken up while it's closed, each until the test opens its ticket.
@MainActor final class Gate {
    var closed = false
    private(set) var tickets: [GateTicket] = []

    func take() -> GateTicket {
        let ticket = GateTicket(number: tickets.count, held: closed)
        tickets.append(ticket)
        return ticket
    }

    /// Lets every ticket held go.
    func openAll() { for ticket in tickets where ticket.held { ticket.open() } }
}

/// `:gated`: a chore of estimate 5 or more, each ask waiting at the gate while its ticket is held.
func gatePlugin(_ gate: Gate) -> Contributor {
    Contributor(id: "gate") { registrar in
        registrar.queryPseudoClass("gated", "a chore of estimate 5 or more, once the gate lets it by", example: "chore:gated", reads: .file,
                                   prepare: { _ in gate.take() },
                                   matches: { shape, ticket in
                                       ticket.pass()
                                       return ((shape.record.props as? Chore)?.estimate ?? 0) >= 5 ? .yes : .no
                                   })
    }
}

/// Chore `n`'s estimate set, on whatever board it's on.
@MainActor func estimate(_ n: Int, _ value: Int?, on h: EditorHarness) {
    guard let board = h.file.board(containing: id(n)) else { return expect(false, "no chore \(n)") }
    if board == h.editor.board {
        h.editor.transact("Estimate") { $0.update(id(n), as: Chore.self) { $0.props.estimate = value } }
    } else {
        h.editor.transact(on: board, "Estimate") { $0.update(id(n), as: Chore.self) { $0.props.estimate = value } }
    }
}

@MainActor let standingQueryTests = Suite("Standing queries", [
    test("the first answer: every match of the whole file, asked once; pending until it lands") {
        let h = try shelf()
        let queries = try require(h.editor.queries)
        let query = try queries.stand("chore")
        expect(!query.isAnswered)
        expect(query.isAskingWholeFile)
        expect(query.isPending(id(1)), "every shape is pending while the whole file is asked")
        expectEqual(query.answer(for: id(1)), nil)
        expect(!query.isSettled)
        settle(query)
        expect(query.isAnswered)
        expectEqual(query.matches, ids([1, 11, 21]), "on every board")
        expectEqual(query.answer(for: id(1)), true)
        expectEqual(query.answer(for: id(2)), false)
        expectEqual(query.pending, [])
        expectEqual(query.canonical, "chore")
        expectEqual(Array(asked(on: h).prefix(2)), [1, 0])
        expectEqual(queries.liveSnapshots, 0, "nothing is held between answers")
    },
    test("a query that reads the editor, or binds a shape, can't stand") {
        let h = try shelf()
        let queries = try require(h.editor.queries)
        for text in [":audited", ":scope", "chor"] {
            do throws(QueryError) {
                _ = try queries.stand(text)
                expect(false, "\(text) stands")
            } catch {
                expectEqual(error.reason, text == "chor" ? .unknownKind : .unsupported, text)
            }
        }
        expectEqual(Array(asked(on: h).prefix(2)), [0, 0], "nothing asked")
    },
    test("a shape changed to match flips in, and changed back flips out: only that shape asked, no other walked") {
        let h = try shelf()
        let told = Box<[StandingQueryChange]>([])
        let query = try standing("chore[estimate>=5]", on: h, told: told)
        expectEqual(query.matches, [])
        told.value = []
        let before = asked(on: h)
        estimate(11, 8, on: h)
        expectEqual(query.pending, [id(11)], "the shape the commit named")
        expect(query.isPending(id(11)))
        expect(!query.isPending(id(1)))
        expectEqual(query.answer(for: id(11)), nil)
        expectEqual(query.answer(for: id(1)), false)
        settle(query)
        expectEqual(query.matches, [id(11)])
        expectEqual(told.value, [StandingQueryChange(flipped: [], isSettled: false), StandingQueryChange(flipped: [id(11)], isSettled: true)])
        estimate(11, 1, on: h)
        settle(query)
        expectEqual(query.matches, [])
        expectEqual(told.value.last, StandingQueryChange(flipped: [id(11)], isSettled: true))
        let after = asked(on: h)
        expectEqual(after[0], before[0], "no whole file")
        expectEqual(after[1], before[1] + 2, "an ask a commit")
        expectEqual(after[2], before[2] + 2, "one shape each")
        expectEqual(after[3], before[3], "no walk of every shape")
    },
    test("a commit that only moved shapes asks nothing") {
        let h = try shelf()
        let query = try standing("chore[estimate>=5]", on: h)
        let queries = try require(h.editor.queries)
        let before = asked(on: h), captures = queries.captures
        for step in 1...5 { h.editor.transact { $0.moveBox(id(1), to: CGPoint(x: step * 10, y: 0)) } }
        expect(query.isSettled)
        expectEqual(query.pending, [])
        expectEqual(asked(on: h), before)
        expectEqual(queries.captures, captures, "the file isn't even taken up")
    },
    test("a commit of a few shapes asks those and walks no other, whatever the plan's anchors, kinds and titles among them") {
        let h = try yard()
        let texts = ["chore[estimate>=5]", #""Pen" chore"#, #""Pen" > *"#, "corral chore", #"chore:not([caption^="G"])"#, #":inside(corral[caption="Bin"])"#,
                     #"chore:not("Alpha")"#]
        let queries = try texts.map { try standing($0, on: h) }
        expectEqual(queries[1].matches, ids([6, 8, 16, 21, 11]), "inside Pen at any depth: in it, in corral 7, on the pantry's board")
        expectEqual(queries[2].matches, ids([6, 7, 2]))
        let before = asked(on: h)
        let titles = try require(h.editor.queries).derivedTitlesAsked
        estimate(6, 9, on: h)
        estimate(16, 7, on: h)
        for query in queries { settle(query) }
        let after = asked(on: h)
        expectEqual(after[0], before[0], "no whole file")
        expectEqual(after[1], before[1] + 2 * texts.count)
        expectEqual(after[2], before[2] + 2 * texts.count, "one shape each")
        expectEqual(after[3], before[3], "no walk of every shape")
        expectEqual(try require(h.editor.queries).derivedTitlesAsked, titles)
        expectEqual(queries[0].matches, ids([6, 16]))
        expectEqual(queries[1].matches, ids([6, 8, 16, 21, 11]), "as it was")
    },
    test("a fact a word took that moved asks the whole file; one that didn't, the shapes; one that can't say, the whole file each time") {
        let h = try kinHarness()
        let told = Box<[StandingQueryChange]>([])
        let query = try standing(#"chore:kin-of("Bea")"#, on: h, told: told)
        expectEqual(query.matches, ids([1]))
        var before = asked(on: h)
        estimate(3, 4, on: h)
        settle(query)
        expectEqual(asked(on: h)[0], before[0], "the fact as it was: the shape alone")
        expectEqual(asked(on: h)[1], before[1] + 1)
        try require(h.editor.service(Kin.self)).parents[id(3)] = [id(1)]
        expectEqual(asked(on: h)[1], before[1] + 1, "no commit, nothing asked")
        before = asked(on: h)
        estimate(4, 4, on: h)
        settle(query)
        expectEqual(asked(on: h)[0], before[0] + 1, "the fact moved: the whole file")
        expectEqual(query.matches, ids([1, 3]), "Cat is kin to Ann, who is kin to Bea")
        expectEqual(told.value.last, StandingQueryChange(flipped: [id(3)], isSettled: true))
        before = asked(on: h)
        estimate(4, 5, on: h)
        settle(query)
        expectEqual(asked(on: h)[0], before[0], "and as it was after that")

        let vague = try standing(#"chore:vaguely-kin-of("Bea")"#, on: h)
        expectEqual(vague.matches, ids([1, 3]))
        before = asked(on: h)
        estimate(4, 6, on: h)
        settle(vague)
        settle(query)
        expectEqual(asked(on: h)[0], before[0] + 1, "a fact that can't say: the whole file, for the plan that reads it alone")
        before = asked(on: h)
        h.editor.transact { $0.moveBox(id(4), to: CGPoint(x: 30, y: 30)) }
        expectEqual(asked(on: h), before, "but never for a move")
    },
    test("a renamed anchor title asks the whole file for a plan that names it, and not for one that doesn't") {
        let h = try yard()
        let told = Box<[StandingQueryChange]>([])
        let named = try standing(#""Pen" chore"#, on: h, told: told)
        let kinds = try standing("corral chore", on: h)
        let before = asked(on: h)
        h.editor.transact("Rename") { $0.update(id(5)) { $0[Caption.self] = "Pound" } }
        settle(named)
        settle(kinds)
        let after = asked(on: h)
        expectEqual(after[1], before[1] + 2, "each asks the corral")
        expectEqual(after[3], before[3] + 1, "the one whose anchor it moved answers the whole file")
        expectEqual(named.matches, [])
        expectEqual(told.value.last, StandingQueryChange(flipped: ids([6, 8, 16, 21, 11]), isSettled: true))
        expectEqual(kinds.matches, ids([6, 8, 16, 21, 11]))
        h.editor.transact("Rename") { $0.update(id(1)) { $0[Caption.self] = "Pen" } }
        settle(named)
        expectEqual(asked(on: h)[3], after[3] + 1, "a shape given the title moves the anchor too")
        expectEqual(named.matches, [], "a chore holds nothing")
    },
    test("an edge changed asks the whole file for a plan that reads edges of its type, and not for one that doesn't") {
        let h = try wiresHarness()
        let edges = try standing(#"chore:edge-to("C2")"#, on: h)
        let wires = try standing(#"chore:edge-to("C3", hot-wire)"#, on: h)
        let captions = try standing(#"chore[caption^="C"]"#, on: h)
        expectEqual(edges.matches, ids([1]))
        expectEqual(wires.matches, ids([2]))
        let before = asked(on: h)
        h.editor.transact("Rewire") { $0.update(id(11), as: Link.self) { $0.props.from = id(4) } }
        for query in [edges, wires, captions] { settle(query) }
        let after = asked(on: h)
        expectEqual(after[0], before[0] + 1, "a wire changed: the whole file for the plan of every wire")
        expectEqual(after[1], before[1] + 2, "the link asked by the others")
        expectEqual(edges.matches, ids([4]))
        expectEqual(wires.matches, ids([2]), "a hot wire's plan reads no plain wire")
        expectEqual(captions.matches, ids(Array(1...6)))
    },
    test("a stand-in's answer, which no commit carries, asks the whole file for a plan that reads its edges") {
        let h = try relay()
        let edges = try standing(#"chore:edge-from("Gamma")"#, on: h)
        let captions = try standing(#"chore[caption^="B"]"#, on: h)
        expectEqual(edges.matches, ids([1]))
        let before = asked(on: h)
        try require(h.editor.topology).provide([id(6): provided("q", [id(2)])])
        spinRunLoop(until: { edges.matches.contains(id(2)) && edges.isSettled }, timeout: 5)
        expectEqual(edges.matches, ids([1, 2]), "the lens stands for Beta now")
        settle(captions)
        expectEqual(asked(on: h)[0], before[0] + 1, "the plan of edges alone")
        expectEqual(asked(on: h)[1], before[1])
    },
    test("a container moved asks the whole file for a plan that reads containment, and not for one that doesn't") {
        let h = try yard()
        let told = Box<[StandingQueryChange]>([])
        let nested = try standing("corral corral chore", on: h, told: told)
        let plain = try standing("chore[estimate>=5]", on: h)
        expectEqual(nested.matches, ids([8, 16, 21]), "in corral 7, in Pen; in Bin, on the board of a pocket in Pen")
        var before = asked(on: h)
        h.editor.transact("Move out") { $0.setContainer(id(7), to: nil) }
        settle(nested)
        settle(plain)
        expectEqual(asked(on: h)[0], before[0] + 1, "the corral left Pen, with chore 8: the whole file")
        expectEqual(asked(on: h)[1], before[1] + 1, "the plain plan asks the corral")
        expectEqual(nested.matches, ids([16, 21]))
        expectEqual(told.value.last, StandingQueryChange(flipped: ids([8]), isSettled: true))
        before = asked(on: h)
        h.editor.transact("Move in") { $0.setContainer(id(9), to: id(5)) }
        settle(nested)
        expectEqual(asked(on: h)[0], before[0], "a chore holds nothing: asked itself")
        expectEqual(nested.matches, ids([16, 21]))
        h.editor.transact("Move in") { $0.setContainer(id(9), to: id(7)) }
        settle(nested)
        expectEqual(nested.matches, ids([16, 21]), "corral 7 is in nothing now")
    },
    test("a shape that holds nothing put in or taken out of a container asks the containers it leaves and joins, for a plan of what's inside") {
        let h = try yard()
        let chores = try standing("corral:has(chore)", on: h)
        let alpha = try standing(#"corral:has("Alpha")"#, on: h)
        let anchored = try standing("chore:inside(:has(chore))", on: h)
        expectEqual(chores.matches, ids([5, 7, 15]), "Pen through corral 7 and the pantry's board, 7 holding 8, Bin holding 16")
        expectEqual(alpha.matches, [])
        expectEqual(anchored.matches, ids([6, 8, 16, 21, 11]))
        let all = [chores, alpha, anchored]
        @MainActor func agree(_ why: String) throws {
            for query in all { settle(query) }
            for query in all { expectEqual(query.matches, try afresh(query.canonical, on: h), "\(query.canonical): \(why)") }
        }
        var before = asked(on: h)
        h.editor.transact("Move out") { $0.setContainer(id(8), to: nil) }
        for query in all { settle(query) }
        expectEqual(chores.matches, ids([5, 15]), "corral 7 holds no chore now")
        expectEqual(asked(on: h)[0], before[0], "no whole file asked as such")
        expectEqual(asked(on: h)[1], before[1] + 3)
        expectEqual(asked(on: h)[2], before[2] + 9, "each asked chore 8, corral 7 and Pen, which 7 is in")
        expect(asked(on: h)[3] > before[3], "corral 7 had a chore and has none: the anchor moved, and the plan inside it answered the whole file")
        try agree("chore 8 out of corral 7")
        before = asked(on: h)
        h.editor.transact("Move in") { $0.setContainer(id(1), to: id(5)) }
        for query in all { settle(query) }
        expectEqual(alpha.matches, [id(5)], "Alpha in Pen")
        expectEqual(asked(on: h)[0], before[0])
        expectEqual(asked(on: h)[2], before[2] + 6, "each asked Alpha and Pen")
        expectEqual(asked(on: h)[3], before[3], "no anchor moved: no walk")
        try agree("Alpha into Pen")
        h.editor.transact("Move in") { $0.setContainer(id(1), to: id(7)) }
        try agree("Alpha into corral 7, in Pen")
        expectEqual(alpha.matches, ids([5, 7]))
        expectEqual(anchored.matches, ids([6, 16, 21, 11, 1]), "corral 7 has a chore again")
        h.editor.transact("Move out") { $0.setContainer(id(1), to: nil) }
        try agree("Alpha out of everything")
        expectEqual(alpha.matches, [])
        before = asked(on: h)
        h.editor.transact("Move") { $0.move([id(1)], to: BoardID(owner: id(12))) }
        for query in all { settle(query) }
        expectEqual(asked(on: h)[0], before[0] + 3, "to another board, where it was before isn't said: the whole file")
        try agree("Alpha onto pocket 12's board, in Bin")
        expectEqual(alpha.matches, ids([5, 15]), "pocket 12 is in Bin, on the pantry's board, which is in Pen")
    },
    test("removed shapes leave at once, asking nothing; one an anchor matched asks the whole file") {
        let h = try yard()
        let told = Box<[StandingQueryChange]>([])
        let query = try standing(#""Pen" chore"#, on: h, told: told)
        let before = asked(on: h)
        h.editor.transact("Delete") { $0.delete([id(8)]) }
        expectEqual(query.matches, ids([6, 16, 21, 11]), "gone as the commit settles")
        expectEqual(told.value.last, StandingQueryChange(flipped: [id(8)], isSettled: true))
        expect(query.isSettled)
        expectEqual(asked(on: h), before, "nothing asked")
        h.editor.transact("Delete") { $0.delete([id(5)]) }
        settle(query)
        expectEqual(asked(on: h)[0], before[0] + 1, "Pen itself: the whole file")
        expectEqual(query.matches, [])
        h.editor.undo()
        settle(query)
        expectEqual(query.matches, ids([6, 16, 21, 11]), "put back")
    },
    test("pending while an ask is out, and a commit while the whole file is asked waits for it") {
        let gate = Gate()
        let h = try shelf(more: [gatePlugin(gate)])
        let query = try standing("chore:gated", on: h)
        gate.closed = true
        estimate(1, 9, on: h)
        spinRunLoop(until: { gate.tickets.count == 2 }, timeout: 2)
        expect(!query.isSettled)
        expectEqual(query.pending, [id(1)])
        expectEqual(query.answer(for: id(1)), nil)
        expectEqual(query.answer(for: id(11)), false)
        gate.openAll()
        settle(query)
        expectEqual(query.matches, ids([1]))
        // The whole file asked again (a file put in place), held: every shape pending, and a commit meanwhile owed.
        h.editor.replaceFile(with: Shelf().file)
        expect(query.isAskingWholeFile)
        expect(query.isPending(id(21)))
        estimate(21, 6, on: h)
        expectEqual(query.pending, [id(21)])
        gate.openAll()
        spinRunLoop(until: { !query.isAskingWholeFile }, timeout: 5)
        expect(query.isPending(id(21)), "taken up before chore 21 changed: asked once the whole file lands")
        expect(!query.isPending(id(1)))
        expectEqual(query.answer(for: id(1)), false, "the file put in place has chore 1 as it was")
        gate.openAll()
        settle(query)
        gate.openAll()
        expectEqual(query.matches, ids([21]))
        expectEqual(query.pending, [])
    },
    test("the last answer it had is kept while a shape is asked again: nil for a shape it never answered, a first answer not landed, and a file put in place") {
        let h = try shelf()
        let queries = try require(h.editor.queries)
        let query = try queries.stand("chore[estimate>=5]")
        expectEqual(query.lastAnswer(for: id(1)), nil, "before its first answer")
        settle(query)
        expectEqual(query.lastAnswer(for: id(1)), false)
        estimate(1, 8, on: h)
        expectEqual(query.answer(for: id(1)), nil, "asked again")
        expectEqual(query.lastAnswer(for: id(1)), false, "what it had")
        settle(query)
        expectEqual(query.lastAnswer(for: id(1)), true)
        estimate(1, 2, on: h)
        expectEqual(query.lastAnswer(for: id(1)), true, "a yes is kept as a no is")
        // A shape new to the file has no answer to keep.
        h.editor.transact("Add") { $0.insert(chore(id(7), caption: "Zeta")) }
        expectEqual(query.lastAnswer(for: id(7)), nil, "new to the file")
        expectEqual(query.lastAnswer(for: id(1)), true, "the shape asked beside it keeps its own")
        settle(query)
        expectEqual(query.lastAnswer(for: id(7)), false)
        expectEqual(query.lastAnswer(for: id(1)), false)
        // A shape added while the whole file is asked: its ask is owed, and it has none until that lands.
        let gate = Gate()
        let g = try shelf(more: [gatePlugin(gate)])
        let waiting = try standing("chore:gated", on: g)
        gate.closed = true
        g.editor.replaceFile(with: Shelf().file)
        expect(waiting.isAskingWholeFile)
        expectEqual(waiting.lastAnswer(for: id(1)), nil, "a file put in place: what it had is of the file before")
        g.editor.transact("Add") { $0.insert(chore(id(7), caption: "Zeta")) }
        gate.openAll()
        spinRunLoop(until: { !waiting.isAskingWholeFile }, timeout: 5)
        expectEqual(waiting.lastAnswer(for: id(1)), false, "answered by the whole file")
        expectEqual(waiting.lastAnswer(for: id(7)), nil, "the whole file was taken up before the shape came")
        gate.openAll()
        settle(waiting)
        gate.openAll()
        expectEqual(waiting.lastAnswer(for: id(7)), false)
    },
    test("the whole file asked again for a fact that moved keeps what each shape last answered") {
        let h = try kinHarness()
        let query = try standing(#"chore:kin-of("Bea")"#, on: h)
        expectEqual(query.matches, ids([1]))
        try require(h.editor.service(Kin.self)).parents[id(3)] = [id(1)]
        estimate(4, 4, on: h)
        expect(query.isAskingWholeFile, "the fact moved: the whole file")
        expectEqual(query.answer(for: id(3)), nil)
        expectEqual(query.lastAnswer(for: id(1)), true)
        expectEqual(query.lastAnswer(for: id(3)), false, "what it had, until the new answer lands")
        settle(query)
        expectEqual(query.lastAnswer(for: id(3)), true)
    },
    test("an answer older than a newer ask about the same shape is dropped when it lands last") {
        let gate = Gate()
        let h = try shelf(more: [gatePlugin(gate)])
        let told = Box<[StandingQueryChange]>([])
        let query = try standing("chore:gated", on: h, told: told)
        told.value = []
        gate.closed = true
        estimate(11, 9, on: h)
        estimate(11, 2, on: h)
        spinRunLoop(until: { gate.tickets.count == 3 }, timeout: 2)
        let (first, second) = (gate.tickets[1], gate.tickets[2])
        second.open()
        spinRunLoop(until: { !query.isPending(id(11)) }, timeout: 5)
        expectEqual(query.matches, [], "the newer answer: estimate 2")
        expect(!query.isSettled, "the older ask is still out")
        first.open()
        settle(query)
        expectEqual(query.matches, [], "the older answer, estimate 9, is dropped")
        expect(!told.value.contains { !$0.flipped.isEmpty }, "nothing flipped: \(told.value)")
    },
    test("a failed ask's shapes are asked again by the next commit, and a failed whole file's by the next drag") {
        let gate = Gate()
        let h = try shelf(more: [gatePlugin(gate)])
        let query = try standing("chore:inside(:gated)", on: h)
        let queries = try require(h.editor.queries)
        gate.closed = true
        estimate(1, 9, on: h)
        spinRunLoop(until: { gate.tickets.count == 2 }, timeout: 2)
        h.scheduler.advance(by: .seconds(30))
        gate.openAll()
        spinRunLoop(until: { query.failure != nil }, timeout: 5)
        expectEqual(query.failure?.reason, .tooSlow)
        expect(query.isPending(id(1)))
        expect(query.isSettled, "nothing out")
        gate.closed = false
        var before = asked(on: h)
        estimate(11, 9, on: h)
        settle(query)
        expectEqual(asked(on: h)[1], before[1] + 1)
        expectEqual(asked(on: h)[2], before[2] + 2, "chore 11, and chore 1 again")
        expect(!query.isPending(id(1)))
        expectEqual(query.answer(for: id(1)), false)
        expectEqual(query.failure, nil)
        // The whole file failed: a drag's next event asks it again.
        gate.closed = true
        h.editor.replaceFile(with: Shelf().file)
        spinRunLoop(until: { gate.tickets.count >= 4 }, timeout: 2)
        h.scheduler.advance(by: .seconds(30))
        gate.openAll()
        spinRunLoop(until: { query.failure != nil }, timeout: 5)
        expect(query.isPending(id(21)), "every shape, the whole file's ask having failed")
        gate.closed = false
        before = asked(on: h)
        h.editor.transact { $0.moveBox(id(1), to: CGPoint(x: 30, y: 0)) }
        settle(query)
        expectEqual(asked(on: h)[0], before[0] + 1)
        expect(!query.isPending(id(21)))
        expectEqual(query.failure, nil)
        expectEqual(queries.liveSnapshots, 0)
    },
    test("stopped, or let go of, it asks nothing more and tells nothing; what it had out is cancelled") {
        let gate = Gate()
        let h = try shelf(more: [gatePlugin(gate)])
        let told = Box<[StandingQueryChange]>([])
        let query = try standing("chore:gated", on: h, told: told)
        told.value = []
        query.stop()
        expect(query.isStopped)
        let before = asked(on: h)
        estimate(1, 9, on: h)
        expectEqual(asked(on: h), before)
        expectEqual(told.value, [])
        expectEqual(query.matches, [], "as it was")

        var held: StandingQuery? = try standing("chore:gated", on: h, told: told)
        weak var gone = held
        told.value = []
        gate.closed = true
        estimate(11, 9, on: h)
        spinRunLoop(until: { gate.tickets.count == 3 }, timeout: 2)
        held = nil
        expect(gone == nil, "nothing keeps it")
        let after = asked(on: h)
        gate.openAll()
        spinRunLoop(until: { (h.editor.queries?.liveSnapshots ?? 1) == 0 }, timeout: 5)
        estimate(21, 9, on: h)
        expectEqual(asked(on: h), after, "let go, it asks nothing")
        expectEqual(told.value.filter { !$0.flipped.isEmpty }, [])
    },
    test("an editor gone stops it: the ask out answers nothing, and the editor isn't kept") {
        let gate = Gate()
        let scheduler = ManualScheduler()
        let editor = Box<CanvasEditor?>(CanvasEditor(registry: try Registry(plugins: queryPlugins(more: [gatePlugin(gate)])), file: Shelf().file,
                                                     scheduler: scheduler))
        weak var closed = editor.value
        let queries = try require(editor.value?.queries)
        gate.closed = true
        let query = try queries.stand("chore:gated")
        spinRunLoop(until: { gate.tickets.count == 1 }, timeout: 2)
        editor.value = nil
        expect(closed == nil, "the editor went")
        gate.openAll()
        spinRunLoop(until: { query.isStopped }, timeout: 5)
        expect(!query.isAnswered)
        expectEqual(query.matches, [])

        // And the editor's queries going with it stop every standing query at once.
        let other = Box<CanvasEditor?>(CanvasEditor(registry: try Registry(plugins: queryPlugins()), file: Shelf().file, scheduler: scheduler))
        let alone = try require(other.value?.queries).stand("chore")
        spinRunLoop(until: { alone.isSettled }, timeout: 5)
        other.value = nil
        expect(alone.isStopped)
    },
    test("none held, no upkeep: commits ask nothing and nothing follows Topology") {
        let h = try wiresHarness()
        let queries = try require(h.editor.queries)
        estimate(1, 3, on: h)
        h.editor.transact("Rewire") { $0.update(id(11), as: Link.self) { $0.props.from = id(4) } }
        expectEqual(Array(asked(on: h).prefix(3)), [0, 0, 0])
        let query = try standing("chore", on: h)
        query.stop()
        let before = asked(on: h), captures = queries.captures
        estimate(1, 4, on: h)
        h.editor.transact("Rewire") { $0.update(id(11), as: Link.self) { $0.props.from = id(1) } }
        expectEqual(asked(on: h), before)
        expectEqual(queries.captures, captures)
        expectEqual(queries.liveSnapshots, 0)
    },
])
