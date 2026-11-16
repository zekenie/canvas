import Canvas
import CanvasRPC
import CanvasTesting
import CoreGraphics
import Foundation
import Queries
import QueryLanguage
import TestKit
import Topology

// What a query says a shape is, written onto a record (`QueryState.fit`): a property set by `[a=v]`, typed by its schema
// (text, numbers, true|false, choices, dates), a member inside an object (`[facts.a.b=v]`), the first alternative of `:is`
// and of a list that can be written, a kind head that is the record's kind or, when the kind is open, turns it, a title
// or an id never, a word's own writer (`makes:`), and every part of a query that nothing can be sure of skipped. Fixtures
// only: chores (a property of every sort a schema has, `facts`, a caption, `flag`) and tiles (a kind a tool places).

/// What the fixture words write: `:urgent` sets the flag, `:labelled("x")` the caption, and `:tied-to(S)` the caption as the
/// alternatives of S read (their text, title, kind and id, one after another), so the test sees what the word was handed.
private func fitWordsPlugin() -> Contributor {
    Contributor(id: "fit-words") { registrar in
        registrar.optIn(Tile.self, to: Flagged.self)
        registrar.queryPseudoClass("urgent", "it is urgent", example: ":urgent",
                                   prepare: { _ in () },
                                   matches: { _, _ in .no },
                                   makes: { record, _ in
                                       var made = record
                                       made[Flagged.self] = true
                                       return made
                                   })
        registrar.queryPseudoClass("labelled", "it carries the label", example: #":labelled("red")"#, argument: "label",
                                   prepare: { _, _ in () },
                                   matches: { _, _ in .no },
                                   makes: { text, record, _ in
                                       var made = record
                                       made[Caption.self] = text
                                       return made
                                   })
        registrar.queryPseudoClass("silent", "it is quiet", example: ":silent", prepare: { _ in () }, matches: { _, _ in .no })
        registrar.queryRelation("tied-to", "it is tied to a shape S matches", example: #":tied-to("Alpha")"#, reads: .file, transitive: false,
                                prepare: { _ in () }, seeds: { _ in [] }, related: { _, _ in [] },
                                makes: { anchors, record, _ in
                                    var made = record
                                    made[Caption.self] = anchors.map { anchor in
                                        [anchor.text, anchor.title ?? "-", anchor.kind?.rawValue ?? "-", anchor.id.map { String($0.rawValue.uuidString.suffix(2)) } ?? "-"]
                                            .joined(separator: "|")
                                    }.joined(separator: ";")
                                    return made
                                })
    }
}

@MainActor private func fitting() throws -> EditorHarness {
    try EditorHarness(plugins: queryPlugins(more: [factsPlugin, fitWordsPlugin()]), file: CanvasFile())
}

/// A chore made to be written on: the defaults of its kind.
private func fresh(_ n: Int = 50) -> AnyShapeRecord { chore(id(n)) }

@MainActor private func fit(_ record: AnyShapeRecord, _ text: String, open: Bool = false, on h: EditorHarness) throws -> AnyShapeRecord? {
    try require(h.editor.queries).fit(record, toMatch: text, kindIsOpen: open)
}

/// The chore a query's writes make of a fresh one; fails the test when it writes nothing.
@MainActor private func written(_ text: String, on h: EditorHarness, from record: AnyShapeRecord = fresh(), file: StaticString = #fileID, line: UInt = #line) throws -> Chore {
    let made = try require(try fit(record, text, on: h), "\(text) writes something", file: file, line: line)
    expectEqual(made.id, record.id, "\(text) leaves the shape what it was", file: file, line: line)
    return try require(made.props as? Chore, file: file, line: line)
}

@MainActor private func writesNothing(_ queries: [String], from record: AnyShapeRecord = fresh(), open: Bool = false, on h: EditorHarness,
                                      file: StaticString = #fileID, line: UInt = #line) throws {
    for text in queries {
        expect(try fit(record, text, open: open, on: h) == nil, "\(text) writes nothing", file: file, line: line)
    }
}

@MainActor let fitTests = Suite("A query says what a shape is, and it is written", [
    test("a property is set by [a=v], read by its schema: text, numbers, true|false, choices and dates") {
        let h = try fitting()
        expectEqual(try written(#"chore[note="Buy milk"]"#, on: h).note, "Buy milk")
        expectEqual(try written("[note=milk]", on: h).note, "milk", "no kind said: any kind")
        expectEqual(try written("chore[estimate=3]", on: h).estimate, 3)
        expectEqual(try written(#"chore[estimate="3"]"#, on: h).estimate, 3, "a quoted number is a number, as a query reads it")
        expectEqual(try written("chore[ratio=-2.5]", on: h).ratio, -2.5)
        expectEqual(try written("chore[status=done]", on: h).status, .done)
        expectEqual(try written("chore[status=DONE i]", on: h).status, .done, "the choice, written as the property spells it")
        expectEqual(try written("chore[due=2026-10-01]", on: h).due, instant("2026-10-01T00:00:00Z"), "a day is the start of it, in UTC")
        expectEqual(try written("chore[due=2026-10-01T09:30:00Z]", on: h).due, instant("2026-10-01T09:30:00Z"))
        expectEqual(try written("chore[due=2026-10-01T09:30]", on: h).due, instant("2026-10-01T09:30:00Z"), "the minute form, and no zone is UTC")
        expectEqual(try written("chore[due=2026-10-01T11:30:00+02:00]", on: h).due, instant("2026-10-01T09:30:00Z"), "an offset")
        let flagged = try require(try fit(fresh(), "chore[flag]", on: h))
        expectEqual(flagged[Flagged.self], true, "[a] on a true|false is true")
        expectEqual(try require(try fit(fresh(), "chore[flag=false]", on: h))[Flagged.self], false)
        let named = try require(try fit(fresh(), #"chore[caption="Alpha"]"#, on: h))
        expectEqual(named[Caption.self], "Alpha", "the name a kind has by a property of its own")
        let several = try written(#"chore[status=doing][estimate=2][note="x"]"#, on: h)
        expectEqual([several.status == .doing, several.estimate == 2, several.note == "x"], [true, true, true], "every test of a compound is written")
    },
    test("a value the schema refuses, or that is no value of the property, is not written") {
        let h = try fitting()
        try writesNothing(["chore[status=later]", "chore[status=DONE]", "chore[estimate=2.5]", "chore[estimate=-1]", "chore[estimate=many]",
                           "chore[ratio=nan]", "chore[ratio=null]", "chore[due=soon]", "chore[flag=maybe]", "chore[meta.size=x]", "chore[frame=1]"], on: h)
        // What is refused is skipped, the rest of the compound still written.
        let rest = try written("chore[status=later][note=ok]", on: h)
        expectEqual(rest.status, .todo)
        expectEqual(rest.note, "ok")
    },
    test("what says nothing that can be written is skipped: lists, objects, an empty value, and text a format reads") {
        let h = try fitting()
        try writesNothing([#"chore[note=""]"#, "chore[tags~=red]", "chore[tags=red]", "chore[tags]", "chore[meta]", "chore[estimate]", "chore[note]",
                           "chore[shout=HEY]", "chore[shout]", "chore[nothing=1]"], on: h)
    },
    test("a path into an object or any JSON sets that member, making the objects on the way, and keeps the rest") {
        let h = try fitting()
        var made = try require(try fit(fresh(), #"chore[facts.owner.name="Ann"]"#, on: h))
        expectEqual(made[Facts.self]?.json, ["owner": ["name": "Ann"]], "the objects on the way are made")
        made = try require(try fit(made, #"chore[facts.owner.age=30][facts.admin=true][facts.label="5"][facts.ok=yes]"#, on: h))
        expectEqual(made[Facts.self]?.json, ["owner": ["name": "Ann", "age": 30], "admin": true, "label": "5", "ok": "yes"],
                    "a bare number, true or false is read as one, a quoted value is text, and the members already there stay")
        expectEqual(try require(try fit(made, "chore[facts.owner.name=Bob]", on: h))[Facts.self]?.json["owner"],
                    ["name": "Bob", "age": 30], "an existing member is set")
        expectEqual(try written("chore[meta.owner=ann]", on: h).meta.owner, "ann", "a member of an object the kind declares")
        // In the way: something that is no object.
        var blocked = fresh()
        blocked[Facts.self] = Bag(["owner": "Ann", "list": [1, 2]])
        try writesNothing(["chore[facts.owner.name=Bob]", "chore[facts.list.a=1]"], from: blocked, on: h)
        // No value, an operator that is not =, an attribute with no members.
        try writesNothing(["chore[facts.a]", #"chore[facts.a=""]"#, "chore[facts.a!=1]", "chore[facts.a^=1]", "chore[facts.a>1]", "chore[note.a=1]"], on: h)
    },
    test("an attribute's owner types its members: its writer is given the path, the value as written, the record and the editor") {
        let owned = Contributor(id: "facts-owner") { registrar in
            registrar.queryPathCheck(attribute: "facts", { _, _ in nil }, makes: { members, literal, record, _ in
                guard members == ["size"] else { return nil }
                return .string("\(literal.text)|\(literal.isQuoted)|\(literal.ignoresCase)|\(record.id == id(50))")
            })
        }
        let h = try EditorHarness(plugins: queryPlugins(more: [factsPlugin, fitWordsPlugin(), owned]), file: CanvasFile())
        expectEqual(try require(try fit(fresh(), #"chore[facts.size="Big" i]"#, on: h))[Facts.self]?.json, ["size": "Big|true|true|true"])
        expectEqual(try require(try fit(fresh(), "chore[facts.size=3]", on: h))[Facts.self]?.json, ["size": "3|false|false|true"], "never read as a number: the owner types it")
        // A member the owner writes nothing for is not written, as is a path with no writer given.
        try writesNothing(["chore[facts.owner.name=Ann]", "chore[facts.other=1]"], on: h)
        let bare = Contributor(id: "facts-bare") { $0.queryPathCheck(attribute: "facts") { _, _ in nil } }
        let silent = try EditorHarness(plugins: queryPlugins(more: [factsPlugin, fitWordsPlugin(), bare]), file: CanvasFile())
        try writesNothing(["chore[facts.size=3]"], on: silent)
    },
    test(":is and :where write the first of their alternatives that writes something; a list at the top the first that can be written") {
        let h = try fitting()
        expectEqual(try written("chore:is([note=a], [note=b])", on: h).note, "a")
        expectEqual(try written("chore:where([note=a], [note=b])", on: h).note, "a")
        expectEqual(try written("chore:is([status=nonsense], [note=b])", on: h).note, "b", "an alternative that writes nothing is passed over")
        expectEqual(try written("chore:is(tile[finish=glossy], [note=b])", on: h).note, "b", "and one of another kind, which can't be written")
        expectEqual(try written("chore:is([note=a]):is([estimate=2])", on: h).estimate, 2, "each :is is its own")
        expectEqual(try written("chore:is([note=a]):is([estimate=2])", on: h).note, "a")
        try writesNothing(["chore:is(tile, tile[finish=glossy])", "chore:is()"], on: h)
        // At the top, the first alternative that can be written is the one, even when it writes nothing.
        expectEqual(try written("tile[finish=glossy], [note=x]", on: h).note, "x", "a kind that isn't the record's can't be written")
        try writesNothing(["[status=nonsense], [note=x]", "chore, [note=x]"], on: h)
        expectEqual(try written("[note=x], [note=y]", on: h).note, "x")
        expectEqual(try written(#""Alpha", chore[note=x]"#, on: h).note, "x", "a title names one shape: not written")
    },
    test("only the subject says what the shape is: the compounds it must be inside are where it sits") {
        let h = try fitting()
        expectEqual(try written(#""Pantry" > chore[note=x]"#, on: h).note, "x")
        expectEqual(try written(#"pocket[note=zzz] chore[note=x]"#, on: h).note, "x")
        expectEqual(try written(#"chore[status=done] chore[note=x]"#, on: h).status, .todo, "what the places say is not written")
        expectEqual(try written(#"chore[note=x]:inside("Pantry")"#, on: h).note, "x")
    },
    test("what nothing can be sure of is skipped: not, has, inside, where a shape is, contains, edges, and every operator but =") {
        let h = try fitting()
        try writesNothing(["chore:not([status=done])", #"chore:has("Alpha")"#, "chore:has(> chore)", #"chore:inside("Pantry")"#, "chore:top-level",
                           "chore:current-board", #"chore:contains("x")"#, #"chore:edge-to("Alpha")"#, ":dangling", "chore:dangling(wire)",
                           "chore[note!=x]", "chore[note^=x]", "chore[note$=x]", "chore[note*=x]", "chore[note~=x]", "chore[note|=x]",
                           "chore[estimate>1]", "chore[estimate<=1]", "chore[ratio>=0.5]", "chore[due>2026-10-01]", "chore:silent", ":heavy", ":starred",
                           #"chore:wired-to("Alpha")"#], on: h)
        // The rest of a compound is still written.
        let rest = try written(#"chore[note=x]:not([status=done]):top-level[estimate>1]:inside("A")"#, on: h)
        expectEqual(rest.note, "x")
        expectEqual(rest.status, .todo)
        expectEqual(rest.estimate, nil)
    },
    test("a head: the record's kind, any kind, or one that can't be written (another kind, a title, an id)") {
        let h = try fitting()
        let wrong = AnyShapeRecord(ShapeRecord(id: id(51), Tile(unit)))
        try writesNothing(["tile[finish=glossy]", "blob[note=x]"], on: h)
        expectEqual((try require(try fit(wrong, "tile[finish=glossy]", on: h)).props as? Tile)?.finish, .glossy)
        expectEqual((try require(try fit(wrong, "*[finish=glossy]", on: h)).props as? Tile)?.finish, .glossy)
        expectEqual((try require(try fit(wrong, "[finish=glossy]", on: h)).props as? Tile)?.finish, .glossy)
        try writesNothing(["chore[note=x]"], from: wrong, on: h)
        try writesNothing([#""Alpha"[note=x]"#, #"chore"Alpha"[note=x]"#, "#\(uuid(1))[note=x]", #""Alpha" chore"Beta"[note=x]"#], on: h)
        try writesNothing(["chore", "*", ":is(chore)"], on: h)
    },
    test("an open kind lets a kind head turn the shape: made by the kind's placement, keeping its id, place, container and what both kinds hold") {
        let h = try fitting()
        var record = held(chore(id(52), caption: "Alpha", Chore(CGRect(x: 100, y: 200, width: 100, height: 60), note: "kept?")), in: id(5))
        record[Flagged.self] = true
        let closed = try fit(record, "tile[finish=glossy]", on: h)
        expect(closed == nil, "closed, a kind that isn't the record's can't be written")
        let turned = try require(try fit(record, "tile[finish=glossy]", open: true, on: h))
        let tile = try require(turned.props as? Tile)
        expectEqual(turned.kind, Tile.kind)
        expectEqual(turned.id, id(52))
        expectEqual(turned.container, id(5), "the container is kept")
        expectEqual(tile.finish, .glossy)
        expectEqual(tile.frame, CGRect(x: 100, y: 200, width: 100, height: 60), "the shape's own frame")
        expectEqual(turned[Flagged.self], true, "a value both kinds hold is kept")
        expectEqual(turned[Caption.self], nil, "and one only the old kind holds goes with it")
        // The kind alone is a write; a kind it already is turns nothing; a kind with no placement can't be turned into.
        expectEqual(try require(try fit(record, "tile", open: true, on: h)).kind, Tile.kind)
        expectEqual(try require(try fit(AnyShapeRecord(ShapeRecord(id: id(53), Tile(unit))), "tile[finish=glossy]", open: true, on: h)).kind, Tile.kind)
        try writesNothing(["tile", "chore[note=x]"], from: AnyShapeRecord(ShapeRecord(id: id(53), Tile(unit))), open: true, on: h)
        try writesNothing(["pocket", "blob"], open: true, on: h)
        // A title or an id names one shape, whatever is open; the other alternatives are used.
        try writesNothing([#""Alpha""#, "#\(uuid(1))"], open: true, on: h)
        expectEqual(try require(try fit(record, #""Alpha", tile[finish=glossy]"#, open: true, on: h)).kind, Tile.kind)
        // Without a kind said, a shape stays what it is.
        expectEqual(try require(try fit(record, "[note=x]", open: true, on: h)).kind, Chore.kind)
        // :is turns by its first alternative that writes something.
        expectEqual(try require(try fit(record, "chore:is(tile, [note=x])", open: true, on: h)).kind, Tile.kind)
    },
    test("a word's own writer (`makes:`) is given its text, and a word that has none is skipped") {
        let h = try fitting()
        expect(try written("chore:urgent", on: h).note == "")
        expectEqual(try require(try fit(fresh(), "chore:urgent", on: h))[Flagged.self], true)
        expectEqual(try require(try fit(fresh(), #"chore:labelled("Zed")"#, on: h))[Caption.self], "Zed")
        expectEqual(try require(try fit(fresh(), #"chore:labelled( 'a \"q\"' )"#, on: h))[Caption.self], #"a "q""#, "the text as the language reads it")
        let both = try require(try fit(fresh(), #"chore[note=x]:urgent:labelled("L")"#, on: h))
        expectEqual([(both.props as? Chore)?.note == "x", both[Flagged.self] == true, both[Caption.self] == "L"], [true, true, true])
        try writesNothing(["chore:labelled", "chore:labelled(red)", #"chore:labelled("a", "b")"#, #":urgent("x")"#, "chore:silent"], on: h)
        expectEqual(try require(try fit(fresh(), "chore:is(:silent, :urgent)", on: h))[Flagged.self], true, ":is passes over a word that writes nothing")
        // A word of another kind's shapes: its writer decides.
        expectEqual(try require(try fit(AnyShapeRecord(ShapeRecord(id: id(54), Tile(unit))), ":urgent", on: h))[Flagged.self], true)
    },
    test("a relation's writer is given the alternatives of its argument as written, each by its title, kind and id when it names one") {
        let h = try fitting()
        let id1 = "#\(uuid(1))"
        let made = try require(try fit(fresh(), #"chore:tied-to("Alpha", \#(id1), chore"Beta", chore, "A" chore, [note=x])"#, on: h))
        let alternatives = try require(made[Caption.self]).split(separator: ";").map(String.init)
        expectEqual(alternatives, [#""Alpha"|Alpha|-|-"#, "\(id1)|-|-|01", #"chore"Beta"|Beta|chore|-"#, "chore|-|-|-", #""A" chore|-|-|-"#, "[note=x]|-|-|-"])
        expectEqual(try require(try fit(fresh(), #":tied-to("Alpha")"#, on: h))[Caption.self], #""Alpha"|Alpha|-|-"#)
        try writesNothing([":tied-to", "chore:tied-to()", "chore:tied-to(<<)"], on: h)
    },
    test("a text that doesn't read writes nothing; neither does one that says nothing to write") {
        let h = try fitting()
        try writesNothing(["", "   ", "chore[", "chore[note=", ":is(", "chore[note=x]]", "chore:", "(", "/* nothing */"], on: h)
        let alreadyThere = chore(id(55), Chore(unit, note: "x"))
        expect(try fit(alreadyThere, "chore[note=x]", on: h) == nil, "what is already so writes nothing")
        expectEqual(try written("chore[note=y]", on: h, from: alreadyThere).note, "y")
    },
    test("it asks nothing of the file and takes no snapshot: the shape alone is read, and the record given is unchanged") {
        let h = try fitting()
        let queries = try require(h.editor.queries)
        let record = fresh()
        let captures = queries.captures
        _ = try fit(record, #"chore[note="x"][status=done]:urgent"#, on: h)
        expectEqual(queries.captures, captures, "the file is not taken up")
        expectEqual(queries.liveSnapshots, 0)
        expectEqual(record, fresh(), "a value: the record given is as it was")
    },
])
