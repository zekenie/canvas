import Canvas
import CanvasTesting
import Foundation
import Queries
import QueryLanguage
import TestKit

// A title where an edge word takes edge types may name a type: `:edge-to("Bo", "Friendship")`. The parser refuses it as
// `bad_argument` (a comma after the shape starts edge types) and leaves a premise; the app, once it has read the titles,
// hints the query that asks for it through the word that finds a type's shapes. The word here is `:descends-from`
// (`linesPlugin`), which names types; a shape titled "Placed by" stands for a relationship type's.

/// Chore 1 "Placed by", chore 2 "Order 12", chore 3 "Bo", and a chore titled "wire", which is an edge type's name too.
@MainActor private func harness(namesTypes: Bool = true) throws -> EditorHarness {
    let shapes = [chore(id(1), caption: "Placed by"), chore(id(2), caption: "Order 12"), chore(id(3), caption: "Bo"), chore(id(4), caption: "wire")]
    return try EditorHarness(plugins: queryPlugins(more: [linesPlugin(namesTypes: namesTypes)]), file: CanvasFile(root: CanvasDocument(shapes: shapes)))
}

/// What the app says of `text`, answered, and the query its hint writes (the text after "write ", where it says so).
@MainActor private func hinted(_ text: String, on h: EditorHarness) throws -> (error: QueryError, query: String?) {
    let error = try require(try refusedAnswer(text, on: h), "\(text) is refused")
    let query = error.hint.flatMap { hint in hint.range(of: "write ").map { String(hint[$0.upperBound...]) } }
    return (error, query)
}

@MainActor let typeArgumentHintTests = Suite("A type's title where edge types go", [
    test("checked alone the refusal waits on the titles; answered, each edge word's hint is the query that asks for the arrows of the type") {
        let h = try harness()
        let waiting = try require(refusal(#":edge-to("Bo", "Placed by")"#, on: h))
        expectEqual(waiting.reason, .badArgument)
        expectEqual(waiting.premise?.claim, .titledArgument(word: "edge-to", anchors: [#""Bo""#], title: "Placed by"))
        let cases: KeyValuePairs<String, String> = [
            #":edge-to("Bo", "Placed by")"#: #":start-of(:descends-from("Placed by"):ends-at("Bo"))"#,
            #":edge-from("Order 12", "Placed by")"#: #":end-of(:descends-from("Placed by"):starts-at("Order 12"))"#,
            #":connected-to("Bo", "Placed by")"#: #":end-of(:descends-from("Placed by"):starts-at("Bo")), :start-of(:descends-from("Placed by"):ends-at("Bo"))"#,
            #":starts-at("Bo", "Placed by")"#: #":descends-from("Placed by"):starts-at("Bo")"#,
            #":ends-at("Bo", "Placed by")"#: #":descends-from("Placed by"):ends-at("Bo")"#,
            #":between("Order 12", "Bo", "Placed by")"#: #":descends-from("Placed by"):between("Order 12", "Bo")"#,
        ]
        for (text, query) in cases {
            let said = try hinted(text, on: h)
            expectEqual(said.error.reason, .badArgument, text)
            expectEqual(said.error.hint, "Placed by is a type, not an edge type: write \(query)", text)
            expectEqual(said.error.premise, nil, text)
            // The query it writes answers.
            _ = try answer(query, on: h)
        }
    },
    test("a word given as a bare word is the same, a second shape in the anchor is kept as written, and the words that follow arrows far get a sentence") {
        let h = try harness()
        let bare = try hinted(#":edge-to("Bo", Wire)"#, on: h)
        expectEqual(bare.error.reason, .unknownEdgeType, "no shape is titled Mention: the plain refusal")
        expectEqual(bare.error.premise?.claim, nil)
        let plain = try hinted(#":edge-to("Bo", Nobody)"#, on: h)
        expectEqual(plain.error.reason, .unknownEdgeType)
        let anchored = try hinted(#":edge-from(chore"Order 12", "Placed by")"#, on: h)
        expectEqual(anchored.query, #":end-of(:descends-from("Placed by"):starts-at(chore"Order 12"))"#)
        let far = try hinted(#":downstream-of("Bo", "Placed by")"#, on: h)
        expectEqual(far.error.hint, #"Placed by is a type, not an edge type, and a relationship is one hop: :descends-from("Placed by") finds the arrows of the type, and :end-of and :start-of the notes at their ends."#)
    },
    test("no hint of this kind where no shape is titled so, where the title is an edge type's too, or where nothing names types") {
        let h = try harness()
        let none = try hinted(#":edge-to("Bo", "Nobody")"#, on: h)
        expectEqual(none.error.hint, #":edge-to(:is("Bo", "Nobody"))"#, "the parser's own hint")
        let edgeType = try hinted(#":edge-to("Bo", "wire")"#, on: h)
        expectEqual(edgeType.error.hint, #":edge-to(:is("Bo", "wire"))"#, "a title that is an edge type's name is not a type")
        let without = try harness(namesTypes: false)
        let silent = try hinted(#":edge-to("Bo", "Placed by")"#, on: without)
        expectEqual(silent.error.hint, #":edge-to(:is("Bo", "Placed by"))"#, "with no word that finds a type's shapes")
        expectEqual(silent.error.premise, nil)
    },
    test("a bare word that is a shape's title, after an anchor, is hinted the same way") {
        let h = try harness()
        let ok = try hinted(#":edge-to("Bo", Bo)"#, on: h)
        expectEqual(ok.error.reason, .unknownEdgeType)
        expectEqual(ok.error.hint, #"Bo is a type, not an edge type: write :start-of(:descends-from("Bo"):ends-at("Bo"))"#)
        let checked = try require(refusal(#":edge-to("Bo", Bo)"#, on: h))
        expectEqual(checked.premise?.claim, .titledArgument(word: "edge-to", anchors: [#""Bo""#], title: "Bo"), "checked alone it waits")
    },
    test("where the word says which shapes are the types, only a title of one is called a type") {
        let shapes = [chore(id(1), caption: "Placed by"), chore(id(2), caption: "Order 12"), chore(id(3), caption: "Bo")]
        let h = try EditorHarness(plugins: queryPlugins(more: [linesPlugin(typesAreParents: true)]), file: CanvasFile(root: CanvasDocument(shapes: shapes)))
        h.editor.service(Lines.self)?.parents = [id(3): [id(1)]]
        let type = try hinted(#":edge-to("Bo", "Placed by")"#, on: h)
        expectEqual(type.query, #":start-of(:descends-from("Placed by"):ends-at("Bo"))"#, "a shape that is a parent is a type")
        let plain = try hinted(#":edge-to("Bo", "Order 12")"#, on: h)
        expectEqual(plain.error.hint, #":edge-to(:is("Bo", "Order 12"))"#, "a shape that is no type keeps the parser's hint")
        expectEqual(plain.error.premise, nil)
        let bare = try hinted(#":edge-to("Bo", Bo)"#, on: h)
        expect(bare.error.hint?.contains("is a type") != true, "\(String(describing: bare.error.hint))")
    },
])
