import Canvas
import CanvasTesting
import Queries
import QueryLanguage
import TestKit

// Hints that are queries lead to no refusal the query they mend didn't have: a stray space's form
// for a shape inside, and `:has()`'s combinators written as `:has`s of their own, only where the
// shapes put where a container goes can hold shapes (by kind or id as the query resolves, by title
// as it's answered); a word that isn't a kind hinted as a title only when a shape has it. And a
// name no shape has, standing for an anchor whose edges point at shapes that aren't there, is
// hinted `:dangling`.

/// Chore 1 "Ledger" cites a shape that isn't in the file, chore 2 "Auth" cites chore 1, and a wire
/// 3 runs from chore 2 to chore 1.
@MainActor func goneHarness() throws -> EditorHarness {
    let shapes = [chore(id(1), caption: "Ledger", Chore(unit, tags: [uuid(99)])), chore(id(2), caption: "Auth", Chore(unit, tags: [uuid(1)])),
                  link(id(3), id(2), id(1))]
    return try EditorHarness(plugins: queryPlugins(more: [citesPlugin()]), file: CanvasFile(root: CanvasDocument(shapes: shapes)))
}

/// Chore 1 "Alpha", and links 5, 6, … from it, each to a shape that isn't there, of these grades.
@MainActor func looseHarness(_ grades: LinkGrade?...) throws -> EditorHarness {
    let links = grades.enumerated().map { link(id(5 + $0.offset), id(1), id(98 - $0.offset), grade: $0.element) }
    return try EditorHarness(plugins: queryPlugins(), file: CanvasFile(root: CanvasDocument(shapes: [chore(id(1), caption: "Alpha")] + links)))
}

/// The refusal a query's answer gives, and the queries its hint offers answered (or refused for
/// its reason).
@MainActor func answerRefusal(_ text: String, on h: EditorHarness, file: StaticString = #fileID, line: UInt = #line) throws -> QueryError {
    let error = try require(try refusedAnswer(text, on: h, file: file, line: line), "\(text) is answered", file: file, line: line)
    expectOfferedAnswered(text, error, on: h, file: file, line: line)
    return error
}

private let together = "Write them together for one shape:"

@MainActor let hintsTests = Suite("Hints", [
    test("a stray space's form for a shape inside is offered only where the shape before can hold shapes: by kind and id as it resolves") {
        let h = try shelf()
        let stray = "A space before :starred asks for shapes inside the one before it."
        expectRefused([
            Refused("chore :starred", .straySpace, stray, hint: "\(together) chore:starred.", at: 6, 8),
            Refused("tile[caption] :starred", .straySpace, stray, hint: "\(together) tile[caption]:starred.", at: 14, 8),
            Refused("pocket :starred", .straySpace, stray, hint: "\(together) pocket:starred; for a shape inside it: pocket *:starred.", at: 7, 8),
            Refused("* :starred", .straySpace, stray, hint: "\(together) *:starred; for a shape inside it: * *:starred.", at: 2, 8),
            Refused("[caption] :starred", .straySpace, stray, hint: "\(together) [caption]:starred; for a shape inside it: [caption] *:starred.",
                    at: 10, 8),
            Refused("#\(uuid(1)) :starred", .straySpace, stray, hint: "\(together) #\(uuid(1)):starred.", at: 38, 8),
            Refused("#\(uuid(2)) :starred", .straySpace, stray, hint: "\(together) #\(uuid(2)):starred; for a shape inside it: #\(uuid(2)) *:starred.",
                    at: 38, 8),
            // In :has(), a shape inside is a :has of its own.
            Refused(":has(chore :starred)", .straySpace, stray, hint: "\(together) chore:starred.", at: 11, 8),
            Refused(":has(pocket :starred)", .straySpace, stray, hint: "\(together) pocket:starred; for a shape inside it: pocket:has(:starred).",
                    at: 12, 8),
            // Nothing can be said of a kind that isn't one, nor of an id no shape has.
            Refused("chor :starred", .straySpace, stray, hint: "\(together) chor:starred.", at: 5, 8),
            // A kind with a title, by its kind.
            Refused(#"chore"Alpha" :starred"#, .straySpace, stray, hint: #"\#(together) chore"Alpha":starred."#, at: 13, 8),
            Refused(#"pocket"Pantry" :starred"#, .straySpace, stray,
                    hint: #"\#(together) pocket"Pantry":starred; for a shape inside it: pocket"Pantry" *:starred."#, at: 15, 8),
            Refused("#\(uuid(99)) :starred", .straySpace, stray, hint: "\(together) #\(uuid(99)):starred.", at: 38, 8),
        ], on: h)
        // A title waits for the answer, which reads what it names.
        expectEqual(refusal(#""Pantry" :starred"#, on: h)?.hint, #"\#(together) "Pantry":starred."#)
        expectEqual(refusal(#""Pantry" :starred"#, on: h)?.premise?.hint, #"\#(together) "Pantry":starred; for a shape inside it: "Pantry" *:starred."#)
        expectEqual(try answerRefusal(#""Pantry" :starred"#, on: h).hint,
                    #"\#(together) "Pantry":starred; for a shape inside it: "Pantry" *:starred."#, "a pocket")
        expectEqual(try answerRefusal(#""Alpha" :starred"#, on: h).hint, #"\#(together) "Alpha":starred."#, "a chore")
        expectEqual(try answerRefusal(#""Tiled" :starred"#, on: h).hint, #"\#(together) "Tiled":starred."#, "a tile, named on the main actor")
        expectEqual(try answerRefusal(#""Nope" :starred"#, on: h).hint, #"\#(together) "Nope":starred."#, "no shape's")
        expectEqual(try answerRefusal(#":has("Pantry" :starred)"#, on: h).hint,
                    #"\#(together) "Pantry":starred; for a shape inside it: "Pantry":has(:starred)."#)
        let settled = try answerRefusal(#""Alpha" :starred"#, on: h)
        expectEqual(settled.premise, nil, "settled")
        expectEqual(settled.reason, .straySpace)
        expectEqual(settled.span, QuerySpan(offset: 8, length: 8))
    },
    test(":has()'s combinators are written as :has()s of their own only where the parts before them can hold shapes") {
        let h = try shelf()
        let alone = "Inside :has(), each part stands alone, or after > for what's directly on the board."
        let holders = "The kinds that hold boards: pocket."
        expectRefused([
            Refused(":has(pocket > chore)", .unsupported, alone, hint: ":has(pocket:has(> chore))", at: 5, 14),
            Refused(":has(* chore)", .unsupported, alone, hint: ":has(*:has(chore))", at: 5, 7),
            Refused(":has(pocket pocket > *)", .unsupported, alone, hint: ":has(pocket:has(pocket:has(> *)))", at: 5, 17),
            Refused(":has(chore > *)", .unsupported, alone, hint: holders, at: 5, 9),
            Refused(":has(pocket chore > *)", .unsupported, alone, hint: holders, at: 5, 16),
            Refused(":has(#\(uuid(1)) > *)", .unsupported, alone, hint: holders, at: 5, 41),
            // A kind with a title holds shapes as its kind does.
            Refused(#":has(pocket"Pantry" > chore)"#, .unsupported, alone, hint: #":has(pocket"Pantry":has(> chore))"#, at: 5, 22),
            Refused(#":has(chore"Alpha" > *)"#, .unsupported, alone, hint: holders, at: 5, 16),
        ], on: h)
        expectEqual(refusal(#":has("Pantry" > chore)"#, on: h)?.hint, nil, "a title waits for the answer")
        expectEqual(try answerRefusal(#":has("Pantry" > chore)"#, on: h).hint, #":has("Pantry":has(> chore))"#)
        expectEqual(try answerRefusal(#":has("Alpha" > chore)"#, on: h).hint, holders)
        expectEqual(try answerRefusal(#":has("Nope" > chore)"#, on: h).hint, nil, "no shape's: the answer can't say")
    },
    test("a word that isn't a kind, like none, is hinted as a title once the answer finds a shape that has it") {
        let h = try shelf()
        let kinds = "The kinds: chore, pocket, tile, link."
        let resolved = try require(refusal("Alpha", on: h))
        expectEqual(resolved.hint, kinds, "until the titles are read")
        expectEqual(resolved.premise, HintPremise(.titled("Alpha"), hint: #""Alpha" is the shape titled so."#))
        expectEqual(try answerRefusal("Alpha", on: h).hint, #""Alpha" is the shape titled so."#)
        expectEqual(try answerRefusal(":wired-to(Pantry)", on: h).hint, #""Pantry" is the shape titled so."#)
        expectEqual(try answerRefusal("pocket > Beta", on: h).hint, #""Beta" is the shape titled so."#)
        expectEqual(try answerRefusal("Tiled", on: h).hint, "Did you mean tile (a Tile)?", "a kind near it comes first")
        expectEqual(try answerRefusal("zebra", on: h).hint, kinds, "no shape's")
        expectEqual(try answerRefusal("alpha", on: h).hint, kinds, "titles are matched as written: case counts")
        expectEqual(try answerRefusal("chor", on: h).hint, "Did you mean chore (a Task)?", "a kind near it: did you mean")
        expectEqual(try answerRefusal(#"Alpha"Beta""#, on: h).hint, kinds, "a title follows it, so it stands where a kind goes")
        let both = try answerRefusal("Alpha, zebra", on: h)
        expectEqual(both.errors.map(\.hint), [#""Alpha" is the shape titled so."#, kinds], "each settled")
        expectEqual(both.hint, #""Alpha" is the shape titled so."#)

        let unnamed = try shelf(names: false)
        expectEqual(refusal("Alpha", on: unnamed)?.premise, nil, "nothing names shapes: no title to hint")
        expectEqual(try answerRefusal("Alpha", on: unnamed).hint, kinds)
    },
    test("the language's own hints that take a title or a kind's titles for granted wait for the answer to find them so") {
        let h = try shelf()
        let holders = "The kinds that hold boards: pocket."
        let hints: KeyValuePairs<String, String?> = [
            // A kind and a title the other way round: the two together, where the kind's shapes have titles.
            #""Alpha"chore"#: #"chore"Alpha""#,
            #"tile[caption]"Tiled""#: #"tile"Tiled"[caption]"#,
            #""Alpha"link"#: nil,
            // A kind that isn't one: the hint carries the query's own word, whose refusal is the query's.
            #""Alpha"zebra"#: #"zebra"Alpha""#,
            // # or @ before a word: the title, where a shape has it.
            "#Alpha": #""Alpha" is the shape titled so."#,
            "#Nope": nil,
            "@Alpha": #""Alpha""#,
            "@Nope": nil,
            // A word people invent for being inside: :inside, where what it names holds a board.
            #":within("Pantry")"#: #"Inside it, at any depth: :inside("Pantry")."#,
            #":within("Alpha")"#: holders,
            #":within("Nope")"#: nil,
            ":in(pocket)": "Inside it, at any depth: :inside(pocket).",
            ":in(chore)": holders,
            #"chore:child-of("Pantry")"#: #"Directly on its board: "Pantry" > *; at any depth: :inside("Pantry")."#,
        ]
        for (query, hint) in hints {
            expectEqual(try answerRefusal(query, on: h).hint, hint, query)
        }
        let unnamed = try shelf(names: false)
        expectEqual(try answerRefusal("#Alpha", on: unnamed).hint, nil, "nothing names shapes")
        expectEqual(try answerRefusal(#""Alpha"chore"#, on: unnamed).hint, nil, "nothing names shapes")
    },
    test("[board=…] is hinted as a row gives board: root on top, an owner by id or title directly on it, once it holds a board") {
        let h = try shelf()
        let holders = "The kinds that hold boards: pocket."
        let hints: KeyValuePairs<String, String?> = [
            "chore[board=root]": "chore:top-level",
            "[board=root]": ":top-level",
            #""Alpha"[page=ROOT][estimate>3]"#: #""Alpha"[estimate>3]:top-level"#,
            // By id, as the query resolves: a pocket's board; a chore holds none; no shape has it.
            "chore[board=\(uuid(2))]": "#\(uuid(2).uppercased()) > chore",
            "chore[board=\(uuid(1))]": holders,
            "chore[board=\(uuid(99))]": nil,
            // By title, as it's answered: directly on it, as a row's board is.
            "chore[board=Pantry]": #""Pantry" > chore"#,
            "[board=Pantry][estimate>3]": #""Pantry" > *[estimate>3]"#,
            "chore[board=Alpha]": holders,
            "chore[board=Nope]": nil,
            "[board]": nil,
            // Only = says where a shape is: a hint made from another operator's value would ask the opposite.
            "chore[board!=root]": nil,
            "chore[board!=Pantry]": nil,
            "chore[board^=Pan]": nil,
        ]
        for (query, hint) in hints {
            expectEqual(try answerRefusal(query, on: h).hint, hint, query)
        }
        expectEqual(try matched(#""Pantry" > chore"#, on: h), [id(11)], "the chore directly on it, not the one further in")
        expectEqual(try answerRefusal("chore[board=Pantry]", on: try shelf(names: false)).hint, nil, "nothing names shapes")
    },
    test("[kind=…] keeps the head it's on: a title with the kind, where its shapes have titles; an id alone") {
        let h = try shelf()
        let hints: KeyValuePairs<String, String?> = [
            #""Alpha"[kind=chore]"#: #"chore"Alpha""#,
            #""Alpha"[type=task][estimate>3]"#: #"chore"Alpha"[estimate>3]"#,
            #"pocket"Pantry"[kind=chore]"#: #"chore"Pantry""#,
            #""Alpha"[kind=link]"#: nil,
            "#\(uuid(1))[kind=chore]": "#\(uuid(1).uppercased())",
            "chore[kind=pocket]": "pocket",
            // Only = says what a shape is: every shape but chores isn't chores.
            "[kind!=chore]": nil,
            #""Alpha"[kind!=chore]"#: nil,
            "#\(uuid(1))[kind!=chore]": nil,
            "[id!=\(uuid(1))]": nil,
        ]
        for (query, hint) in hints {
            expectEqual(try answerRefusal(query, on: h).hint, hint, query)
        }
    },
    test("a name no shape has, as the anchor of edges that point at shapes that aren't there, is hinted :dangling") {
        let h = try goneHarness()
        expectMatches([":dangling": [1], ":dangling(cite)": [1], ":dangling(wire)": []], on: h)
        let cites = "Some cite edges point at shapes that aren't there: :dangling(cite) finds what carries them."
        let any = "Some edges point at shapes that aren't there: :dangling finds what carries them."
        let nearLedger = #"Did you mean "Ledger"?"#
        let hints: KeyValuePairs<String, String> = [
            // Keeping did you mean; without a name like it; in an :is(); every type; either end.
            #":cites("Old ledger")"#: "\(nearLedger) \(cites)",
            #":cites("Zzzz")"#: cites,
            #":cites(:is("Old ledger", "Auth"))"#: "\(nearLedger) \(cites)",
            #":edge-to("Old ledger")"#: "\(nearLedger) \(any)",
            #":connected-to("Old ledger")"#: "\(nearLedger) \(any)",
            #":cites(chore"Old ledger")"#: "\(nearLedger) \(cites)",
            #":between("Auth", "Old ledger", cite)"#: "\(nearLedger) \(cites)",
            // Not where the end that isn't there would be the anchor's, nor for edges of other types, nor a name that's no anchor
            // (what an anchor is inside isn't one).
            #":cited-by("Old ledger")"#: nearLedger,
            #":edge-from("Old ledger")"#: nearLedger,
            #":edge-to("Old ledger", wire)"#: nearLedger,
            #""Old ledger""#: nearLedger,
            #":cites("Old ledger" > *)"#: nearLedger,
        ]
        for (text, hint) in hints {
            let error = try answerRefusal(text, on: h)
            expectEqual(error.reason, .unknownTitle, text)
            expectEqual(error.hint, hint, text)
        }
        expectEqual(try answerRefusal(#":wired-to("Gone")"#, on: try shelf()).hint, nil, "nothing dangles")
    },
    test("the :dangling a hint writes finds exactly the types the anchor's edges are: a type without those under it is only it") {
        func some(_ types: String, _ word: String) -> String { "Some \(types) edges point at shapes that aren't there: \(word) finds what carries them." }
        let plain = try looseHarness(nil)
        let hints: KeyValuePairs<String, String?> = [
            // :wired-to follows wires alone, not hot ones.
            #":wired-to("Gone")"#: some("wire", ":dangling(only wire)"),
            #":edge-to("Gone", wire)"#: some("wire", ":dangling(wire)"),
            #":edge-to("Gone", only wire)"#: some("wire", ":dangling(only wire)"),
            #":edge-to("Gone", only wire|hot-wire)"#: some("wire", ":dangling(wire)"),
            #":edge-to("Gone", hot-wire)"#: nil,
        ]
        for (text, hint) in hints { expectEqual(try answerRefusal(text, on: plain).hint, hint, text) }
        let hot = try looseHarness(.hot, .loose)
        expectEqual(try answerRefusal(#":edge-to("Gone", only wire)"#, on: hot).hint, nil, "a hot wire isn't only a wire")
        expectEqual(try answerRefusal(#":wired-to("Gone")"#, on: hot).hint, nil)
        expectEqual(try answerRefusal(#":edge-to("Gone", wire|tether)"#, on: hot).hint, some("wire or tether", ":dangling(wire|tether)"),
                    "a type nobody declares after those declared")
        expectMatches([":dangling(only wire)": [5], ":dangling(hot-wire)": []], on: plain)
    },
])
