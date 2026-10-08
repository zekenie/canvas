import Canvas
import CanvasTesting
import Foundation
import Queries
import TestKit
import Topology

// What each word and text format says its verdict reads: the file alone, or the editor too. A word
// that reads only the file is written with a `prepare` that is given the file as the query took it
// up (the snapshot and the registry) and no editor, which is what keeps the claim true (it can't be
// tested: the other is a compile error). What a plan says of itself follows: the words in it that
// read the editor, whether it reads only the file, and whether it reads edges.

/// What `:linked`'s preparation was given.
@MainActor final class Prepared {
    var calls = 0
    var edges = 0
    var kinds = 0
}

/// What a hush is read through, which reads only the file: lowercase.
enum Hush {}
extension Hush: ShapeProperty {
    static let key: PropertyKey = "hush"
    static var defaultValue: String? { nil }
    static var keywords: PropertyKeywords<String> { PropertyKeywords().keywords(["contentMediaType": .string(hushType)]) }
}

let hushType = "text/x-hush"

/// `:linked` (a shape a wire touches, from the file's edges, which only the file says) and hushes,
/// text that reads in lowercase, each reading only the file; `prepared` counts what they're given.
func fileReadsPlugin(_ prepared: Prepared = Prepared()) -> Contributor {
    Contributor(id: "file-reads") { registrar in
        registrar.queryPseudoClass("linked", "a plain wire touches it", example: "chore:linked", reads: .file,
                                   prepare: { (file: QueryFilePreparation) -> Set<ShapeID> in
                                       prepared.calls += 1
                                       prepared.kinds = file.registry.kinds.count
                                       var ends: Set<ShapeID> = []
                                       for edge in file.snapshot.edges(ofType: .only(WireEdge.id)) {
                                           prepared.edges += 1
                                           ends.formUnion([edge.source, edge.target])
                                       }
                                       return ends
                                   },
                                   matches: { shape, ends in ends.contains(shape.record.id) ? .yes : .no })
        registrar.declare(Hush.self)
        registrar.optIn(Chore.self, to: Hush.self)
        registrar.queryTextFormat(mediaType: hushType, describes: "read in lowercase", reads: .file,
                                  prepare: { (file: QueryFilePreparation) in file.registry.kinds.count },
                                  read: { text, _ in text.lowercased() })
    }
}

/// What a plugin keeps of the file that is a function of its records alone: abbreviations and what
/// they stand for, set by the test.
@MainActor final class Glossary {
    var words: [String: String] = [:]
    init() {}
}

extension Glossary: EditorService {}

/// The glossary as a query takes it up: a fact of the file.
struct GlossaryFact: QueryFileFact {
    let words: [String: String]

    static func current(in editor: CanvasEditor) -> GlossaryFact { GlossaryFact(words: editor.service(Glossary.self)?.words ?? [:]) }
}

/// Text read with its abbreviations spelled out, through the glossary.
enum Gloss {}
extension Gloss: ShapeProperty {
    static let key: PropertyKey = "gloss"
    static var defaultValue: String? { nil }
    static var keywords: PropertyKeywords<String> { PropertyKeywords().keywords(["contentMediaType": .string(glossType)]) }
}

let glossType = "text/x-gloss"

/// The glossary, and glosses read through it by a format that reads only the file.
let glossaryPlugin = Contributor(id: "glossary") { registrar in
    registrar.service { _ in Glossary() }
    registrar.declare(Gloss.self)
    registrar.optIn(Chore.self, to: Gloss.self)
    registrar.queryTextFormat(mediaType: glossType, describes: "abbreviations spelled out", reads: .file,
                              prepare: { (file: QueryFilePreparation) in file.fact(GlossaryFact.self) },
                              read: { text, fact in fact.words[text] ?? text })
}

@MainActor let readsTests = Suite("What a word reads", [
    test("a plan says which of its words read the editor, in the order the query uses them, and whether it reads only the file") {
        let h = try wiresHarness()
        let cases: [(query: String, words: [String])] = [
            ("chore", []),
            ("chore[caption^=\"C\"]:not(:wired-to(*))", []),
            ("chore:starred", [":starred"]),
            ("chore:audited:starred", [":audited", ":starred"]),
            ("chore:starred, chore:audited, chore:starred", [":starred", ":audited"]),
            ("chore:not(:starred)", [":starred"]),
            ("pocket:has(:audited)", [":audited"]),
            (":current-board", [":current-board"]),
            ("chore:heavy", [":heavy"]),
            ("chore[shout^=\"H\"]", ["[shout]"]),
            (#"chore:contains("x")"#, [":contains"]),
            (#"chore[shout="X"]:starred, :current-board"#, ["[shout]", ":starred", ":current-board"]),
        ]
        for (query, words) in cases {
            let planned = try plan(query, on: h)
            // `:heavy` is a plugin's word that takes `QueryPreparation` as every word did: it reads the editor as far as anyone can tell.
            expectEqual(planned.editorWords, words, query)
            expectEqual(planned.readsOnlyTheFile, words.isEmpty, query)
        }
    },
    test("a word or a format that says it reads only the file isn't one of them, and is answered as any is") {
        let prepared = Prepared()
        let h = try choresHarness(plugins: queryPlugins(more: [fileReadsPlugin(prepared)]))
        for query in ["chore:linked", #"chore[hush="x"]"#, #"chore:linked[hush^="x"]:wired-to("Alpha")"#] {
            let planned = try plan(query, on: h)
            expectEqual(planned.editorWords, [], query)
            expect(planned.readsOnlyTheFile, query)
        }
        let mixed = try plan(#"chore:linked[hush="x"][shout="y"]:audited"#, on: h)
        expectEqual(mixed.editorWords, ["[shout]", ":audited"], "only the words that read the editor, whatever else it holds")
        expect(!mixed.readsOnlyTheFile)
        expectEqual(try plan("chore:linked, :current-board", on: h).editorWords, [":current-board"])
        expect(try plan(#":contains("x")"#, on: h).editorWords == [":contains"], "while a format that reads the editor is installed, a text search reads it")
        // No format that reads the editor: a text search reads only the file.
        let quiet = try choresHarness(plugins: queryPlugins(names: true, words: false, more: [fileReadsPlugin()]))
        expectEqual(try plan(#":contains("x")"#, on: quiet).editorWords, [])
        expectEqual(try plan(#"chore[hush="x"]:contains("x")"#, on: quiet).readsOnlyTheFile, true)
        _ = prepared
    },
    test("a file word's preparation is given the file as the query takes it up, once, and its verdict is the word's") {
        let prepared = Prepared()
        let h = try wiresHarness(more: [fileReadsPlugin(prepared)])
        let before = prepared.calls
        let result = try answer("chore:linked", on: h)
        // The plain wires 11, 14 and 15 join chores 1, 2, 4, 5 and 6 (12 is a hot wire, 13 a tether).
        expectEqual(result.rows.map(\.id), [1, 2, 4, 5, 6].map(id))
        expectEqual(prepared.calls - before, 1, "prepared in the turn it took up the file")
        expectEqual(prepared.edges, 3, "the plain wires: 11, 14 and 15")
        expect(prepared.kinds > 0, "and the registry")
        // And in a batch, with a word that reads the editor beside it, which the batch still answers.
        let answers = try batched([QueryMatchRequest("chore:linked"), QueryMatchRequest("chore:starred")], on: h)
        expectEqual(found(answers[0])?.ids, [1, 2, 4, 5, 6].map(id))
        expectEqual(found(answers[1])?.ids, [])
    },
    test("a file text format reads text as any does, and a plan with one is still a plan of the file alone") {
        var quiet = chore(id(1), caption: "Alpha")
        quiet[Hush.self] = "QUIET Please"
        let h = try EditorHarness(plugins: queryPlugins(more: [fileReadsPlugin()]), file: CanvasFile(root: CanvasDocument(shapes: [quiet, chore(id(2))])))
        expectEqual(try matched(#"chore[hush="quiet please"]"#, on: h), [id(1)], "read in lowercase")
        expectEqual(try matched(#"chore[hush="QUIET Please"]"#, on: h), [])
        let row = try require(try answer("#\(uuid(1))", on: h).rows.first)
        expectEqual(row.properties?["hush"], "quiet please")
        expect(try plan(#"chore[hush="x"]"#, on: h).readsOnlyTheFile)
    },
    test("a file format reads what a plugin keeps through a fact of the file, taken as the query takes up the file, and still reads only the file") {
        var glossed = chore(id(1), caption: "Alpha")
        glossed[Gloss.self] = "PR"
        let h = try EditorHarness(plugins: queryPlugins(more: [glossaryPlugin]), file: CanvasFile(root: CanvasDocument(shapes: [glossed, chore(id(2))])))
        let glossary = try require(h.editor.service(Glossary.self))
        expectEqual(try plan(#"chore[gloss="pull request"]"#, on: h).editorWords, [])
        expectEqual(try matched(#"chore[gloss="pull request"]"#, on: h), [], "nothing spelled out yet")
        glossary.words = ["PR": "pull request"]
        expectEqual(try matched(#"chore[gloss="pull request"]"#, on: h), [id(1)], "the glossary as it is when the query takes up the file")
        expectEqual(try matched(#"chore:contains("pull request")"#, on: h), [id(1)])
        let row = try require(try answer("#\(uuid(1))", on: h).rows.first)
        expectEqual(row.properties?["gloss"], "pull request")
    },
    test("a plan reads edges when it has an edge word, a relation or :dangling, and not otherwise") {
        let h = try wiresHarness()
        let reading = ["chore:edge-to(*)", "chore:edge-from(*)", "chore:connected-to(*)", "chore:downstream-of(*)", "chore:upstream-of(*)",
                       "chore:component-of(*)", "link:starts-at(*)", "link:ends-at(*)", "chore:start-of(*)", "chore:end-of(*)", "link:between(*, *)",
                       "chore:dangling", "chore:dangling(wire)",
                       #"chore:wired-to("C1")"#, #"chore:not(:edge-to("C1"))"#, #"chore, :has(:edge-to(*))"#, #":is(chore:wired-to(*), link)"#]
        for query in reading { expect(try plan(query, on: h).readsEdges, "\(query) reads edges") }
        let not = ["chore", "*", #""C1""#, "chore:starred", "chore:inside(*)", "chore:top-level", ":current-board", "chore:heavy", #"chore[caption^="C"]"#]
        for query in not { expect(!(try plan(query, on: h).readsEdges), "\(query) doesn't") }
    },
])
