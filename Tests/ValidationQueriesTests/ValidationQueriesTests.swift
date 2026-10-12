import Canvas
import CanvasTesting
import Queries
import QueryLanguage
import TestKit
import Topology
import Validation

// `:invalid` and `:warned` on every board of the file: from Validation's cache on the board shown
// while it's current, else by running the shape's rules against the board it's on as the app has
// it, in the query's main slices.

@MainActor let validationQueriesTests = Suite("Validation in queries", [
    test("on the board shown, Validation's verdicts are taken from its cache: no rule runs") {
        let runs = RuleRuns()
        let h = try checkedHarness(runs)
        let queries = try require(h.editor.queries)
        let before = runs.count, asked = queries.verdictsAsked
        expectEqual(try matched(":current-board:invalid", on: h), [1].map(id))
        expectEqual(try matched(":current-board:warned", on: h), [2].map(id))
        expectEqual(runs.count, before, "every verdict was Validation's own")
        expect(queries.verdictsAsked > asked, "asked on the main actor all the same")
    },
    test("on a board that isn't shown, the shape's rules run against its own board, in slices") {
        let runs = RuleRuns()
        let h = try checkedHarness(runs)
        let queries = try require(h.editor.queries)
        let before = runs.count, slices = queries.mainSlices
        expectEqual(try matched(":invalid", on: h), [1, 11, 14].map(id), "tag 13's shape is on its board; tag 14's isn't")
        expectEqual(runs.count, before + 4 + 2, "the pocket's four shapes, those on the board shown from the cache; and each listed row's problems, read the same way: cards 11 and 14")
        expect(queries.mainSlices > slices)
        expectEqual(try matched(":warned", on: h), [2, 12].map(id))
        expectEqual(try matched(#"card:invalid:not(:current-board)"#, on: h), [11].map(id))
    },
    test("a board never shown is judged as Validation would judge it once shown") {
        let runs = RuleRuns()
        let h = try checkedHarness(runs)
        let answered = try matched(":invalid, :warned", on: h).filter { h.editor.file.board(containing: $0) == BoardID(owner: id(4)) }
        expect(h.enter(id(4)))
        let judged = h.editor.document.shapes.map(\.id).filter { h.editor.validation?.results[$0] != nil }
        expectEqual(answered, judged)
    },
    test("with a commit landed since the query took up the file, the cache isn't taken: rules judge each shape as the app has it") {
        let runs = RuleRuns()
        let landed = Flag()
        let landing = Contributor(id: "landing") { registrar in
            registrar.queryPseudoClass("landing", "a commit lands as it's taken up", example: ":landing",
                                       prepare: { preparation in
                                           guard !landed.value else { return }
                                           landed.value = true
                                           let editor = preparation.editor
                                           editor.transact { $0.update(id(3), as: Card.self) { $0.props.text = "bad now" } }
                                           editor.transact(on: BoardID(owner: id(4))) { $0.update(id(12), as: Card.self) { $0.props.text = "fine" } }
                                       },
                                       matches: { _, _ in .no })
        }
        let h = try checkedHarness(runs, more: [landing])
        let before = runs.count
        expectEqual(try matched("card:invalid, :landing", on: h), [1, 3, 11].map(id), "card 3 as it is now")
        expect(landed.value)
        expectEqual(runs.count, before + 5 + 3, "every card's rules: the board shown's changed since the query started; and the three listed rows' problems")
        // Card 3 is waiting to be checked again, so its verdict isn't in the cache until a frame reads it.
        expectEqual(try matched("card:warned", on: h), [2].map(id), "card 12 as it is now")
        expectEqual(runs.count, before + 8 + 3, "cards 3, 11 and 12; no commit since this one started, so cards 1 and 2 from the cache")
        _ = h.editor.validation?.results
        let checked = runs.count
        expectEqual(try matched("card:warned", on: h), [2].map(id))
        expectEqual(runs.count, checked + 2, "the pocket's cards alone")
    },
    test("a query never has Validation check a board: it runs the rules itself, and Validation's cache is left as it was") {
        let runs = RuleRuns()
        let h = try EditorHarness(plugins: validationPlugins(runs), file: checkedFile())
        expectEqual(runs.count, 0, "Validation hasn't read the board shown")
        expectEqual(try matched(":invalid", on: h), [1, 11, 14].map(id))
        expectEqual(runs.count, 8 + 3, "every card's and tag's rules, the board shown's too, each run by the query; and again for the three rows' problems")
        _ = h.editor.validation?.results
        expectEqual(runs.count, 12 + 3, "Validation reads the board shown itself, as it would have with no query")
    },
    test("the vocabulary lists the words, from ValidationQueriesPlugin; without it, they're refused") {
        let runs = RuleRuns()
        let vocabulary = try require(try checkedHarness(runs).editor.queries).vocabulary
        let words = vocabulary.words.filter { $0.from == ValidationQueriesPlugin().id }
        expectEqual(words.map(\.form), [":invalid", ":warned"])
        expectEqual(words.map(\.summary), ["it has an error", "it has a warning"])
        let bare = try EditorHarness(plugins: [TopologyPlugin(), FixturesPlugin(), CardsPlugin(), ValidationPlugin(), QueriesPlugin()])
        expectEqual(try refusal(":invalid", on: bare)?.reason, .unknownPseudoClass)
    },
    test("a row of :invalid lists each error, a field's with where in it, from the cache or from the rules; :warned lists none") {
        let runs = RuleRuns()
        let file = CanvasFile(root: CanvasDocument(shapes: [record(1, Card(unit, text: "bad")), record(2, Card(unit, text: "deep")),
                                                          record(3, Card(unit, text: "fine")), record(4, Card(unit, text: "meh"))]))
        let whole = ShapeProblem(field: nil, path: nil, class: "wrong", message: "It's bad.")
        let deep = ShapeProblem(field: "lines", path: "/lines/0", class: "wrong", message: "Line 1 is bad.")
        for cached in [true, false] {
            let h = try EditorHarness(plugins: validationPlugins(runs), file: file)
            if cached { _ = h.editor.validation?.results }
            let queries = try require(h.editor.queries)
            let asked = queries.problemsAsked
            let rows = try awaitResult { try await queries.run(QueryRequest(":invalid", limit: 10, properties: .none)) }.rows
            expectEqual(rows.map(\.id), [1, 2].map(id), "cached: \(cached)")
            expectEqual(rows.map(\.problems), [[whole], [deep]], "an error with no field has neither field nor path; a warning is no problem (cached: \(cached))")
            expectEqual(queries.problemsAsked - asked, 2)
            let warned = try awaitResult { try await queries.run(QueryRequest(":warned", limit: 10, properties: .none)) }.rows
            expectEqual(warned.map(\.id), [2, 4].map(id))
            expect(warned.allSatisfy { $0.problems == nil }, "`:warned` is not asked")
        }
    },
])
