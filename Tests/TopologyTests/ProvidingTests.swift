@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import TestKit
import Topology

// Answers provided for stand-ins that stand for what's provided (`provide`, over the lenses of
// `StandInFixtures.swift`), the one delivery of every change to the edges (`follow`), and settling
// (`keepsSettling`, `settled(timeout:)`).

@MainActor let providingTests = Suite("Provided answers, following and settling", [
    test("a lens stands for nothing until an answer for the key its record holds comes, then for what it names") {
        let a = ShapeID(), c = ShapeID(), b = ShapeID(), r = ShapeID(), l = ShapeID()
        let h = try lensing(CanvasFile(root: board(box(a), box(c), box(b), lens(r, asks: "first"), link(l, b, r))))
        let topology = h.topology
        expectEqual(topology.standInKinds, [Proxy.kind, Gate.kind, Lens.kind])
        expectEqual(topology.forwarding(of: r), .pending)
        expectEqual(topology.pendingStandIns, [r])
        expectEqual(topology.edges(carriedBy: l), [edge(WireEdge.id, b, r, by: l)], "asked, not answered: the arrow stays at the lens")
        let onA = topology.revision(of: a), onR = topology.revision(of: r)

        topology.provide([r: answer("first", [a, c])])
        expectEqual(topology.forwards(of: r), [a, c])
        expectEqual(topology.forwarding(of: r), .provided([a, c]))
        expectEqual(topology.pendingStandIns, [])
        expectEqual(topology.edges(carriedBy: l), [a, c].map { forwarded(WireEdge.id, b, $0, by: l, to: r) })
        expectEqual(topology.edges(carriedBy: r), [stands(r, for: a), stands(r, for: c)])
        expectEqual(topology.touched, [b, a, c, r], "a provide's ends")
        expectEqual(topology.touched(types: .only(StandingEdge.id)), [r, a, c])
        expect(topology.revision(of: a) > onA)
        expect(topology.revision(of: r) > onR)

        // The recorded view leaves a stand-in for what's provided at its own end, with no standing
        // edges; the literal view is as emitted.
        expectEqual(topology.edges(carriedBy: l, view: .recorded), [edge(WireEdge.id, b, r, by: l)])
        expectEqual(topology.edges(of: a, view: .recorded), [])
        expectEqual(topology.edges(of: r, view: .recorded), [edge(WireEdge.id, b, r, by: l)])
        expectEqual(topology.edges(ofType: .all, view: .recorded), [edge(WireEdge.id, b, r, by: l)])
        expectEqual(topology.snapshot(.recorded).presentTypes, [WireEdge.id])
        expectEqual(topology.snapshot().presentTypes, [WireEdge.id, StandingEdge.id])
        expectEqual(topology.edges(carriedBy: l, view: .literal), [edge(WireEdge.id, b, r, by: l)])
        try expectAnswered(h, [r: answer("first", [a, c])], "answered")
    },

    test("an edge between a stand-in for what's named and one for what's provided: the recorded view reverts only the provided end") {
        let a = ShapeID(), c = ShapeID(), r = ShapeID(), p = ShapeID(), s = ShapeID(), l = ShapeID(), m = ShapeID()
        let h = try lensing(CanvasFile(root: board(box(a), box(c), lens(r, asks: "q"), lens(s, asks: "q"), proxy(p, [c]), link(l, r, p), link(m, r, s))))
        let topology = h.topology
        topology.provide([r: answer("q", [a, c]), s: answer("q", [c])])
        expectEqual(topology.edges(carriedBy: l), [forwarded(WireEdge.id, a, c, by: l, from: r, to: p), forwarded(WireEdge.id, c, c, by: l, from: r, to: p)])
        expectEqual(topology.edges(carriedBy: l, view: .recorded), [forwarded(WireEdge.id, r, c, by: l, to: p)], "the copies for the lens's end are one")
        expectEqual(topology.edges(carriedBy: l, view: .literal), [edge(WireEdge.id, r, p, by: l)])
        expectEqual(topology.edges(carriedBy: m, view: .recorded), [edge(WireEdge.id, r, s, by: m)], "both ends reverted: as emitted")
        expectEqual(topology.edges(of: r, .outgoing, types: .within(WireEdge.id), view: .recorded), [forwarded(WireEdge.id, r, c, by: l, to: p), edge(WireEdge.id, r, s, by: m)])
        expectEqual(topology.edges(of: p, .incoming, types: .within(WireEdge.id), view: .recorded), [], "as resolved, a forwarded edge is at the shapes it reaches, not the stand-in it went through")
        expectEqual(topology.edges(of: c, .incoming, types: .within(WireEdge.id), view: .recorded), [forwarded(WireEdge.id, r, c, by: l, to: p)])
        expectEqual(topology.edges(of: a, view: .recorded), [])
        expectEqual(topology.neighbors(of: r, .outgoing, types: .within(WireEdge.id), view: .recorded), [WireEdge.id: [c, s]])
        expect(!topology.hasEdges(of: a, view: .recorded))
    },

    test("an answer for another key, an older one, and one for a shape that isn't a lens are dropped, touching nothing") {
        let a = ShapeID(), c = ShapeID(), b = ShapeID(), r = ShapeID(), p = ShapeID(), l = ShapeID()
        let h = try lensing(CanvasFile(root: board(box(a), box(c), box(b), lens(r, asks: "first"), proxy(p, [a]), link(l, b, r))))
        let topology = h.topology
        var heard: [TopologyChange] = []
        let following = topology.follow { heard.append($0) }
        topology.provide([r: answer("first", [a], 3)])
        expectEqual(heard.count, 1)
        let touched = topology.touched, onC = topology.revision(of: c)

        topology.provide([r: answer("second", [c], 4)])
        expectEqual(topology.forwards(of: r), [a], "another key: dropped")
        topology.provide([r: answer("first", [c], 2)])
        expectEqual(topology.forwards(of: r), [a], "older: dropped")
        topology.provide([r: answer("first", [a], 3)])
        topology.provide([b: answer("first", [c]), p: answer("first", [c]), ShapeID(): answer("first", [c])])
        expectEqual(topology.forwards(of: p), [a], "a proxy goes by its record")
        expectEqual(topology.touched, touched, "nothing changed: touched is the last change's")
        expectEqual(topology.revision(of: c), onC)
        expectEqual(heard.count, 1, "nothing told")

        topology.provide([r: answer("first", [c], 3)])
        expectEqual(topology.forwards(of: r), [c], "as recent as the one held: taken")
        topology.provide([r: answer("first", [a, c], 9)])
        expectEqual(topology.forwards(of: r), [a, c])
        expectEqual(heard.count, 3)
        following.cancel()
    },

    test("a commit that changes the key lets go of the answer, so an undo waits for one, and takes an older one again") {
        let a = ShapeID(), b = ShapeID(), r = ShapeID(), l = ShapeID()
        let h = try lensing(CanvasFile(root: board(box(a), box(b), lens(r, asks: "first"), link(l, b, r))))
        let topology = h.topology
        topology.provide([r: answer("first", [a], 7)])
        h.editor.transact("Ask") { $0.update(r, as: Lens.self) { $0.props.asks = "second" } }
        expectEqual(topology.forwarding(of: r), .pending, "asks again: the answer was for another question")
        expectEqual(topology.pendingStandIns, [r])
        expectEqual(topology.edges(carriedBy: l), [edge(WireEdge.id, b, r, by: l)])
        expectEqual(topology.touched, [b, a, r], "back at the lens")
        topology.provide([r: answer("first", [a], 8)])
        expectEqual(topology.forwards(of: r), [], "for the key it held before: dropped")

        h.editor.undo()
        expectEqual(topology.forwarding(of: r), .pending, "an undo asks the first question again, which nothing has answered since")
        topology.provide([r: answer("first", [a], 1)])
        expectEqual(topology.forwards(of: r), [a], "no answer held for the key: an older revision is taken (a memo given again)")

        h.editor.transact("Delete") { $0.delete([r]) }
        expectEqual(topology.pendingStandIns, [])
        h.editor.undo()
        expectEqual(topology.forwarding(of: r), .pending, "deleted and back: its answer went with it")
        h.editor.transact("Ask nothing") { $0.update(r, as: Lens.self) { $0.props.asks = "" } }
        expectEqual(topology.forwarding(of: r), .none)
        expectEqual(topology.pendingStandIns, [])
    },

    test("an answer's shapes are held to the rule, and a commit to one of them looks at the lens again") {
        let loaded = try hiddenFile()
        let a = ShapeID(), c = ShapeID(), d = ShapeID(), b = ShapeID(), r = ShapeID(), p = ShapeID(), l = ShapeID(), gone = ShapeID()
        let records = [box(a), box(c), box(d), box(b), lens(r, asks: "q"), proxy(p, [a]), link(l, b, r)]
        let h = try lensing(CanvasFile(root: CanvasDocument(shapes: loaded.file.root.shapes + records), children: loaded.file.children),
                            most: 2)
        let topology = h.topology
        let named = [gone, id(10), id(11), p, r, a, a, c, d]
        topology.provide([r: answer("q", named)])
        expectEqual(topology.forwards(of: r), [a, c], "missing, kept aside, unavailable, a stand-in, itself, again, past its most")
        let read = topology.recordsRead
        h.editor.transact("Delete") { $0.delete([a]) }
        expectEqual(topology.forwards(of: r), [c, d])
        expectEqual(topology.edges(carriedBy: l), [c, d].map { forwarded(WireEdge.id, b, $0, by: l, to: r) })
        expectEqual(topology.recordsRead, read, "a box and a lens carry nothing to read; the answer is kept")
        h.editor.undo()
        expectEqual(topology.forwards(of: r), [a, c])
        try expectAnswered(h, [r: answer("q", named)], "after undo")
        h.editor.transact { $0.moveBox(c, to: CGPoint(x: 400, y: 0)) }
        expectEqual(topology.recordsRead, read, "a move reads nothing")
        expectEqual(topology.touched, [])

        let gated = try lensing(CanvasFile(root: board(open(a), box(c), lens(r, asks: "q"))), gated: true)
        gated.topology.provide([r: answer("q", [a, c])])
        expectEqual(gated.topology.forwards(of: r), [a], "admitted")
        gated.editor.transact { $0.update(c) { $0.meta[Open.self] = true } }
        expectEqual(gated.topology.forwards(of: r), [a, c], "opened: a change to an answer's shape alone")
    },

    test("an arrow between two lenses for 50 each is held to the cap, and a provide sets only the carriers at the lenses it changed") {
        let first = (0..<50).map { _ in ShapeID() }, second = (0..<50).map { _ in ShapeID() }
        let r = ShapeID(), s = ShapeID(), l = ShapeID(), b = ShapeID(), m = ShapeID(), far = ShapeID(), n = ShapeID()
        let shapes = (first + second + [b, far]).map(box) + [lens(r, asks: "all"), lens(s, asks: "all"), link(l, r, s), link(m, b, r), link(n, far, far)]
        let h = try lensing(CanvasFile(root: CanvasDocument(shapes: shapes)))
        let topology = h.topology
        topology.provide([r: answer("all", first), s: answer("all", second)])
        expectEqual(topology.edges(carriedBy: l).count, EdgeForwarding.maxPairsPerCarrier)
        expectEqual(topology.edges(carriedBy: m).count, 50)
        let onFar = topology.revision(of: far)
        topology.provide([r: answer("all", second, 2)])
        expectEqual(topology.edges(carriedBy: m).map(\.target), second)
        expectEqual(topology.edges(carriedBy: l).count, EdgeForwarding.maxPairsPerCarrier)
        expectEqual(topology.revision(of: far), onFar)
        expect(!topology.touched.contains(far))
        try expectAnswered(h, [r: answer("all", second), s: answer("all", second)], "fanned out")
    },

    test("followers hear every change to the edges once, a commit's, a provide's and a rebuild's, and touched is the last change's") {
        let a = ShapeID(), c = ShapeID(), b = ShapeID(), r = ShapeID(), l = ShapeID()
        let h = try lensing(CanvasFile(root: board(box(a), box(c), box(b), lens(r, asks: "q"))))
        let topology = h.topology
        var heard: [(cause: TopologyChange.Cause, touched: Set<ShapeID>, wires: Set<ShapeID>, atCall: Set<ShapeID>)] = []
        var order: [String] = []
        var following: TopologyFollowing? = topology.follow { change in
            heard.append((change.cause, change.touched, change.touched(types: .within(WireEdge.id), in: topology.types), topology.touched))
            order.append("first")
        }
        let second = topology.follow { _ in order.append("second") }

        h.editor.transact("Link") { $0.insert(link(l, b, r)) }
        expectEqual(heard.count, 1)
        expectEqual(heard.last?.cause, .commit)
        expectEqual(heard.last?.touched, [b, r])
        expectEqual(heard.last?.atCall, [b, r], "the index is as the change left it")
        expectEqual(order, ["first", "second"], "in the order they began")

        h.editor.transact("Move") { $0.moveBox(b, to: CGPoint(x: 300, y: 0)) }
        expectEqual(heard.count, 1, "a commit that changes no edge is no change to them")
        expectEqual(topology.touched, [])

        topology.provide([r: answer("q", [a])])
        expectEqual(heard.count, 2)
        expectEqual(heard.last?.cause, .provide)
        expectEqual(heard.last?.touched, [b, a, r])
        expectEqual(heard.last?.wires, [b, a, r])
        expectEqual(topology.touched, [b, a, r], "touched is the provide's")

        h.editor.transact("Delete") { $0.delete([a]) }
        expectEqual(heard.count, 3)
        expectEqual(heard.last?.cause, .commit)
        expectEqual(topology.touched, [b, a, r], "and then the commit's")
        h.editor.undo()
        expectEqual(heard.count, 4, "undo is a commit")

        h.editor.replaceDocument(with: board(box(a), box(b), lens(r, asks: "q"), link(l, b, r)))
        expectEqual(heard.last?.cause, .rebuild, "a board put in place is read afresh")
        expectEqual(heard.count, 5)
        expectEqual(topology.forwarding(of: r), .pending, "and its answers asked again")

        h.editor.replaceFile(with: CanvasFile(root: board(box(c))))
        expectEqual(heard.count, 6)
        expectEqual(heard.last?.cause, .rebuild)

        second.cancel()
        following = nil
        h.editor.transact("Link") { $0.insert(link(ShapeID(), c, c)) }
        expectEqual(heard.count, 6, "a follower let go of hears nothing")
        expectEqual(order.count, 12, "nor one cancelled")
        _ = following
    },

    test("settling: sources keep the edges settling, a wait ends as they go idle or a provide answers, and times out on the scheduler") {
        let a = ShapeID(), r = ShapeID()
        let h = try lensing(CanvasFile(root: board(box(a), lens(r, asks: "q"))))
        let topology = h.topology
        expect(!topology.isSettling, "no source, nothing on its way")
        expectEqual(try awaitResult { await topology.settled(timeout: .seconds(1)) }, true)

        let work = Waiting()
        work.busy = true
        let source = topology.keepsSettling { work.busy }
        expect(topology.isSettling)
        let idle = waiting(topology, .seconds(5))
        expectEqual(idle.settled, nil, "it waits")
        work.busy = false
        expectEqual(idle.settled, nil, "until told to look")
        topology.settleSourceChanged()
        spinRunLoop(until: { idle.settled != nil })
        expectEqual(idle.settled, true)

        // A source that's busy while a stand-in waits for its answer: the provide wakes it.
        let asking = topology.keepsSettling { !topology.pendingStandIns.isEmpty }
        let answered = waiting(topology, .seconds(5))
        expectEqual(answered.settled, nil)
        topology.provide([r: answer("q", [a])])
        spinRunLoop(until: { answered.settled != nil })
        expectEqual(answered.settled, true)
        expect(!topology.isSettling)

        work.busy = true
        let timedOut = waiting(topology, .milliseconds(500))
        h.scheduler.advance(by: .milliseconds(499))
        expectEqual(timedOut.settled, nil)
        h.scheduler.advance(by: .milliseconds(1))
        spinRunLoop(until: { timedOut.settled != nil })
        expectEqual(timedOut.settled, false, "timed out")
        expectEqual(h.scheduler.pendingCount, 0)

        let cancelled = waiting(topology, .seconds(5))
        cancelled.task?.cancel()
        spinRunLoop(until: { cancelled.settled != nil })
        expectEqual(cancelled.settled, false, "cancelled")

        let stopped = waiting(topology, .seconds(5))
        source.cancel()
        spinRunLoop(until: { stopped.settled != nil })
        expectEqual(stopped.settled, true, "the busy source stopped")
        expectEqual(h.scheduler.pendingCount, 0, "each wait's timeout cancelled as it ended")
        asking.cancel()
    },

    test("through seeded commits, undo, boards it can't show and answers: the index is as a fresh one given the answers it still holds, in every view") {
        for seed: UInt64 in [3, 11, 24, 58, 90, 123] {
            let churn = try Turnover(seed: seed, lenses: true)
            var answered = 0
            for step in 0..<150 {
                let what = churn.step(), context = "seed \(seed), step \(step), after \(what)"
                churn.keepHeld()
                guard try expectAnswered(churn.h, churn.answers, context), expectLiteral(churn.h, context) else { break }
                if !churn.answers.isEmpty { answered += 1 }
            }
            expect(answered > 30, "lenses stood for answers through much of the run (\(answered) of 150), seed \(seed)")
        }
    },
])

// MARK: Helpers

/// A wait for the index to settle, begun in a task, the run loop turned until it waits; or, for a
/// source, whether it has work.
@MainActor private final class Waiting {
    var busy = false
    var settled: Bool?
    var task: Task<Void, Never>?
}

@MainActor private func waiting(_ topology: TopologyIndex, _ timeout: Duration) -> Waiting {
    let wait = Waiting()
    wait.task = Task { @MainActor in wait.settled = await topology.settled(timeout: timeout) }
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
    return wait
}

/// Holds the index to a fresh one given the same answers (those it still takes), in every view:
/// what each shape's and carrier's edges are, and what stands for what.
@MainActor @discardableResult
func expectAnswered(_ h: EditorHarness, _ answers: [ShapeID: ProvidedForwarding], _ context: String,
                            file: StaticString = #fileID, line: UInt = #line) throws -> Bool {
    // Kept for as long as its index is read: the index provides through it.
    let editor = CanvasEditor(registry: h.editor.registry, file: h.file, showing: h.editor.board, scheduler: ManualScheduler())
    defer { withExtendedLifetime(editor) {} }
    let fresh = try require(editor.topology)
    fresh.provide(answers)
    let index = h.topology
    var ids = h.file.root.shapes.map(\.id)
    for board in h.file.children.values { ids += board.shapes.map(\.id) }
    var problems: [String] = []
    for view in [EdgeView.resolved, .recorded, .literal] {
        if Set(index.edges(ofType: .all, view: view)) != Set(fresh.edges(ofType: .all, view: view)) { problems.append("the file's edges, \(view)") }
        for id in ids {
            if Set(index.edges(of: id, view: view)) != Set(fresh.edges(of: id, view: view)) { problems.append("edges(of: \(id)), \(view)") }
            if index.edges(carriedBy: id, view: view) != fresh.edges(carriedBy: id, view: view) { problems.append("carried by \(id), \(view)") }
        }
    }
    for id in ids {
        if index.forwards(of: id) != fresh.forwards(of: id) { problems.append("forwards(of: \(id))") }
        if Set(index.standIns(for: id)) != Set(fresh.standIns(for: id)) { problems.append("standIns(for: \(id))") }
        if index.forwarding(of: id) != fresh.forwarding(of: id) { problems.append("forwarding(of: \(id))") }
    }
    if index.pendingStandIns != fresh.pendingStandIns { problems.append("pending") }
    expect(problems.isEmpty, "as a fresh index given the same answers, \(context): \(problems.prefix(4).joined(separator: "; "))", file: file, line: line)
    return problems.isEmpty
}
