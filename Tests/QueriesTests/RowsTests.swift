import Canvas
import CanvasTesting
import Foundation
import Queries
import QueryLanguage
import TestKit
import Topology

// What an answer lists: each row's id, kind, name, board and the boards it's inside, named as the
// path names them; its attributes as they read (none that says where it is, not its name), cut
// unless named, or none; where a connection runs; and whether it's being typed into. The warnings,
// how many there are, and `--ask`'s titles and where the person is.

@MainActor let rowsTests = Suite("Rows", [
    test("a row: id, kind, name, board, what it's inside, and its attributes as they read") {
        let h = try choresHarness()
        let rows = try answer("chore, tile", on: h).rows
        expectEqual(rows.map(\.id), [1, 2, 3, 4, 5, 11].map(id))
        let first = rows[0]
        expectEqual(first.kind, Chore.kind)
        expectEqual(first.title, "Alpha")
        expectEqual(first.board, .root)
        expectEqual(first.inside, [])
        expectEqual(first.properties, [
            "status": "todo", "estimate": 3, "ratio": 0.5, "due": "2026-10-01T09:30:00Z", "tags": ["red", "blue"], "note": "Buy milk",
            "meta": ["owner": "ann", "size": 2], "flag": true, "shout": "HEY THERE",
        ], "no frame (where it is), no caption (its name), its shout read in capitals")
        expectEqual(first.cut, nil)
        expectEqual(first.connection, nil)
        expectEqual(first.editing, nil)
        // What a shape hasn't isn't listed; a number that isn't one is listed as the board writes it.
        expectEqual(rows[1].title, nil)
        expectEqual(rows[1].properties, ["status": "done", "ratio": -2.5, "tags": [], "note": "", "meta": ["owner": "", "size": 0]])
        expectEqual(rows[3].properties?["ratio"], "nan")
        expectEqual(rows[2].title, "Gamma")
        // A derived name is its title; what it's derived from is listed too.
        expectEqual(rows[4].title, "Tiled")
        expectEqual(rows[4].properties, ["label": "Tiled", "finish": "matte"])
        expectEqual(rows[5].board, BoardID(owner: id(6)))
        expectEqual(rows[5].inside, ["Pantry"])
    },
    test("long text cut at 500, whole when asked for by name, and no attributes at all") {
        let long = String(repeating: "word ", count: 120) + "end"
        let h = try EditorHarness(plugins: queryPlugins(), file: CanvasFile(root: CanvasDocument(shapes: [
            chore(id(1), caption: "Long", Chore(unit, tags: ["short", long], note: long)),
        ])))
        let cut = try require(answer("chore", on: h).rows.first)
        expectEqual(cut.properties?["note"], .string(String(long.prefix(500)) + "…"))
        expectEqual(cut.properties?["tags"], ["short", .string(String(long.prefix(500)) + "…")])
        expectEqual(cut.cut, ["note", "tags"])
        let whole = try require(answer("chore", on: h, properties: .only(["note", "frame", "caption", "zzz"])).rows.first)
        expectEqual(whole.properties, ["note": .string(long)], "only what's named, whole: never where it is, nor its name")
        expectEqual(whole.cut, nil)
        let brief = try require(answer("chore", on: h, properties: .none).rows.first)
        expectEqual(brief.properties, nil)
        expectEqual(brief.title, "Long")
    },
    test("inside: the boards' names, outermost first, as the path names them") {
        // Pocket 12 is untitled: its board is an "Untitled Pocket" (the board names point's).
        let named = try shelf()
        expectEqual(try answer("tile", on: named).rows.first?.inside, ["Pantry", "Untitled Pocket"])
        expectEqual(try answer("#\(uuid(12))", on: named).rows.first?.inside, ["Pantry"])
        named.editor.transact(on: BoardID(owner: id(2))) { $0.update(id(12)) { $0[Caption.self] = "Shelf" } }
        expectEqual(try answer("tile", on: named).rows.first?.inside, ["Pantry", "Shelf"])
        // Without the board names point, an untitled owner's board goes by its kind's label.
        let unnamedBoards = try EditorHarness(plugins: queryPlugins(names: false, more: [namesPlugin()]), file: Shelf().file)
        expectEqual(try answer("tile", on: unnamedBoards).rows.first?.inside, ["Pantry", "pocket"])
        // With nothing naming shapes, every board goes by it.
        let nameless = try EditorHarness(plugins: queryPlugins(names: false), file: Shelf().file)
        let row = try require(answer("tile", on: nameless).rows.first)
        expectEqual(row.inside, ["pocket", "pocket"])
        expectEqual(row.title, nil)
    },
    test("inside: the containers a shape is in too, between the boards, outermost first: a container's name, else its kind's label") {
        let h = try yard()
        let inside = Dictionary(try answer("*", on: h).rows.map { ($0.id, $0.inside) }, uniquingKeysWith: { first, _ in first })
        expectEqual(inside[id(1)], [])
        expectEqual(inside[id(5)], [])
        expectEqual(inside[id(6)], ["Pen"])
        expectEqual(inside[id(8)], ["Pen", "corral"], "an untitled corral by its kind's label: it holds no board to have a placeholder")
        expectEqual(inside[id(2)], ["Pen"])
        expectEqual(inside[id(15)], ["Pen", "Pantry"])
        expectEqual(inside[id(16)], ["Pen", "Pantry", "Bin"])
        expectEqual(inside[id(21)], ["Pen", "Pantry", "Bin", "Untitled Pocket"])
        expectEqual(inside[id(11)], ["Pen", "Pantry"])
        let rows = try answer(#""Delta", "Gamma""#, on: h).rows
        expectEqual(rows.map(\.board), [.root, BoardID(owner: id(2))], "the board it's on, whatever it's in there")
        // --ask's titles name them as a row does.
        let queries = try require(h.editor.queries)
        let titles = try awaitResult { try await queries.titles(for: "Delta", limit: 1) }
        expectEqual(titles.first?.title, "Delta")
        expectEqual(titles.first?.inside, ["Pen", "Pantry", "Bin"])
    },
    test("a connection says where it runs: its type, from the shape it starts on to the one it ends on") {
        let h = try shelf()
        let rows = try answer("link", on: h).rows
        expectEqual(rows.map(\.connection), [
            QueryConnection(type: WireEdge.id, from: QueryEnd(id: id(1), title: "Alpha"), to: QueryEnd(id: id(2), title: "Pantry")),
            QueryConnection(type: tether, from: QueryEnd(id: id(2), title: "Pantry"), to: QueryEnd(id: id(1), title: "Alpha")),
        ])
        expectEqual(rows[1].properties?["grade"], "loose")
        expectEqual(rows[0].properties?["from"], .string(uuid(1)))
        expectEqual(try answer("pocket", on: h).rows.map(\.connection), [nil, nil])
    },
    test("how many match, the rows listed, and the warning when some aren't") {
        let h = try shelf()
        let limited = try answer("*", on: h, limit: 3)
        expectEqual(limited.count, 8)
        expectEqual(limited.rows.map(\.id), [1, 2, 11].map(id))
        expectEqual(limited.warnings, [QueryWarning(.limited, "3 of 8 listed. --limit 30 lists more; --count only counts.")])
        let counted = try answer("*", on: h, limit: 3, countOnly: true)
        expectEqual(counted.count, 8)
        expectEqual(counted.rows, [])
        expectEqual(counted.warnings, [])
        expectEqual(try answer("*", on: h, limit: 0).rows.count, 1, "at least one row")
        expectEqual(try answer("*", on: h).warnings, [])
        let result = try answer("pocket>chore ,  tile", on: h)
        expectEqual(result.query, "pocket > chore, tile", "the query as the language writes it")
    },
    test("a shape being typed into: its row says so, and so does a warning when it's listed or read; typing goes on") {
        let h = try EditorHarness(plugins: queryPlugins(more: [CardsPlugin()]), file: CanvasFile(root: CanvasDocument(shapes: [
            chore(id(1), caption: "Alpha"),
            AnyShapeRecord(ShapeRecord(id: id(2), Card(unit, text: "Draft"))),
        ])))
        expect(h.editor.beginEditing(id(2)))
        let typing = "A Card is being typed into; its text may still change."
        let listed = try answer("card", on: h)
        expectEqual(listed.rows.first?.editing, true)
        expectEqual(listed.warnings, [QueryWarning(.editing, typing)])
        let read = try answer(#"[text*="Zz"], chore"#, on: h)
        expectEqual(read.rows.map(\.id), [id(1)])
        expectEqual(read.rows.first?.editing, nil)
        expectEqual(read.warnings, [QueryWarning(.editing, typing)], "the card's text was read")
        expectEqual(try answer("chore", on: h).warnings, [], "nothing typed was read")
        expectEqual(h.editor.editingShapeID, id(2), "a query never ends typing")
    },
    test("a name tested for with = that no shape has is warned about, with the names it may have meant") {
        let h = try shelf()
        let typo = try answer(#"[caption="Alpah"]"#, on: h)
        expectEqual(typo.count, 0)
        expectEqual(typo.warnings, [QueryWarning(.noTitleMatch, #"No shape is titled Alpah. Did you mean "Alpha"?"#)])
        expectEqual(try answer(#"[caption="ALPHA"]"#, on: h).warnings.map(\.message), [#"No shape is titled ALPHA. Did you mean "Alpha"?"#])
        expectEqual(try answer(#"[caption="alpha" i]"#, on: h).warnings, [], "any case: it's a name")
        expectEqual(try answer(#"chore[caption="Pantry"]"#, on: h).warnings, [], "a pocket's name: no chore has it, but it's a name")
        expectEqual(try answer(#"[caption!="Alpah"]"#, on: h).warnings.map(\.reason), [.noTitleMatch])
        expectEqual(try answer(#"[caption="Qwxzv"]"#, on: h).warnings.map(\.message), ["No shape is titled Qwxzv."])
        expectEqual(try answer(#"[caption^="Alpah"]"#, on: h).warnings, [], "only =")
    },
    test("--ask's titles: those sharing a word with the question, then the board shown's, then the rest, each once") {
        let h = try storyHarness()
        let queries = try require(h.editor.queries)
        let titles = try awaitResult { try await queries.titles(for: "which chores cite the Gateway?", limit: 200) }
        expectEqual(titles.map(\.title), ["API gateway", "Payments", "Auth", "Warehouse", "Order", "Ledger", "Checkout", "Refunds", "Refund policy"])
        expectEqual(titles.first, QueryTitle(title: "API gateway", id: id(2), kind: Chore.kind, board: .root, inside: []))
        expectEqual(titles.last, QueryTitle(title: "Refund policy", id: id(21), kind: Chore.kind, board: BoardID(owner: id(12)),
                                            inside: ["Payments", "Refunds"]))
        let few = try awaitResult { try await queries.titles(for: "a refund", limit: 3) }
        expectEqual(few.map(\.title), ["Refund policy", "Payments", "API gateway"], "whole words: refund isn't Refunds")
        let refunds = try awaitResult { try await queries.titles(for: "the refunds policy", limit: 2) }
        expectEqual(refunds.map(\.title), ["Refunds", "Refund policy"])
        expect(h.enter(id(1)))
        let inPayments = try awaitResult { try await queries.titles(for: "", limit: 4) }
        expectEqual(inPayments.map(\.title), ["Checkout", "Refunds", "Payments", "Refund policy"])
    },
    test("--ask's titles: a name some shapes share once a place, words in any script, and nothing after the first tier fills") {
        let root = CanvasDocument(shapes: [
            pocket(id(1), caption: "Pantry"), chore(id(2), caption: "Dup"), chore(id(3), caption: "Dup"),
            chore(id(4), caption: "Café menu"), chore(id(5), caption: "Road 660 plan"), chore(id(6), caption: "Other"),
        ])
        let pantry = CanvasDocument(shapes: [chore(id(11), caption: "Dup"), chore(id(12), caption: "Dup")])
        let h = try EditorHarness(plugins: queryPlugins(), file: CanvasFile(root: root, children: [id(1): pantry]))
        let queries = try require(h.editor.queries)
        let dup = try awaitResult { try await queries.titles(for: "the dup", limit: 10) }
        expectEqual(dup.map(\.id), [id(11), id(2), id(1), id(4), id(5), id(6)], "each Dup once a place, in file order, then the board shown's")
        expectEqual(dup.first?.inside, ["Pantry"])
        expectEqual(try awaitResult { try await queries.titles(for: "the dup", limit: 2) }.map(\.id), [id(11), id(2)])
        expectEqual(try awaitResult { try await queries.titles(for: "DUP", limit: 1) }.map(\.id), [id(11)], "the first tier full: nothing after it")
        expectEqual(try awaitResult { try await queries.titles(for: "a CAFÉ?", limit: 2) }.map(\.id), [id(4), id(1)], "a word in any script, any case")
        expectEqual(try awaitResult { try await queries.titles(for: "road 660", limit: 2) }.map(\.id), [id(5), id(1)], "digits are a word's")
        expectEqual(try awaitResult { try await queries.titles(for: "the 66 men", limit: 2) }.map(\.id), [id(1), id(2)], "words of 3 or more, whole")
    },
    test("where the person is: the path's names, and what they have selected") {
        let h = try storyHarness()
        let queries = try require(h.editor.queries)
        let atTop = try awaitResult { try await queries.whereThePersonIs(selectedLimit: 20) }
        expectEqual(atTop, QueryWhere(board: .root, path: [], selected: [QuerySelected(id: id(3), kind: Chore.kind, title: "Auth")], selectedCount: 1))
        expect(h.enter(id(12)))
        let inside = try awaitResult { try await queries.whereThePersonIs(selectedLimit: 20) }
        expectEqual(inside.board, BoardID(owner: id(12)))
        expectEqual(inside.path, ["Payments", "Refunds"])

        let picked = Picked()
        picked.ids = [id(13), id(99), id(21), id(4)]
        let picking = try EditorHarness(plugins: queryPlugins(more: [citesPlugin(), pickedPlugin(picked)]), file: h.editor.file)
        let few = try awaitResult { try await picking.editor.queries!.whereThePersonIs(selectedLimit: 2) }
        expectEqual(few.selected, [QuerySelected(id: id(13), kind: Chore.kind), QuerySelected(id: id(21), kind: Chore.kind, title: "Refund policy")],
                    "in the selection's order, what isn't there left out")
        expectEqual(few.selectedCount, 3)
        let noSelection = try EditorHarness(plugins: queryPlugins(), file: h.editor.file)
        let none = try awaitResult { try await noSelection.editor.queries!.whereThePersonIs(selectedLimit: 20) }
        expectEqual(none.selected, [])
        expectEqual(none.selectedCount, 0)
    },
    test("a second selection word is refused") {
        let picked = Picked()
        do {
            _ = try Registry(plugins: queryPlugins(more: [pickedPlugin(picked), Contributor(id: "chosen") { registrar in
                registrar.querySelection("chosen", "the person chose it", example: ":chosen") { _ in [] }
            }]))
            expect(false, "two words say what's selected")
        } catch let error as RegistryError {
            expect("\(error)".contains("the person's selection"), "\(error)")
        }
    },
    test("a row as JSON leaves out what it hasn't") {
        let h = try shelf()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let rows = try answer("#\(uuid(4)), #\(uuid(21))", on: h, properties: .none).rows
        let texts = try rows.map { String(decoding: try encoder.encode($0), as: UTF8.self) }
        expectEqual(texts, [
            #"{"board":"\#(uuid(12))","id":"\#(uuid(21))","inside":["Pantry","Untitled Pocket"],"kind":"chore"}"#,
            #"{"board":"root","connection":{"from":{"id":"\#(uuid(2))","title":"Pantry"},"to":{"id":"\#(uuid(1))","title":"Alpha"},"type":"tether"},"#
                + #""id":"\#(uuid(4))","kind":"link"}"#,
        ])
    },
])
