import Canvas
import CanvasTesting
import Queries
import QueryLanguage
import QueryLexicon
import TestKit
import Titles

// Queries naming shapes by their titles, as Titles has them: a named title read from the shape on
// any thread, a derived one asked of Titles on the main actor, both folded as Titles folds titles,
// for a title head, the title attribute, rows and --ask's titles.

@MainActor let titleQueriesTests = Suite("Titles name shapes for queries", [
    test("a kind is named when it holds Titles' title, derived when Titles works titles out, and untitled with neither") {
        let h = try titledHarness()
        let vocabulary = try require(h.editor.queries).vocabulary
        expectEqual(vocabulary.nameAttribute, TitleProperty.key.rawValue)
        expectEqual(vocabulary.kind(Card.kind)?.names, .named)
        expectEqual(vocabulary.kind(Tile.kind)?.names, .derived, "named, and worked out for those nobody named: Titles works it out")
        expectEqual(vocabulary.kind(Disc.kind)?.names, .derived)
        expectEqual(vocabulary.kind(Box.kind)?.names, QueryNameSource.none)
        expectEqual(vocabulary.kind(Card.kind)?.attribute(TitleProperty.key.rawValue)?.isName, true)
        expectEqual(vocabulary.kind(Disc.kind)?.attribute(TitleProperty.key.rawValue)?.isName, true, "a title worked out is an attribute too")
        expect(vocabulary.kind(Box.kind)?.attribute(TitleProperty.key.rawValue) == nil, "a kind with no titles has no title attribute")
        expectEqual(try refusal("box[title]", on: h)?.reason, .unknownAttribute)
    },
    test("a title head matches named and derived titles, each folded as Titles folds titles, the query's too") {
        let h = try titledHarness()
        expectMatches([
            #""API gateway""#: [1],
            #""Auth service""#: [2],
            #""  Auth   service ""#: [2],
            #""Auth\nservice""#: [2],
            #""Kiosk""#: [4],
            #""Lobby""#: [5],
            #""Disc, 120 × 80""#: [6],
        ], on: h)
        let error = try require(try refusal(#""auth service""#, on: h))
        expectEqual(error.reason, .unknownTitle, "a title's case counts, as draw's does")
        expect(error.hint?.contains(#""Auth service""#) == true, "\(error.hint ?? "no hint")")
    },
    test("the title attribute tests what the shape is called, named or worked out") {
        let h = try titledHarness()
        expectMatches([
            "card[title]": [1, 2],
            "card:not([title])": [3],
            "*:not([title])": [3, 7],
            #"[title^="API"]"#: [1],
            #"[title="auth service" i]"#: [2],
            #"[title*="120"]"#: [6],
            "tile[title=Kiosk]": [4],
            #":contains("kiosk")"#: [4, 5],
        ], on: h)
    },
    test("rows carry each shape's title as it reads, none for the untitled") {
        let h = try titledHarness()
        let rows = try answer("*", on: h).rows
        expectEqual(rows.map(\.title), ["API gateway", "Auth service", nil, "Kiosk", "Lobby", "Disc, 120 × 80", nil])
        expectEqual(rows.first?.properties?[TitleProperty.key.rawValue], nil, "a title is the row's, never one of its attributes")
    },
    test("a named title is read from the shape, a derived one asked of Titles on the main actor") {
        let h = try titledHarness()
        let queries = try require(h.editor.queries)
        let before = queries.derivedTitlesAsked
        expectMatches([#"card[title^="API"]"#: [1]], on: h)
        expectEqual(queries.derivedTitlesAsked, before, "cards are named: nothing asked on the main actor")
        expectMatches([#"disc[title^="Disc"]"#: [6]], on: h)
        expectEqual(queries.derivedTitlesAsked, before + 1)
        expectMatches(["tile[title]": [4, 5]], on: h)
        expectEqual(queries.derivedTitlesAsked, before + 3, "both tiles, the named one too: Titles says what either is called")
    },
    test("a derived title is Titles' as the app has it when asked; the rest of the row is as the query took up the file") {
        let landed = Flag()
        let landing = Contributor(id: "landing") { registrar in
            registrar.queryPseudoClass("landing", "a commit lands as it's taken up", example: ":landing",
                                       prepare: { preparation in
                                           guard !landed.value else { return }
                                           landed.value = true
                                           preparation.editor.transact { $0.update(id(4), as: Tile.self) { $0.props.label = "Booth" } }
                                       },
                                       matches: { _, _ in .no })
        }
        let h = try titledHarness(more: [landing])
        let rows = try answer("tile[label=Kiosk], :landing", on: h).rows
        expect(landed.value)
        expectEqual(rows.map(\.id), [4, 5].map(id))
        expectEqual(rows.first?.title, "Booth", "worked out from the label as it is now")
        expectEqual(rows.first?.properties?["label"], "Kiosk", "the label as the query took it up")
        expectEqual(rows.last?.title, "Lobby")
    },
    test("--ask's titles are the shapes' titles, named and worked out, those the question names first") {
        let h = try titledHarness()
        let queries = try require(h.editor.queries)
        let titles = try awaitResult { try await queries.titles(for: "where's the gateway?", limit: 10) }
        expectEqual(titles.map(\.title), ["API gateway", "Auth service", "Kiosk", "Lobby", "Disc, 120 × 80"])
        expectEqual(titles.map(\.id), [1, 2, 4, 5, 6].map(id))
    },
    test("without TitleQueriesPlugin, nothing names shapes: a title head is refused") {
        let h = try titledHarness(withPlugin: false)
        expectEqual(h.editor.queries?.vocabulary.nameAttribute, nil)
        expectEqual(try refusal(#""API gateway""#, on: h)?.reason, .noNames)
    },
])
