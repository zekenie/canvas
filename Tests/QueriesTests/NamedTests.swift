import Canvas
import CanvasTesting
import Foundation
import Queries
import QueryLanguage
import TestKit
import Topology

// A stored query's title heads, bound to the shapes they name (`bindNames(in:)`) and read by those shapes (`named(_:by:as:)`):
// every head at any depth (a compound's title and a kind with a title, in `:not`, `:is`, `:where`, `:has`, `:inside`, a space and
// `>`, the edge words' anchors and a relation's argument), never a word's text or an attribute's value, none for a title that
// names none or several, titles matched folded, and the two forms: by id while the shape is in the file, by its title now.
// Over the shelf: chore 1 "Alpha", pocket 2 "Pantry", chore 11 "Beta" on the pantry's board, tile 22 "Tiled" (named by its label,
// derived).

@MainActor private func shelved() throws -> EditorHarness {
    try shelf(more: [Contributor(id: "named-words") { registrar in
        registrar.queryPseudoClass("labelled", "it carries the label", example: #":labelled("red")"#, argument: "label",
                                   prepare: { _, _ in () }, matches: { _, _ in .no })
        registrar.queryRelation("tied-to", "it is tied to a shape S matches", example: #":tied-to("Alpha")"#, reads: .file, transitive: false,
                                prepare: { _ in () }, seeds: { _ in [] }, related: { _, _ in [] })
    }])
}

@MainActor private func bound(_ text: String, on h: EditorHarness) throws -> [String: ShapeID] {
    try require(h.editor.queries).bindNames(in: text)
}

@MainActor private func read(_ text: String, _ names: [String: ShapeID], _ form: QueryNameForm, on h: EditorHarness) throws -> String {
    try require(h.editor.queries).named(text, by: names, as: form)
}

private func hash(_ n: Int) -> String { "#" + uuid(n).uppercased() }

@MainActor private func rename(_ n: Int, to caption: String, on h: EditorHarness) {
    h.editor.transact("Rename") { $0.update(id(n)) { $0[Caption.self] = caption } }
}

@MainActor let namedTests = Suite("A query's title heads are bound to shapes, and read by them", [
    test("a title head is bound at every depth a query holds one") {
        let h = try shelved()
        expectEqual(try bound(#""Alpha""#, on: h), ["Alpha": id(1)], "a head alone")
        expectEqual(try bound(#"chore"Alpha""#, on: h), [#"chore"Alpha""#: id(1)], "a kind and a title, keyed as the head is written")
        expectEqual(try bound(#":not("Alpha")"#, on: h), ["Alpha": id(1)], ":not")
        expectEqual(try bound(#"chore:is("Alpha", "Beta")"#, on: h), ["Alpha": id(1), "Beta": id(11)], ":is, a list")
        expectEqual(try bound(#"chore:where("Beta")"#, on: h), ["Beta": id(11)], ":where")
        expectEqual(try bound(#"chore:inside("Pantry")"#, on: h), ["Pantry": id(2)], ":inside")
        expectEqual(try bound(#"pocket:has("Beta")"#, on: h), ["Beta": id(11)], ":has")
        expectEqual(try bound(#"pocket:has(> "Beta")"#, on: h), ["Beta": id(11)], ":has, directly")
        expectEqual(try bound(#""Pantry" "Beta""#, on: h), ["Pantry": id(2), "Beta": id(11)], "a space: the container's side too")
        expectEqual(try bound(#""Pantry" > "Beta""#, on: h), ["Pantry": id(2), "Beta": id(11)], ">")
        expectEqual(try bound(#"*:connected-to("Alpha")"#, on: h), ["Alpha": id(1)], "an edge word's anchor")
        expectEqual(try bound(#"*:between("Alpha", "Pantry", wire)"#, on: h), ["Alpha": id(1), "Pantry": id(2)], "both anchors, not the edge type")
        expectEqual(try bound(#"chore:wired-to("Pantry")"#, on: h), ["Pantry": id(2)], "an edge relation's argument, read as selectors")
        expectEqual(try bound(#"chore:tied-to("Alpha", "Beta")"#, on: h), ["Alpha": id(1), "Beta": id(11)], "a file relation's argument")
        expectEqual(try bound(#"chore:not(:is("Alpha")):wired-to(pocket:has("Beta"))"#, on: h), ["Alpha": id(1), "Beta": id(11)], "nested in a relation's argument, and in :not")
        expectEqual(try bound(#"chore:wired-to(:not("Alpha"))"#, on: h), ["Alpha": id(1)], "a word inside a relation's argument")
        expectEqual(try bound(#""Tiled""#, on: h), ["Tiled": id(22)], "a title the names point derives")
        expectEqual(try bound(#"tile"Tiled""#, on: h), [#"tile"Tiled""#: id(22)], "a kind with a derived title")
    },

    test("a word's text and an attribute's value are never a title head") {
        let h = try shelved()
        expectEqual(try bound(#":labelled("Alpha")"#, on: h), [:], "a text argument")
        expectEqual(try bound(#"chore:contains("Alpha")"#, on: h), [:], ":contains")
        expectEqual(try bound(#"chore[caption="Alpha"]"#, on: h), [:], "an attribute's value")
        expectEqual(try bound(#"chore:labelled("Alpha"):not("Beta")"#, on: h), ["Beta": id(11)], "beside a head that is one")
        let names = [#"Alpha"#: id(1)]
        expectEqual(try read(#":labelled("Alpha")"#, names, .ids, on: h), #":labelled("Alpha")"#, "a text argument is written as it was")
        expectEqual(try read(#"chore[caption="Alpha"]"#, names, .ids, on: h), #"chore[caption="Alpha"]"#)
    },

    test("a title that names none or several is left out; titles match as the engine folds them") {
        let h = try shelved()
        expectEqual(try bound(#""Nobody""#, on: h), [:], "none")
        expectEqual(try bound(#":is("Alpha", "Nobody")"#, on: h), ["Alpha": id(1)], "the one that names one")
        expectEqual(try bound(#"tile"Alpha""#, on: h), [:], "a kind with a title no shape of that kind has")
        expectEqual(try bound(#""Beta ""#, on: h), ["Beta ": id(11)], "a title with a trailing space matches folded")
        rename(1, to: "Beta", on: h)
        expectEqual(try bound(#""Beta""#, on: h), [:], "two shapes so titled")
        expectEqual(try bound(#"chore"Beta""#, on: h), [:], "two of that kind so titled")
        expectEqual(try bound(#":is("Beta", "Pantry")"#, on: h), ["Pantry": id(2)], "the unambiguous one stays")
        h.editor.transact("Rename") { $0.update(id(2)) { $0[Caption.self] = "Beta" } }
        expectEqual(try bound(#"pocket"Beta""#, on: h), ["pocket\"Beta\"": id(2)], "a kind makes it one")
    },

    test("no text, no names; a text that doesn't read binds nothing and comes back as it was") {
        let h = try shelved()
        expectEqual(try bound("chore", on: h), [:], "no title head: nothing read")
        expectEqual(try bound(":::", on: h), [:])
        expectEqual(try read(":::", ["Alpha": id(1)], .ids, on: h), ":::")
        expectEqual(try read(":::", ["Alpha": id(1)], .titles, on: h), ":::")
    },

    test("by id: each bound head is the shape's id, canonical, while the shape is in the file") {
        let h = try shelved()
        let query = #"chore:wired-to( "Pantry" ) , chore"Alpha":not("Beta")"#
        let names = try bound(query, on: h)
        expectEqual(try read(query, names, .ids, on: h),
                    "chore:wired-to(\(hash(2))), \(hash(1)):not(\(hash(11)))", "every head by id; a kind with a title as the id alone, printed canonically")
        expectEqual(try read(#":is("Alpha")"#, [:], .ids, on: h), #":is("Alpha")"#, "no binding: canonical, as it was")
        expectEqual(try read(#":is( "Alpha" ,"Beta" )"#, [:], .ids, on: h), #":is("Alpha", "Beta")"#, "the canonical form")
        expectEqual(try read(#"chore:wired-to("Alpha"), tile"Tiled""#, ["Alpha": id(1)], .ids, on: h), "chore:wired-to(\(hash(1))), tile\"Tiled\"", "a head the binding lacks stays")
        // The id form reads: it checks as a stored query and finds what the title found.
        let plan = try require(try? h.editor.queries?.checkStored(try read(query, names, .ids, on: h)))
        expect(!plan.canonical.isEmpty)
    },

    test("a bound shape that is gone is written as the query had it, in both forms") {
        let h = try shelved()
        let query = #"chore:wired-to("Pantry"):not("Alpha")"#
        let names = try bound(query, on: h)
        h.editor.transact("Delete") { $0.delete([id(1)]) }
        expectEqual(try read(query, names, .ids, on: h), "chore:wired-to(\(hash(2))):not(\"Alpha\")", "Pantry by id, Alpha as written")
        expectEqual(try read(query, names, .titles, on: h), #"chore:wired-to("Pantry"):not("Alpha")"#, "the title now, else as written")
        h.editor.undo()
        expectEqual(try read(query, names, .ids, on: h), "chore:wired-to(\(hash(2))):not(\(hash(1)))", "undone: by id again")
    },

    test("by title now: a renamed shape's new title, a shape with none as written") {
        let h = try shelved()
        let query = #"chore:wired-to("Pantry"):not(chore"Alpha")"#
        let names = try bound(query, on: h)
        expectEqual(try read(query, names, .titles, on: h), #"chore:wired-to("Pantry"):not(chore"Alpha")"#, "as it is named: as written")
        rename(2, to: "Larder", on: h)
        rename(1, to: "Omega", on: h)
        expectEqual(try read(query, names, .titles, on: h), #"chore:wired-to("Larder"):not(chore"Omega")"#, "both heads by the title now, the kind kept")
        expectEqual(try read(query, names, .ids, on: h), "chore:wired-to(\(hash(2))):not(\(hash(1)))", "the id form doesn't change with a rename")
        h.editor.transact("Untitle") { $0.update(id(1)) { $0[Caption.self] = nil } }
        expectEqual(try read(query, names, .titles, on: h), #"chore:wired-to("Larder"):not(chore"Alpha")"#, "a shape with no title: as written")
        h.editor.undo()
        h.editor.undo()
        h.editor.undo()
        expectEqual(try read(query, names, .titles, on: h), query, "undone")
    },

    test("a title with escapes binds and prints as the language does") {
        let h = try shelved()
        rename(1, to: #"Say "hi" \ now"#, on: h)
        let query = #":not("Say \"hi\" \\ now")"#
        let names = try bound(query, on: h)
        expectEqual(names, [#"Say "hi" \ now"#: id(1)], "keyed by the title, escapes undone")
        expectEqual(try read(query, names, .ids, on: h), ":not(\(hash(1)))")
        rename(1, to: #"A "quote""#, on: h)
        expectEqual(try read(query, names, .titles, on: h), #":not("A \"quote\"")"#, "escaped again")
    },

    test("a shape the engine can't see isn't bound by id") {
        let h = try hiddenShelf()
        expectEqual(try require(h.editor.queries).named(#":not("Alpha")"#, by: ["Alpha": id(11)], as: .ids), #":not("Alpha")"#, "a shape on a board the app can't show")
        expectEqual(try require(h.editor.queries).named(#":not("Alpha")"#, by: ["Alpha": id(10)], as: .ids), #":not("Alpha")"#, "a shape kept aside")
    },
])
