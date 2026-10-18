import Automation
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CoreGraphics
import Draw
import Foundation
import TestKit

// `group "A" and "B"` and `ungroup "A"`: the draw engine's statements, over a fixture that groups. Draw knows no meaning of a
// group: it finds the shapes a statement names, on the board the run draws on, and hands them with the run's transaction to
// what groups shapes (the point `DrawGroups`, which Grouping fills in the app). The fixture's groups are cliques, a name each
// shape holds (a property of the test's own), so what these tests hold is the engine: which shapes it hands over, when, what it
// refuses, and what the rows say.

/// The clique a shape is in, a name: the fixture's group, written only by the plugin below. Unlisted, as groups are: a plugin's
/// own, which no script lists or writes.
enum Clique {}

extension Clique: ShapeProperty {
    static let key: PropertyKey = "clique"
    static var defaultValue: String? { nil }
    static var keywords: PropertyKeywords<String> { PropertyKeywords().unlisted() }
}

/// What the groups plugin was handed, in order: the word and the shapes.
@MainActor final class GroupLog {
    var calls: [(word: String, ids: [ShapeID])] = []
    /// How many cliques it has made.
    var made = 0
}

/// Groups as cliques: `group` puts the shapes it is handed in a clique of their own (a new name), and answers that it changed
/// nothing for shapes that already are one clique alone; `ungroup` takes each out of its clique. Every shape may hold one.
@MainActor func groupsPlugin(_ log: GroupLog = GroupLog()) -> Contributor {
    Contributor(id: "cliques") { registrar in
        registrar.declare(Clique.self)
        registrar.optInEveryShape(to: Clique.self)
        registrar.drawGroups(group: { ids, transaction in
            log.calls.append(("group", ids))
            let held = ids.map { transaction.document[$0]?[Clique.self] }
            if let first = held.first, let clique = first, held.allSatisfy({ $0 == clique }),
               transaction.document.shapes.filter({ $0[Clique.self] == clique }).count == ids.count {
                return false
            }
            log.made += 1
            for id in ids { transaction.update(id) { $0[Clique.self] = "clique \(log.made)" } }
            return true
        }, ungroup: { ids, transaction in
            log.calls.append(("ungroup", ids))
            let held = ids.filter { transaction.document[$0]?[Clique.self] != nil }
            for id in held { transaction.update(id) { $0[Clique.self] = nil } }
            return !held.isEmpty
        })
    }
}

/// The clique the shape called this is in, on the board shown.
@MainActor func clique(_ title: String, in editor: CanvasEditor) -> String? {
    shape(title, in: editor).flatMap { editor.document[$0.id]?[Clique.self] }
}

/// An id as a script writes it.
private func mark(_ id: ShapeID) -> String { "#\(id)" }

/// The root: tiles Hub and East, the pocket "Plans", frozen, whose board holds tiles Deep and Next, both in the clique "old",
/// and Side, in none; and the pocket "Open", whose board holds tile Free.
@MainActor private struct Plans {
    let hub = ShapeID(), east = ShapeID(), plans = ShapeID(), open = ShapeID(), deep = ShapeID(), next = ShapeID(), side = ShapeID(), free = ShapeID()
    var openBoard: BoardID { BoardID(owner: open) }

    var file: CanvasFile {
        func tile(_ id: ShapeID, _ label: String, x: CGFloat, clique: String? = nil) -> AnyShapeRecord {
            var record = AnyShapeRecord(ShapeRecord(id: id, Tile(CGRect(x: x, y: 0, width: 100, height: 60), label: label)))
            record[Clique.self] = clique
            return record
        }
        func pocket(_ id: ShapeID, _ name: String, x: CGFloat, frozen: Bool = false) -> AnyShapeRecord {
            var record = AnyShapeRecord(ShapeRecord(id: id, Pocket(CGRect(x: x, y: 300, width: 100, height: 100))))
            record[Nickname.self] = name
            if frozen { record[Frozen.self] = true }
            return record
        }
        return CanvasFile(root: CanvasDocument(shapes: [tile(hub, "Hub", x: 0), tile(east, "East", x: 200), pocket(plans, "Plans", x: 0, frozen: true), pocket(open, "Open", x: 200)]),
                          children: [plans: CanvasDocument(shapes: [tile(deep, "Deep", x: 0, clique: "old"), tile(next, "Next", x: 200, clique: "old"), tile(side, "Side", x: 400)]),
                                     open: CanvasDocument(shapes: [tile(free, "Free", x: 0)])])
    }

    func editor(_ log: GroupLog = GroupLog()) throws -> CanvasEditor {
        let editor = try drawEditor([PocketsPlugin(), namedPockets, FreezingPlugin(), groupsPlugin(log)])
        editor.replaceFile(with: file)
        return editor
    }
}

@MainActor let drawGroupTests = Suite("draw: group and ungroup", [
    test("group hands the shapes it names, once each, in the order written, to what groups shapes; its row says grouped, and calls them as written") {
        let log = GroupLog()
        let editor = try drawEditor([groupsPlugin(log)])
        _ = try drawn(threeShapes, on: editor)
        let hub = try require(shape("Hub", in: editor)), east = try require(shape("East", in: editor)), ab = try require(shape("AB", in: editor))
        let result = try drawn(#"group "East" and "Hub", "AB""#, on: editor)
        expectEqual(rows(result), [["line": 1, "did": "grouped", "shapes": ["East", "Hub", "AB"]]])
        expectEqual(messages(result), [])
        expectEqual(result["dryRun"], nil)
        expectEqual(log.calls.map(\.word), ["group"])
        expectEqual(log.calls.first?.ids, [east.id, hub.id, ab.id])
        expectEqual([clique("Hub", in: editor), clique("East", in: editor), clique("AB", in: editor)], ["clique 1", "clique 1", "clique 1"])
        expectEqual(editor.undoHistory.undoName, "Draw")
    },
    test("ungroup hands the shapes it names; its row says ungrouped when it changed something, and unchanged when every shape was in none already") {
        let log = GroupLog()
        let editor = try drawEditor([groupsPlugin(log)])
        _ = try drawn(threeShapes, on: editor)
        _ = try drawn(#"group "Hub" and "East""#, on: editor)
        let east = try require(shape("East", in: editor)), ab = try require(shape("AB", in: editor))
        let result = try drawn(#"ungroup "East" and "AB""#, on: editor)
        expectEqual(rows(result), [["line": 1, "did": "ungrouped", "shapes": ["East", "AB"]]])
        expectEqual(log.calls.last?.word, "ungroup")
        expectEqual(log.calls.last?.ids, [east.id, ab.id])
        expectEqual([clique("Hub", in: editor), clique("East", in: editor), clique("AB", in: editor)], ["clique 1", nil, nil])
        let none = try drawn(#"ungroup "East" and "AB""#, on: editor)
        expectEqual(rows(none), [["line": 1, "did": "unchanged", "shapes": ["East", "AB"]]])
        expectEqual(log.calls.count, 3, "it is asked all the same: whether anything changes is its to say")
    },
    test("a statement that changes nothing is unchanged, and a run of them opens no undo step: group again, ungroup shapes in none") {
        let log = GroupLog()
        let editor = try drawEditor([groupsPlugin(log)])
        _ = try drawn(threeShapes, on: editor)
        _ = try drawn(#"group "Hub" and "East""#, on: editor)
        let before = editor.document
        var events: [UndoEvent] = []
        editor.undoHistory.didChange = { events.append($0) }
        let again = try drawn(#"group "East" and "Hub""#, on: editor)
        expectEqual(rows(again), [["line": 1, "did": "unchanged", "shapes": ["East", "Hub"]]])
        let none = try drawn("ungroup \"AB\"\ngroup \"Hub\" and \"East\"", on: editor)
        expectEqual(rows(none).map { $0["did"] }, ["unchanged", "unchanged"])
        expectEqual(editor.document, before)
        expectEqual(events, [], "no step")
        // Shapes that are not all of the group do change it.
        let wider = try drawn(#"group "Hub" and "East" and "AB""#, on: editor)
        expectEqual(rows(wider).map { $0["did"] }, ["grouped"])
        expect(!events.isEmpty, "a step")
    },
    test("the shapes a script draws can be named, whether the statement comes before them or after, new or restated, renamed or moved") {
        let log = GroupLog()
        let editor = try drawEditor([groupsPlugin(log)])
        _ = try drawn(threeShapes, on: editor)
        let before = editor.document
        let result = try drawn("""
            group "Fresh" and "Hub" and "Last"
            tile "Fresh" right of "East"
            tile "Last" right of "Fresh"
            edge "Fresh" -> "Last"
            tile "Hub" title: "Core" finish: glossy
            ungroup "AB"
            """, on: editor)
        expectEqual(rows(result).map { $0["did"] }, ["grouped", "created", "created", "connected", "renamed", "unchanged"])
        expectEqual(rows(result).first?["shapes"], ["Fresh", "Hub", "Last"], "a shape is called as its statement calls it, though the run renames it")
        let fresh = try require(shape("Fresh", in: editor)), last = try require(shape("Last", in: editor)), core = try require(shape("Core", in: editor))
        expectEqual(log.calls.first?.ids, [fresh.id, core.id, last.id], "the shapes in the transaction: one the script made, one it renamed")
        expectEqual([clique("Fresh", in: editor), clique("Core", in: editor), clique("Last", in: editor)], ["clique 1", "clique 1", "clique 1"])
        expectEqual(editor.undoHistory.undoName, "Draw")
        editor.undo()
        expectEqual(editor.document, before)
    },
    test("rows come in line order with the others', and the groups are applied last, once every shape and edge is where it goes") {
        let editor = try drawEditor([groupsPlugin()])
        _ = try drawn(threeShapes, on: editor)
        let result = try drawn("""
            ungroup "East"
            tile "New" right of "East"
            delete "AB"
            group "Hub" and "New"
            edge "Hub" -> "New"
            """, on: editor)
        let got = withoutIDs(rows(result))
        expectEqual(got.map { $0["line"] }, [1, 2, 3, 4, 5])
        expectEqual(got.map { $0["did"] }, ["unchanged", "created", "deleted", "grouped", "connected"])
        expectEqual(got[0], ["line": 1, "did": "unchanged", "shapes": ["East"]])
        expectEqual(got[3], ["line": 4, "did": "grouped", "shapes": ["Hub", "New"]])
        expectEqual(links(in: editor), ["Hub -> New"])
        expectEqual(clique("New", in: editor), "clique 1")
    },
    test("a shape with no title is named by its id: the row calls it so, and calls a shape that has a title by it, though it was named by its id") {
        let q = Quay()
        let log = GroupLog()
        let editor = try q.editor(log: EdgeLog(), [groupsPlugin(log)])
        let result = try drawn("group \(mark(q.a)) and \"Hub\" and \(mark(q.b))", on: editor)
        expectEqual(rows(result), [["line": 1, "did": "grouped", "shapes": [.string(mark(q.a)), "Hub", .string(mark(q.b))]]])
        expectEqual(log.calls.first?.ids, [q.a, q.hub, q.b])
        let byID = try drawn("ungroup \(mark(q.hub)) and \(mark(q.a))", on: editor)
        expectEqual(rows(byID), [["line": 1, "did": "ungrouped", "shapes": ["Hub", .string(mark(q.a))]]])
        expectEqual(log.calls.last?.ids, [q.hub, q.a])
        expectEqual(editor.document[q.b]?[Clique.self], "clique 1")
        expectEqual(editor.document[q.a]?[Clique.self], nil)
        // A title and an id name a shape alike.
        let again = try drawn("group \"Hub\" and \(mark(q.a))", on: editor)
        expectEqual(rows(again).map { $0["did"] }, ["grouped"])
    },
    test("what groups shapes keeps its property for itself: no kind lists it, and a script can't write it, in a shape or in a style") {
        let editor = try drawEditor([groupsPlugin()])
        _ = try drawn(threeShapes, on: editor)
        let before = editor.document
        let shape = try refused(#"tile "Hub" clique: "mine""#, on: editor)
        expectEqual(shape.reason, "unknown_attribute")
        expectEqual(shape.data?["line"], 1)
        expect(shape.hint?.contains("clique") != true, "the hint lists what a tile takes: \(shape.hint ?? "")")
        expectEqual(try refused("style own clique: \"mine\"\ntile \"Hub\" style: own", on: editor).reason, "unknown_attribute")
        expectEqual(editor.document, before)
        for kind in try run(["kinds"], on: editor).get().arrayValue ?? [] {
            expectEqual(kind["attributes"]?["clique"], nil, "\(kind["kind"]?.stringValue ?? "?") lists it")
        }
        // The statements are how it's written.
        expectEqual(rows(try drawn(#"group "Hub" and "East""#, on: editor)).map { $0["did"] }, ["grouped"])
    },
    test("a name that finds no shape is refused where it is written, with the closest titles, and nothing is handed over") {
        let log = GroupLog()
        let editor = try drawEditor([groupsPlugin(log)])
        _ = try drawn(threeShapes, on: editor)
        let east = try require(shape("East", in: editor))
        let before = editor.document
        let typo = try refused("tile \"Fine\"\ngroup \"Hub\" and \"Easst\"", on: editor)
        expectEqual(typo.reason, "unknown_title")
        expectEqual(typo.message, #"there's no shape called "Easst""#)
        expectEqual(typo.hint, #"did you mean "East"?"#)
        expectEqual(typo.data?["line"], 2)
        expectEqual(typo.data?["statement"], #"group "Hub" and "Easst""#)
        expectEqual(try refused(#"ungroup "Nowhere""#, on: editor).reason, "unknown_title")
        let gone = try refused("delete \"East\"\ngroup \"Hub\" and \"East\"", on: editor)
        expectEqual(gone.reason, "unknown_title")
        expectEqual(gone.message, #"group names "East", which this script deletes"#)
        let nobody = mark(ShapeID())
        let unknown = try refused("group \"Hub\" and \(nobody)", on: editor)
        expectEqual(unknown.reason, "unknown_id")
        expectEqual(unknown.message, "there's no shape with the id \(nobody)")
        let deleted = try refused("delete \"East\"\nungroup \(mark(east.id))", on: editor)
        expectEqual(deleted.reason, "unknown_id")
        expectEqual(deleted.message, "ungroup names \(mark(east.id)), which this script deletes")
        expectEqual(log.calls.count, 0)
        expectEqual(editor.document, before)
    },
    test("a statement that names a shape whose own statement can't be resolved adds no error of its own") {
        let editor = try drawEditor([groupsPlugin()])
        _ = try drawn(threeShapes, on: editor)
        let result = try refused("card \"Hub\"\ngroup \"Hub\" and \"East\"\nungroup #\(try require(shape("AB", in: editor)).id)", on: editor)
        expectEqual(result.reason, "wrong_kind")
        expectEqual(result.data?["errors"], nil, "one mistake: the group only follows from it")
        expectEqual(result.data?["line"], 1)
    },
    test("an arrow and a reference can't be named: an id of one is invalid_value, as at every place that takes an id") {
        let q = Quay()
        let editor = try q.editor(log: EdgeLog(), [groupsPlugin()])
        _ = try drawn("edge \"Hub\" -> \"Deep\"", on: editor)
        let relay = try require(editor.relays().first)
        for id in [q.tie, relay.id] {
            for script in ["group \"Hub\" and \(mark(id))", "ungroup \(mark(id))"] {
                let error = try refused(script, on: editor)
                expectEqual(error.reason, "invalid_value", script)
                expectEqual(error.data?["line"], 1, script)
            }
        }
        expectEqual(try refused("group \"Hub\" and \(mark(q.tie))", on: editor).message, "\(mark(q.tie)) is a link, which a script can't name")
    },
    test("a shape is named once in a run: twice in one statement, by two statements, by its title and by its id, is duplicate") {
        let log = GroupLog()
        let editor = try drawEditor([groupsPlugin(log)])
        _ = try drawn(threeShapes, on: editor)
        let before = editor.document
        let hub = try require(shape("Hub", in: editor))
        let same = try refused(#"group "Hub" and "East" and "Hub""#, on: editor)
        expectEqual(same.reason, "duplicate")
        expectEqual(same.message, #""Hub" is named twice in this statement"#)
        expectEqual(same.hint, "name each shape once")
        expectEqual(same.data?["line"], 1)
        let two = try refused("group \"Hub\" and \"East\"\ngroup \"East\" and \"AB\"", on: editor)
        expectEqual(two.reason, "duplicate")
        expectEqual(two.message, #""East" is named twice, here and on line 1"#)
        expectEqual(two.hint, "a run says a shape's group once: keep one of the two statements")
        expectEqual(two.data?["line"], 2)
        expectEqual(try refused("group \"Hub\" and \"East\"\nungroup \"Hub\"", on: editor).reason, "duplicate", "a group and an ungroup of one shape")
        expectEqual(try refused("ungroup \"Hub\"\nungroup \"Hub\"", on: editor).reason, "duplicate")
        let both = try refused("group \"Hub\" and \"East\"\nungroup \(mark(hub.id))", on: editor)
        expectEqual(both.reason, "duplicate", "one shape, named by its title and by its id")
        expectEqual(both.message, #""Hub" is named twice, here and on line 1"#)
        let inside = try refused("group \"Hub\" and \(mark(hub.id))", on: editor)
        expectEqual(inside.message, #""Hub" is named twice in this statement"#)
        expectEqual(log.calls.count, 0)
        expectEqual(editor.document, before)
        // Two statements about different shapes are fine.
        expectEqual(rows(try drawn("group \"Hub\" and \"East\"\nungroup \"AB\"", on: editor)).map { $0["did"] }, ["grouped", "unchanged"])
    },
    test("all the shapes are on the run's board: a title or an id on another board claims it, and two boards are several_boards") {
        let n = Nest(), log = GroupLog()
        let editor = try n.editor([groupsPlugin(log)])
        let before = editor.file
        let apart = try refused(#"group "Hub" and "Deep""#, on: editor)
        expectEqual(apart.reason, "several_boards")
        expectEqual(apart.message, #"this script draws on the root board ("Hub", line 1) and on "P"'s board ("Deep")"#)
        expectEqual(apart.data?["line"], 1)
        expectEqual(try refused("group \"Hub\" and \(mark(n.deep))", on: editor).reason, "several_boards")
        expectEqual(try refused("group \(mark(n.deep)) and \"Hub\"", on: editor).reason, "several_boards")
        expectEqual(try refused("ungroup \"Hub\" and \"Deep\"", on: editor).reason, "several_boards")
        expectEqual(try refused("tile \"X\" in \"Q\"\ngroup \"Hub\" and \"Deep\"", on: editor).reason, "several_boards")
        expectEqual(log.calls.count, 0)
        expectEqual(editor.file, before)
        // Shapes of one board are a group there, wherever the window is; a title the board has settles one that two boards have.
        let there = try drawn(#"group "Deep" and "Twin""#, on: editor)
        expectEqual(there["on"]?["board"], .string(n.p.description))
        expectEqual(rows(there), [["line": 1, "did": "grouped", "shapes": ["Deep", "Twin"]]])
        expectEqual(editor.file.record(n.deep)?[Clique.self], "clique 1")
        expectEqual(editor.file.record(n.pTwin)?[Clique.self], "clique 1", "P's Twin, where Deep is")
        expectEqual(editor.file.record(n.twin)?[Clique.self], nil, "not Q's")
        expectEqual(editor.board, .root, "the window stays where it is")
        expectEqual(editor.undoHistory.undoName, "Draw")
        let root = try drawn(#"group "Hub" and "P""#, on: editor)
        expectEqual(root["on"]?["board"], .string("root"))
        let apartAgain = try drawn(#"ungroup "Deep""#, on: editor)
        expectEqual(apartAgain["on"]?["board"], .string(n.p.description))
        expectEqual(editor.file.record(n.deep)?[Clique.self], nil)
        expectEqual(editor.file.record(n.pTwin)?[Clique.self], "clique 1")
    },
    test("a shape that is read-only and would be written is read_only, with the messages a locked shape has; nothing commits and no step opens") {
        let log = GroupLog()
        let editor = try drawEditor([FreezingPlugin(), groupsPlugin(log)])
        _ = try drawn(threeShapes, on: editor)
        let east = try require(shape("East", in: editor))
        editor.freeze([east.id])
        let before = editor.document, step = editor.undoHistory.undoName
        let grouped = try refused(#"group "Hub" and "East""#, on: editor)
        expectEqual(grouped.reason, "read_only")
        expectEqual(grouped.message, #""East" is read-only (locked, say), so it can't be grouped"#)
        expectEqual(grouped.hint, "leave it out of the script, or ask the user to unlock it")
        expectEqual(grouped.data?["line"], 1)
        expectEqual(grouped.data?["statement"], #"group "Hub" and "East""#)
        let dry = try refused(#"group "East" and "Hub""#, on: editor, ["--dry-run"])
        expectEqual(dry.message, grouped.message, "a dry run says the same")
        expectEqual(editor.document, before)
        expectEqual(editor.undoHistory.undoName, step)
        // Nothing to write is no refusal: shapes in none are not ungrouped, and a statement that changes nothing goes through.
        expectEqual(rows(try drawn(#"ungroup "East" and "Hub""#, on: editor)).map { $0["did"] }, ["unchanged"])
        // Thawed, grouped, frozen again: it can't be taken out; grouped again as it is, nothing is written, and that goes through.
        editor.freeze([east.id], false)
        _ = try drawn(#"group "Hub" and "East""#, on: editor)
        editor.freeze([east.id])
        let apart = try refused(#"ungroup "Hub" and "East""#, on: editor)
        expectEqual(apart.message, #""East" is read-only (locked, say), so it can't be ungrouped"#)
        expectEqual(rows(try drawn(#"group "East" and "Hub""#, on: editor)).map { $0["did"] }, ["unchanged"])
        expectEqual(clique("Hub", in: editor), "clique \(log.made)", "the clique the run that grouped them made")
        expectEqual(clique("East", in: editor), clique("Hub", in: editor))
        // What the script itself unlocks, it unlocks first.
        let thawed = try drawn("tile \"East\" frozen: false\nungroup \"Hub\" and \"East\"", on: editor)
        expectEqual(rows(thawed).map { $0["did"] }, ["updated", "ungrouped"])
        expectEqual(clique("East", in: editor), nil)
    },
    test("what a locked frame holds is read-only, and one of the shapes is enough") {
        let log = GroupLog()
        let editor = try drawEditor([pens, FreezingPlugin(), groupsPlugin(log)])
        let pen = AnyShapeRecord(ShapeRecord(Pen(CGRect(x: 0, y: 0, width: 400, height: 300), label: "Pen")))
        editor.transact { $0.insert(pen) }
        let held = tile("Held", CGRect(x: 40, y: 40, width: 120, height: 80), in: editor)
        _ = tile("Free", CGRect(x: 600, y: 40, width: 120, height: 80), in: editor)
        editor.transact { $0.setContainer(held.id, to: pen.id) }
        editor.freeze([pen.id])
        let before = editor.document, step = editor.undoHistory.undoName
        let first = try refused(#"group "Free" and "Held""#, on: editor)
        expectEqual(first.reason, "read_only")
        expectEqual(first.message, #""Held" is read-only (locked, say), so it can't be grouped"#)
        expectEqual(try refused(#"group "Held" and "Free""#, on: editor).message, first.message)
        expectEqual(editor.document, before, "nothing written")
        expectEqual(editor.undoHistory.undoName, step)
        expectEqual(rows(try drawn(#"ungroup "Held""#, on: editor)).map { $0["did"] }, ["unchanged"])
        editor.freeze([pen.id], false)
        expectEqual(rows(try drawn(#"group "Held" and "Free""#, on: editor)).map { $0["did"] }, ["grouped"])
    },
    test("what is on a locked subboard's board is read-only too, at any depth; a board that isn't locked takes it") {
        let p = Plans(), log = GroupLog()
        let editor = try p.editor(log)
        let before = editor.file, step = editor.undoHistory.undoName
        let into = try refused(#"group "Deep" and "Side""#, on: editor)
        expectEqual(into.reason, "read_only")
        expectEqual(into.message, #""Deep" is read-only (locked, say), so it can't be grouped"#)
        let out = try refused(#"ungroup "Next""#, on: editor)
        expectEqual(out.message, #""Next" is read-only (locked, say), so it can't be ungrouped"#)
        expectEqual(editor.file, before)
        expectEqual(editor.undoHistory.undoName, step)
        // Already as asked, or in none: nothing is written, and the run goes through.
        expectEqual(rows(try drawn(#"group "Deep" and "Next""#, on: editor)).map { $0["did"] }, ["unchanged"])
        expectEqual(rows(try drawn(#"ungroup "Side""#, on: editor)).map { $0["did"] }, ["unchanged"])
        let open = try drawn("tile \"Mate\" in \"Open\"\ngroup \"Free\" and \"Mate\"", on: editor)
        expectEqual(rows(open).map { $0["did"] }, ["created", "grouped"])
        expectEqual(open["on"]?["board"], .string(p.open.description))
        expectEqual(editor.file.record(p.free)?[Clique.self], "clique \(log.made)")
        expectEqual(editor.file.record(p.free)?[Clique.self], editor.contents(of: p.openBoard).shapes.last?[Clique.self])
    },
    test("without anything that groups shapes, a script with either statement is no_groups, at its line, and nothing is drawn") {
        let editor = try drawEditor()
        _ = try drawn(threeShapes, on: editor)
        let before = editor.document
        let group = try refused("tile \"Fine\"\ngroup \"Hub\" and \"East\"", on: editor)
        expectEqual(group.reason, "no_groups")
        expectEqual(group.message, "nothing here groups shapes")
        expectEqual(group.hint, "leave group and ungroup out: this app has no plugin that groups shapes")
        expectEqual(group.data?["line"], 2)
        expectEqual(group.data?["statement"], #"group "Hub" and "East""#)
        expectEqual(try refused(#"ungroup "Hub""#, on: editor).reason, "no_groups")
        expectEqual(try refused(#"group "Nowhere" and "Nada""#, on: editor).reason, "no_groups", "before the shapes are looked for")
        let both = try refused("group \"Hub\" and \"East\"\nungroup \"AB\"", on: editor)
        expectEqual(both.data?["errors"]?.arrayValue?.map { $0["line"] }, [1, 2], "each statement says so")
        expectEqual(editor.document, before)
        expectEqual(rows(try drawn("tile \"Fine\"", on: editor)).map { $0["did"] }, ["created"], "the rest of the language is as it was")
        let unnamed = try makeEditor([groupsPlugin()])
        expectEqual(try refused(#"group "A" and "B""#, on: unnamed).reason, "no_names", "shapes are named by titles, and nothing here gives shapes names")
    },
    test("a dry run says the same rows and changes nothing: no shape, no group, no step") {
        let log = GroupLog()
        let editor = try drawEditor([groupsPlugin(log)])
        _ = try drawn(threeShapes, on: editor)
        let before = editor.document, step = editor.undoHistory.undoName
        let script = "tile \"New\" right of \"East\"\ngroup \"New\" and \"Hub\"\nungroup \"AB\""
        let dry = try drawn(script, on: editor, ["--dry-run"])
        expectEqual(dry["dryRun"], true)
        expectEqual(editor.document, before)
        expectEqual(editor.undoHistory.undoName, step)
        let real = try drawn(script, on: editor)
        expectEqual(withoutIDs(rows(dry)), withoutIDs(rows(real)))
        expectEqual(rows(dry).map { $0["did"] }, ["created", "grouped", "unchanged"])
        expectEqual(clique("New", in: editor), "clique 2", "the dry run asked for a clique too, in a transaction thrown away")
    },
    test("a run with groups is one undo step, Draw: undone, the shapes and groups are as they were; redone, as the run left them") {
        let editor = try drawEditor([groupsPlugin()])
        _ = try drawn(threeShapes, on: editor)
        _ = try drawn(#"group "Hub" and "AB""#, on: editor)
        let before = editor.document
        _ = try drawn("tile \"New\" below \"East\"\ngroup \"New\" and \"East\"\nungroup \"Hub\"", on: editor)
        let after = editor.document
        expectEqual(editor.undoHistory.undoName, "Draw")
        expectEqual([clique("New", in: editor), clique("East", in: editor), clique("Hub", in: editor), clique("AB", in: editor)], ["clique 2", "clique 2", nil, "clique 1"])
        editor.undo()
        expectEqual(editor.document, before)
        expectEqual([clique("Hub", in: editor), clique("AB", in: editor)], ["clique 1", "clique 1"])
        editor.redo()
        expectEqual(editor.document, after)
    },
    test("canvas measure leaves both statements out, as it leaves out deletes: no size, no refusal, with or without something that groups") {
        for editor in try [drawEditor([groupsPlugin()]), drawEditor()] {
            let measured = try run(["measure", "-"], on: editor, input: "tile \"A\"\ntile \"B\"\ngroup \"A\" and \"B\"\nungroup \"A\"\ngroup \"X\" and \"Y\"").get()
            expectEqual((measured["shapes"]?.arrayValue ?? []).map { $0["line"] }, [1, 2])
            expectEqual(measured["warnings"], nil)
            let alone = try run(["measure", "-"], on: editor, input: "group \"X\" and \"Y\"\nungroup \"X\"").get()
            expectEqual(alone["shapes"], [])
            expectEqual(editor.document.shapes.count, 0, "nothing drawn")
        }
    },
    test("what groups shapes is a point with one plugin: two refuse the plugin list, it needs the engine, and the registry reports it") {
        let grouping = { (id: PluginID) in Contributor(id: id) { $0.drawGroups(group: { _, _ in false }, ungroup: { _, _ in false }) } }
        expectThrows(RegistryError.conflict(point: "DrawGroups", key: "draw groups", plugins: ["a", "b"])) {
            _ = try Registry(plugins: [DrawPlugin(), AutomationPlugin(), grouping("a"), grouping("b")])
        }
        expectThrows(RegistryError.ownerNotInstalled(point: "DrawGroups", owner: "draw-engine", contributor: "a")) {
            _ = try Registry(plugins: [grouping("a")])
        }
        let registry = try Registry(plugins: [DrawPlugin(), AutomationPlugin(), grouping("cliques")])
        expect(registry.report.contains("draw groups"), registry.report)
    },
    test("a row has shapes of its own, so no edge attribute or report member can be named so") {
        expectThrows(RegistryError.invalid(point: "DrawEdges", reason: "attribute shapes: a draw result's row has shapes of its own")) {
            _ = try Registry(plugins: [DrawPlugin(), AutomationPlugin(), Contributor(id: "edges") {
                $0.drawEdges(kind: { _ in Link.kind }, attributes: ["shapes"], sides: { _, _ in [:] }, ends: { _, _ in nil }, make: { _, _, _ throws(DrawError) in
                    throw DrawError("no", reason: "cannot_connect")
                })
            }])
        }
        expectThrows(RegistryError.invalid(point: "DrawReports", reason: "member shapes: a draw result's row has shapes of its own")) {
            _ = try Registry(plugins: [DrawPlugin(), AutomationPlugin(), Contributor(id: "reports") {
                $0.drawReports(members: ["shapes"]) { _, _, _, _ in DrawShapeReport() }
            }])
        }
    },
])
