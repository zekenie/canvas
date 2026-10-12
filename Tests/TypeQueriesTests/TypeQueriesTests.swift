import Canvas
import CanvasTesting
import Queries
import QueryLanguage
import TestKit
import Titles
import Types

// `:is-a(S)` and a type read as its title, in Types: over a file of memos that are types and
// instances (Fixtures.swift), the types two of them lead to each other through, a cycle.

@MainActor let typeQueriesTests = Suite("Types in canvas query", [
    test(":is-a(S) is a shape that is one S matches, however far: Ann is a Person through Employee card; a type is of its supertypes") {
        let h = try typeHarness()
        expectMatches([
            #":is-a("Person")"#: [2, 3, 4, 5],
            #":is-a("Employee card")"#: [3, 5],
            #":is-a("Ann")"#: [],
            #"memo:is-a("Person")"#: [2, 3, 4, 5],
            #":not(:is-a("Person")):not([schema])"#: [6, 9, 10],
            #":is-a("Person"):not([schema])"#: [3, 4, 5],
            #":is-a("Person", "Employee card")"#: [2, 3, 4, 5],
            #":is-a(:is-a("Person"))"#: [3, 5],
            #":is-a([schema]) > *"#: [],
        ], on: h)
    },

    test("it follows a cycle once and ends where it began: a type that is its own ancestor is its own instance, and what is an instance of it is found") {
        let h = try typeHarness()
        expectMatches([
            #":is-a("Alpha")"#: [7, 8, 9],
            #":is-a("Beta")"#: [7, 8, 9],
        ], on: h)
    },

    test(":edge-to(S, is-a) stays direct: one hop, each shape's own types") {
        let h = try typeHarness()
        expectMatches([
            #":edge-to("Person", is-a)"#: [2, 4, 5],
            #":edge-to("Employee card", is-a)"#: [3, 5],
            #":edge-from("Person", is-a)"#: [],
        ], on: h)
    },

    test("[is~=...] reads a shape's types by their titles, and a row's is reads as titles; a type renamed is read by its new title") {
        let h = try typeHarness()
        expectMatches([
            #"[is~="Person"]"#: [2, 4, 5],
            #"[is~="Employee card"]"#: [3, 5],
            #"[is~="Employee"]"#: [],
            #"[is]"#: [2, 3, 4, 5, 7, 8, 9],
            #"memo:not([is])"#: [1, 6, 10],
        ], on: h)
        expectEqual(try refusal(#"[is="Person"]"#, on: h)?.reason, .unsupportedOperator, "= compares one value; ~= finds one in a list")
        let rows = try answer(#"memo[title=Cy]"#, on: h).rows
        expectEqual(rows.first?.properties?["is"], .array([.string("Person"), .string("Employee card")]))
        h.editor.transact { $0.update(id(1)) { $0[TitleProperty.self] = "Human" } }
        expectMatches([
            #"[is~="Human"]"#: [2, 4, 5],
            #"[is~="Person"]"#: [],
            #":is-a("Human")"#: [2, 3, 4, 5],
        ], on: h)
        // A type that is gone leaves its id: the entry reads as what it is.
        h.editor.transact { $0.delete([id(1)]) }
        let after = try answer(#"memo[title=Bob]"#, on: h).rows
        expectEqual(after.first?.properties?["is"], .array([.string(uuid(1))]))
    },

    test("the word is fed by the index: a type the person adds is found at once; one that is no longer is not") {
        let h = try typeHarness()
        h.editor.transact { $0.update(id(6)) { $0[IsAProperty.self] = [TypeLink(id(2))] } }
        expectMatches([#":is-a("Person")"#: [2, 3, 4, 5, 6]], on: h)
        h.editor.transact { $0.update(id(6)) { $0[IsAProperty.self] = nil } }
        expectMatches([#":is-a("Person")"#: [2, 3, 4, 5]], on: h)
        h.editor.undo()
        expectMatches([#":is-a("Person")"#: [2, 3, 4, 5, 6]], on: h)
    },

    test("it reads only the file, as does the type format: no editor, so a stand-in's own query may use them") {
        let h = try typeHarness()
        let queries = try require(h.editor.queries)
        for text in [#":is-a("Person")"#, #"[is~="Person"]"#, #"memo:is-a("Person"):not([is~="Employee card"])"#] {
            let plan = try queries.check(text)
            expect(plan.readsOnlyTheFile, "\(text) reads only the file")
            expect(plan.editorWords.isEmpty, text)
        }
        let vocabulary = queries.vocabulary.text
        expect(vocabulary.contains(":is-a"), vocabulary)
        expect(vocabulary.contains("types read as their titles"), vocabulary)
    },

    test(".Name is refused toward the word when a shape is titled so: `unsupported`, with the word as the hint; with no such word, a plain refusal") {
        let h = try typeHarness()
        let error = try require(try refusal(".Person", on: h))
        expectEqual(error.reason, .unsupported)
        expectEqual(error.hint, #":is-a("Person")"#)
        let none = try typeHarness(typeWords: false)
        let plain = try require(try refusal(".Person", on: none))
        expectEqual(plain.reason, .unsupported)
        expect(plain.hint?.contains("is-a") == false, "\(plain.hint ?? "")")
        // With the word missing the query is refused as any unknown word.
        expectEqual(try require(try refusal(#":is-a("Person")"#, on: none)).reason, .unknownPseudoClass)
    },

    test("a shape that is named and gone from the file is related to nothing: the instance stays one of the types it still has") {
        let h = try typeHarness()
        h.editor.transact { $0.delete([id(2)]) }
        expectMatches([
            #":is-a("Person")"#: [4, 5],
            #"[is~="Employee card"]"#: [],
        ], on: h)
    },
])
