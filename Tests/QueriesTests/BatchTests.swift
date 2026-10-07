import Canvas
import CanvasTesting
import Foundation
import Queries
import QueryLanguage
import TestKit
import Topology
import os

// Many queries, ids only, on one snapshot (`QueryState.matches`), and the names pass alone
// (`checkNames`): for what keeps answers (a plugin that stores the shapes a query found) and what
// checks a query it's about to keep.

/// A batch's answers on `h`'s editor, the main run loop turned while it runs.
@MainActor func batched(_ requests: [QueryMatchRequest], on h: EditorHarness, file: StaticString = #fileID,
                        line: UInt = #line) throws -> [Result<QueryMatches, QueryError>] {
    let queries = try require(h.editor.queries, file: file, line: line)
    return try awaitResult(file: file, line: line) { await queries.matches(requests) }
}

/// What a request matched, or nil if it was refused.
func found(_ answer: Result<QueryMatches, QueryError>) -> QueryMatches? {
    if case .success(let matches) = answer { matches } else { nil }
}

/// Why a request was refused, or nil if it was answered.
func refused(_ answer: Result<QueryMatches, QueryError>) -> QueryError? {
    if case .failure(let error) = answer { error } else { nil }
}

/// Where each shape asked about was asked: on the main thread, or not.
final class Askers: Sendable {
    private let onMain = OSAllocatedUnfairLock(initialState: [Bool]())
    func note() { let main = Thread.isMainThread; onMain.withLock { $0.append(main) } }
    var calls: [Bool] { onMain.withLock { $0 } }
}

/// Tiles 1 to `count` labelled "Tile 1" to "Tile n", whose names are derived (asked of the main actor),
/// and chore `count + 1` "Alpha".
func tiled(_ count: Int) -> CanvasFile {
    CanvasFile(root: CanvasDocument(shapes: (1...count).map { tile(id($0), label: "Tile \($0)") } + [chore(id(count + 1), caption: "Alpha")]))
}

@MainActor let matchesBatchTests = Suite("A batch of queries, ids only", [
    test("every request is answered in order over one snapshot: one capture, no rows built, none left held") {
        let h = try answeredRelay()
        let queries = try require(h.editor.queries)
        let before = queries.captures
        let answers = try batched([QueryMatchRequest("chore"), QueryMatchRequest(#""Alpha""#), QueryMatchRequest(#"chore:connected-to("Beta")"#),
                                   QueryMatchRequest("link", edges: .literal), QueryMatchRequest("lens")], on: h)
        expectEqual(answers.compactMap { found($0)?.ids }, [[1, 2, 3], [1], [1, 3], [7, 8, 9, 10], [6]].map { $0.map(id) })
        expectEqual(answers.compactMap { found($0)?.count }, [3, 1, 2, 4, 1])
        expectEqual(answers.compactMap { found($0)?.canonical }, ["chore", #""Alpha""#, #"chore:connected-to("Beta")"#, "link", "lens"])
        expectEqual(queries.captures - before, 1, "one capture for all five")
        #if DEBUG
        expectEqual(queries.recordsEncoded, 0, "ids only: no row's attributes written")
        #endif
        expectEqual(queries.liveSnapshots, 0)
    },
    test("no request: nothing is taken up") {
        let h = try relay()
        let queries = try require(h.editor.queries)
        expectEqual(try batched([], on: h).count, 0)
        expectEqual(queries.captures, 0)
    },
    test("admission comes before the limit: the first match is the first one admitted, and the count is of those admitted") {
        let h = try relay()
        let notAlpha = QueryMatchRequest("chore", limit: 1) { $0.id != id(1) }
        let none = QueryMatchRequest("chore") { _ in false }
        let all = QueryMatchRequest("chore", limit: 2)
        let clamped = QueryMatchRequest("chore", limit: 0)
        let answers = try batched([notAlpha, none, all, clamped], on: h)
        expectEqual(found(answers[0])?.ids, [id(2)], "Alpha isn't admitted: the first is Beta")
        expectEqual(found(answers[0])?.count, 2, "Beta and Gamma")
        expectEqual(found(answers[1])?.ids, [])
        expectEqual(found(answers[1])?.count, 0)
        expectEqual(found(answers[2])?.ids, [id(1), id(2)], "file order, at most the limit")
        expectEqual(found(answers[2])?.count, 3)
        expectEqual(found(answers[3])?.ids, [id(1)], "a limit under 1 is 1")
    },
    test("admission is asked off the main actor, of each match once") {
        let h = try relay()
        let askers = Askers()
        let request = QueryMatchRequest("chore") { _ in
            askers.note()
            return true
        }
        _ = try batched([request], on: h)
        expectEqual(askers.calls, [false, false, false])
    },
    test("every answer is stamped with the revision the file was taken up at") {
        let h = try relay()
        let revision = h.editor.revision
        let first = try batched([QueryMatchRequest("chore"), QueryMatchRequest("lens")], on: h)
        expectEqual(first.compactMap { found($0)?.revision }, [revision, revision])
        h.editor.transact("Add") { $0.insert(chore(id(40), caption: "Delta")) }
        expect(h.editor.revision > revision)
        let second = try batched([QueryMatchRequest("chore")], on: h)
        expectEqual(found(second[0])?.revision, h.editor.revision)
        expectEqual(found(second[0])?.ids, [1, 2, 3, 40].map(id))
    },
    test("a request the engine refuses is that request's answer alone, as `run` refuses it") {
        let h = try relay()
        let texts = ["chor", #""Nope""#, "#\(uuid(99))", "chore"]
        let answers = try batched(texts.map { QueryMatchRequest($0) }, on: h)
        expectEqual(answers.compactMap { found($0)?.ids }, [[1, 2, 3].map(id)], "the last is answered")
        for (text, answer) in zip(texts.dropLast(), answers) {
            let error = try require(refused(answer), text)
            let ran = try require(try refusedAnswer(text, on: h), text)
            expectEqual(error.reason, ran.reason, text)
            expectEqual(error.message, ran.message, text)
            expectEqual(error.span, ran.span, text)
        }
        expectEqual(refused(answers[0])?.reason, .unknownKind, "refused before the file was taken up")
        expectEqual(refused(answers[1])?.reason, .unknownTitle, "refused by the names the file has")
        expectEqual(refused(answers[2])?.reason, .unknownID)
    },
    test("a batch of refusals takes up nothing") {
        let h = try relay()
        let queries = try require(h.editor.queries)
        let answers = try batched([QueryMatchRequest("chor"), QueryMatchRequest("")], on: h)
        expectEqual(answers.compactMap { refused($0)?.reason }, [.unknownKind, .emptyQuery])
        expectEqual(queries.captures, 0)
    },
    test("names are read once for the batch, derived ones asked of the main actor once each, however many requests name a title") {
        let h = try EditorHarness(plugins: queryPlugins(), file: tiled(12))
        let queries = try require(h.editor.queries)
        let requests = (1...5).map { QueryMatchRequest("\"Tile \($0)\"") } + [QueryMatchRequest(#"tile"Tile 7""#), QueryMatchRequest(#"chore"Alpha""#)]
        let answers = try batched(requests, on: h)
        expectEqual(answers.compactMap { found($0)?.ids }, ((1...5).map { [id($0)] } + [[id(7)], [id(13)]]))
        #if DEBUG
        expectEqual(queries.derivedTitlesAsked, 12, "each tile's name, once")
        // Asked one at a time, each read them all again.
        let before = queries.derivedTitlesAsked
        for request in requests.prefix(3) { _ = try batched([request], on: h) }
        expectEqual(queries.derivedTitlesAsked - before, 36)
        #endif
        expectEqual(queries.liveSnapshots, 0)
    },
    test("each request reads edges in its own view, all over the one snapshot") {
        let h = try answeredRelay()
        let queries = try require(h.editor.queries)
        let before = queries.captures
        let text = #"chore:connected-to("Beta")"#
        let answers = try batched([QueryMatchRequest(text, edges: .resolved), QueryMatchRequest(text, edges: .recorded),
                                   QueryMatchRequest(text, edges: .literal), QueryMatchRequest(text)], on: h)
        expectEqual(answers.compactMap { found($0)?.ids }, [[1, 3], [], [], [1, 3]].map { $0.map(id) })
        expectEqual(queries.captures - before, 1)
    },
    test("each text is checked once, however many requests carry it: a query asked in two views, or twice, is read and resolved once, and a refusal is every request's") {
        let h = try answeredRelay()
        let queries = try require(h.editor.queries)
        let text = #"chore:connected-to("Beta")"#
        #if DEBUG
        let before = queries.checks
        #endif
        let answers = try batched([QueryMatchRequest(text, edges: .resolved), QueryMatchRequest(text, edges: .literal), QueryMatchRequest("chore"),
                                   QueryMatchRequest(text, edges: .recorded), QueryMatchRequest("chore", limit: 1)], on: h)
        expectEqual(answers.compactMap { found($0)?.ids }, [[1, 3], [], [1, 2, 3], [], [1]].map { $0.map(id) }, "each in its own view, with its own limit")
        #if DEBUG
        expectEqual(queries.checks - before, 2, "two texts, five requests")
        let refusals = queries.checks
        #endif
        let mixed = try batched([QueryMatchRequest("chor"), QueryMatchRequest("chor", edges: .literal), QueryMatchRequest("chore")], on: h)
        expectEqual(mixed.compactMap { refused($0)?.reason }, [.unknownKind, .unknownKind])
        expectEqual(found(mixed[2])?.ids, [1, 2, 3].map(id))
        #if DEBUG
        expectEqual(queries.checks - refusals, 2, "the refused text once, and the other")
        #endif
        // One at a time, each is checked as often as it's asked.
        #if DEBUG
        let single = queries.checks
        _ = try batched([QueryMatchRequest(text)], on: h)
        _ = try batched([QueryMatchRequest(text)], on: h)
        expectEqual(queries.checks - single, 2)
        #endif
    },
    test("what one request matched is not another's: the same words in two queries answer for each") {
        let h = try relay()
        let answers = try batched([QueryMatchRequest(#"chore:not("Alpha")"#), QueryMatchRequest(#"chore:is("Alpha")"#), QueryMatchRequest(#"chore:not("Beta")"#)], on: h)
        expectEqual(answers.compactMap { found($0)?.ids }, [[2, 3], [1], [1, 3]].map { $0.map(id) })
    },
    test("cancelled mid-batch: every request is, and nothing is left held") {
        let slow = SlowWord()
        let h = try relay(more: [slowPlugin(slow)])
        let queries = try require(h.editor.queries)
        let running = Box<Task<[Result<QueryMatches, QueryError>], Never>?>(nil)
        slow.onAsk = { _ in running.value?.cancel() }
        let requests = [QueryMatchRequest("chore"), QueryMatchRequest("chore:slow"), QueryMatchRequest("lens")]
        let task = Task { @MainActor in await queries.matches(requests) }
        running.value = task
        let answers = try awaitResult { await task.value }
        expectEqual(answers.compactMap { refused($0)?.reason }, [.cancelled, .cancelled, .cancelled])
        expectEqual(queries.liveSnapshots, 0)
        slow.onAsk = nil
        expectEqual(try batched(requests, on: h).compactMap { found($0)?.ids }, [[1, 2, 3], [1, 2, 3], [6]].map { $0.map(id) }, "and it runs again")
    },
    test("it waits for no query before it, and none waits for it: asked while one is mid-slices, a batch takes up the file and answers before it ends") {
        let slow = SlowWord()
        slow.cost = { _ in .microseconds(300) }
        let h = try EditorHarness(plugins: queryPlugins(more: [slowPlugin(slow)]), file: manyChores(60))
        let queries = try require(h.editor.queries)
        let order = Box<[String]>([])
        let batch = Box<Task<Int, Never>?>(nil)
        // The batch is asked while the query is in its first slice.
        slow.onAsk = { _ in
            guard slow.calls == 1 else { return }
            batch.value = Task { @MainActor () -> Int in
                let answers = await queries.matches([QueryMatchRequest("chore")])
                order.value.append("batch done")
                return found(answers[0])?.count ?? -1
            }
        }
        let run = Task { @MainActor () -> Int in
            let result = try await queries.run(QueryRequest("chore:slow"))
            order.value.append("run done")
            return result.count
        }
        expectEqual(try awaitResult(timeout: 10) { try await run.value }, 60, "the query answers as it would alone")
        let asked = try require(batch.value, "the batch was asked")
        expectEqual(try awaitResult(timeout: 10) { await asked.value }, 60)
        expectEqual(order.value, ["batch done", "run done"], "the batch took up the file and answered while the query was still in its slices")
        expectEqual(slow.calls, 60)
        expectEqual(queries.liveSnapshots, 0)
    },
])

@MainActor let checkNamesTests = Suite("The names pass alone", [
    test("a plan whose titles and ids are all right passes, and a plan naming nothing takes up nothing") {
        let h = try relay()
        let queries = try require(h.editor.queries)
        let named = try plan("chore\"Alpha\", #\(uuid(2))", on: h)
        expectEqual(try awaitResult { await queries.checkNames(named) }?.reason, nil)
        let before = queries.captures
        let unnamed = try plan("chore:connected-to(*)", on: h)
        expectEqual(try awaitResult { await queries.checkNames(unnamed) }?.reason, nil)
        expectEqual(queries.captures, before, "no title, no id: no file taken up")
    },
    test("it refuses a title or an id no shape has, and a title standing where a container goes, as `run` does, and evaluates nothing") {
        let h = try relay()
        let queries = try require(h.editor.queries)
        let texts = [#""Alph""#, "#\(uuid(99))", #""Alpha" *"#, #"chore:edge-to("Nope")"#]
        for text in texts {
            let checked = try plan(text, on: h)
            let refusal = try require(try awaitResult { await queries.checkNames(checked) }, text)
            let ran = try require(try refusedAnswer(text, on: h), text)
            expectEqual(refusal.reason, ran.reason, text)
            expectEqual(refusal.message, ran.message, text)
            expectEqual(refusal.hint, ran.hint, text)
            expectEqual(refusal.span, ran.span, text)
        }
        let didYouMean = try require(try awaitResult { await queries.checkNames(try plan(#""Alph""#, on: h)) })
        expectEqual(didYouMean.reason, .unknownTitle)
        #if DEBUG
        expectEqual(queries.recordsEncoded, 0)
        #endif
        expectEqual(queries.liveSnapshots, 0)
    },
    test("it reads the names a query reads, derived ones too, and nothing else") {
        let h = try EditorHarness(plugins: queryPlugins(), file: tiled(12))
        let queries = try require(h.editor.queries)
        let right = try plan(#""Tile 4""#, on: h), wrong = try plan(#""Tile 40""#, on: h)
        expectEqual(try awaitResult { await queries.checkNames(right) }?.reason, nil)
        #if DEBUG
        expectEqual(queries.derivedTitlesAsked, 12)
        #endif
        let refusal = try require(try awaitResult { await queries.checkNames(wrong) })
        expectEqual(refusal.reason, .unknownTitle, "a derived name is one")
        expect(refusal.hint?.contains("Tile 4") == true, "and offered: \(refusal.hint ?? "no hint")")
    },
    test("a shape the app can't show is no shape: the id of one is refused as it is") {
        let h = try hiddenShelf()
        let queries = try require(h.editor.queries)
        let hidden = try plan("#\(uuid(11))", on: h)
        expectEqual(try awaitResult { await queries.checkNames(hidden) }?.reason, .unknownID)
        expectEqual(try refusedAnswer("#\(uuid(11))", on: h)?.reason, .unknownID)
    },
])
