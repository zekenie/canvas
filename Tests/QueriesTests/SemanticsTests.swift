import Canvas
import CanvasTesting
import Foundation
import Queries
import QueryLanguage
import TestKit
import Topology

// What queries mean, answered: attributes typed by their schemas (every operator on every type, and
// what's absent, false, null or empty), text as it reads, names, the shapes a query ranges over and
// their order, a query without Topology, and every construct at once on a story of fixtures, as the
// design's table has it on shipped kinds.

/// An instant, as ISO 8601 writes it.
func instant(_ text: String) -> Date {
    // A fixture's own dates: a test that can't read them fails at once.
    try! Date(text, strategy: .iso8601)
}

/// Chores 1 to 4 on the top board, each holding its properties another way, a tile 5 "Tiled" and a
/// pocket 6 "Pantry" holding chore 11:
/// 1 "Alpha": todo, estimate 3, ratio 0.5, due 2026-10-01 09:30 UTC, tags red and blue, note "Buy
///   milk", meta ann 2, flagged, shouting "hey there";
/// 2, untitled: done, no estimate, ratio -2.5, no due date, no tags, an empty note, meta as made;
/// 3 "  Gamma " (folded, "Gamma"): doing, estimate 10, ratio 1000, due 2026-10-02 00:00 UTC, tags Red,
///   note "buy-in plan", meta Bob, flagged false;
/// 4, untitled: blocked, estimate 0, a ratio that isn't a number, due 2026-09-30 23:59:59 UTC, tags
///   green, note "milk and honey".
@MainActor func choresHarness(plugins: [any CanvasPlugin] = queryPlugins()) throws -> EditorHarness {
    try EditorHarness(plugins: plugins, file: choresFile())
}

/// The chores `choresHarness` opens.
func choresFile() -> CanvasFile {
    var first = chore(id(1), caption: "Alpha", Chore(unit, status: .todo, estimate: 3, ratio: 0.5, due: instant("2026-10-01T09:30:00Z"),
                                                     tags: ["red", "blue"], note: "Buy milk", meta: Chore.Meta(owner: "ann", size: 2)))
    first[Flagged.self] = true
    first[Shout.self] = "hey there"
    let second = chore(id(2), Chore(unit, status: .done, ratio: -2.5))
    var third = chore(id(3), caption: "  Gamma ", Chore(unit, status: .doing, estimate: 10, ratio: 1000, due: instant("2026-10-02T00:00:00Z"),
                                                        tags: ["Red"], note: "buy-in plan", meta: Chore.Meta(owner: "Bob")))
    third[Flagged.self] = false
    let fourth = chore(id(4), Chore(unit, status: .blocked, estimate: 0, ratio: .nan, due: instant("2026-09-30T23:59:59Z"), tags: ["green"],
                                    note: "milk and honey"))
    return CanvasFile(root: CanvasDocument(shapes: [first, second, third, fourth, tile(id(5), label: "Tiled"), pocket(id(6), caption: "Pantry")]),
                      children: [id(6): CanvasDocument(shapes: [chore(id(11))])])
}

// MARK: The story

// Every construct on one file, as the design's table has it on the shipped kinds (§1.17), with
// fixtures in their places: chores for notes, pockets for subboards, tiles for the shapes named by
// what they hold (a schema card), links for arrows (a hot one is under wire as a channel's type is
// under arrow), and citations for mentions: a chore's tags that are ids cite those shapes (`cite`,
// carried in the slot `tags`; `:cites(S)`, `:cited-by(S)`). What's picked is the selection
// (`:picked`), and a tile with no label is faulty (`:faulty`, asked on the main actor).

enum CiteEdge {}
extension CiteEdge: EdgeType {
    static let id: EdgeTypeID = "cite"
    static let summary: String? = "a citation in a chore's tags, from the chore to the shape it names"
}

/// Citations, and their words: `:cites(S)` and `:cited-by(S)`.
func citesPlugin() -> Contributor {
    Contributor(id: "cites") { registrar in
        registrar.edgeType(CiteEdge.self)
        registrar.edges(Chore.self) { record, _, sink in
            guard let chore = record.props as? Chore else { return }
            for tag in chore.tags {
                if let cited = UUID(uuidString: tag) { sink.emit(CiteEdge.id, from: record.id, to: ShapeID(cited), slot: "tags") }
            }
        }
        registrar.queryRelation("cites", "its tags cite a shape the query matches", example: #":cites("Checkout")"#,
                                types: [CiteEdge.id], direction: .outgoing)
        registrar.queryRelation("cited-by", "a shape the query matches cites it", example: #":cited-by("Checkout")"#,
                                types: [CiteEdge.id], direction: .incoming)
    }
}

/// What's picked is the person's selection (`:picked`).
@MainActor final class Picked {
    var ids: [ShapeID] = []
}

func pickedPlugin(_ picked: Picked) -> Contributor {
    Contributor(id: "picked") { registrar in
        registrar.querySelection("picked", "the person picked it", example: ":picked") { _ in picked.ids }
    }
}

/// A tile with no label is faulty, which only the main actor says.
func faultyPlugin(_ calls: MainCalls = MainCalls()) -> Contributor {
    Contributor(id: "faulty") { registrar in
        registrar.queryPseudoClass("faulty", "it has no label", example: ":faulty", prepare: { _ in () },
                                   matches: { shape, _ in shape.record.kind == Tile.kind ? .onMain : .no },
                                   onMain: { record, _, _, _ in
                                       calls.onMain += 1
                                       return (record.props as? Tile)?.label.isEmpty ?? false
                                   })
    }
}

/// The story's shapes, by letter, and their numbers (`id(n)`).
let storyShapes: [String: Int] = [
    "P": 1, "A": 2, "U": 3, "N1": 4, "W": 5, "S": 6, "V": 7, "R1": 8, "R2": 9, "L": 10,
    "C": 11, "F": 12, "N2": 13, "Y": 21,
]

/// The story's shapes named by letters: "C, Y, N2".
func story(_ letters: String) -> [ShapeID] {
    letters.isEmpty ? [] : letters.split(separator: ",").map { id(storyShapes[$0.trimmingCharacters(in: .whitespaces)]!) }
}

/// "Roadmap", the top board, back to front: pocket P "Payments"; chore A "API gateway", which cites
/// C; chore U "Auth"; chore N1, untitled; tile W "Warehouse"; tile S "Order"; tile V, no label; link
/// R1 from A to U, hot; link R2 from W to P; chore L "Ledger", which cites a shape that's gone. On
/// Payments' board: chore C "Checkout", which cites A; pocket F "Refunds"; chore N2, untitled. On
/// Refunds' board: chore Y "Refund policy", flagged. U is picked.
@MainActor func storyHarness(calls: MainCalls = MainCalls()) throws -> EditorHarness {
    func note(_ letter: String, _ caption: String?, _ text: String, cites: [String] = []) -> AnyShapeRecord {
        chore(id(storyShapes[letter]!), caption: caption, Chore(unit, tags: cites, note: text))
    }
    let gone = uuid(255)
    var refundPolicy = note("Y", "Refund policy", "30 days")
    refundPolicy[Flagged.self] = true
    let root = CanvasDocument(shapes: [
        pocket(id(1), caption: "Payments"),
        note("A", "API gateway", "Owns auth. See @Checkout", cites: [uuid(11)]),
        note("U", "Auth", "JWT, 15 min expiry"),
        note("N1", nil, "TODO: rate limits"),
        tile(id(5), label: "Warehouse"), tile(id(6), label: "Order"), tile(id(7), label: ""),
        link(id(8), id(2), id(3), grade: .hot), link(id(9), id(5), id(1)),
        note("L", "Ledger", "Moved to @Old ledger", cites: [gone]),
    ])
    let payments = CanvasDocument(shapes: [note("C", "Checkout", "Calls @API gateway for tokens", cites: [uuid(2)]), pocket(id(12), caption: "Refunds"),
                                           note("N2", nil, "Retry on 502")])
    let file = CanvasFile(root: root, children: [id(1): payments, id(12): CanvasDocument(shapes: [refundPolicy])])
    let picked = Picked()
    picked.ids = [id(3)]
    return try EditorHarness(plugins: queryPlugins(more: [citesPlugin(), pickedPlugin(picked), faultyPlugin(calls)]), file: file)
}

@MainActor let semanticsTests = Suite("Semantics", [
    test("text: =, ^=, $=, *=, ~=, |=, with i and without, present, absent, and !=") {
        let h = try choresHarness()
        expectMatches([
            #"chore[note="Buy milk"]"#: [1],
            #"chore[note="buy milk"]"#: [],
            #"chore[note="buy milk" i]"#: [1],
            #"chore[note^="buy"]"#: [3],
            #"chore[note^="buy" i]"#: [1, 3],
            #"chore[note$="honey"]"#: [4],
            #"chore[note$="HONEY" i]"#: [4],
            #"chore[note*="milk"]"#: [1, 4],
            #"chore[note*="MILK" i]"#: [1, 4],
            "chore[note~=milk]": [1, 4],
            "chore[note~=Milk]": [],
            "chore[note~=Milk i]": [1, 4],
            "chore[note|=buy]": [3],
            "chore[note|=BUY i]": [3],
            // CSS: nothing to find finds nothing, and a word with a space is no word.
            #"chore[note^=""]"#: [],
            #"chore[note*=""]"#: [],
            #"chore[note~="and honey"]"#: [],
            // [a]: text that says something; != is :not(=), so what hasn't the text matches.
            "chore[note]": [1, 3, 4],
            "chore:not([note])": [2, 11],
            #"chore[note!="Buy milk"]"#: [2, 3, 4, 11],
            // null is text.
            "chore[note=null]": [],
        ], on: h)
    },
    test(#"[a=""] is no value, absent or empty, on text, text through a format, choices, dates and names; [a!=""] is its :not"#) {
        let h = try choresHarness()
        expectMatches([
            #"chore[note=""]"#: [2, 11],
            #"chore[note="" i]"#: [2, 11],
            #"chore[note!=""]"#: [1, 3, 4],
            #"chore[shout=""]"#: [2, 3, 4, 11],
            #"chore[status=""]"#: [],
            #"chore[status!=""]"#: [1, 2, 3, 4, 11],
            #"chore[due=""]"#: [2, 11],
            #"chore[due!=""]"#: [1, 3, 4],
            // A name: none, named or derived (a blank one is none).
            #"[caption=""]"#: [2, 4, 11],
            #"chore[caption=""]"#: [2, 4, 11],
            #"tile[caption=""]"#: [],
            // As != always is, the kinds without it too.
            #"[caption!=""]"#: [1, 3, 5, 6],
            #"[note!=""]"#: [1, 3, 4, 5, 6],
            // Only the kinds that have it: a tile has no note.
            #"[note=""]"#: [2, 11],
        ], on: h)
        expectEqual(try answer(#"[caption=""]"#, on: h).warnings.map(\.reason), [], "no name at all is no name nobody has")
        expectEqual(try plan(#"chore[note=""]"#, on: h).description, """
            all of
              kind chore
              [note] of chore text: absent or empty
            """)
        // Elsewhere, "" is what it always was: no number, no date with a flag, no list's value.
        expectEqual(refusal(#"chore[estimate=""]"#, on: h)?.reason, .invalidValue)
        expectEqual(refusal(#"chore[due="" i]"#, on: h)?.reason, .unsupportedOperator)
        expectEqual(refusal(#"chore[tags=""]"#, on: h)?.reason, .unsupportedOperator)
        expectEqual(refusal(#"chore[flag=""]"#, on: h)?.reason, .invalidValue)
    },
    test("a kind and a title together: the kind's shapes with that title, folded, as [title=…] finds them; a title no shape has refused") {
        let h = try choresHarness()
        expectMatches([
            #"chore"Alpha""#: [1],
            #"chore"  Gamma""#: [3],
            #"chore"Gamma"[estimate>3]"#: [3],
            #"chore"Gamma"[estimate<3]"#: [],
            #"tile"Tiled""#: [5],
            #"pocket"Pantry""#: [6],
            #"pocket"Pantry" > *"#: [11],
            // A title some shape has, but none of the kind: none, an answer.
            #"pocket"Alpha""#: [],
            #":not(chore"Alpha")"#: [2, 3, 4, 5, 6, 11],
        ], on: h)
        for (joined, tested) in [(#"chore"Alpha""#, #"chore[caption="Alpha"]"#), (#"tile"Tiled""#, #"tile[caption="Tiled"]"#)] {
            expectEqual(try matched(joined, on: h), try matched(tested, on: h), joined)
        }
        let refused = try require(refusedAnswer(#"chore"Alpah""#, on: h))
        expectEqual(refused.reason, .unknownTitle)
        expectEqual(refused.message, "No shape is titled Alpah.")
        expectEqual(refused.hint, #"Did you mean "Alpha"?"#)
        expectEqual(refused.span, QuerySpan(offset: 5, length: 7), "the title")
        expectEqual(try answer(#"chore"Alpha""#, on: h).query, #"chore"Alpha""#)
    },
    test("choices: exact, any case with i, text for the other operators") {
        let h = try choresHarness()
        expectMatches([
            "chore[status=done]": [2],
            "chore[status=DONE i]": [2],
            #"chore[status="done"]"#: [2],
            "chore[status!=todo]": [2, 3, 4],
            "chore[status^=do]": [2, 3],
            "chore[status~=blocked]": [4],
            // Every chore has a status: one made without one has its default.
            "chore[status]": [1, 2, 3, 4, 11],
            "chore[status=todo]": [1, 11],
        ], on: h)
    },
    test("numbers: whole and not, quoted or not, a number that isn't one matching nothing, and absent") {
        let h = try choresHarness()
        expectMatches([
            "chore[estimate=3]": [1],
            #"chore[estimate="3"]"#: [1],
            "chore[estimate>3]": [3],
            "chore[estimate>=3]": [1, 3],
            "chore[estimate<3]": [4],
            "chore[estimate<=3]": [1, 4],
            "chore[estimate=0]": [4],
            // Ordering takes any finite number, a whole number's too.
            "chore[estimate<3.5]": [1, 4],
            "chore[estimate>2.5]": [1, 3],
            "chore[estimate>=0.5]": [1, 3],
            "chore[estimate<-0.5]": [],
            // Absent is no number: it passes only !=, and fails [estimate].
            "chore[estimate]": [1, 3, 4],
            "chore:not([estimate])": [2, 11],
            "chore[estimate!=3]": [2, 3, 4, 11],
            "chore[ratio=-2.5]": [2],
            "chore[ratio>0]": [1, 3],
            "chore[ratio<=0.5]": [1, 2, 11],
            "chore[ratio=1e3]": [3],
            // Not a number (stored as "nan"): no numeric test holds, but it's there.
            "chore[ratio<1e9]": [1, 2, 3, 11],
            "chore[ratio>-1e9]": [1, 2, 3, 11],
            "chore[ratio]": [1, 2, 3, 4, 11],
        ], on: h)
    },
    test("dates: a day is the whole UTC day, an instant is itself, and absent") {
        let h = try choresHarness()
        expectMatches([
            "chore[due=2026-10-01]": [1],
            "chore[due=2026-10-01T09:30]": [1],
            #"chore[due="2026-10-01T09:30:00Z"]"#: [1],
            "chore[due=2026-10-01T11:30+02:00]": [1],
            "chore[due=2026-10-01T09:31]": [],
            // Against a day: < before its start, <= before its end, > from its end, >= from its start.
            "chore[due<2026-10-01]": [4],
            "chore[due<=2026-10-01]": [1, 4],
            "chore[due>2026-10-01]": [3],
            "chore[due>=2026-10-01]": [1, 3],
            // Against an instant, as instants compare.
            "chore[due>2026-10-01T09:30]": [3],
            "chore[due>=2026-10-01T09:30]": [1, 3],
            "chore[due<2026-10-01T09:30]": [4],
            "chore[due<=2026-10-01T09:30]": [1, 4],
            "chore[due=2026-10-02]": [3],
            "chore[due]": [1, 3, 4],
            "chore[due!=2026-10-01]": [2, 3, 4, 11],
        ], on: h)
    },
    test("true|false: absent is false, [a] is true, and != is :not(=)") {
        let h = try choresHarness()
        expectMatches([
            "chore[flag]": [1],
            "chore[flag=true]": [1],
            "chore[flag=false]": [2, 3, 4, 11],
            "chore[flag!=true]": [2, 3, 4, 11],
            "chore[flag!=false]": [1],
            "chore:not([flag])": [2, 3, 4, 11],
            // With no kind, only the kinds that have it: chores.
            "[flag=false]": [2, 3, 4, 11],
            ":not([flag])": [2, 3, 4, 5, 6, 11],
        ], on: h)
    },
    test("lists by their items, objects by whether they say anything") {
        let h = try choresHarness()
        expectMatches([
            "chore[tags~=red]": [1],
            "chore[tags~=red i]": [1, 3],
            "chore[tags~=Red]": [3],
            "chore[tags~=purple]": [],
            "chore[tags]": [1, 3, 4],
            "chore:not([tags])": [2, 11],
            // Every chore's meta is an object with members.
            "chore[meta]": [1, 2, 3, 4, 11],
        ], on: h)
    },
    test("names: named and derived, folded for =, any case with i") {
        let calls = MainCalls()
        let h = try choresHarness(plugins: queryPlugins(names: false, more: [namesPlugin(calls), boardNamesPlugin()]))
        expectMatches([
            #"[caption="Alpha"]"#: [1],
            #"[caption="alpha"]"#: [],
            #"[caption="alpha" i]"#: [1],
            #"[caption^="Al"]"#: [1],
            #"[caption="Gamma"]"#: [3],
            #"[caption="  Gamma"]"#: [3],
            #""Gamma""#: [3],
            #"chore[caption]"#: [1, 3],
            #"chore:not([caption])"#: [2, 4, 11],
            #"[caption]"#: [1, 3, 5, 6],
            #"tile[caption=Tiled]"#: [5],
            #"[caption$="led"]"#: [5],
            #""Tiled", "Pantry""#: [5, 6],
        ], on: h)
        expect(calls.derived > 0, "a tile's name is derived, on the main actor")
        expectEqual(h.editor.queries?.derivedTitlesAsked, calls.derived)
    },
    test("text through its format, and :contains over names and every string") {
        let h = try choresHarness()
        expectMatches([
            #"chore[shout="HEY THERE"]"#: [1],
            #"chore[shout="hey there"]"#: [],
            #"chore[shout*="HEY"]"#: [1],
            #":contains("milk")"#: [1, 4],
            #":contains("ALPHA")"#: [1],
            #":contains("tiled")"#: [5],
            // In a list, in an object, and through a format.
            #":contains("ann")"#: [1],
            #":contains("red")"#: [1, 3],
            #":contains("bob")"#: [3],
            #":contains("THERE")"#: [1],
            #":contains("pantry")"#: [6],
            #":contains("zebra")"#: [],
        ], on: h)
    },
    test("the shapes a query ranges over: every board the app can show, none kept aside") {
        let h = try hiddenShelf()
        expectMatches(["*": [1], "chore": [1], ":not(chore)": []], on: h)
        let result = try answer("*", on: h)
        expectEqual(result.count, 1)
    },
    test("file order: the top board back to front, each owner followed by its board") {
        let h = try shelf()
        expectMatches([
            "*": [1, 2, 11, 12, 21, 22, 3, 4],
            "chore, tile": [1, 11, 21, 22],
            "tile, chore": [1, 11, 21, 22],
            // Found without walking every shape (an id, a name): still in file order.
            "#\(uuid(22)), #\(uuid(1)), #\(uuid(11))": [1, 11, 22],
            #""Tiled", "Beta", "Alpha""#: [1, 11, 22],
        ], on: h)
        h.editor.transact { $0.bringToFront(id(1)) }
        expectMatches(["chore": [11, 21, 1]], on: h)
    },
    test("without Topology every query is refused no_topology, whatever it is") {
        let plugins: [any CanvasPlugin] = [ChoresPlugin(), PocketsPlugin(), TilesPlugin(), LinksPlugin(), QueriesPlugin(), captionsPlugin(),
                                           namesPlugin(), boardNamesPlugin()]
        let h = try EditorHarness(plugins: plugins, file: Shelf().file)
        let queries = try require(h.editor.queries)
        for text in ["*", "chore", "#\(uuid(1))", "zebra", ":edge-to(*)"] {
            expectEqual(refusal(text, on: h)?.reason, .noTopology, text)
            expectEqual(try refusedAnswer(text, on: h)?.reason, .noTopology, text)
        }
        do {
            _ = try awaitResult { try await queries.titles(for: "Alpha", limit: 10) }
            expect(false, "titles are refused too")
        } catch let error as QueryError {
            expectEqual(error.reason, .noTopology)
        }
        do {
            _ = try awaitResult { try await queries.whereThePersonIs(selectedLimit: 10) }
            expect(false, "where the person is is refused too")
        } catch let error as QueryError {
            expectEqual(error.reason, .noTopology)
        }
        expectEqual(queries.vocabulary.kinds.count, 4, "the vocabulary is the registry's")
    },
    test("every construct, on the story") {
        let calls = MainCalls()
        let h = try storyHarness(calls: calls)
        let table: KeyValuePairs<String, String> = [
            "chore": "C, Y, N2, A, U, N1, L",
            "pocket, tile": "P, F, W, S, V",
            #""Checkout""#: "C",
            #""Order""#: "S",
            #"[caption="checkout" i]"#: "C",
            #"[caption^="API"]"#: "A",
            "chore[caption]": "C, Y, A, U, L",
            "chore:not([caption])": "N2, N1",
            "#\(uuid(11))": "C",
            "[flag]": "Y",
            "[flag=false]": "C, N2, A, U, N1, L",
            #"chore[note*="TODO"]"#: "N1",
            #"chore[note*="@API gateway"]"#: "C",
            "link[grade]": "R1",
            "link:not([grade])": "R2",
            "link[grade=hot]": "R1",
            #":contains("auth")"#: "A, U",
            #""Payments" > *"#: "C, F, N2",
            #""Payments" *"#: "C, F, Y, N2",
            #"chore:inside("Payments")"#: "C, Y, N2",
            #""Refund policy":inside("Payments")"#: "Y",
            #""Checkout":inside("Refunds")"#: "",
            #"pocket:has("Refund policy")"#: "P, F",
            #":has(> "Refund policy")"#: "F",
            #""Payments":has(> "Refund policy")"#: "",
            "chore:top-level": "A, U, N1, L",
            ":current-board": "P, A, U, N1, W, S, V, R1, R2, L",
            #"chore:cites("API gateway")"#: "C",
            #""Checkout":cited-by("API gateway")"#: "C",
            ":cited-by(*)": "C, A",
            "chore:not(:cites(*))": "Y, N2, U, N1, L",
            ":dangling": "L",
            "chore:dangling(cite)": "L",
            #":edge-to("Auth")"#: "A",
            #":edge-from("API gateway")"#: "C, U",
            #":edge-from("API gateway", wire)"#: "U",
            #":edge-from("API gateway", only wire)"#: "",
            #":edge-to("Payments", only wire)"#: "W",
            #":edge-from("API gateway", hot-wire|cite)"#: "C, U",
            #":connected-to("Checkout")"#: "A",
            #":downstream-of("Checkout")"#: "C, A, U",
            #":upstream-of("Auth")"#: "C, A",
            #":component-of("Warehouse")"#: "P",
            #"link:starts-at("Warehouse")"#: "R2",
            #"link:ends-at("Auth")"#: "R1",
            #"link:between("Auth", "API gateway")"#: "R1",
            ":picked": "U",
            ":faulty": "V",
            #""Payments" chore[flag]"#: "Y",
            ":is(pocket, tile):edge-from(*)": "P",
            "chore:edge-to(*, hot-wire)": "A",
            #"[caption="Chekout"]"#: "",
        ]
        for (text, letters) in table {
            expectEqual(try matched(text, on: h), story(letters), text)
        }
        expectEqual(try answer("*", on: h).count, 14)
        expectEqual(calls.onMain, 3, ":faulty asked the main actor about the three tiles alone")

        let connection = try require(answer("link[grade=hot]", on: h).rows.first?.connection)
        expectEqual(connection, QueryConnection(type: HotWireEdge.id, from: QueryEnd(id: id(2), title: "API gateway"),
                                                to: QueryEnd(id: id(3), title: "Auth")))
        let noMatch = try answer(#"[caption="Chekout"]"#, on: h)
        expectEqual(noMatch.warnings, [QueryWarning(.noTitleMatch, #"No shape is titled Chekout. Did you mean "Checkout"?"#)])

        let refusals: [(String, QueryError.Reason)] = [
            ("chore :picked", .straySpace),
            (#":inside("Warehouse")"#, .cannotContain),
            (#":cites("Old ledger")"#, .unknownTitle),
            ("task", .unknownKind),
        ]
        for (text, reason) in refusals {
            expectEqual(try refusedAnswer(text, on: h)?.reason, reason, text)
        }
        let spatial = try require(refusedAnswer(#":inside("Warehouse")"#, on: h))
        expectEqual(spatial.message, "Warehouse is a tile, which holds no board: nothing is inside it. "
                    + "Being drawn within its bounds isn't something a query can ask yet.")
        expectEqual(spatial.hint, "The kinds that hold boards: pocket.")
        expectEqual(spatial.span, QuerySpan(offset: 8, length: 11))
    },
])
