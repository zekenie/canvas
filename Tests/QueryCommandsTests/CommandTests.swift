import Automation
import Canvas
import CanvasRPC
import CanvasTesting
import Foundation
import Queries
import QueryCommands
import QueryLanguage
import TestKit
import Topology

// `canvas query`, run as the app's server runs it: what it takes (a query or a question, exactly
// one; --brief or --fields, not both), what it answers (the rows as the wire's JSON, built off the
// main actor, equal to what the rows write themselves as), --limit, --fields, --brief, cuts and
// --count, and its refusals, each where it is in the query, the line whole so a caret lands on it.

@MainActor let commandTests = Suite("query", [
    test("its help: a query or a question, standard input for either, --ask waiting 60 s; no kind by name; the skill's pages") {
        let h = try shelfHarness()
        let spec = try require(h.editor.registry.automationCommands.first { $0.name == "query" })
        expectEqual(spec.scope, .board)
        expectEqual(spec.positionals, ["query"])
        let arguments = Dictionary(uniqueKeysWithValues: spec.arguments.map { ($0.name, $0) })
        let query = try require(arguments["query"]), ask = try require(arguments["ask"])
        expect(query.isPositional && query.readsStandardInput && !query.isRequired)
        expectEqual(query.valueName, "query")
        expectEqual(query.waits, nil)
        expect(ask.readsStandardInput && !ask.isPositional)
        expectEqual(ask.valueName, "question")
        expectEqual(ask.waits, 60)
        expectEqual(spec.params["properties"]?["ask"]?["maxLength"], 2_000)
        let limit = try require(arguments["limit"])
        expectEqual(limit.value, .integer)
        expectEqual(limit.defaultValue, 100)
        expectEqual(spec.params["properties"]?["limit"]?["minimum"], 1)
        expectEqual(spec.params["properties"]?["limit"]?["maximum"], nil, "a query has no most rows")
        expectEqual(arguments["fields"]?.value, .list(.text(choices: nil)))
        expectEqual(arguments["fields"]?.valueName, "attribute")
        expectEqual(arguments["count"]?.value, .flag)
        expectEqual(arguments["brief"]?.value, .flag)
        for example in spec.examples {
            expect(!example.command.contains(Chore.kind.rawValue) && !example.command.contains(Pocket.kind.rawValue), example.command)
        }
        expect(spec.examples.contains { $0.command.contains("<kind>") } && spec.examples.contains { $0.command.contains("<title>") })
        let discussion = try require(spec.discussion)
        for said in ["reference/query.md", "query-prompt.md", "standard input", "query-vocabulary"] {
            expect(discussion.contains(said), said)
        }
        // Help says what's read from standard input (x-stdin), once: no description says it again.
        for argument in [query, ask] { expect(argument.summary?.contains("standard input") == false, argument.summary ?? argument.name) }
    },
    test("--fields names attributes some kind has; one no kind has is the params' fault, with the one like it") {
        let h = try shelfHarness()
        let bogus = try refused(["query", "chore", "--fields", "note", "--fields", "estimat"], on: h)
        expectEqual(bogus.code, RPCError.invalidParams)
        expectEqual(bogus.reason, "unknown_attribute")
        expectEqual(bogus.message, "No kind has an attribute estimat for --fields to list.")
        expectEqual(bogus.hint, "Did you mean estimate?")
        let unlike = try refused(["query", "chore", "--fields", "zzzqqq"], on: h)
        expectEqual(unlike.hint, "`canvas query-vocabulary` lists each kind's attributes.")
        expectEqual(try refused(["query", "--ask", "which chores?", "--fields", "zzzqqq"], on: h).reason, "unknown_attribute", "a question's rows too")
        // One some kind has lists nothing for a shape of a kind without it; the name point's word is the row's title.
        let pockets = try answered(["query", "pocket", "--fields", "estimate", "--fields", "caption"], on: h)
        expect(pockets["rows"]?.arrayValue?.allSatisfy { $0["properties"] == [:] } == true, "\(pockets)")
    },
    test("exactly one of a query and a question; --brief or --fields, not both: the params' fault, said in its words") {
        let h = try shelfHarness()
        for line in [["query"], ["query", "chore", "--ask", "which chores?"], ["query", "--ask", "   "], ["query", "chore", "--ask", "  "]] {
            let error = try refused(line, on: h)
            expectEqual(error.code, RPCError.invalidParams, "\(line)")
            expectEqual(error.reason, "invalid_params", "\(line)")
            expectEqual(error.message, #"Say what to find: a query, or --ask "…"."#, "\(line)")
            expectEqual(error.hint, "`canvas help query` says what it takes.", "\(line)")
        }
        let both = try refused(["query", "chore", "--brief", "--fields", "note"], on: h)
        expectEqual(both.code, RPCError.invalidParams)
        expectEqual(both.message, "Give --brief or --fields, not both.")
        expectEqual(both.hint, "--brief leaves every attribute out; --fields lists only those it names.")
        let long = try refused(["query", "--ask", String(repeating: "a", count: 2_001)], on: h)
        expectEqual(long.reason, "invalid_params")
        expectEqual(rowIDs(try answered(["query", "-"], on: h, input: "chore:top-level\n")), [uuid(1)], "a query from standard input")
        expectEqual(try answered(["query", "--brief", "chore"], on: h)["count"], 4, "--brief alone")
    },
    test("rows as the wire's JSON, built off the main actor, equal to the rows written as they write themselves") {
        let h = try shelfHarness()
        let answer = try result("*", on: h)
        expectEqual(answer.rows.map(\.id), [1, 2, 11, 12, 21, 22, 3].map(id), "file order")
        let expected = try JSON(encoding: answer.rows)
        let built = try awaitResult { await QueryOutput.json(answer, countOnly: false) }
        expectEqual(built["rows"], expected)
        expectEqual(QueryOutput.lastBuiltOnMainThread, false)
        expectEqual(built["query"], "*")
        expectEqual(built["count"], 7)
        expectEqual(built["warnings"], nil, "none to say")
        for row in answer.rows { expectEqual(QueryOutput.row(row), try JSON(encoding: row), "\(row.id)") }

        // Every member a row can have: a title, inside, properties, cut, a connection.
        let rows = try require(built["rows"]?.arrayValue)
        let alpha = rows[0], gamma = rows[5], wire = rows[6]
        expectEqual(alpha["title"], "Alpha")
        expectEqual(alpha["board"], "root")
        expectEqual(alpha["inside"], nil)
        expectEqual(alpha["cut"], ["note"])
        expectEqual(alpha["properties"]?["note"]?.stringValue?.count, 501, "cut at 500, and …")
        expectEqual(gamma["inside"], ["Pantry", "Untitled Pocket"])
        expectEqual(gamma["board"], .string(uuid(12)))
        expectEqual(gamma["properties"]?["status"], "done")
        expectEqual(rows[4]["title"], nil, "untitled")
        expectEqual(wire["connection"], ["type": "wire", "from": ["id": .string(uuid(1)), "title": "Alpha"],
                                         "to": ["id": .string(uuid(2)), "title": "Pantry"]])

        // The command answers the same.
        let command = try answered(["query", "*"], on: h)
        expectEqual(command["rows"], expected)
        expectEqual(command["count"], 7)
        expectEqual(QueryOutput.lastBuiltOnMainThread, false)
    },
    test("a row's inside names the containers a shape is in between the boards; > is directly inside one") {
        // Corral 30 "Bay" on the top board holds chore 31 and pocket 32 "Shed", whose board holds chore 41.
        let captioned = Contributor(id: "corral-captions") { $0.optIn(Corral.self, to: Caption.self) }
        var bay = AnyShapeRecord(ShapeRecord(id: id(30), Corral(unit)))
        bay[Caption.self] = "Bay"
        let file = CanvasFile(root: CanvasDocument(shapes: [bay, chore(id(31)).copy(as: id(31), container: id(30)),
                                                            pocket(id(32), caption: "Shed").copy(as: id(32), container: id(30))]),
                              children: [id(32): CanvasDocument(shapes: [chore(id(41))])])
        let h = try shelfHarness(commandPlugins() + [CorralsPlugin(), captioned], file: file)
        let json = try answered(["query", "--brief", "chore"], on: h)
        let rows = try require(json["rows"]?.arrayValue)
        expectEqual(rows.map { $0["id"] }, [.string(uuid(31)), .string(uuid(41))])
        expectEqual(rows.map { $0["inside"] }, [["Bay"], ["Bay", "Shed"]])
        expectEqual(rows.map { $0["board"] }, ["root", .string(uuid(32))])
        expectEqual(rowIDs(try answered(["query", #""Bay" > *"#], on: h)), [uuid(31), uuid(32)])
        expectEqual(try answered(["query", "--count", #""Bay" *"#], on: h)["count"], 3)
    },
    test("--limit lists the first rows, counting them all; --fields only those, whole; --brief none; --count only how many") {
        let h = try shelfHarness()
        let limited = try answered(["query", "--limit", "2", "chore"], on: h)
        expectEqual(rowIDs(limited), [uuid(1), uuid(11)])
        expectEqual(limited["count"], 4)
        expectEqual(limited["warnings"]?.arrayValue?.map { $0["reason"] }, ["limited"])

        let fields = try answered(["query", "--fields", "note", "--fields", "status", "chore"], on: h)
        let alpha = try require(fields["rows"]?.arrayValue?.first)
        expectEqual(alpha["properties"], ["note": .string(longNote), "status": "todo"], "whole")
        expectEqual(alpha["cut"], nil)

        let brief = try answered(["query", "--brief", "chore"], on: h)
        expect(brief["rows"]?.arrayValue?.allSatisfy { $0["properties"] == nil && $0["id"] != nil } == true)
        expectEqual(brief["rows"]?.arrayValue?.first?["title"], "Alpha")

        let counted = try answered(["query", "--count", #""Pantry" chore"#], on: h)
        expectEqual(counted, ["board": ["shows": "root", "showsPath": ["root"]], "query": #""Pantry" chore"#, "count": 3],
                    "where it ran, the board shown as it took up the file")
        expect(h.enter(id(2)))
        let inside = try answered(["query", "--count", ":current-board"], on: h)
        expectEqual(inside["board"], ["shows": .string(id(2).description), "showsPath": ["root", .string(id(2).description)]])
        expect(h.editor.showBoard(.root))
        let none = try answered(["query", "--count", "chore[status=blocked]"], on: h)
        expectEqual(none["count"], 0)
        expectEqual(none["rows"], nil)

        let refusedLimit = try refused(["query", "--limit", "0", "chore"], on: h)
        expectEqual(refusedLimit.reason, "invalid_params")
    },
    test("--limit has no most: a number past 10,000 lists that many rows, and the warning offers ten times the number") {
        let many = 10_005
        let h = try shelfHarness(file: CanvasFile(root: CanvasDocument(shapes: (0..<many).map { _ in chore(ShapeID()) })))
        let all = try answered(["query", "--brief", "--limit", "20000", "chore"], on: h)
        expectEqual(all["count"], .number(Double(many)))
        expectEqual(all["rows"]?.arrayValue?.count, many, "every row, none cut at 10,000")
        expectEqual(all["warnings"], nil, "nothing is left unlisted")
        let some = try answered(["query", "--brief", "--limit", "10002", "chore"], on: h)
        expectEqual(some["rows"]?.arrayValue?.count, 10_002)
        expectEqual(some["warnings"]?.arrayValue?.compactMap { $0["message"]?.stringValue },
                    ["10002 of 10005 listed. --limit 100020 lists more; --count only counts."])
        expectEqual(try answered(["query", "--brief", "chore"], on: h)["rows"]?.arrayValue?.count, 100, "the default is still 100")
    },
    test("canvas query is refused too_slow at 8 s over a file of any size, before canvas stops waiting at 10; the engine itself gives a larger file longer") {
        let desk = Desk()
        let shapes = (1...3).map { chore(id($0), caption: "Alpha") } + (0..<19_997).map { _ in chore(ShapeID()) }
        let h = try shelfHarness(commandPlugins(desk: desk), file: CanvasFile(root: CanvasDocument(shapes: shapes)))
        let queries = try require(h.editor.queries)
        expectEqual(QueryBudget.deadline(forShapes: 20_000), .milliseconds(8_500))
        // The three Alphas are asked `:slow`, each costing more than a slice's 2 ms, so each is a slice of its own;
        // the first moves the clock on 8 s, and the slices after it are not asked.
        desk.onSlow = {
            if desk.slowCalls == 1 { h.wait(8_000) }
            let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            while clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start < 3_000_000 {}
        }
        let error = try refused(["query", #"chore"Alpha":slow"#], on: h)
        expectEqual(error.reason, "too_slow")
        expectEqual(error.message, "The query took more than 8 seconds.")
        expectEqual(desk.slowCalls, 1)
        spinRunLoop(until: { queries.liveSnapshots == 0 })
        expectEqual(h.scheduler.pendingCount, 0)
        desk.slowCalls = 0
        let direct = try awaitResult { try await queries.run(QueryRequest(#"chore"Alpha":slow"#)) }
        expectEqual(direct.count, 3, "asked of the engine alone, 8 s of 8.5 is in time")
    },
    test("the query as the language writes it, and its warnings") {
        let h = try shelfHarness()
        let json = try answered(["query", #"chore:TOP-LEVEL,   [caption="Gama"]"#], on: h)
        expectEqual(json["query"], #"chore:top-level, [caption="Gama"]"#)
        expectEqual(json["warnings"]?.arrayValue?.map { $0["reason"] }, ["no_title_match"])
        expect(json["warnings"]?.arrayValue?.first?["message"]?.stringValue?.isEmpty == false)
    },
    test("a refusal says where: line, column and length within the line as written, whole up to 200 characters, so a caret under it lands") {
        let h = try shelfHarness()
        @MainActor func problem(_ text: String) -> QueryError? { checked(text, on: h) }
        /// What a caret drawn under `statement` from `column`, `length` long, marks.
        func marked(_ data: JSON?) -> String? {
            guard let statement = data?["statement"]?.stringValue, let column = data?["column"]?.intValue,
                  let length = data?["length"]?.intValue else { return nil }
            let characters = Array(statement)
            guard column >= 1, column - 1 + length <= characters.count else { return nil }
            return String(characters[(column - 1)..<(column - 1 + length)])
        }

        let one = try refused(["query", "chroe"], on: h)
        expectEqual(one.reason, "unknown_kind")
        expectEqual(one.code, RPCError.failed)
        expectEqual(one.data?["line"], 1)
        expectEqual(one.data?["column"], 1)
        expectEqual(one.data?["length"], 5)
        expectEqual(one.data?["statement"], "chroe")
        expectEqual(one.hint, problem("chroe")?.hint)

        // On its second line, indented: the line as written, and the column counted from its start.
        let text = "chore,\n   chore:nope\n"
        let second = try refused(["query", "-"], on: h, input: text)
        let expected = try require(problem(text))
        let span = try require(expected.span)
        expectEqual(second.reason, expected.reason.rawValue)
        expectEqual(second.message, expected.message)
        expectEqual(second.data?["line"], 2)
        expectEqual(second.data?["statement"], "   chore:nope")
        expectEqual(marked(second.data), String(Array(text)[span.offset..<span.end]))
        expectEqual(second.data?["column"], .number(Double(span.offset - "chore,\n".count + 1)))

        // Several problems at once: the first, and every one, each where it is.
        let several = #"chroe, chore[capton="x"]"#
        let both = try refused(["query", several], on: h)
        let problems = try require(both.data?["errors"]?.arrayValue)
        let found = try require(problem(several))
        expectEqual(problems.count, found.errors.count)
        expect(problems.count == 2, "\(problems)")
        for (entry, error) in zip(problems, found.errors) {
            let at = try require(error.span)
            expectEqual(entry["reason"], .string(error.reason.rawValue))
            expectEqual(entry["message"], .string(error.message))
            expectEqual(entry["line"], 1)
            expectEqual(entry["statement"], .string(several))
            expectEqual(marked(entry), String(Array(several)[at.offset..<at.end]))
        }

        // An empty query is about no part of it.
        let empty = try refused(["query", "/* nothing */"], on: h)
        expectEqual(empty.reason, "empty_query")
        expectEqual(empty.data?["line"], nil)

        // A line longer than that is quoted around what's wrong: a query too long, its last 200
        // characters, the caret under the 50 past the limit (not 8,242 characters quoted).
        let long = "chore" + String(repeating: " ", count: QueryLimits.characters + 45)
        let tooLong = try refused(["query", "-"], on: h, input: long)
        expectEqual(tooLong.reason, "too_long")
        expectEqual(tooLong.data?["line"], 1)
        expectEqual(tooLong.data?["statement"], .string("…" + String(repeating: " ", count: QueryOutput.quoted)))
        expectEqual(tooLong.data?["column"], .number(Double(QueryOutput.quoted - 50 + 2)))
        expectEqual(tooLong.data?["length"], 50)
        expectEqual(marked(tooLong.data), String(repeating: " ", count: 50))
    },
    test("a word the engine binds to a request (:scope, :scope-start, :scope-end) is refused, where it stands, since a command binds nothing; and the vocabulary does not list it") {
        let h = try shelfHarness()
        let hint = "`:scope` is the shape a query is asked about, and this one is asked about none."
        // The query, the word as the message says it, and where it stands in the line.
        for (query, word, column) in [(":scope", ":scope", 1), (":scope-start", ":scope-start", 1), (":scope-end", ":scope-end", 1),
                                      ("chore:not(:scope)", ":scope", 11), ("link:starts-at(:scope-start)", ":scope-start", 16),
                                      ("chore:SCOPE-End", ":scope-end", 6)] {
            for line in [["query", query], ["query", "--count", query], ["query", "--brief", query]] {
                let error = try refused(line, on: h)
                expectEqual(error.reason, "unsupported", "\(line)")
                expectEqual(error.code, RPCError.failed, "\(line)")
                expectEqual(error.message, "“\(word)” can’t be used here.", "\(line)")
                expectEqual(error.hint, hint, "\(line)")
                expectEqual(error.data?["line"], 1, "\(line)")
                expectEqual(error.data?["column"], .number(Double(column)), "\(line)")
                expectEqual(error.data?["length"], .number(Double(word.count)), "\(line)")
                expectEqual(error.data?["statement"], .string(query), "\(line)")
                expectEqual(error.data?["errors"], nil, "one use, one problem: \(line)")
            }
            // As the engine says it.
            let engine = try require(checked(query, on: h), query)
            expectEqual(engine.reason, .unsupported, query)
            expectEqual(engine.hint, hint, query)
        }
        // Each use is a problem of its own, where it stands, the first leading.
        let several = try refused(["query", ":scope:not(:scope-end)"], on: h)
        expectEqual(several.reason, "unsupported")
        expectEqual(several.message, "“:scope” can’t be used here.")
        let problems = try require(several.data?["errors"]?.arrayValue)
        expectEqual(problems.map { $0["message"] }, ["“:scope” can’t be used here.", "“:scope-end” can’t be used here."])
        expectEqual(problems.map { $0["column"] }, [1, 12])
        expectEqual(problems.map { $0["reason"] }, ["unsupported", "unsupported"])
        // Neither the block `--ask` sends nor the words listed name them: a command can't use them, so no one is told of them.
        let json = try answered(["query-vocabulary"], on: h)
        expect(json["vocabulary"]?.stringValue?.contains("scope") == false, "not in the block --ask sends")
        expect(try require(json["words"]?.arrayValue).allSatisfy { $0["word"]?.stringValue?.hasPrefix("scope") == false }, "nor among the words")
    },
    test("without QueriesPlugin, nothing answers queries: no_queries") {
        let h = try shelfHarness(commandPlugins(queries: false))
        for line in [["query", "chore"], ["query", "--ask", "which chores?"]] {
            let error = try refused(line, on: h)
            expectEqual(error.reason, "no_queries", "\(line)")
            expectEqual(error.message, "This app can't answer queries.")
        }
        expectEqual(try refused(["query-vocabulary"], on: h).reason, "no_queries")
    },
    test("without Topology, every query is refused no_topology, as the engine says") {
        // Wires are Topology's edges, so they go too.
        let plugins = commandPlugins().filter { ![PluginID.topology, "graph"].contains($0.id) }
        let h = try shelfHarness(plugins)
        let error = try refused(["query", "chore"], on: h)
        expectEqual(error.reason, "no_topology")
    },
])
