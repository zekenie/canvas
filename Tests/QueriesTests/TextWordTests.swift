import Canvas
import CanvasRPC
import CanvasTesting
import CoreGraphics
import Foundation
import os
import Queries
import QueryLanguage
import TestKit
import Topology

// A word that takes one quoted text (`registrar.queryPseudoClass(…, argument:, reads: .file, …)`), the members a
// word adds to the rows it matched (`members:`, `rowMembers:`), what a word names that the file no longer holds
// (`absent:`), and where a shape is on every row (`at`): `:tagged("x")` over a fact the test sets, and `:marked`,
// which takes none, fixture words only.

/// The shapes each tag marks and the ids a tag names that the file no longer holds, set by the test.
@MainActor final class Tags: EditorService {
    var shapes: [String: [ShapeID]] = [:]
    var gone: [String: [String]] = [:]
    var marked: Set<ShapeID> = []
    init() {}
}

struct TagsFact: QueryFileFact {
    let shapes: [String: [ShapeID]]
    let gone: [String: [String]]
    let marked: Set<ShapeID>

    static func current(in editor: CanvasEditor) -> TagsFact {
        let tags = editor.service(Tags.self)
        return TagsFact(shapes: tags?.shapes ?? [:], gone: tags?.gone ?? [:], marked: tags?.marked ?? [])
    }
}

/// What `:tagged("x")` took for its text.
struct TagBook: Sendable {
    let text: String
    let shapes: Set<ShapeID>
    let gone: [String]
}

/// The texts `prepare` was given, in order, from anywhere.
final class Texts: Sendable {
    private let seen = OSAllocatedUnfairLock<[String]>(initialState: [])
    func add(_ text: String) { seen.withLock { $0.append(text) } }
    var all: [String] { seen.withLock { $0 } }
}

func tagsPlugin(_ texts: Texts = Texts(), taggedMembers: [String] = ["tag", "count"], markedMembers: [String] = ["tag", "mark"]) -> Contributor {
    Contributor(id: "tags") { registrar in
        registrar.service { _ in Tags() }
        registrar.queryPseudoClass("tagged", "it carries the tag", example: #":tagged("red")"#, argument: "tag", reads: .file,
                                   prepare: { (file: QueryFilePreparation, text: String) -> TagBook in
                                       texts.add(text)
                                       let fact = file.fact(TagsFact.self)
                                       return TagBook(text: text, shapes: Set(fact.shapes[text] ?? []), gone: fact.gone[text] ?? [])
                                   },
                                   seeds: { $0.shapes },
                                   matches: { shape, book in book.shapes.contains(shape.record.id) ? .yes : .no },
                                   members: taggedMembers,
                                   rowMembers: { shape, book in
                                       book.shapes.contains(shape.record.id) ? ["tag": .string(book.text), "count": .number(Double(book.shapes.count))] : [:]
                                   },
                                   absent: { book in book.gone.map { QueryAbsent(id: $0, members: ["tag": .string(book.text)]) } })
        registrar.queryPseudoClass("marked", "someone marked it", example: ":marked", reads: .file,
                                   prepare: { (file: QueryFilePreparation) in file.fact(TagsFact.self) },
                                   matches: { shape, fact in fact.marked.contains(shape.record.id) ? .yes : .no },
                                   members: markedMembers,
                                   rowMembers: { shape, fact in
                                       fact.marked.contains(shape.record.id) ? ["tag": .string("marked"), "mark": .bool(true)] : [:]
                                   },
                                   absent: { _ in [QueryAbsent(id: "old", members: ["why": .string("marked")])] })
    }
}

@MainActor private func tagged(_ texts: Texts = Texts()) throws -> EditorHarness {
    let h = try choresHarness(plugins: queryPlugins(more: [tagsPlugin(texts)]))
    let tags = try require(h.editor.service(Tags.self))
    tags.shapes = ["red": [id(1), id(3)], "blue": [id(3), id(4)], "a \"q\"": [id(2)]]
    tags.gone = ["red": ["g1", "g2"], "blue": ["g2", "g3"]]
    tags.marked = [id(4)]
    return h
}

@MainActor private func registryError(_ plugins: [any CanvasPlugin]) -> String? {
    do {
        _ = try Registry(plugins: plugins)
        return nil
    } catch {
        return "\(error)"
    }
}

private func text(_ json: JSON?) -> String? {
    if case .string(let text)? = json { text } else { nil }
}

@MainActor let textWordTests = Suite("A word with a text, members and absent ids", [
    test("the text reaches prepare, seeds and matches, and the answer says the query as the language prints it") {
        let texts = Texts()
        let h = try tagged(texts)
        let result = try answer(#"chore:tagged( 'red' )"#, on: h)
        expectEqual(result.rows.map(\.id), [id(1), id(3)])
        expectEqual(result.query, #"chore:tagged("red")"#)
        expectEqual(texts.all, ["red"], "prepared once, with the text")
        expectEqual(try matched(#":tagged("a \"q\"")"#, on: h), [id(2)], "an escaped quote is read")
        expectEqual(try answer(#":tagged("a \"q\"")"#, on: h).query, #":tagged("a \"q\"")"#)
        expectEqual(try matched(#":tagged("nobody")"#, on: h), [])
    },
    test("two uses with different texts in one query each see their own, and the same text twice is prepared once") {
        let texts = Texts()
        let h = try tagged(texts)
        expectEqual(try matched(#":tagged("red"), :tagged("blue")"#, on: h), [id(1), id(3), id(4)])
        expectEqual(texts.all.sorted(), ["blue", "red"])
        expectEqual(try matched(#":tagged("red"):not(:tagged("blue"))"#, on: h), [id(1)])
        expectEqual(try matched(#":tagged("blue"):not(:tagged("red"))"#, on: h), [id(4)])
        expectEqual(try matched(#":not(:tagged("red")):not(:tagged("blue")):marked"#, on: h), [])
        let again = Texts()
        let g = try tagged(again)
        expectEqual(try matched(#":tagged("red"), chore:tagged("red")"#, on: g), [id(1), id(3)])
        expectEqual(again.all, ["red"], "one text, one preparation")
        expectEqual(try matched(#":tagged("red")"#, on: g), [id(1), id(3)])
        expectEqual(again.all, ["red", "red"], "each query takes up the file again")
    },
    test("the argument is exactly one string: each other form is bad_argument, where the argument is, and a word that takes none stays refused") {
        let h = try tagged()
        for (query, offset) in [(":tagged", 0), (":tagged()", 0), ("chore:tagged(red)", 13), (#"chore:tagged(chore "red")"#, 13), (#"chore:tagged("red", "blue")"#, 13),
                                (":tagged(3)", 8)] {
            let error = try require(try refusedAnswer(query, on: h), query)
            expectEqual(error.reason, .badArgument, query)
            if offset > 0 { expectEqual(error.span?.offset, offset, query) }
            expect(error.message.contains(":tagged takes one text"), error.message)
        }
        expectEqual(try require(try refusedAnswer(":tagged", on: h)).hint, #":tagged("red")"#)
        expectEqual(try require(try refusedAnswer("chore:tagged(red)", on: h)).hint, #":tagged("red")"#)
        expectEqual(try require(try refusedAnswer(#":tagged("a", "b")"#, on: h)).hint, #":is(:tagged("a"), :tagged("b"))"#)
        let none = try require(try refusedAnswer(#":marked("x")"#, on: h))
        expectEqual(none.reason, .badArgument)
        expect(none.message.contains(":marked takes no argument"), none.message)
        expectEqual(try matched(#":tagged("")"#, on: h), [], "the empty string is a text")
    },
    test("the plan holds the text, and the vocabulary says the form and the argument's name") {
        let h = try tagged()
        let vocabulary = QueryVocabulary(registry: h.editor.registry)
        let word = try require(vocabulary.words.first { $0.word == "tagged" })
        expectEqual(word.form, #":tagged("…")"#)
        expectEqual(word.takes, "tag")
        expectEqual(word.example, #":tagged("red")"#)
        expectEqual(try require(vocabulary.words.first { $0.word == "marked" }).form, ":marked")
        expect(vocabulary.text.contains(#"- :tagged("…") — it carries the tag. Example: :tagged("red")"#), vocabulary.text)
        let queries = try require(h.editor.queries)
        let plan = try queries.check(#"chore:tagged("red"), :tagged("a \"q\"")"#)
        expect(plan.description.contains(#":tagged("red")"#), plan.description)
        expect(plan.description.contains(#":tagged("a \"q\"")"#), plan.description)
        expect(!plan.readsOnlyTheFile == false, "a file word reads only the file")
        let again = try queries.check(plan.canonical)
        expectEqual(again.canonical, plan.canonical, "the canonical form is a fixed point")
    },
    test("members are added to the rows the word matched, flat, in the order of the words' names, the first keeping a member; --brief's rows keep them") {
        let h = try tagged()
        let red = try answer(#":tagged("red")"#, on: h).rows
        expectEqual(red.map(\.members), [["tag": .string("red"), "count": .number(2)], ["tag": .string("red"), "count": .number(2)]])
        let none = try answer(#":tagged("red")"#, on: h, properties: .none).rows
        expectEqual(none.map(\.members), red.map(\.members), "a word's answer, not a property")
        let both = try answer(#":tagged("blue"), :marked"#, on: h).rows
        expectEqual(both.map(\.id), [id(3), id(4)])
        expectEqual(both[0].members, ["tag": .string("blue"), "count": .number(2)])
        expectEqual(both[1].members, ["tag": .string("marked"), "mark": .bool(true), "count": .number(2)],
                    "marked is named before tagged: its tag stays, tagged adds count")
        expectEqual(try answer(#":tagged("red"), :tagged("blue")"#, on: h).rows[1].members, ["tag": .string("blue"), "count": .number(2)],
                    "shape 3 has both: the first word by name (blue) keeps tag")
        expectEqual(try answer("chore", on: h).rows.map(\.members).compactMap { $0 }, [], "a query that names no such word adds none")
        expectEqual(try answer(#":tagged("red")"#, on: h, countOnly: true).rows.count, 0, "a count has no rows")
    },
    test("members are encoded flat beside a row's own") {
        let h = try tagged()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let rows = try answer(#":tagged("blue"):marked"#, on: h, properties: .none).rows
        let row = try String(decoding: encoder.encode(try require(rows.first)), as: UTF8.self)
        expectEqual(row, #"{"at":[[0,0],[100,60]],"board":"root","count":2,"id":"\#(uuid(4))","kind":"chore","mark":true,"tag":"marked"}"#)
    },
    test("a member that is a row's own key, a blank or a repeated one, or members without a function, are registry errors; the report line says the members") {
        expectEqual(QueryRow.ownKeys.count, 11)
        for own in QueryRow.ownKeys.sorted() {
            let error = registryError(queryPlugins(more: [tagsPlugin(taggedMembers: ["fine", own])]))
            expect(error?.contains("the row member \(own), which a row has of its own") == true, "\(own): \(error ?? "accepted")")
        }
        expect(registryError(queryPlugins(more: [tagsPlugin(taggedMembers: ["a", "a"])]))?.contains("declared twice") == true)
        expect(registryError(queryPlugins(more: [tagsPlugin(taggedMembers: ["a b"])]))?.contains("isn't a word a row can carry") == true)
        expect(registryError(queryPlugins(more: [tagsPlugin(taggedMembers: [""])]))?.contains("isn't a word a row can carry") == true)
        expect(registryError(queryPlugins(more: [tagsPlugin(taggedMembers: [])]))?.contains("without saying their names") == true)
        expect(registryError(queryPlugins(more: [tagsPlugin()])) == nil, "the fixture's own words are accepted")
        let report = try Registry(plugins: queryPlugins(more: [tagsPlugin()])).report
        expect(report.contains(#"query word :tagged("…") members tag, count"#), report)
        expect(report.contains("query word :marked members tag, mark"), report)
    },
    test("absent ids are listed once, in the order of the words' names, whatever the rows, and kept when only counting") {
        let h = try tagged()
        let red = try answer(#":tagged("red")"#, on: h)
        expectEqual(red.absent, [QueryAbsent(id: "g1", members: ["tag": .string("red")]), QueryAbsent(id: "g2", members: ["tag": .string("red")])])
        let both = try answer(#":tagged("blue"), :tagged("red"), :marked"#, on: h)
        expectEqual(both.absent.map(\.id), ["old", "g2", "g3", "g1"], ":marked, then blue's (g2, g3), then red's g1: g2 once, blue's")
        expectEqual(both.absent[1].members, ["tag": .string("blue")], "the first word to say an id gives its members")
        expectEqual(try answer(#":tagged("red")"#, on: h, countOnly: true).absent.map(\.id), ["g1", "g2"], "--count keeps the list")
        expectEqual(try answer(#":tagged("nobody")"#, on: h).absent, [], "none to say")
        expectEqual(try answer("chore", on: h).absent, [], "a query that names no such word")
        expectEqual(try answer(#"chore:not(:tagged("red"))"#, on: h).absent.map(\.id), ["g1", "g2"], "the words the plan names")
    },
    test("where a shape is: its stored box on every row, whatever properties are listed, none for an arrow-like shape") {
        let h = try shelf()
        let rows = try answer("*", on: h, properties: .none).rows
        expect(rows.contains { $0.kind == "link" }, "the file has links")
        for row in rows {
            if row.kind == "link" {
                expectEqual(row.at, nil, "a link has no box")
            } else {
                expectEqual(row.at, unit, "\(row.kind)'s box")
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let alpha = try require(rows.first { $0.id == id(1) })
        expect(String(decoding: try encoder.encode(alpha), as: UTF8.self).contains(#""at":[[0,0],[100,60]]"#))
        let moved = try shelf()
        moved.editor.transact("Move") { tx in
            tx.update(id(1), as: Chore.self) { $0.props.frame = CGRect(x: 12.5, y: -3, width: 40, height: 20) }
        }
        expectEqual(try answer("#\(uuid(1))", on: moved, properties: .none).rows.first?.at, CGRect(x: 12.5, y: -3, width: 40, height: 20))
        let attributesOnly = try answer("#\(uuid(1))", on: h, properties: .all).rows.first
        expectEqual(attributesOnly?.at, unit)
        expect(attributesOnly?.properties?["frame"] == nil, "where a shape is stays unqueryable as a property")
    },
])
