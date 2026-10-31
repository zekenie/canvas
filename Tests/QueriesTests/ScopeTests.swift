import Canvas
import CanvasTesting
import Foundation
import Queries
import QueryLanguage
import TestKit
import Topology

// Words the engine binds per request (`QueryBinding.scope`, `QueryMatchRequest.scope`): `:scope`, the
// shape a request is about, and `:scope-start` and `:scope-end`, where the connection that shape
// carries starts and ends. A phrase asked of many shapes is one text in one batch, each request its
// own shape's. Their meaning is two equivalences, the oracle of these tests: `:scope` is `#<id>`,
// and `:scope-start` is `:start-of(#<id>)` and `:scope-end` is `:end-of(#<id>)`, in the request's
// edge view. Asked with nothing bound (`check`, `checkStored`, `run`, so `canvas query`) they are
// refused. Over the fixtures of EdgeTests (wires between chores), StandIns.swift (a proxy and a lens)
// and the yard (containers).

/// `text` with each word bound per request written as the query that finds the same shapes for
/// shape `n`: `:scope` is `#<id>` (`:is(#<id>)` after a kind or another test in its compound, where a
/// head can't stand), `:scope-start` is `:start-of(#<id>)`, `:scope-end` is `:end-of(#<id>)`.
func withID(_ text: String, of n: Int) -> String {
    let shape = "#\(uuid(n))"
    let ends = text.replacingOccurrences(of: ":scope-start", with: ":start-of(\(shape))")
        .replacingOccurrences(of: ":scope-end", with: ":end-of(\(shape))")
    var written = "", rest = Substring(ends)
    while let word = rest.range(of: ":scope") {
        written += rest[..<word.lowerBound]
        let continues = written.last.map { $0.isLetter || $0.isNumber || "-_])\"".contains($0) } ?? false
        written += continues ? ":is(\(shape))" : shape
        rest = rest[word.upperBound...]
    }
    return written + rest
}

/// A query resolved on `h`'s editor with a shape bound to it.
@MainActor func boundPlan(_ text: String, on h: EditorHarness, file: StaticString = #fileID, line: UInt = #line) throws -> QueryPlan {
    do throws(QueryError) {
        return try h.editor.queries!.check(text, binding: .scope)
    } catch {
        expect(false, "\(text) is refused when a shape is bound: \(error)", file: file, line: line)
        throw error
    }
}

/// Why `h`'s editor refuses a query asked with `binding`, checked as `check` does or as `checkStored` does; nil if it resolves.
@MainActor func refusal(_ text: String, binding: QueryBinding?, stored: Bool = false, on h: EditorHarness) -> QueryError? {
    do throws(QueryError) {
        let queries = h.editor.queries!
        _ = try stored ? queries.checkStored(text, binding: binding) : queries.check(text, binding: binding)
        return nil
    } catch {
        return error
    }
}

/// What a word bound per request is refused with when nothing is bound to it, standing at `offset`.
func unboundRefusal(_ word: String, at offset: Int) -> QueryError {
    QueryError(.unsupported, "“\(word)” can’t be used here.",
               hint: "`:scope` is the shape a query is asked about, and this one is asked about none.",
               span: QuerySpan(offset: offset, length: word.count))
}

@MainActor let scopeBatchTests = Suite("Words bound to a request: :scope, :scope-start, :scope-end", [
    test("one text asked of many shapes in one batch: each request answers what the query with its shape's id written in answers, from one capture and one check a text") {
        let h = try wiresHarness(unfinished: true)
        let queries = try require(h.editor.queries)
        // As a test of a compound, as the anchor of every sort of edge word, and in lists.
        let texts = [":scope", ":scope-start", ":scope-end", "chore:not(:scope)", "chore:connected-to(:scope)", "chore:edge-from(:scope-start, wire)",
                     "link:starts-at(:scope-start)", "link:ends-at(:scope-end)", ":start-of(:scope)", ":end-of(:scope, only wire)",
                     "chore:is(:scope, :scope-end)", ":scope, :scope-start", "chore:downstream-of(:scope-end)", "chore:edge-to(:scope-start, wire|tether)",
                     "link:between(:scope-start, :scope-end)", "chore:component-of(:scope-end, wire)", "chore:scope-end", "chore:scope-start",
                     "link:scope", "chore:scope-end:not(:scope-start)", #"chore"C2":scope-end"#, #""C1":scope-start"#]
        // Every shape of the file: chores 1 to 6, links 11 to 17 (16 and 17 have a free end).
        let shapes = Array(1...6) + Array(11...17)
        let requests = texts.flatMap { text in shapes.map { QueryMatchRequest(text, scope: id($0)) } }
        let captures = queries.captures
        #if DEBUG
        let checks = queries.checks
        #endif
        let answers = try batched(requests, on: h)
        expectEqual(answers.count, requests.count)
        expectEqual(queries.captures - captures, 1, "one capture for all \(requests.count)")
        #if DEBUG
        expectEqual(queries.checks - checks, texts.count, "each text is checked once, however many shapes it is asked of")
        #endif
        var answeredSome: [String: Int] = [:]
        for (index, answer) in answers.enumerated() {
            let (text, n) = (texts[index / shapes.count], shapes[index % shapes.count])
            let expected = try matched(withID(text, of: n), on: h)
            expectEqual(found(answer)?.ids, expected, "\(text) of \(n): \(withID(text, of: n))")
            expectEqual(found(answer)?.count, expected.count, "\(text) of \(n)")
            expectEqual(found(answer)?.canonical, try boundPlan(text, on: h).canonical, "\(text) of \(n)")
            answeredSome[text, default: 0] += expected.isEmpty ? 0 : 1
        }
        for text in texts { expect(answeredSome[text, default: 0] > 0, "\(text) finds something for some shape, or the equivalence says nothing") }
        expectEqual(queries.liveSnapshots, 0)
        // What one request matched is not another's: the same requests the other way round answer the same.
        let backwards = try batched(Array(requests.reversed()), on: h)
        expectEqual(backwards.reversed().map { found($0)?.ids }, answers.map { found($0)?.ids })
    },
    test("where a shape's connection starts and ends: a link's two ends, a self-link's one; none for a link with a free end, a chore, or a chore that cites") {
        let h = try wiresHarness(unfinished: true)
        // Link 11 is a wire from 1 to 2, 12 a hot wire from 2 to 3, 13 a tether from 3 to 1, 14 a wire from 4 to itself, 15 a wire
        // from 5 to 6; 16 has a free end at its end, 17 at its start. Chore 1 cites chore 4 and chore 6 cites itself, in their tags' slot.
        let ends: [(shape: Int, start: [Int], end: [Int])] = [(11, [1], [2]), (12, [2], [3]), (13, [3], [1]), (14, [4], [4]), (15, [5], [6]),
                                                              (16, [], []), (17, [], []), (1, [], []), (4, [], []), (6, [], [])]
        let requests = ends.flatMap { [QueryMatchRequest(":scope-start", scope: id($0.shape)), QueryMatchRequest(":scope-end", scope: id($0.shape)),
                                       QueryMatchRequest(":scope", scope: id($0.shape))] }
        let answers = try batched(requests, on: h)
        for (index, end) in ends.enumerated() {
            expectEqual(found(answers[3 * index])?.ids, end.start.map(id), "where \(end.shape) starts")
            expectEqual(found(answers[3 * index + 1])?.ids, end.end.map(id), "where \(end.shape) ends")
            expectEqual(found(answers[3 * index + 2])?.ids, [id(end.shape)], "\(end.shape) itself")
        }
        // Nothing is no error: an empty answer is an answer, and its count says so.
        expectEqual(found(answers[3 * 5])?.count, 0)
        expectEqual(found(answers[3 * 5])?.canonical, ":scope-start")
        // And the words work as an anchor with no connection to start from: nothing is related to nothing.
        let none = try batched([QueryMatchRequest("chore:edge-from(:scope-start)", scope: id(16)), QueryMatchRequest("link:ends-at(:scope-end)", scope: id(1)),
                                QueryMatchRequest(":end-of(:scope)", scope: id(1)), QueryMatchRequest(":start-of(:scope)", scope: id(16))], on: h)
        expectEqual(none.map { found($0)?.ids }, [[], [], [], []])
    },
    test("a stand-in at an end: the resolved view gives what it stands for, recorded what its own record names, literal the stand-in; a lens nothing has answered stays where it is") {
        let h = try answeredRelay()
        let views: [EdgeView] = [.resolved, .recorded, .literal]
        // Wire 7 runs from Gamma to the proxy (for Alpha), 8 from Gamma to the lens (answered Beta, which recorded leaves at the
        // lens), 9 from Gamma to Alpha as drawn, 10 from the proxy to the lens; each in the three views.
        let ends: [(link: Int, start: [[Int]], end: [[Int]])] = [(7, [[3], [3], [3]], [[1], [1], [5]]), (8, [[3], [3], [3]], [[2], [6], [6]]),
                                                                 (9, [[3], [3], [3]], [[1], [1], [1]]), (10, [[1], [1], [5]], [[2], [6], [6]])]
        var requests: [QueryMatchRequest] = [], expected: [[ShapeID]] = [], said: [String] = []
        for end in ends {
            for (v, view) in views.enumerated() {
                requests += [QueryMatchRequest(":scope-start", scope: id(end.link), edges: view), QueryMatchRequest(":scope-end", scope: id(end.link), edges: view)]
                expected += [end.start[v].map(id), end.end[v].map(id)]
                said += ["start of \(end.link), \(view)", "end of \(end.link), \(view)"]
            }
        }
        let answers = try batched(requests, on: h)
        for (index, answer) in answers.enumerated() { expectEqual(found(answer)?.ids, expected[index], said[index]) }

        // As the anchor of edge words, and the shapes themselves: the same as with the id written in, in each view.
        let texts = ["link:starts-at(:scope-start)", "link:ends-at(:scope-end)", "chore:connected-to(:scope)", "chore:connected-to(:scope-end)",
                     "chore:edge-to(:scope-end)", ":end-of(:scope)", ":start-of(:scope)", ":scope", "link:between(:scope-start, :scope-end)"]
        let shapes = [7, 8, 9, 10, 5, 6, 1, 2]
        var anchored: [QueryMatchRequest] = [], oracle: [[ShapeID]] = [], whose: [String] = []
        for text in texts {
            for n in shapes {
                for view in views {
                    anchored.append(QueryMatchRequest(text, scope: id(n), edges: view))
                    oracle.append(try ran(withID(text, of: n), edges: view, on: h).rows.map(\.id))
                    whose.append("\(text) of \(n), \(view)")
                }
            }
        }
        let anchoredAnswers = try batched(anchored, on: h)
        for (index, answer) in anchoredAnswers.enumerated() { expectEqual(found(answer)?.ids, oracle[index], whose[index]) }
        expect(oracle.contains { !$0.isEmpty } && oracle.contains { $0.isEmpty }, "answers of both sorts")
        // The ends differ by view, so the words that start from them do.
        let ending = anchored.indices.filter { anchored[$0].text == "link:ends-at(:scope-end)" && anchored[$0].scope == id(7) }
        expectEqual(ending.map { found(anchoredAnswers[$0])?.ids }, [[id(7), id(9)], [id(7), id(9)], [id(7)]],
                    "wire 7 and wire 9 end at Alpha, resolved and recorded; wire 7 alone ends at the proxy, as drawn")

        // The shape bound is the shape, whatever it stands for: the proxy is the proxy in every view, and so is the lens.
        let itself = try batched(views.flatMap { view in [5, 6].map { QueryMatchRequest(":scope", scope: id($0), edges: view) } }, on: h)
        expectEqual(itself.map { found($0)?.ids }, views.flatMap { _ in [[id(5)], [id(6)]] })

        // A lens nothing has answered stands for nothing: its wire stays at it in every view.
        let waiting = try relay()
        let unanswered = try batched(views.map { QueryMatchRequest(":scope-end", scope: id(8), edges: $0) }, on: waiting)
        expectEqual(unanswered.map { found($0)?.ids }, [[id(6)], [id(6)], [id(6)]])
    },
    test("bound to a container, :scope is what :inside and > are asked of; bound to a shape that holds nothing it finds nothing, where its id is refused cannot_contain") {
        let h = try yard()
        let texts = [":inside(:scope)", ":scope > *", ":scope *", "chore:inside(:scope)"]
        // Corrals 5 and 7 and pockets 2 and 12 hold shapes; chore 1 and wire 3 hold none.
        let holders = [5, 7, 2, 12], holdingNothing = [1, 3]
        let every = holders + holdingNothing
        let answers = try batched(texts.flatMap { text in every.map { QueryMatchRequest(text, scope: id($0)) } }, on: h)
        // What holds the shape is asked of any shape: a chore in a pen, a pocket's board, the top board.
        let holding = [":has(:scope)", ":has(> :scope)", "corral:has(:scope)", "pocket:has(:scope):not(:scope)"]
        let places = [6, 8, 16, 21, 11, 5, 2, 1, 9, 3]
        let held = try batched(holding.flatMap { text in places.map { QueryMatchRequest(text, scope: id($0)) } }, on: h)
        for (index, answer) in held.enumerated() {
            let (text, n) = (holding[index / places.count], places[index % places.count])
            expectEqual(found(answer)?.ids, try matched(withID(text, of: n), on: h), "\(text) of \(n)")
        }
        // Chore 21 is on pocket 12's board, which corral 15 holds on pocket 2's board, which the pen holds: all hold it, one directly.
        let at21 = places.firstIndex(of: 21)!
        expectEqual(holding.indices.map { found(held[$0 * places.count + at21])?.ids ?? [] }, [[5, 2, 15, 12], [12], [5, 15], [2, 12]].map { $0.map(id) })
        for (index, answer) in answers.enumerated() {
            let (text, n) = (texts[index / every.count], every[index % every.count])
            if holders.contains(n) {
                expectEqual(found(answer)?.ids, try matched(withID(text, of: n), on: h), "\(text) of \(n)")
            } else {
                expectEqual(found(answer)?.ids, [], "\(text) of \(n)")
                expectEqual(try refusedAnswer(withID(text, of: n), on: h)?.reason, .cannotContain, "\(withID(text, of: n))")
            }
        }
        let pen = texts.indices.map { found(answers[$0 * every.count])?.ids }
        expectEqual(pen[0], [6, 7, 8, 2, 15, 16, 12, 21, 11].map(id), "everything inside the pen, through the pantry's board")
        expectEqual(pen[1], [6, 7, 2].map(id), "what the pen holds")
        expectEqual(pen[2], pen[0])
        expectEqual(pen[3], [6, 8, 16, 21, 11].map(id))
        expectEqual(found(answers[1 * every.count + 3])?.ids, [id(21)], "what is on the board of pocket 12, in no container")
    },
    test("found directly: the shape bound, its ends and an edge word anchored at them walk no shape, nor does a kind they are tested beside; a kind among every shape still does") {
        let h = try wiresHarness(unfinished: true)
        let queries = try require(h.editor.queries)
        let direct = [":scope", ":scope-start", ":scope-end", "chore:connected-to(:scope)", "chore:edge-from(:scope-start, wire)", "link:starts-at(:scope-start)",
                      "link:ends-at(:scope-end)", ":end-of(:scope)", "chore:edge-to(:scope-end)", "chore:scope-end", "link:scope", "chore:scope-start:not(:scope-end)"]
        let requests = direct.flatMap { text in [11, 12, 13, 14, 1, 16].map { QueryMatchRequest(text, scope: id($0)) } }
        #if DEBUG
        let walks = queries.universeWalks, seeded = queries.seededFromAnchors
        #endif
        let answers = try batched(requests, on: h)
        expectEqual(answers.compactMap { found($0) }.count, requests.count)
        #if DEBUG
        expectEqual(queries.universeWalks - walks, 0, "not one walk of every shape")
        expect(queries.seededFromAnchors - seeded > 0, "the compounds start from the edges of the shape bound")
        let before = queries.universeWalks
        _ = try batched([QueryMatchRequest("chore:not(:scope)", scope: id(1)), QueryMatchRequest("chore:not(:scope)", scope: id(2))], on: h)
        expectEqual(queries.universeWalks - before, 1, "a kind among every shape is a walk, once for the batch")
        #endif
    },
    test("canonical: the words as the language writes them, never an id") {
        let h = try wiresHarness()
        let answers = try batched([QueryMatchRequest(":SCOPE-Start", scope: id(11)), QueryMatchRequest("chore:NOT( :Scope )", scope: id(1)),
                                   QueryMatchRequest(":scope-END,:scope", scope: id(11))], on: h)
        expectEqual(answers.map { found($0)?.canonical }, [":scope-start", "chore:not(:scope)", ":scope-end, :scope"])
        expectEqual(answers.map { found($0)?.ids }, [[id(1)], [2, 3, 4, 5, 6].map(id), [id(2), id(11)]])
        expectEqual(try boundPlan(":Scope-Start", on: h).canonical, ":scope-start")
        for answer in answers { expect(found(answer)?.canonical.contains(uuid(11)) == false) }
    },
])

@MainActor let scopeRefusalTests = Suite("Words bound to a request, refused", [
    test("a request with no scope whose query uses one is refused alone, as check refuses it; a scope the query doesn't use is not read") {
        let h = try wiresHarness()
        let queries = try require(h.editor.queries)
        #if DEBUG
        let checks = queries.checks
        #endif
        let requests = [QueryMatchRequest(":scope", scope: id(1)), QueryMatchRequest(":scope"), QueryMatchRequest("chore"),
                        QueryMatchRequest("chore:not(:scope-end)", scope: id(11)), QueryMatchRequest("chore:not(:scope-end)"),
                        QueryMatchRequest("chore", scope: id(99)), QueryMatchRequest(":scope-start")]
        let answers = try batched(requests, on: h)
        let expected: [[ShapeID]?] = [[id(1)], nil, (1...6).map(id), [1, 3, 4, 5, 6].map(id), nil, (1...6).map(id), nil]
        expectEqual(answers.map { found($0)?.ids }, expected, "the others are answered, one with a scope it does not use, even a scope no shape has")
        #if DEBUG
        expectEqual(queries.checks - checks, 4, "four texts, seven requests")
        #endif
        expectEqual(refused(answers[1]), unboundRefusal(":scope", at: 0))
        expectEqual(refused(answers[4]), unboundRefusal(":scope-end", at: 10))
        expectEqual(refused(answers[6]), unboundRefusal(":scope-start", at: 0))
        for index in [1, 4, 6] {
            let error = try require(refused(answers[index]))
            expectEqual(error.reason, .unsupported)
            expectEqual(error, try require(refusal(requests[index].text, binding: nil, on: h)), "the refusal `check` gives the same text")
        }
    },
    test("a scope that is no shape the query ranges over is that request's refusal, unknown_id as the id would be: gone, kept aside, on a board the app can't show") {
        let h = try hiddenShelf()
        // Chore 1 is a shape; gadget 10 is kept aside, chore 11 is on its board, which the app can't show; 99 is nothing.
        let texts = [":scope", ":scope-start", "chore:not(:scope-end)"]
        let spans = [(0, 6), (0, 12), (10, 10)]
        for (n, said) in [(99, "No shape the app can show has that id: it may have been deleted."), (10, "That shape is kept aside: the app can't read it."),
                          (11, "That shape is on a board the app can't show.")] {
            let answers = try batched(texts.map { QueryMatchRequest($0, scope: id(n)) } + [QueryMatchRequest(":scope", scope: id(1))], on: h)
            expectEqual(found(answers[3])?.ids, [id(1)], "a shape of the file is answered beside")
            let like = try require(try refusedAnswer("#\(uuid(n))", on: h))
            expectEqual(like.reason, .unknownID)
            expectEqual(like.message, said)
            for (index, answer) in answers.prefix(3).enumerated() {
                let error = try require(refused(answer), "\(texts[index]) of \(n)")
                expectEqual(error.reason, .unknownID, texts[index])
                expectEqual(error.message, like.message, texts[index])
                expectEqual(error.hint, like.hint, texts[index])
                expectEqual(error.span, QuerySpan(offset: spans[index].0, length: spans[index].1), "where the word stands: \(texts[index])")
            }
        }
        // A shape deleted since is gone, and the batch's other requests are answered.
        let relayed = try relay()
        relayed.editor.transact("Delete") { $0.delete([id(1)]) }
        let gone = try batched([QueryMatchRequest(":scope", scope: id(1)), QueryMatchRequest(":scope", scope: id(2))], on: relayed)
        expectEqual(refused(gone[0])?.reason, .unknownID)
        expectEqual(refused(gone[0])?.message, "No shape the app can show has that id: it may have been deleted.")
        expectEqual(found(gone[1])?.ids, [id(2)])
    },
    test("a scope no shape has is told with any other name no shape has, in the order the query writes them, as ids and titles are") {
        let h = try wiresHarness()
        let answers = try batched([QueryMatchRequest(#":scope, "Nope""#, scope: id(99)), QueryMatchRequest(#""Nope", :scope"#, scope: id(99)),
                                   QueryMatchRequest(":scope:not(:scope-end)", scope: id(99))], on: h)
        let said = try answers.map { try require(refused($0)) }
        expectEqual(said.map(\.reason), [.unknownID, .unknownTitle, .unknownID])
        expectEqual(said.map { $0.errors.map(\.reason) }, [[.unknownID, .unknownTitle], [.unknownTitle, .unknownID], [.unknownID, .unknownID]])
        expectEqual(said[0].errors.map(\.span), [QuerySpan(offset: 0, length: 6), QuerySpan(offset: 8, length: 6)])
        expectEqual(said[2].errors.map(\.span), [QuerySpan(offset: 0, length: 6), QuerySpan(offset: 11, length: 10)], "each use")
        let like = try require(try refusedAnswer(#"#\#(uuid(99)), "Nope""#, on: h))
        expectEqual(like.errors.map(\.reason), [.unknownID, .unknownTitle])
    },
    test("asked with nothing bound, check, checkStored and run refuse each use where it stands: unsupported, “:word” can’t be used here, and why") {
        let h = try wiresHarness()
        let cases: [(query: String, uses: [(word: String, offset: Int)])] = [
            (":scope", [(":scope", 0)]), (":scope-start", [(":scope-start", 0)]), (":scope-end", [(":scope-end", 0)]),
            ("chore:not(:scope)", [(":scope", 10)]), ("link:starts-at(:scope-start)", [(":scope-start", 15)]),
            ("chore:connected-to(:scope-end, wire)", [(":scope-end", 19)]), (":start-of(:scope)", [(":scope", 10)]),
            ("chore:is(:scope, :scope-end)", [(":scope", 9), (":scope-end", 17)]), (":scope-end:scope", [(":scope-end", 0), (":scope", 10)]),
            (":scope:not(:scope-start)\n, :scope", [(":scope", 0), (":scope-start", 11), (":scope", 27)]),
            ("chore:not(:SCOPE-End)", [(":scope-end", 10)]),
        ]
        for (query, uses) in cases {
            let expected = uses.map { unboundRefusal($0.word, at: $0.offset) }
            var errors: [QueryError] = []
            errors.append(try require(refusal(query, binding: nil, on: h), query))
            errors.append(try require(refusal(query, binding: nil, stored: true, on: h), "\(query), stored"))
            errors.append(try require(try refusedAnswer(query, on: h), "\(query), run"))
            for error in errors {
                expectEqual(error.reason, .unsupported, query)
                expectEqual(error.message, expected[0].message, query)
                expectEqual(error.hint, "`:scope` is the shape a query is asked about, and this one is asked about none.", query)
                expectEqual(error.span, expected[0].span, "where the first stands: \(query)")
                expectEqual(error.errors.isEmpty ? [error] : error.errors, expected, "each use: \(query)")
            }
            expectEqual(errors[0], errors[1], "check and checkStored: \(query)")
            expectEqual(errors[0], errors[2], "check and run: \(query)")
            // Bound, it is a query like any other.
            expect(try boundPlan(query, on: h).usesScope, query)
            expect(refusal(query, binding: .scope, on: h) == nil && refusal(query, binding: .scope, stored: true, on: h) == nil, query)
        }
        expectEqual(try require(refusal("chore:is(:scope, :scope-end)", binding: nil, on: h)).message, "“:scope” can’t be used here.", "the first leads")
        expectEqual(try require(refusal("chore:is(:scope, :scope-end)", binding: nil, on: h)).errors.map(\.message),
                    ["“:scope” can’t be used here.", "“:scope-end” can’t be used here."])
        // A query that uses none is as it was, bound or not.
        for query in ["chore", "chore:connected-to(*)", ":current-board"] {
            expect(refusal(query, binding: nil, on: h) == nil && refusal(query, binding: .scope, on: h) == nil, query)
            expect(!(try boundPlan(query, on: h).usesScope), query)
        }
    },
    test("stored, a word bound per request is refused first when it is not bound, and is no word that reads the editor when it is") {
        let h = try wiresHarness()
        let editor = "A stored query reads only the file, never who is looking or what is selected."
        // Unbound: the scope word leads, since a stored query is checked as any is first.
        let both = try require(refusal(":scope:starred", binding: nil, stored: true, on: h))
        expectEqual(both.message, "“:scope” can’t be used here.")
        expectEqual(both.hint, "`:scope` is the shape a query is asked about, and this one is asked about none.")
        expectEqual(both.span, QuerySpan(offset: 0, length: 6))
        let starred = try require(refusal("chore:starred:scope-end", binding: nil, stored: true, on: h))
        expectEqual(starred.message, "“:scope-end” can’t be used here.")
        // Bound: only what reads the editor is refused, named, with the editor's hint.
        let editorWord = try require(refusal(":scope:starred", binding: .scope, stored: true, on: h))
        expectEqual(editorWord.reason, .unsupported)
        expectEqual(editorWord.message, "“:starred” can’t be used here.")
        expectEqual(editorWord.hint, editor)
        expectEqual(editorWord.span, nil)
        for query in [":scope", "chore:not(:scope)", "link:starts-at(:scope-start)", ":scope-end"] {
            let plan = try require(try h.editor.queries?.checkStored(query, binding: .scope), query)
            expectEqual(plan.editorWords, [], query)
            expect(plan.readsOnlyTheFile, query)
        }
        // A query with no scope word is checked as it was, bound or not.
        expectEqual(try h.editor.queries?.checkStored("chore:not(:wired-to(*))", binding: .scope).canonical, "chore:not(:wired-to(*))")
        expectEqual(refusal(":current-board", binding: .scope, stored: true, on: h)?.message, "“:current-board” can’t be used here.")
        // What a missing kind or a wrong argument is refused with does not depend on what is bound.
        for binding in [nil, QueryBinding.scope] {
            expectEqual(refusal("chor:not(:scope)", binding: binding, on: h)?.reason, .unknownKind)
            expectEqual(refusal(":scope(x)", binding: binding, on: h)?.reason, .badArgument)
        }
    },
    test("they take no argument") {
        let h = try wiresHarness()
        for word in [":scope", ":scope-start", ":scope-end"] {
            for argument in ["(chore)", "( )", "()"] {
                let text = "chore\(word)\(argument)"
                for binding in [nil, QueryBinding.scope] {
                    let error = try require(refusal(text, binding: binding, on: h), text)
                    expectEqual(error.reason, .badArgument, text)
                    expectEqual(error.message, "\(word) takes no argument.", text)
                    expectEqual(error.hint, word, text)
                    expectEqual(error.span, QuerySpan(offset: 5, length: word.count + argument.count), text)
                }
            }
        }
    },
])

@MainActor let scopePlanTests = Suite("Words bound to a request, in a plan", [
    test("a plan says it uses them, that only the ends read edges, and that none reads the editor") {
        let h = try wiresHarness()
        let cases: [(query: String, uses: Bool, edges: Bool, waits: Bool, editor: [String])] = [
            ("chore", false, false, false, []),
            ("chore:connected-to(*)", false, true, true, []),
            (":scope", true, false, false, []),
            ("chore:not(:scope)", true, false, false, []),
            ("chore:is(:scope, #\(uuid(2)))", true, false, false, []),
            (":scope-start", true, true, true, []),
            (":scope-end", true, true, true, []),
            ("chore:not(:scope-end)", true, true, true, []),
            ("chore:connected-to(:scope)", true, true, true, []),
            (":start-of(:scope)", true, true, true, []),
            (":scope:not(:scope-start)", true, true, true, []),
            (":scope, :scope-end", true, true, true, []),
            (":scope:current-board", true, false, false, [":current-board"]),
            (":scope-end:starred:audited", true, true, true, [":starred", ":audited"]),
            (#"chore[shout^="H"]:scope"#, true, false, false, ["[shout]"]),
        ]
        for (query, uses, edges, waits, editor) in cases {
            let plan = try boundPlan(query, on: h)
            expectEqual(plan.usesScope, uses, "\(query) uses a word bound per request")
            expectEqual(plan.readsEdges, edges, "\(query) reads edges")
            expectEqual(plan.waitsForAnswers, waits, "\(query) waits for answers")
            expectEqual(plan.editorWords, editor, "\(query)'s words that read the editor")
            expectEqual(plan.readsOnlyTheFile, editor.isEmpty, "\(query) reads only the file")
        }
    },
    test("a plan prints them as nodes of its tree, never an id") {
        let h = try wiresHarness()
        expectEqual(try boundPlan(":scope", on: h).description, ":scope")
        expectEqual(try boundPlan(":scope-start", on: h).description, ":scope-start")
        expectEqual(try boundPlan(":scope-end", on: h).description, ":scope-end")
        expectEqual(try boundPlan("chore:not(:scope)", on: h).description, """
            all of
              kind chore
              not
                :scope
            """)
        expectEqual(try boundPlan("link:starts-at(:scope-start)", on: h).description, """
            all of
              kind link
              starts-at (every type)
                :scope-start
            """)
        expectEqual(try boundPlan(":end-of(:scope, only wire)", on: h).description, """
            end-of (wire)
              :scope
            """)
        expectEqual(try boundPlan(":scope:scope-end", on: h).description, """
            all of
              :scope
              :scope-end
            """)
    },
    test("they are the engine's, not the language's nor a plugin's: the vocabulary does not list them, and no plugin may add a word called so") {
        let vocabulary = try QueryVocabulary(registry: Registry(plugins: queryPlugins()))
        expect(!vocabulary.words.contains { $0.word.hasPrefix("scope") }, "not among the words")
        expect(!vocabulary.text.contains("scope"), "nor in the block --ask sends")
        expect(!vocabulary.textForStoredQueries.contains("scope"), "nor in a stored query's")
        expectEqual(vocabulary.words.map(\.word), Word.allCases.map(\.rawValue) + ["starred", "heavy", "audited", "wired-to"])
        func adding(_ word: String) -> Contributor {
            Contributor(id: "more-words") { registrar in
                registrar.queryPseudoClass(word, "x", example: ":x", prepare: { _ in () }, matches: { _, _ in .no })
            }
        }
        for word in ["scope", "scope-start", "scope-end"] {
            expectThrows(RegistryError.invalid(point: "QueryWords", reason: "more-words adds :\(word), one of the engine's own words, bound per request")) {
                _ = try Registry(plugins: queryPlugins(more: [adding(word)]))
            }
        }
        // The words near them are just words.
        for word in ["scoped", "scope-of", "my-scope"] { _ = try Registry(plugins: queryPlugins(more: [adding(word)])) }
    },
])
