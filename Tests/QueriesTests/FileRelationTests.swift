import Canvas
import CanvasTesting
import Foundation
import QueryLanguage
import Queries
import TestKit
import Topology

// A relation answered from what a plugin keeps of the file (`registrar.queryRelation(…, reads: .file,
// transitive:, prepare:, seeds:, related:)`): `:descends-from(S)`, here, over a fact of parents
// that a test sets. Transitive, breadth first, once per query, cycle-safe, reading only the file.

/// Who each shape descends from directly, set by the test.
@MainActor final class Lines {
    var parents: [ShapeID: [ShapeID]] = [:]
    init() {}
}

extension Lines: EditorService {}

/// The lines as a query takes up the file.
struct LinesFact: QueryFileFact {
    let parents: [ShapeID: [ShapeID]]

    static func current(in editor: CanvasEditor) -> LinesFact { LinesFact(parents: editor.service(Lines.self)?.parents ?? [:]) }
}

/// `:descends-from(S)` (transitive; the word that names types, unless `namesTypes` is false) and
/// `:sprung-from(S)` (direct only), over the lines; `asked` counts every shape `related` is asked of.
func linesPlugin(namesTypes: Bool = true, asked: Tally = Tally()) -> Contributor {
    Contributor(id: "lines") { registrar in
        registrar.service { _ in Lines() }
        registrar.queryRelation("descends-from", "it descends from a shape the query matches", example: #":descends-from("Cat")"#,
                                reads: .file, transitive: true, namesTypes: namesTypes,
                                prepare: { (file: QueryFilePreparation) in file.fact(LinesFact.self) },
                                seeds: { Set($0.parents.keys) },
                                related: { shape, fact in
                                    asked.add()
                                    return fact.parents[shape] ?? []
                                })
        registrar.queryRelation("sprung-from", "it is a direct child of a shape the query matches", example: #":sprung-from("Cat")"#,
                                reads: .file, transitive: false,
                                prepare: { (file: QueryFilePreparation) in file.fact(LinesFact.self) },
                                seeds: { Set($0.parents.keys) },
                                related: { shape, fact in fact.parents[shape] ?? [] })
    }
}

/// Chores 1 "Ann", 2 "Bea", 3 "Cat", 4 "Dan", 5 "Eve", 6 "Fay", 7 "Gus", 8 "Hal" and pocket 9 "Pantry";
/// Ann descends from Bea, who descends from Cat; Dan from Bea and Cat; Eve and Fay from each other;
/// Gus from a shape that isn't there; Hal and Cat from nothing.
@MainActor private func lines(asked: Tally = Tally(), namesTypes: Bool = true) throws -> EditorHarness {
    let names = ["Ann", "Bea", "Cat", "Dan", "Eve", "Fay", "Gus", "Hal"]
    let shapes = names.enumerated().map { chore(id($0.offset + 1), caption: $0.element) } + [pocket(id(9), caption: "Pantry")]
    let h = try EditorHarness(plugins: queryPlugins(more: [linesPlugin(namesTypes: namesTypes, asked: asked)]),
                              file: CanvasFile(root: CanvasDocument(shapes: shapes)))
    try require(h.editor.service(Lines.self)).parents = [id(1): [id(2)], id(2): [id(3)], id(4): [id(2), id(3)], id(5): [id(6)], id(6): [id(5)],
                                                          id(7): [id(99)]]
    return h
}

@MainActor let fileRelationTests = Suite("A relation answered from a fact of the file", [
    test("transitive: whoever reaches a shape the query matches, however far, in file order") {
        let h = try lines()
        expectMatches([
            #":descends-from("Cat")"#: [1, 2, 4],
            #":descends-from("Bea")"#: [1, 4],
            #":descends-from("Ann")"#: [],
            #":descends-from("Hal")"#: [],
            #":descends-from(chore[caption^=C])"#: [1, 2, 4],
            #":descends-from(:is("Bea", "Cat"))"#: [1, 2, 4],
            #"chore:descends-from("Cat")[caption^=D]"#: [4],
            #":not(:descends-from("Cat"))"#: [3, 5, 6, 7, 8, 9],
            #":descends-from(:descends-from("Cat"))"#: [1, 4],
            #"pocket:descends-from("Cat")"#: [],
        ], on: h)
    },
    test("only the direct ones when it isn't transitive") {
        let h = try lines()
        expectMatches([
            #":sprung-from("Cat")"#: [2, 4],
            #":sprung-from("Bea")"#: [1, 4],
            #":sprung-from(chore[caption^=B])"#: [1, 4],
            #":sprung-from("Ann")"#: [],
        ], on: h)
    },
    test("a cycle ends where it began: a shape in one descends from itself, and nothing hangs") {
        let h = try lines()
        expectMatches([
            #":descends-from("Fay")"#: [5, 6],
            #":descends-from("Eve")"#: [5, 6],
            #":descends-from(chore[caption^=E], chore[caption^=F])"#: [5, 6],
        ], on: h)
        // A shape that is its own parent.
        try require(h.editor.service(Lines.self)).parents[id(8)] = [id(8)]
        expectMatches([#":descends-from("Hal")"#: [8], #":sprung-from("Hal")"#: [8]], on: h)
    },
    test("what a shape descends from need not be a shape in the file") {
        let h = try lines()
        expectMatches([#":descends-from("Gus")"#: [], #":descends-from(*)"#: [1, 2, 4, 5, 6]], on: h)
    },
    test("the fact is read as the query takes up the file, so a change to it is an answer to the next query") {
        let h = try lines()
        expectEqual(try matched(#":descends-from("Hal")"#, on: h), [])
        try require(h.editor.service(Lines.self)).parents[id(3)] = [id(8)]
        expectEqual(try matched(#":descends-from("Hal")"#, on: h), [id(1), id(2), id(3), id(4)])
    },
    test("it is worked out once per query, however often the query uses it") {
        let asked = Tally()
        let h = try lines(asked: asked)
        _ = try matched(#":descends-from("Cat")"#, on: h)
        expectEqual(asked.count, 6, "each shape that has a parent, once")
        let before = asked.count
        _ = try matched(#"chore:descends-from("Cat"), chore:descends-from("Bea"), :not(:descends-from("Eve")):descends-from(*)"#, on: h)
        expectEqual(asked.count - before, 6, "and not again for each use")
    },
    test("it reads only the file, and waits for edges as an edge word does") {
        let h = try lines()
        let planned = try plan(#"chore:descends-from("Cat")"#, on: h)
        expect(planned.readsOnlyTheFile)
        expectEqual(planned.editorWords, [])
        expect(planned.readsEdges)
        expectEqual(planned.description, """
            all of
              kind chore
              descends-from of the file
                titled "Cat"
            """)
        let vocabulary = try require(h.editor.queries?.vocabulary)
        let word = try require(vocabulary.words.first { $0.word == "descends-from" })
        expectEqual(word.form, ":descends-from(S)")
        expectEqual(word.takes, "shapes")
        expect(!word.readsEditor)
        expectEqual(try require(vocabulary.words.first { $0.word == "sprung-from" }).from, "lines")
    },
    test("it begins from its anchors when they're few, never a walk of every shape") {
        let h = try lines()
        let queries = try require(h.editor.queries)
        let (walks, seeded) = (queries.universeWalks, queries.seededFromAnchors)
        expectEqual(try matched("chore:descends-from(#\(uuid(3)))", on: h), [id(1), id(2), id(4)])
        expectEqual(queries.universeWalks - walks, 0, "no walk of every shape")
        expectEqual(queries.seededFromAnchors - seeded, 1, "the compound began from the relation")
    },
    test("an argument that isn't shapes is refused as a relation's is, with the word's own example") {
        let h = try lines()
        expectRefused([
            Refused(":descends-from", .badArgument, ":descends-from takes shapes.", hint: #":descends-from("Cat")"#, at: 0, 14),
            Refused(":descends-from( )", .badArgument, ":descends-from takes shapes.", hint: #":descends-from("Cat")"#, at: 0, 17),
            Refused(":descends-from(Cat)", .unknownKind, "Cat isn't a kind.", hint: "The kinds: chore, pocket, tile, link.", at: 15, 3),
        ], on: h)
        let error = try require(try refusedAnswer(#":descends-from("Nobody")"#, on: h))
        expectEqual(error.reason, .unknownTitle)
    },
    test(".Name is refused as unsupported, hinted toward the one word that names types, once a shape is titled so") {
        let h = try lines()
        // Checked alone, the hint waits on the titles.
        let waiting = try require(refusal(".Cat", on: h))
        expectEqual(waiting.reason, .unsupported)
        expectEqual(waiting.premise?.claim, .typeWord("Cat"))
        let said = try answerRefusal(".Cat", on: h)
        expectEqual(said.reason, .unsupported)
        expectEqual(said.hint, #":descends-from("Cat")"#)
        expectEqual(said.premise, nil)
        expectEqual(said.span, QuerySpan(offset: 0, length: 4))
        // The hint is answered.
        expectEqual(try matched(try require(said.hint), on: h), [id(1), id(2), id(4)])
        // Beside a kind and a test.
        let beside = try answerRefusal("chore[caption^=D].Cat", on: h)
        expectEqual(beside.hint, #":descends-from("Cat")"#)
        // No shape titled so: the plain hint.
        let none = try answerRefusal(".Nobody", on: h)
        expectEqual(none.hint, #"Name a kind, or find the word: :contains("Nobody")."#)
        // [class=…] is the same refusal.
        let attribute = try answerRefusal("[class=Cat]", on: h)
        expectEqual(attribute.reason, .unsupported)
        expectEqual(attribute.hint, #":descends-from("Cat")"#)
        let nothing = try answerRefusal("[class=Nobody]", on: h)
        expectEqual(nothing.hint, #"Name a kind, or find the word: :contains("Nobody")."#)
    },
    test("with no word that names types, .Name is a plain refusal that says neither class nor schema") {
        let h = try lines(namesTypes: false)
        for query in [".Cat", "[class=Cat]", "chore.Cat"] {
            let error = try answerRefusal(query, on: h)
            expectEqual(error.reason, .unsupported, query)
            expectEqual(error.hint, #"Name a kind, or find the word: :contains("Cat")."#, query)
            for text in [error.message, error.hint ?? ""] {
                let lowered = text.lowercased()
                expect(!lowered.contains("schema") && !(lowered.contains("class") && !query.contains("class")), "\(query): \(text)")
            }
        }
        let plain = try EditorHarness(plugins: queryPlugins(), file: Shelf().file)
        let error = try answerRefusal(".Alpha", on: plain)
        expectEqual(error.hint, #"Name a kind, or find the word: :contains("Alpha")."#)
    },
    test("at most one relation names types") {
        let twice = Contributor(id: "lines-again") { registrar in
            registrar.queryRelation("lines-of", "it is in the lines of a shape", example: #":lines-of("Cat")"#, reads: .file, transitive: true,
                                    namesTypes: true, prepare: { (_: QueryFilePreparation) in () }, seeds: { _ in [] }, related: { _, _ in [] })
        }
        do {
            _ = try EditorHarness(plugins: queryPlugins(more: [linesPlugin(), twice]), file: Shelf().file)
            expect(false, "two words that name types are installed")
        } catch {
            expect("\(error)".contains("names types") || "\(error)".contains("a relation that names types"), "\(error)")
        }
    },
])
