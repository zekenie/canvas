import Canvas
import CanvasRPC
import CanvasTesting
import Foundation
import Queries
import QueryLanguage
import TestKit
import Topology

// A query that reads edges waits, when it's asked to, for answers that are still arriving
// (`QueryRequest.settle`), before it takes up the file and holding up no other query, at most as long
// as it's told; then it goes on, and says so (`pending`). A query that reads no edges never waits.

/// What a query running in a task came to.
@MainActor final class Outcome {
    var result: QueryResult?
    var error: QueryError?
    var done: Bool { result != nil || error != nil }
}

/// Runs a query in a task, the run loop turned a little so it gets as far as waiting.
@MainActor func start(_ request: QueryRequest, on h: EditorHarness) throws -> Outcome {
    let queries = try require(h.editor.queries)
    let outcome = Outcome()
    Task { @MainActor in
        do throws(QueryError) { outcome.result = try await queries.run(request) } catch { outcome.error = error }
    }
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
    return outcome
}

/// Something that provides answers: busy while a test says so.
@MainActor final class Working {
    var busy = false
}

@MainActor let settleTests = Suite("Settling", [
    test("a query that reads edges waits while answers are arriving, and goes on once they've come, with nothing to say") {
        let h = try relay()
        let topology = try require(h.editor.topology)
        let queries = try require(h.editor.queries)
        let working = Working()
        working.busy = true
        let source = topology.keepsSettling { working.busy }
        let before = queries.captures
        let waiting = try start(QueryRequest(#"chore:connected-to("Beta")"#, settle: .seconds(2)), on: h)
        expect(!waiting.done, "it waits")
        expectEqual(queries.captures, before, "and has taken up nothing")
        topology.provide([id(6): provided("q", [id(2)])])
        working.busy = false
        topology.settleSourceChanged()
        spinRunLoop(until: { waiting.done })
        expectEqual(waiting.result?.rows.map(\.id), [id(1), id(3)], "it read the edges as they settled: through the lens")
        expectEqual(waiting.result?.warnings, [])
        expectEqual(h.scheduler.pendingCount, 0, "no timer left")
        source.cancel()
    },
    test("it waits no longer than it's told, then goes on and warns that answers were pending, saying how many") {
        let h = try relay()
        let topology = try require(h.editor.topology)
        let source = topology.keepsSettling { !topology.pendingStandIns.isEmpty }
        expectEqual(topology.pendingStandIns, [id(6)])
        let waiting = try start(QueryRequest(#"chore:connected-to("Beta")"#, settle: .seconds(2)), on: h)
        h.scheduler.advance(by: .milliseconds(1_999))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        expect(!waiting.done, "just under the time")
        h.scheduler.advance(by: .milliseconds(1))
        spinRunLoop(until: { waiting.done })
        expectEqual(waiting.result?.rows.map(\.id), [], "read as the edges were: nothing for the lens yet")
        let warning = try require(waiting.result?.warnings.first)
        expectEqual(waiting.result?.warnings.count, 1)
        expectEqual(warning.reason, .pending)
        expectEqual(warning, QueryWarning.pending(1))
        expect(warning.message.hasPrefix("1 answer is still arriving"), warning.message)
        source.cancel()
    },
    test("a source that settles no edges waits only a query that holds a word that waits: one of edges goes on, and one that waits says no edges") {
        let checked = Contributor(id: "checked-words") { registrar in
            registrar.queryPseudoClass("checked", "its verdict is in", example: ":checked", prepare: { _ in () },
                                       matches: { _, _ in .yes }, settles: true)
        }
        let h = try relay(more: [checked])
        let topology = try require(h.editor.topology)
        let working = Working()
        working.busy = true
        let source = topology.keepsSettling(edges: false) { working.busy }
        expect(topology.isSettling && !topology.isSettlingEdges)
        let edges = try start(QueryRequest(#"chore:connected-to("Alpha")"#, settle: .seconds(2)), on: h)
        expect(edges.done, "edges alone: no source of edges is busy")
        expectEqual(edges.result?.warnings, [])
        let waiting = try start(QueryRequest("chore:checked", settle: .seconds(2)), on: h)
        expect(!waiting.done, "it waits for the verdicts")
        h.scheduler.advance(by: .seconds(2))
        spinRunLoop(until: { waiting.done })
        expectEqual(waiting.result?.warnings, [QueryWarning.pending(0, ofEdges: false)])
        expectEqual(waiting.result?.warnings.first?.message, "Answers are still arriving; what the query says may change.")
        let settled = try start(QueryRequest("chore:checked", settle: .seconds(2)), on: h)
        expect(!settled.done)
        working.busy = false
        topology.settleSourceChanged()
        spinRunLoop(until: { settled.done })
        expectEqual(settled.result?.warnings, [], "woken once the source went idle")
        source.cancel()
    },
    test("a query that reads no edge never waits, nor warns, and a request that doesn't ask to wait doesn't") {
        let h = try relay()
        let topology = try require(h.editor.topology)
        let working = Working()
        working.busy = true
        let source = topology.keepsSettling { working.busy }
        for text in ["chore", #""Alpha""#, "chore:starred", "chore:inside(*)"] {
            let answered = try start(QueryRequest(text, settle: .seconds(2)), on: h)
            expect(answered.done, "\(text) doesn't wait")
            expectEqual(answered.result?.warnings, [], text)
        }
        let unasked = try start(QueryRequest(#"chore:connected-to("Beta")"#), on: h)
        expect(unasked.done, "no settle: no wait")
        expectEqual(unasked.result?.warnings, [], "and nothing said")
        source.cancel()
    },
    test("a wait for answers holds up no other query, and a cancelled wait is a cancelled query that took up nothing") {
        let h = try relay()
        let topology = try require(h.editor.topology)
        let queries = try require(h.editor.queries)
        let working = Working()
        working.busy = true
        let source = topology.keepsSettling { working.busy }
        let waiting = try start(QueryRequest("chore:edge-to(*)", settle: .seconds(2)), on: h)
        expect(!waiting.done)
        let other = try start(QueryRequest("chore"), on: h)
        expect(other.done, "another query runs while one waits for answers")
        expectEqual(other.result?.count, 3)
        // Cancelled while it waits: it doesn't take up the file.
        let before = queries.captures
        let task = Task { @MainActor in try await queries.run(QueryRequest("chore:edge-to(*)", settle: .seconds(2))) }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
        task.cancel()
        let thrown = try thrown(by: task)
        expectEqual(thrown?.reason, .cancelled)
        expectEqual(queries.captures, before, "it waited before taking up the file, so it never did")
        working.busy = false
        topology.settleSourceChanged()
        spinRunLoop(until: { waiting.done })
        expectEqual(waiting.result?.count, 2, "the first goes on once settled: Gamma, and Alpha through the proxy")
        source.cancel()
        expectEqual(queries.liveSnapshots, 0)
    },
    test("a query that waits and finds the answers have come already doesn't wait") {
        let h = try answeredRelay()
        let answered = try start(QueryRequest(#"chore:connected-to("Beta")"#, settle: .seconds(2)), on: h)
        expect(answered.done)
        expectEqual(answered.result?.rows.map(\.id), [id(1), id(3)])
        expectEqual(answered.result?.warnings, [])
    },
    test("the wait counts against the deadline: after 2 s of waiting a query that runs slow is refused too_slow at 8 s in all, not 10") {
        let slow = SlowWord()
        let h = try relay(more: [slowPlugin(slow)])
        let topology = try require(h.editor.topology)
        let queries = try require(h.editor.queries)
        let source = topology.keepsSettling { !topology.pendingStandIns.isEmpty }
        // It reads edges (so it waits), then asks `:slow` of what's left, which advances the clock by
        // `ran` as its evaluation goes.
        @MainActor func ask(evaluationTakes ran: Int) throws -> Outcome {
            slow.calls = 0
            slow.onAsk = { _ in if slow.calls == 1 { h.wait(ran) } }
            let outcome = try start(QueryRequest("chore:slow:edge-to(*)", settle: .seconds(2)), on: h)
            expect(!outcome.done, "it waits for the lens's answer")
            expectEqual(slow.calls, 0, "and has asked nothing")
            h.scheduler.advance(by: .seconds(2))
            spinRunLoop(until: { outcome.done })
            return outcome
        }
        // 2 s of waiting and 5.999 s of running: a millisecond short of 8 s in all, so it answers.
        let inTime = try ask(evaluationTakes: 5_999)
        expect(inTime.result != nil, "within the deadline: \(String(describing: inTime.error))")
        expectEqual(inTime.result?.warnings, [.pending(1)], "it went on past the wait, and said so")
        expect(slow.calls > 0, "its evaluation ran")
        // 2 s of waiting and 6 s of running: 8 s in all. It was refused at 8 s, as an evaluation alone
        // would be, though its evaluation had run for only 6.
        let late = try ask(evaluationTakes: 6_000)
        expectEqual(late.error?.reason, .tooSlow)
        expectEqual(late.error?.message, "The query took more than 8 seconds.")
        expectEqual(late.result?.count, nil)
        expect(slow.calls < 3, "it stopped: \(slow.calls) asked")
        expectEqual(h.scheduler.pendingCount, 0, "no deadline left")
        expectEqual(queries.liveSnapshots, 0)
        // Without a wait nothing changed: the evaluation has all 8 s.
        slow.onAsk = { _ in if slow.calls == 1 { h.wait(7_999) } }
        slow.calls = 0
        let unasked = try start(QueryRequest("chore:slow:edge-to(*)"), on: h)
        spinRunLoop(until: { unasked.done })
        expect(unasked.result != nil, "no wait: 7.999 s is in time")
        source.cancel()
    },
    test("the deadline follows the file: 8 s up to 10,000 shapes and 50 µs more for each past that, from the last slice answered; a request may cap it in all, and canvas's refusal comes before it stops waiting") {
        expectEqual(QueryBudget.deadline(forShapes: 0), .seconds(8))
        expectEqual(QueryBudget.deadline(forShapes: QueryBudget.deadlineFrom), .seconds(8), "up to 10,000 shapes it's what it was")
        expectEqual(QueryBudget.deadline(forShapes: 110_000), .seconds(13))
        expectEqual(QueryBudget.deadline(forShapes: 1_010_000), .seconds(58))
        expectEqual(QueryBudget.commandDeadline, .seconds(8))
        expect(QueryBudget.commandDeadline < .seconds(RPC.defaultWait), "refused two seconds before `canvas` stops waiting")
        expectEqual(QueryBudget.deadline, QueryBudget.commandDeadline)

        // A file of 30,000 shapes has 9 s. The query asks `:slow` of the three Alphas, each a slice of its own (it costs
        // more than a slice's 2 ms), and the first moves the clock on: the slices after it are not asked once the deadline's passed.
        let slow = SlowWord()
        slow.cost = { _ in .milliseconds(3) }
        let shapes = (1...3).map { chore(id($0), caption: "Alpha") } + (0..<29_997).map { _ in chore(ShapeID()) }
        let h = try EditorHarness(plugins: queryPlugins(more: [slowPlugin(slow)]), file: CanvasFile(root: CanvasDocument(shapes: shapes)))
        let queries = try require(h.editor.queries)
        @MainActor func ask(taking ran: Int, deadline: Duration? = nil) throws -> Outcome {
            slow.calls = 0
            slow.onAsk = { _ in if slow.calls == 1 { h.wait(ran) } }
            let outcome = try start(QueryRequest(#"chore"Alpha":slow"#, deadline: deadline), on: h)
            spinRunLoop(until: { outcome.done })
            spinRunLoop(until: { queries.liveSnapshots == 0 })
            return outcome
        }
        expectEqual(try ask(taking: 8_999).result?.count, 3, "8.999 s of 9: in time, where 8 s would have refused it")
        let late = try ask(taking: 9_000)
        expectEqual(late.error?.reason, .tooSlow)
        expectEqual(late.error?.message, "The query took more than 9 seconds.", "the file's, said as it is")
        expectEqual(slow.calls, 1, "and stopped")
        // The command line asks for 8: its client waits 10, and the refusal must arrive before that, over a file of any size.
        let command = QueryBudget.commandDeadline
        expectEqual(try ask(taking: 7_999, deadline: command).result?.count, 3)
        let capped = try ask(taking: 8_000, deadline: command)
        expectEqual(capped.error?.reason, .tooSlow)
        expectEqual(capped.error?.message, "The query took more than 8 seconds.")
        // A cap past the file's own deadline changes nothing: it's the time in all, and the file's is the time without a sign of life.
        expectEqual(try ask(taking: 9_000, deadline: .seconds(60)).error?.reason, .tooSlow)
        expectEqual(try ask(taking: 8_999, deadline: .seconds(60)).result?.count, 3)
        expectEqual(h.scheduler.pendingCount, 0, "no deadline left")
        expectEqual(queries.liveSnapshots, 0)
    },
    test("the deadline is a time without a sign of life: slices the main actor answers keep a query going however long it takes in all, and a cap on the total stops it") {
        // Six chores, each asked in a slice of its own, each moving the clock on 5 s: 30 s in all, and never 8 s between one slice's end and the next's.
        let slow = SlowWord()
        slow.cost = { _ in .milliseconds(3) }
        let h = try EditorHarness(plugins: queryPlugins(more: [slowPlugin(slow)]), file: manyChores(6))
        let queries = try require(h.editor.queries)
        slow.onAsk = { _ in h.wait(5_000) }
        let steady = try start(QueryRequest("chore:slow"), on: h)
        spinRunLoop(until: { steady.done })
        expectEqual(steady.result?.count, 6, "\(String(describing: steady.error))")
        expectEqual(slow.calls, 6)
        // The same, held to 20 s in all: four slices, and the fifth isn't asked.
        slow.calls = 0
        let capped = try start(QueryRequest("chore:slow", deadline: .seconds(20)), on: h)
        spinRunLoop(until: { capped.done })
        expectEqual(capped.error?.reason, .tooSlow)
        expectEqual(capped.error?.message, "The query took more than 20 seconds.")
        expectEqual(slow.calls, 4)
        // A slice that takes 8 s with no answer before it ends is refused as it was: nothing to show for the time.
        slow.calls = 0
        slow.onAsk = { _ in h.wait(slow.calls == 3 ? 8_000 : 1_000) }
        let stalled = try start(QueryRequest("chore:slow"), on: h)
        spinRunLoop(until: { stalled.done })
        expectEqual(stalled.error?.message, "The query took more than 8 seconds.")
        expectEqual(slow.calls, 3)
        expectEqual(h.scheduler.pendingCount, 0, "nothing left armed")
        expectEqual(queries.liveSnapshots, 0)
    },
    test("canvas query's wait is two seconds, and a warning says what it's about") {
        expectEqual(QueryBudget.settleWait, .seconds(2))
        expectEqual(QueryWarning.pending(0).message, "Answers are still arriving; what the query says of edges may change.")
        expectEqual(QueryWarning.pending(3).reason.rawValue, "pending")
    },
])
