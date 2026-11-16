import Canvas
import CanvasTesting
import Foundation
import Queries
import QueryLanguage
import TestKit
import Topology

// A reach (`QueryState.reaches`): a one-step query followed from a shape until nothing new is found, in
// one capture and one evaluation, each shape met with its hop (the shortest distance), ways (the
// distinct shapes of the hop before that lead to it) and share (1 at hop 1; past it, the sum over its
// ways of their share divided by how many shapes of the next hop each leads to), and the connections it
// ran: travelled (from a hop to the next) or spared (between two shapes of the reach it didn't travel).
// Over chores joined by wires, and the relay's stand-ins.

/// The step downstream of a shape, and the connections it runs.
let downStep = "chore:edge-from(:scope)"
let downBetween = "link:starts-at(:scope)"
/// The same upstream.
let upStep = "chore:edge-to(:scope)"
let upBetween = "link:ends-at(:scope)"

/// Chores 1 to `count` and a link for each pair of `edges`, the k-th (from 0) with id 100 + k.
@MainActor func graphHarness(_ count: Int, _ edges: [(Int, Int)], more: [any CanvasPlugin] = []) throws -> EditorHarness {
    let chores = (1...count).map { chore(id($0), caption: "N\($0)") }
    let links = edges.enumerated().map { link(id(100 + $0.offset), id($0.element.0), id($0.element.1)) }
    return try EditorHarness(plugins: queryPlugins(more: more), file: CanvasFile(root: CanvasDocument(shapes: chores + links)))
}

/// What a batch of reaches answered, the main run loop turned while it runs.
@MainActor func reaching(_ requests: [QueryReachRequest], on h: EditorHarness, file: StaticString = #fileID,
                         line: UInt = #line) throws -> [Result<QueryReach, QueryError>] {
    let queries = try require(h.editor.queries, file: file, line: line)
    return try awaitResult(file: file, line: line) { await queries.reaches(requests) }
}

/// The reach of one shape, downstream by default, with the connections it runs.
@MainActor func reached(from start: Int, up: Bool = false, step: String? = nil, between: String? = nil, edges: EdgeView = .resolved, on h: EditorHarness,
                      file: StaticString = #fileID, line: UInt = #line) throws -> QueryReach {
    let request = QueryReachRequest(step: step ?? (up ? upStep : downStep), between: between ?? (up ? upBetween : downBetween), start: id(start), edges: edges)
    guard case .success(let reach) = try reaching([request], on: h, file: file, line: line)[0] else {
        expect(false, "the reach of \(start) is refused", file: file, line: line)
        throw QueryError(.cancelled, "refused")
    }
    return reach
}

/// A shape's number, for the numbers of a shape's id the fixtures give (chores 1 to 99, links 100 and up).
func number(_ shape: ShapeID) -> Int { (1...300).first { id($0) == shape } ?? -1 }

/// One shape met: its hop, ways and share.
struct Met: Equatable {
    let hop: Int
    let ways: Int
    let share: Double
}

extension QueryReach {
    /// The shapes met by number, with each one's hop, ways and share.
    var met: [Int: Met] {
        var found: [Int: Met] = [:]
        for (index, shape) in ids.enumerated() { found[number(shape)] = Met(hop: hops[index], ways: ways[index], share: shares[index]) }
        return found
    }

    /// The connections travelled by number, each with its hop and share.
    var travelled: [Int: Met] {
        var found: [Int: Met] = [:]
        for (index, carrier) in carriers.enumerated() { found[number(carrier)] = Met(hop: carrierHops[index], ways: 0, share: carrierShares[index]) }
        return found
    }
}

/// Why a reach was refused, or nil if it was answered.
func reachRefusal(_ answer: Result<QueryReach, QueryError>) -> QueryError.Reason? {
    if case .failure(let error) = answer { error.reason } else { nil }
}

/// Hops, as a list: `[2: 1, 3: 2]` is shape 2 at hop 1 and 3 at hop 2.
func hops(_ pairs: KeyValuePairs<Int, Int>) -> [Int: Int] { Dictionary(uniqueKeysWithValues: pairs.map { ($0.key, $0.value) }) }

@MainActor let reachTests = Suite("A reach", [
    test("a chain: each shape at its distance, one way in, a share of 1; the start is not in it; the connections are travelled at their far ends' hops") {
        let h = try graphHarness(5, [(1, 2), (2, 3), (3, 4), (4, 5)])
        let reach = try reached(from: 1, on: h)
        expectEqual(reach.ids, [2, 3, 4, 5].map(id), "nearest first")
        expectEqual(reach.hops, [1, 2, 3, 4])
        expectEqual(reach.ways, [1, 1, 1, 1])
        expectEqual(reach.shares, [1, 1, 1, 1])
        expectEqual(reach.carriers, [100, 101, 102, 103].map(id))
        expectEqual(reach.carrierHops, [1, 2, 3, 4])
        expectEqual(reach.carrierShares, [1, 1, 1, 1])
        expectEqual(reach.spared, [])
        // From the middle, and upstream; 2's and 3's own reach.
        expectEqual(try reached(from: 3, on: h).ids, [4, 5].map(id))
        let up = try reached(from: 3, up: true, on: h)
        expectEqual(up.ids, [2, 1].map(id))
        expectEqual(up.hops, [1, 2])
        expectEqual(up.carriers, [101, 100].map(id))
        expectEqual(try reached(from: 5, on: h).ids, [], "nothing downstream of the end")
        expectEqual(try reached(from: 5, on: h).revision, h.editor.revision)
    },
    test("a diamond: the shape both sides lead to has two ways in and the sum of their shares, which its own child takes whole") {
        let h = try graphHarness(5, [(1, 2), (1, 3), (2, 4), (3, 4), (4, 5)])
        let reach = try reached(from: 1, on: h)
        expectEqual(reach.met, [2: Met(hop: 1, ways: 1, share: 1), 3: Met(hop: 1, ways: 1, share: 1), 4: Met(hop: 2, ways: 2, share: 2),
                                5: Met(hop: 3, ways: 1, share: 2)])
        expectEqual(reach.hops, [1, 1, 2, 3], "nearest hop first")
        expectEqual(reach.travelled[102], Met(hop: 2, ways: 0, share: 2), "an arrow is lit at the share of the shape it reaches")
        expectEqual(reach.travelled[103], Met(hop: 2, ways: 0, share: 2))
        expectEqual(reach.spared, [])
    },
    test("a fan-out: past hop 1 what reaches a shape splits among the shapes it reaches next; hop 1 is whole to each") {
        let h = try graphHarness(8, [(1, 2), (1, 3), (2, 4), (2, 5), (2, 6), (2, 7), (3, 8)])
        let reach = try reached(from: 1, on: h)
        expectEqual(reach.met, [2: Met(hop: 1, ways: 1, share: 1), 3: Met(hop: 1, ways: 1, share: 1),
                                4: Met(hop: 2, ways: 1, share: 0.25), 5: Met(hop: 2, ways: 1, share: 0.25),
                                6: Met(hop: 2, ways: 1, share: 0.25), 7: Met(hop: 2, ways: 1, share: 0.25), 8: Met(hop: 2, ways: 1, share: 1)])
        // And one more hop on: a shape's own share divides in turn.
        let deeper = try graphHarness(7, [(1, 2), (2, 3), (2, 4), (3, 5), (3, 6), (3, 7)])
        // 2 divides its 1 between 3 and 4, and 3 divides its half three ways.
        let sixth = try require(try reached(from: 1, on: deeper).met[5]?.share)
        expect(abs(sixth - 1.0 / 6) < 1e-12, "a sixth: \(sixth)")
    },
    test("a cycle: it ends where it began, the start is never in the answer, and the arrow back to it is spared") {
        let h = try graphHarness(4, [(1, 2), (2, 3), (3, 1), (3, 4)])
        let reach = try reached(from: 1, on: h)
        expectEqual(Set(reach.ids), Set([2, 3, 4].map(id)))
        expect(!reach.ids.contains(id(1)))
        expectEqual(reach.hops, [1, 2, 3])
        expectEqual(reach.carriers.map(number).sorted(), [100, 101, 103])
        let spared = try require(reach.spared.first)
        expectEqual(reach.spared.count, 1)
        expectEqual(spared.carrier, id(102))
        expectEqual(spared.from, QueryReach.End(hop: 2, share: 1), "3, which the arrow starts at")
        expectEqual(spared.to, QueryReach.End(hop: 0, share: 1), "and the start, which it ends at")
        // From inside the cycle the walk comes round to the shape it left, and stops.
        let inside = try reached(from: 2, on: h)
        expectEqual(inside.met.keys.sorted(), [1, 3, 4])
        expectEqual(inside.met[1]?.hop, 2)
        // A shape's arrow to itself leads nowhere.
        let loop = try graphHarness(2, [(1, 1), (1, 2)])
        expectEqual(try reached(from: 1, on: loop).ids, [id(2)])
        expectEqual(try reached(from: 1, on: loop).spared, [])
    },
    test("an arrow within a hop is not followed: it adds no way in, and is spared at the weaker of its ends") {
        let h = try graphHarness(4, [(1, 2), (1, 3), (2, 3), (3, 4)])
        let reach = try reached(from: 1, on: h)
        expectEqual(reach.met, [2: Met(hop: 1, ways: 1, share: 1), 3: Met(hop: 1, ways: 1, share: 1), 4: Met(hop: 2, ways: 1, share: 1)])
        expectEqual(reach.carriers.map(number).sorted(), [100, 101, 103], "not the arrow from 2 to 3")
        expectEqual(reach.spared, [QueryReach.Spared(carrier: id(102), from: QueryReach.End(hop: 1, share: 1), to: QueryReach.End(hop: 1, share: 1))])
    },
    test("an arrow back to an earlier hop is not followed either: it is spared") {
        let h = try graphHarness(4, [(1, 2), (2, 3), (3, 2), (3, 4)])
        let reach = try reached(from: 1, on: h)
        expectEqual(reach.met, [2: Met(hop: 1, ways: 1, share: 1), 3: Met(hop: 2, ways: 1, share: 1), 4: Met(hop: 3, ways: 1, share: 1)])
        expectEqual(reach.spared, [QueryReach.Spared(carrier: id(102), from: QueryReach.End(hop: 2, share: 1), to: QueryReach.End(hop: 1, share: 1))])
        expectEqual(reach.travelled.keys.sorted(), [100, 101, 103])
        // An arrow to a shape the reach never met is neither.
        let apart = try graphHarness(4, [(1, 2), (3, 4)])
        let far = try reached(from: 1, on: apart)
        expectEqual(far.carriers, [id(100)])
        expectEqual(far.spared, [])
    },
    test("travelled and spared are the connections between shapes of the reach: those from a hop to the next, and the rest; none is both") {
        let h = try graphHarness(6, [(1, 2), (1, 3), (2, 4), (3, 4), (2, 3), (4, 2), (4, 1), (5, 6)])
        let reach = try reached(from: 1, on: h)
        expectEqual(reach.travelled.keys.sorted(), [100, 101, 102, 103])
        expectEqual(reach.spared.map { number($0.carrier) }.sorted(), [104, 105, 106])
        expectEqual(Set(reach.carriers).intersection(reach.spared.map(\.carrier)), [])
        expectEqual(reach.spared.first { $0.carrier == id(106) }?.to, QueryReach.End(hop: 0, share: 1), "an arrow to the start")
    },
    test("without a between query the walk finds shapes alone, and a request reads the view it names") {
        let h = try answeredRelay()
        let walk = QueryReachRequest(step: downStep, start: id(3))
        guard case .success(let resolved) = try reaching([walk], on: h)[0] else { return expect(false, "refused") }
        expectEqual(resolved.met.keys.sorted(), [1, 2], "the wire into the proxy reads at Alpha, and the one into the lens at Beta")
        expectEqual(resolved.carriers, [])
        expectEqual(resolved.spared, [])
        var literal = walk
        literal.edges = .literal
        guard case .success(let drawn) = try reaching([literal], on: h)[0] else { return expect(false, "refused") }
        expectEqual(drawn.met.keys.sorted(), [1], "as drawn, the wire to the proxy leaves the chores' hands: only the wire to Alpha")
    },
    test("a pill the reach goes into is in it, at the hop and share of what it stands for; a pill that only stands for a shape reached elsewhere is not") {
        // Gamma 3 to Beta 2, and Beta to the proxy 5, which stands for Alpha 1: the reach goes through the arrow into the pill.
        let into = CanvasFile(root: CanvasDocument(shapes: [chore(id(1), caption: "Alpha"), chore(id(2), caption: "Beta"), chore(id(3), caption: "Gamma"),
                                                            proxy(id(5), [id(1)]), link(id(7), id(3), id(2)), link(id(8), id(2), id(5))]))
        let h = try relay(file: into)
        let reach = try reached(from: 3, on: h)
        expectEqual(reach.met, [2: Met(hop: 1, ways: 1, share: 1), 1: Met(hop: 2, ways: 1, share: 1), 5: Met(hop: 2, ways: 1, share: 1)])
        expectEqual(reach.hops, [1, 2, 2], "the pill is among its hop's")
        expectEqual(reach.travelled[8], Met(hop: 2, ways: 0, share: 1))
        // The same reach, the other way round: the arrow into the pill reads as one out of Alpha, and Beta is upstream of what it stands for.
        let upstream = try reached(from: 1, up: true, on: h)
        expectEqual(upstream.met.keys.sorted(), [2, 3], "Beta, and Gamma behind it")
        expect(!upstream.ids.contains(id(5)), "the pill is on the arrow's near side, not where the reach goes")
        // Alpha is reached by an arrow as drawn, and the proxy only stands for it: it is not in the reach.
        let elsewhere = CanvasFile(root: CanvasDocument(shapes: [chore(id(1), caption: "Alpha"), chore(id(3), caption: "Gamma"), proxy(id(5), [id(1)]),
                                                                 link(id(9), id(3), id(1))]))
        let plain = try reached(from: 3, on: try relay(file: elsewhere))
        expectEqual(plain.ids, [id(1)])
        // A pill that stands for what is provided is in the reach by what it was answered with; one nothing has answered stays where it is.
        let both = try answeredRelay()
        let through = try reached(from: 3, on: both)
        expectEqual(through.met.keys.sorted(), [1, 2, 5, 6], "Alpha and Beta, and the proxy and the lens their arrows went into")
        expectEqual(through.met[5]?.hop, 1)
        expectEqual(through.met[6]?.hop, 1)
        // A pill that stands for two shapes is in the reach once.
        let pair = CanvasFile(root: CanvasDocument(shapes: [chore(id(1), caption: "Alpha"), chore(id(2), caption: "Beta"), chore(id(3), caption: "Gamma"),
                                                            proxy(id(5), [id(1), id(2)]), link(id(7), id(3), id(5)), link(id(8), id(1), id(2))]))
        let twice = try reached(from: 3, on: try relay(file: pair))
        expectEqual(twice.met[1]?.hop, 1)
        expectEqual(twice.met[2]?.hop, 1)
        expectEqual(twice.met[5], Met(hop: 1, ways: 1, share: 1))
        expectEqual(twice.ids.filter { $0 == id(5) }.count, 1, "once")
    },
    test("a pill into a connection that leads to several shapes is at the strongest of them, by the strength the request gives: else the nearest hop, then the greatest share") {
        // 1 -wire-> 2 (A), 2 -> 3 (M), 2 -> 4 (X), 3 -> 5 (Y); the arrow R, hot, joins the pill 6 (for A and M) to the pill 7 (for X and Y), so it runs
        // A to X (hop 1 to 2, travelled), A to Y (spared), M to X (within a hop, spared) and M to Y (hop 2 to 3, travelled). The walk follows plain
        // wires only (`only wire` leaves the hot one out), so R is only found by the between.
        let file = CanvasFile(root: CanvasDocument(shapes: (1...5).map { chore(id($0), caption: "N\($0)") } + [
            proxy(id(6), [id(2), id(3)]), proxy(id(7), [id(4), id(5)]),
            link(id(100), id(1), id(2)), link(id(101), id(2), id(3)), link(id(102), id(2), id(4)), link(id(103), id(3), id(5)),
            link(id(104), id(6), id(7), grade: .hot)]))
        let h = try relay(file: file)
        let step = "chore:edge-from(:scope, only wire)", between = "link:starts-at(:scope)"
        @MainActor func reach(_ strength: (@Sendable (Int, Double) -> Double)?) throws -> QueryReach {
            let request = QueryReachRequest(step: step, between: between, start: id(1), strength: strength)
            guard case .success(let reach) = try reaching([request], on: h)[0] else { throw QueryError(.cancelled, "refused") }
            return reach
        }
        let nearest = try reach(nil)
        expectEqual(nearest.met.filter { $0.key <= 5 }.mapValues(\.hop), hops([2: 1, 3: 2, 4: 2, 5: 3]))
        expectEqual(nearest.met[7]?.hop, 2, "by default the pill is at the nearest of what it stands for, X")
        expectEqual(nearest.travelled[104]?.hop, 2, "and the arrow at its nearest end")
        // Farther is stronger: the pill and the arrow are at Y's hop.
        let farther = try reach { hop, _ in Double(hop) }
        expectEqual(farther.met[7]?.hop, 3, "the pill at the strongest of what it stands for, Y")
        expectEqual(farther.travelled[104]?.hop, 3, "and the arrow at its strongest end")
        expectEqual(farther.met.filter { $0.key <= 5 }, nearest.met.filter { $0.key <= 5 }, "the shapes themselves are as they were")
    },
    test("a connection with several spared runs is spared once, at the run whose weaker end is the strongest") {
        // 1 -> 2 and 1 -> 3 (hop 1), 2 -> 4 (hop 2) and 3 -> 5, 3 -> 6, 3 -> 7 (hop 2: 4 at share 1, 5 to 7 at a third). An arrow R from the
        // pill for 4 and 5 to the pill for 2 and 3 runs from hop 2 back to hop 1, four runs, all spared: 4's two have a weaker end of
        // share 1, 5's two a third.
        let file = CanvasFile(root: CanvasDocument(shapes: (1...7).map { chore(id($0), caption: "N\($0)") } + [
            proxy(id(8), [id(2), id(3)]), proxy(id(9), [id(4), id(5)]),
            link(id(100), id(1), id(2)), link(id(101), id(1), id(3)), link(id(102), id(2), id(4)), link(id(103), id(3), id(5)),
            link(id(104), id(3), id(6)), link(id(105), id(3), id(7)), link(id(106), id(9), id(8), grade: .hot)]))
        let h = try relay(file: file)
        let step = "chore:edge-from(:scope, only wire)", between = "link:starts-at(:scope)"
        let request = QueryReachRequest(step: step, between: between, start: id(1))
        guard case .success(let reach) = try reaching([request], on: h)[0] else { return expect(false, "refused") }
        let spared = reach.spared.filter { $0.carrier == id(106) }
        expectEqual(spared.count, 1, "once")
        // 4 (hop 2, share 1) and 5 (hop 2, share 1/3 of 3's) each run back to 2 and 3 (hop 1): the strongest weaker end is 4's and 2's or 3's.
        let run = try require(spared.first)
        expectEqual(run.from.hop, 2)
        expectEqual(run.to.hop, 1)
        let weakest = min(run.from.share, run.to.share)
        expect(weakest >= 1 - 1e-12, "the run kept has the strongest weaker end: \(run)")
    },
    test("a walk that starts at a stand-in takes its own arrows' far ends at hop 1, and goes on from there") {
        // The pill 5 stands for Alpha 1, and has an arrow of its own to Beta 2; Alpha has one to Gamma 3, Beta one to Delta 4.
        let file = CanvasFile(root: CanvasDocument(shapes: [chore(id(1), caption: "Alpha"), chore(id(2), caption: "Beta"), chore(id(3), caption: "Gamma"),
                                                            chore(id(4), caption: "Delta"), proxy(id(5), [id(1)]),
                                                            link(id(7), id(5), id(2)), link(id(8), id(1), id(3)), link(id(9), id(2), id(4))]))
        let h = try relay(file: file)
        let reach = try reached(from: 5, on: h)
        expectEqual(reach.met[2]?.hop, 1, "Beta, by the pill's own arrow")
        expectEqual(reach.met[4]?.hop, 2, "and Delta on from it")
        expect(reach.travelled[7] != nil, "the pill's own arrow is travelled")
        expectEqual(reach.travelled[7]?.hop, 1)
        // What the pill stands for is hop 1 as well, where the step names the edge to it, and its arrows go on from there.
        expectEqual(reach.met[1]?.hop, 1, "Alpha, which the pill stands for")
        expectEqual(reach.met[3]?.hop, 2, "and Gamma on from it")
        // Hovering Alpha itself finds the pill's arrow too, resolved: an arrow out of a pill is an arrow out of what it stands for.
        expectEqual(try reached(from: 1, on: h).met.keys.sorted(), [2, 3, 4], "Alpha leads to Gamma, and to Beta by the pill's arrow")
    },
    test("a step that is one transitive relation is evaluated once, from the start: all it finds at hop 1, none expanded") {
        let asked = Tally()
        let h = try EditorHarness(plugins: queryPlugins(more: [linesPlugin(asked: asked)]),
                                  file: CanvasFile(root: CanvasDocument(shapes: (1...5).map { chore(id($0), caption: "N\($0)") })))
        // 1 descends from 2, which descends from 3; 4 from 2 and 3; 5 from nothing.
        try require(h.editor.service(Lines.self)).parents = [id(1): [id(2)], id(2): [id(3)], id(4): [id(2), id(3)]]
        let queries = try require(h.editor.queries)
        #if DEBUG
        let before = queries.reachSteps
        #endif
        guard case .success(let all) = try reaching([QueryReachRequest(step: ":descends-from(:scope)", start: id(3))], on: h)[0] else { return expect(false, "refused") }
        expectEqual(all.met, [1: Met(hop: 1, ways: 1, share: 1), 2: Met(hop: 1, ways: 1, share: 1), 4: Met(hop: 1, ways: 1, share: 1)], "however far, all at hop 1")
        #if DEBUG
        expectEqual(queries.reachSteps - before, 1, "one evaluation, of the start")
        #endif
        // The direct relation is walked: each hop is one step, and a shape's step is evaluated for it.
        #if DEBUG
        let walked = queries.reachSteps
        #endif
        guard case .success(let direct) = try reaching([QueryReachRequest(step: ":sprung-from(:scope)", start: id(3))], on: h)[0] else { return expect(false, "refused") }
        expectEqual(direct.met, [2: Met(hop: 1, ways: 1, share: 1), 4: Met(hop: 1, ways: 1, share: 1), 1: Met(hop: 2, ways: 1, share: 1)],
                    "2 leads to 1 and 4, but 4 is at hop 1 already: 1 is all that 2 leads to next, and takes its share whole")
        #if DEBUG
        expectEqual(queries.reachSteps - walked, 4, "the start, 2, 4 and 1")
        #endif
        // A relation of something else than the shape stepped from isn't the case: `:is(...)` around it is walked.
        guard case .success(let wrapped) = try reaching([QueryReachRequest(step: "chore:descends-from(:scope)", start: id(3))], on: h)[0] else { return expect(false, "refused") }
        expectEqual(Set(wrapped.met.keys), [1, 2, 4], "the same shapes, walked")
        expectEqual(wrapped.met.values.map(\.hop).max(), 1, "each is at hop 1 either way: expanding what is already found finds nothing new")
    },
    test(":downstream-of and :upstream-of are the walk's meeting and nothing else: what a reach meets is what they match, but for the start") {
        let graphs: [(count: Int, edges: [(Int, Int)])] = [(5, [(1, 2), (2, 3), (3, 4), (4, 5)]), (5, [(1, 2), (1, 3), (2, 4), (3, 4), (4, 5)]),
                                                          (4, [(1, 2), (2, 3), (3, 1), (3, 4)]), (4, [(1, 2), (1, 3), (2, 3), (3, 4)]),
                                                          (6, [(1, 2), (2, 1), (3, 4), (4, 4), (5, 3)])]
        for graph in graphs {
            let h = try graphHarness(graph.count, graph.edges)
            for start in 1...graph.count {
                for up in [false, true] {
                    let word = up ? "upstream-of" : "downstream-of"
                    let expected = Set(try matched("chore:\(word)(#\(uuid(start)))", on: h)).subtracting([id(start)])
                    let reached = try reached(from: start, up: up, on: h)
                    expectEqual(Set(reached.ids), expected, "\(up ? "upstream" : "downstream") of \(start) in \(graph.edges)")
                    expectEqual(reached.ids.count, Set(reached.ids).count, "each once")
                }
            }
        }
    },
    test("one capture and one evaluation for a batch, a text checked once however many shapes it is asked of, and nothing left held") {
        let h = try graphHarness(6, [(1, 2), (2, 3), (3, 4), (4, 5), (5, 6)])
        let queries = try require(h.editor.queries)
        let captures = queries.captures
        #if DEBUG
        let checks = queries.checks
        #endif
        let requests = (1...6).flatMap { n in [false, true].map { QueryReachRequest(step: $0 ? upStep : downStep, between: $0 ? upBetween : downBetween, start: id(n)) } }
        let answers = try reaching(requests, on: h)
        expectEqual(answers.count, 12)
        expectEqual(queries.captures - captures, 1, "one capture for all twelve")
        #if DEBUG
        expectEqual(queries.checks - checks, 4, "each of the four texts once")
        #endif
        for (index, answer) in answers.enumerated() {
            guard case .success(let reach) = answer else { expect(false, "request \(index) is refused"); continue }
            let (n, up) = (index / 2 + 1, index % 2 == 1)
            expectEqual(reach.ids.count, up ? n - 1 : 6 - n, "\(up ? "up" : "down")stream of \(n)")
            expectEqual(reach.revision, h.editor.revision)
        }
        expectEqual(queries.liveSnapshots, 0)
        expectEqual(try reaching([], on: h).count, 0)
        expectEqual(queries.captures - captures, 1, "no request takes up nothing")
    },
    test("a refusal is one request's: a query that isn't one, a title that is no shape's, a start no shape has; the rest are answered") {
        let h = try graphHarness(3, [(1, 2), (2, 3)])
        let answers = try reaching([QueryReachRequest(step: downStep, start: id(1)), QueryReachRequest(step: "chor:edge-from(:scope)", start: id(1)),
                                    QueryReachRequest(step: downStep, between: #"link:starts-at("Nobody")"#, start: id(1)),
                                    QueryReachRequest(step: downStep, start: id(99)), QueryReachRequest(step: "chore:edge-from(:scope-start)", start: id(1)),
                                    QueryReachRequest(step: downStep, start: id(2))], on: h)
        expectEqual(answers.count, 6)
        guard case .success(let first) = answers[0], case .success(let last) = answers[5] else { return expect(false, "the others are answered") }
        expectEqual(first.ids, [2, 3].map(id))
        expectEqual(last.ids, [id(3)])
        expectEqual(reachRefusal(answers[1]), .unknownKind)
        expectEqual(reachRefusal(answers[2]), .unknownTitle)
        expectEqual(reachRefusal(answers[3]), .unknownID, "a start that isn't a shape")
        guard case .success(let none) = answers[4] else { return expect(false, "`:scope-start` is bound to the shape, and a chore carries no connection: nothing") }
        expectEqual(none.ids, [])
        expectEqual(try require(h.editor.queries).liveSnapshots, 0)
    },
    test("cancelled mid-walk: every request is, nothing is left held, and the walk stopped; the next asks as ever") {
        let slow = SlowWord()
        let h = try graphHarness(30, (1..<30).map { ($0, $0 + 1) }, more: [slowPlugin(slow)])
        let queries = try require(h.editor.queries)
        let running = Box<Task<[Result<QueryReach, QueryError>], Never>?>(nil)
        slow.onAsk = { _ in if slow.calls == 3 { running.value?.cancel() } }
        let requests = [QueryReachRequest(step: "chore:edge-from(:scope):slow", start: id(1)), QueryReachRequest(step: downStep, start: id(1))]
        let task = Task { @MainActor in await queries.reaches(requests) }
        running.value = task
        let answers = try awaitResult { await task.value }
        expectEqual(answers.map(reachRefusal), [.cancelled, .cancelled])
        expect(slow.calls < 30, "it stopped: \(slow.calls) asked of 29")
        expectEqual(queries.liveSnapshots, 0)
        slow.onAsk = nil
        slow.calls = 0
        guard case .success(let whole) = try reaching(requests, on: h)[0] else { return expect(false, "refused") }
        expectEqual(whole.ids.count, 29, "and it runs again")
    },
    test("the deadline: a reach that runs 8 s on the editor's scheduler is refused too_slow, every request, and the one that is quick answers on its own") {
        let slow = SlowWord()
        let h = try graphHarness(20, (1..<20).map { ($0, $0 + 1) }, more: [slowPlugin(slow)])
        let queries = try require(h.editor.queries)
        let slowRequest = QueryReachRequest(step: "chore:edge-from(:scope):slow", start: id(1))
        slow.onAsk = { _ in if slow.calls == 2 { h.wait(8_000) } }
        let answers = try reaching([slowRequest, QueryReachRequest(step: downStep, start: id(1))], on: h)
        expectEqual(answers.map(reachRefusal), [.tooSlow, .tooSlow])
        expect(slow.calls < 20, "it stopped: \(slow.calls) asked of 19")
        expectEqual(h.scheduler.pendingCount, 0, "and its deadline is gone")
        expectEqual(queries.liveSnapshots, 0)
        slow.onAsk = nil
        guard case .success(let quick) = try reaching([QueryReachRequest(step: downStep, start: id(1))], on: h)[0] else { return expect(false, "refused") }
        expectEqual(quick.ids.count, 19)
        // A reach that finishes cancels its deadline.
        expectEqual(h.scheduler.pendingCount, 0)
    },
    test("it runs off the main actor: the walk asks the main actor nothing but the file, once") {
        let h = try graphHarness(40, (1..<40).map { ($0, $0 + 1) })
        let queries = try require(h.editor.queries)
        #if DEBUG
        let slices = queries.mainSlices
        #endif
        _ = try reached(from: 1, on: h)
        #if DEBUG
        expectEqual(queries.mainSlices, slices, "no slice: every step is worked out where the snapshot is")
        #endif
    },
])
