import Canvas
import CanvasTesting
import Foundation
import Queries
import QueryLanguage
import TestKit
import os

// Where a query runs, and when it stops: the file as it was taken up, with derived names as the app
// has them when asked; what only the main actor says, asked of the shapes in hand, in slices of 2 ms
// plus the one record that crosses it, a query's one at a time, with the run loop's own sources
// between them; the caller's cancellation, the 8 s deadline (on the editor's scheduler) and a closed
// file; and queries at once, none waiting for another or stopping another.

/// A word only the main actor answers, as slowly as a test says: `:slow`, asked of every chore, true
/// for each, each ask costing `cost` of the thread's CPU, then `onAsk`.
@MainActor final class SlowWord {
    var calls = 0
    var cost: (ShapeID) -> Duration = { _ in .zero }
    var onAsk: ((ShapeID) -> Void)?
}

func slowPlugin(_ slow: SlowWord) -> Contributor {
    Contributor(id: "slow") { registrar in
        registrar.queryPseudoClass("slow", "it takes a while to say", example: ":slow", prepare: { _ in () },
                                   matches: { shape, _ in shape.record.kind == Chore.kind ? .onMain : .no },
                                   onMain: { record, _, _, _ in
                                       slow.calls += 1
                                       burn(slow.cost(record.id))
                                       slow.onAsk?(record.id)
                                       return true
                                   })
    }
}

/// Chores 1 to `count` on the top board.
func manyChores(_ count: Int) -> CanvasFile {
    CanvasFile(root: CanvasDocument(shapes: (1...count).map { chore(id($0)) }))
}

/// A task running a query, for a word to cancel from inside it, and what happened, in order.
@MainActor final class Running {
    var task: Task<QueryResult, any Error>?
    var log: [String] = []
}

/// A value a closure changes and a test reads.
@MainActor final class Box<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}

/// Where each call a query makes into a plugin ran, by call: on the main thread (true) or not.
final class Threads: Sendable {
    private let seen = OSAllocatedUnfairLock(initialState: [String: Set<Bool>]())

    func note(_ call: String) {
        let onMain = Thread.isMainThread
        seen.withLock { _ = $0[call, default: []].insert(onMain) }
    }

    var calls: [String: Set<Bool>] { seen.withLock { $0 } }
}

/// Captions named, shouts read in capitals and `:anywhere` (every shape), each call noted in
/// `threads`: what a query asks anywhere, never on the main actor.
func threadsPlugin(_ threads: Threads) -> Contributor {
    Contributor(id: "threads") { registrar in
        registrar.queryNames(attribute: Caption.key.rawValue,
                             source: { kind, registry in registry.properties(for: kind).contains(Caption.key) ? .named : .none },
                             named: { record in
                                 threads.note("named")
                                 return folded(record[Caption.self])
                             },
                             derived: { _, _ in nil }, fold: { folded($0) })
        registrar.declare(Shout.self)
        registrar.optIn(Chore.self, to: Shout.self)
        registrar.queryTextFormat(mediaType: shoutType, describes: "read in capitals", prepare: { _ in () }, read: { text, _ in
            threads.note("read")
            return text.uppercased()
        })
        registrar.queryPseudoClass("anywhere", "every shape", example: ":anywhere", prepare: { _ in () }, matches: { _, _ in
            threads.note("matches")
            return .yes
        })
    }
}

/// What a query's task threw, once it's done; nil if it answered.
@MainActor func thrown(by task: Task<QueryResult, any Error>, file: StaticString = #fileID, line: UInt = #line) throws -> QueryError? {
    do {
        _ = try awaitResult(timeout: 10, file: file, line: line) { try await task.value }
        return nil
    } catch let error as QueryError {
        return error
    }
}

@MainActor let concurrencyTests = Suite("Concurrency", [
    test("off the main actor: names, text read through its format, and a word's matches, for the answer and its rows") {
        let threads = Threads()
        let h = try choresHarness(plugins: queryPlugins(names: false, words: false, more: [threadsPlugin(threads)]))
        let result = try answer(#"chore[shout*="HEY"]:anywhere, [caption="Gamma"]"#, on: h)
        expectEqual(result.rows.map(\.id), [1, 3].map(id))
        expectEqual(result.rows.first?.properties?["shout"], "HEY THERE")
        expectEqual(threads.calls, ["named": [false], "read": [false], "matches": [false]])
    },
    test("one instant: attributes and structure as the query took up the file; a derived name as the app has it when asked") {
        // A word whose `prepare`, in the turn the query takes up the file, lands a commit just after:
        // chore 1 done, link 3 gone, and tile 22 renamed on a board that isn't shown.
        let landed = Box(false)
        let landing = Contributor(id: "landing") { registrar in
            registrar.queryPseudoClass("landing", "a commit lands as it's taken up", example: ":landing",
                                       prepare: { preparation in
                                           guard !landed.value else { return }
                                           landed.value = true
                                           let editor = preparation.editor
                                           editor.transact { transaction in
                                               transaction.update(id(1), as: Chore.self) { $0.props.status = .done }
                                               transaction.delete([id(3)])
                                           }
                                           editor.transact(on: BoardID(owner: id(12))) { transaction in
                                               transaction.update(id(22), as: Tile.self) { $0.props.label = "Renamed" }
                                           }
                                       },
                                       matches: { _, _ in .no })
        }
        let h = try shelf(more: [landing])
        let result = try answer(#"chore[status=todo], link:starts-at("Alpha"), tile[caption=Renamed], tile[caption=Tiled], :landing"#, on: h)
        expect(landed.value)
        expectEqual(result.rows.map(\.id), [1, 11, 21, 22, 3].map(id), "chore 1 as it was, link 3 as it was, tile 22 by its name now")
        let rows = Dictionary(result.rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        expectEqual(rows[id(1)]?.properties?["status"], "todo")
        expectEqual(rows[id(22)]?.title, "Renamed")
        expectEqual(rows[id(3)]?.connection?.from, QueryEnd(id: id(1), title: "Alpha"))
        expectEqual(result.warnings.map(\.reason), [.noTitleMatch], "Tiled is no shape's name now")
        // The commits landed.
        expectEqual((h.editor.document[id(1)]?.props as? Chore)?.status, .done)
        expectEqual(h.editor.document[id(3)] == nil, true)
        expectEqual(try matched("chore[status=todo], link, tile[caption=Renamed]", on: h), [11, 21, 22, 4].map(id))
    },
    test("a derived name of a shape gone since the query took up the file is none, and a word fails it") {
        let slow = SlowWord()
        let deleted = Box(false)
        let h = try shelf(more: [slowPlugin(slow), Contributor(id: "deleting") { registrar in
            registrar.queryPseudoClass("deleting", "deletes the tile as it's taken up", example: ":deleting",
                                       prepare: { preparation in
                                           guard !deleted.value else { return }
                                           deleted.value = true
                                           preparation.editor.transact(on: BoardID(owner: id(12))) { $0.delete([id(21), id(22)]) }
                                       },
                                       matches: { _, _ in .no })
        }])
        let result = try answer("tile, chore:slow, :deleting", on: h)
        expectEqual(result.rows.map(\.id), [1, 11, 22].map(id), "the tile as it was; chore 21, gone, fails :slow")
        expectEqual(result.rows.last?.title, nil, "the tile is gone: it has no name")
        expectEqual(slow.calls, 2)
    },
    test("what a word asks on the main actor sees: the board as it is now, made again once it changes, and the shape as it is now") {
        struct Seen: Equatable {
            let shape: ShapeID
            let boardHasNewcomer: Bool
            let newcomerLive: Bool
            let revision: Int
        }
        let seen = Box<[Seen]>([])
        let started = Box(0)
        let sees = Contributor(id: "sees") { registrar in
            registrar.queryPseudoClass("sees", "sees the board", example: ":sees", prepare: { _ in () },
                                       matches: { _, _ in .onMain },
                                       onMain: { record, board, _, context in
                                           expectEqual(context.registry.kinds, context.editor.registry.kinds)
                                           let shapes = context.shapes(on: board)
                                           seen.value.append(Seen(shape: record.id, boardHasNewcomer: shapes.shape(id(50)) != nil,
                                                                  newcomerLive: context.shape(id(50))?.board == .root, revision: context.revision))
                                           if seen.value.count == 1 { context.editor.add(Chore(unit), id: id(50)) }
                                           return true
                                       })
        }
        let h = try EditorHarness(plugins: queryPlugins(more: [sees]), file: manyChores(3))
        started.value = h.editor.revision
        expectEqual(try matched("chore:sees", on: h), [1, 2, 3].map(id))
        expectEqual(seen.value, [
            Seen(shape: id(1), boardHasNewcomer: false, newcomerLive: false, revision: started.value),
            Seen(shape: id(2), boardHasNewcomer: true, newcomerLive: true, revision: started.value),
            Seen(shape: id(3), boardHasNewcomer: true, newcomerLive: true, revision: started.value),
        ], "the board's context made again after the commit; the revision the query started at")
    },
    test("a word the main actor answers is asked only of the shapes in hand") {
        let calls = MainCalls()
        let h = try choresHarness(plugins: queryPlugins(words: false, more: [wordsPlugin(calls: calls), shoutsPlugin()]))
        expectMatches(["chore[status=done]:audited": []], on: h)
        expectEqual(calls.onMain, 1, "chore 2 alone")
        expectMatches(["chore[flag]:audited": [1]], on: h)
        expectEqual(calls.onMain, 2)
        expectMatches(["chore:audited": [1]], on: h)
        expectEqual(calls.onMain, 7)
        expectMatches(["#\(uuid(3)):audited, #\(uuid(1)):audited": [1]], on: h)
        expectEqual(calls.onMain, 9)
        let queries = try require(h.editor.queries)
        expectEqual(queries.verdictsAsked, 9)
    },
    test("slices: 2 ms each, plus at most the record that crosses it") {
        let slow = SlowWord()
        slow.cost = { $0 == id(100) ? .microseconds(1_800) : .microseconds(50) }
        let h = try EditorHarness(plugins: queryPlugins(more: [slowPlugin(slow)]), file: manyChores(200))
        let result = try answer("chore:slow", on: h, countOnly: true)
        expectEqual(result.count, 200)
        expectEqual(slow.calls, 200)
        let timings = result.timings
        expect(timings.slices >= 5, "\(timings.slices) slices")
        expect(timings.longestSlice <= .microseconds(2_000 + 1_800 + 500), "the longest slice took \(timings.longestSlice)")
        expect(timings.costliestRecord >= .microseconds(1_800), "the costliest record: \(timings.costliestRecord)")
        expect(timings.main >= .microseconds(200 * 50 + 1_800), "the main actor's time counts the slices: \(timings.main)")
        let queries = try require(h.editor.queries)
        expectEqual(queries.mainSlices, timings.slices)
    },
    test("the costliest record counts the records after a slice's last read of its clock") {
        let slow = SlowWord()
        // The clock is read after the first record and, at that pace, not again for 16 more: the
        // records run out first, the last of them the costly one.
        slow.cost = { $0 == id(3) ? .microseconds(1_200) : .microseconds(20) }
        let h = try EditorHarness(plugins: queryPlugins(more: [slowPlugin(slow)]), file: manyChores(3))
        let result = try answer("chore:slow", on: h, countOnly: true)
        expectEqual(result.count, 3)
        expectEqual(result.timings.slices, 1)
        expect(result.timings.costliestRecord >= .microseconds(1_200), "the costliest record: \(result.timings.costliestRecord)")
    },
    test("one slice waits on the main queue at a time: what's queued behind one runs before the next") {
        let slow = SlowWord()
        slow.cost = { _ in .microseconds(300) }
        let markedAt = Box<Int?>(nil)
        slow.onAsk = { _ in
            guard slow.calls == 1 else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { markedAt.value = slow.calls } }
        }
        let h = try EditorHarness(plugins: queryPlugins(more: [slowPlugin(slow)]), file: manyChores(100))
        let result = try answer("chore:slow", on: h, countOnly: true)
        expectEqual(slow.calls, 100)
        let marked = try require(markedAt.value)
        // A record costs at least 300 µs of the thread's CPU (`burn` spins on it), so the first slice
        // asks at most 7: its clock is read after record 1 (300 µs spent, and the 1.2 ms left before
        // `everyRecordAfter` holds 4 more at that pace), after record 5 (1.5 ms: every record from
        // now), 6 and 7 (2.1 ms, past `QueryBudget.slice`). Queued during record 1, it runs after the
        // first slice, and before the second: after 7 at most. Two slices waiting on the main queue
        // at once would put it after the second, 14.
        expect(marked <= 7, "queued in the first slice, it ran after \(marked) of 100: before the second")
        expect(result.timings.slices > 5)
    },
    test("the run loop's own sources run between slices, of one query and of queries at once: a timer fires while one or two queries of 50 slices each run") {
        for count in [1, 2] {
            let slow = SlowWord()
            slow.cost = { _ in .microseconds(2_100) }
            let h = try EditorHarness(plugins: queryPlugins(more: [slowPlugin(slow)]), file: manyChores(50))
            let firedAt = Box<Int?>(nil)
            let timer = Timer(timeInterval: 0.01, repeats: false) { _ in MainActor.assumeIsolated { firedAt.value = slow.calls } }
            // Armed in the first slice, so it can fire only once the queries' slices have begun (the
            // vocabulary, the check and the take-up before them take their own time).
            slow.onAsk = { _ in
                guard slow.calls == 1 else { return }
                RunLoop.main.add(timer, forMode: .default)
            }
            let queries = try require(h.editor.queries)
            let running = (0..<count).map { _ in Task { @MainActor in try await queries.run(QueryRequest("chore:slow", countOnly: true)) } }
            for query in running { expect(try awaitResult(timeout: 10) { try await query.value }.timings.slices >= 50, "\(count) running") }
            timer.invalidate()
            expectEqual(slow.calls, 50 * count)
            let fired = try require(firedAt.value, "the timer never fired while \(count) queries ran")
            expect(fired >= 1 && fired < 50, "it fired after \(fired) of \(50 * count) records, while \(count) ran")
            expectEqual(queries.liveSnapshots, 0)
        }
    },
    test("cancelled mid-slice: the slice ends, no other starts, and nothing is left") {
        let slow = SlowWord()
        slow.cost = { _ in .microseconds(500) }
        let running = Running()
        let cancelledAt = Box<Int?>(nil)
        slow.onAsk = { _ in
            guard slow.calls == 3 else { return }
            cancelledAt.value = slow.calls
            running.task?.cancel()
        }
        let h = try EditorHarness(plugins: queryPlugins(more: [slowPlugin(slow)]), file: manyChores(40))
        let queries = try require(h.editor.queries)
        let task = Task { @MainActor in try await queries.run(QueryRequest("chore:slow")) }
        running.task = task
        expectEqual(try thrown(by: task)?.reason, .cancelled)
        expectEqual(cancelledAt.value, 3)
        expect(slow.calls <= 3 + QueryBudget.clockStride, "\(slow.calls) asked")
        let asked = slow.calls
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        expectEqual(slow.calls, asked, "no slice after")
        expectEqual(queries.liveSnapshots, 0)
        expectEqual(try matched("#\(uuid(1))", on: h), [id(1)], "the next query runs")
    },
    test("the deadline: 8 s on the editor's scheduler cancels the query, too_slow, and goes when it's done first; it's the one query's, and another running meanwhile answers") {
        let slow = SlowWord()
        let h = try EditorHarness(plugins: queryPlugins(more: [slowPlugin(slow)]), file: manyChores(200))
        let queries = try require(h.editor.queries)
        _ = try answer("chore", on: h)
        expectEqual(h.scheduler.pendingCount, 0, "a query done before its deadline cancels it")

        slow.cost = { _ in .microseconds(300) }
        slow.onAsk = { _ in if slow.calls == 1 { h.wait(7_999) } }
        let late = try answer("chore:slow", on: h)
        expectEqual(late.count, 200, "a millisecond short of the deadline, it answers")

        // A quick query is asked beside a slow one, and has its answer by the time the clock runs out on the slow one.
        slow.calls = 0
        let answered = Box(false)
        slow.onAsk = { _ in
            guard answered.value else { return }
            slow.onAsk = nil
            h.wait(8_000)
        }
        let first = Task { @MainActor in try await queries.run(QueryRequest("chore:slow")) }
        let second = Task { @MainActor () -> QueryResult in
            let result = try await queries.run(QueryRequest("chore", countOnly: true))
            answered.value = true
            return result
        }
        let slowError = try require(thrown(by: first))
        expectEqual(slowError.reason, .tooSlow)
        expectEqual(slowError.message, "The query took more than 8 seconds.")
        expectEqual(slowError.hint, "Start from a kind, a title or an id, or give transitive words a type.")
        expect(slow.calls < 200, "it stopped: \(slow.calls) asked")
        expect(answered.value, "the quick one answered before the slow one ran out of time")
        expectEqual(try awaitResult(timeout: 10) { try await second.value }.count, 200, "and its answer stands: the deadline was the slow query's alone")
        expectEqual(h.scheduler.pendingCount, 0)
        expectEqual(queries.liveSnapshots, 0)
        slow.onAsk = nil
        expectEqual(try answer("chore:slow", on: h, countOnly: true).count, 200)
    },
    test("queries on one editor run at once: a quick one asked while a slow one is mid-slices takes up the file and answers before it ends, each over a snapshot of its own") {
        let slow = SlowWord()
        slow.cost = { _ in .microseconds(300) }
        let running = Running()
        let takes = Box(0)
        let alive = Box<[Int]>([])
        let logged = Contributor(id: "logged") { registrar in
            registrar.queryPseudoClass("logged", "logs as it's taken up", example: ":logged",
                                       prepare: { _ in
                                           takes.value += 1
                                           running.log.append("take \(takes.value)")
                                       },
                                       matches: { _, _ in .yes })
        }
        // Asked of every chore on the main actor, it notes how many snapshots are alive.
        let counting = Contributor(id: "counting") { registrar in
            registrar.queryPseudoClass("counting", "notes the snapshots alive as it's asked", example: ":counting", prepare: { _ in () },
                                       matches: { _, _ in .onMain },
                                       onMain: { _, _, _, context in
                                           alive.value.append(context.editor.queries?.liveSnapshots ?? -1)
                                           return true
                                       })
        }
        let h = try EditorHarness(plugins: queryPlugins(more: [slowPlugin(slow), logged, counting]), file: manyChores(200))
        let queries = try require(h.editor.queries)
        let second = Box<Task<QueryResult, any Error>?>(nil)
        // The quick query is asked while the slow one is in its first slice.
        slow.onAsk = { _ in
            guard slow.calls == 1 else { return }
            second.value = Task { @MainActor in
                let result = try await queries.run(QueryRequest("chore:logged:counting", limit: 200))
                running.log.append("end second")
                return result
            }
        }
        let first = Task { @MainActor in
            let result = try await queries.run(QueryRequest("chore:logged:slow", limit: 200))
            running.log.append("end first")
            return result
        }
        let slowAnswer = try awaitResult(timeout: 10) { try await first.value }
        let quick = try require(second.value, "the quick query was asked")
        let quickAnswer = try awaitResult(timeout: 10) { try await quick.value }
        expectEqual(running.log, ["take 1", "take 2", "end second", "end first"], "the second took up the file while the first was in its slices, and answered first")
        expectEqual(slowAnswer.rows.map(\.id), (1...200).map(id), "the slow one still answers right")
        expectEqual(slowAnswer.count, 200)
        expectEqual(slow.calls, 200)
        expectEqual(quickAnswer.rows.map(\.id), (1...200).map(id))
        expect(!alive.value.isEmpty && alive.value.allSatisfy { $0 == 2 }, "both snapshots were held while the quick one asked the main actor: \(alive.value)")
        expectEqual(queries.liveSnapshots, 0, "and neither is held after")
        expectEqual(h.scheduler.pendingCount, 0, "each cancelled its own deadline")
        expectEqual(try matched("#\(uuid(1))", on: h), [id(1)], "the next query runs")
    },
    test("a query cancelled while another runs is the only one stopped, whichever of them it is") {
        let slow = SlowWord()
        slow.cost = { _ in .microseconds(300) }
        let h = try EditorHarness(plugins: queryPlugins(more: [slowPlugin(slow)]), file: manyChores(100))
        let queries = try require(h.editor.queries)
        for cancelled in 0..<2 {
            slow.calls = 0
            let both = Box<[Task<QueryResult, any Error>]>([])
            slow.onAsk = { _ in if slow.calls == 20 { both.value[cancelled].cancel() } }
            both.value = (0..<2).map { _ in Task { @MainActor in try await queries.run(QueryRequest("chore:slow")) } }
            expectEqual(try thrown(by: both.value[cancelled])?.reason, .cancelled, "query \(cancelled)")
            let other = try awaitResult(timeout: 10) { try await both.value[1 - cancelled].value }
            expectEqual(other.count, 100, "the other, asked beside it, answers")
            expectEqual(other.rows.map(\.id), (1...100).map(id))
            expect(slow.calls < 200, "the cancelled one stopped: \(slow.calls) asked of 200")
            expectEqual(queries.liveSnapshots, 0)
        }
        slow.onAsk = nil
        expectEqual(try answer("chore:slow", on: h, countOnly: true).count, 100)
    },
    test("a file closed while its query runs: board_closed, and the editor isn't kept") {
        let slow = SlowWord()
        slow.cost = { _ in .microseconds(500) }
        let scheduler = ManualScheduler()
        let editor = Box<CanvasEditor?>(CanvasEditor(registry: try Registry(plugins: queryPlugins(more: [slowPlugin(slow)])), file: manyChores(20),
                                                     scheduler: scheduler))
        weak var closed = editor.value
        let queries = try require(editor.value?.queries)
        slow.onAsk = { _ in if slow.calls == 1 { editor.value = nil } }
        let task = Task { @MainActor in try await queries.run(QueryRequest("chore:slow")) }
        let refused = try require(thrown(by: task))
        expectEqual(refused.reason, .boardClosed)
        expectEqual(refused.message, "The board was closed before the command finished.")
        expect(closed == nil, "the editor went as its file closed")
        expect(slow.calls < 20)
        expectEqual(queries.liveSnapshots, 0)
        do {
            _ = try awaitResult { try await queries.run(QueryRequest("*")) }
            expect(false, "a query of a closed file answers")
        } catch let error as QueryError {
            expectEqual(error.reason, .boardClosed)
        }
    },
])
