import Canvas
import CanvasTesting
import Foundation
import Queries
import QueryLanguage
import TestKit
import Topology

// A query that reads edges waits, when it's asked to, for answers that are still arriving
// (`QueryRequest.settle`), outside the line queries take their turns in, at most as long as it's
// told; then it goes on, and says so (`pending`). A query that reads no edges never waits.

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
    test("the wait is outside the line: a query behind it isn't held up, and a cancelled wait is a cancelled query") {
        let h = try relay()
        let topology = try require(h.editor.topology)
        let queries = try require(h.editor.queries)
        let working = Working()
        working.busy = true
        let source = topology.keepsSettling { working.busy }
        let waiting = try start(QueryRequest("chore:edge-to(*)", settle: .seconds(2)), on: h)
        expect(!waiting.done)
        let other = try start(QueryRequest("chore"), on: h)
        expect(other.done, "another query takes its turn while one waits for answers")
        expectEqual(other.result?.count, 3)
        // Cancelled while it waits: it doesn't take up the file.
        let before = queries.captures
        let task = Task { @MainActor in try await queries.run(QueryRequest("chore:edge-to(*)", settle: .seconds(2))) }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
        task.cancel()
        let thrown = try thrown(by: task)
        expectEqual(thrown?.reason, .cancelled)
        expectEqual(queries.captures, before, "taking up the file is where it would have waited its turn")
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
    test("canvas query's wait is two seconds, and a warning says what it's about") {
        expectEqual(QueryBudget.settleWait, .seconds(2))
        expectEqual(QueryWarning.pending(0).message, "Answers are still arriving; what the query says of edges may change.")
        expectEqual(QueryWarning.pending(3).reason.rawValue, "pending")
    },
])
