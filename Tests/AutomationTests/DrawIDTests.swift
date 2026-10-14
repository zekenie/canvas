import Automation
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CoreGraphics
import Draw
import Foundation
import TestKit
import Topology

// A shape with no title is named by its id, in the query's spelling, wherever a statement names a shape the file has
// (the owner's answer to Q5: a script names a shape by its title, and an id is for a shape that has none). Over fixtures:
// tiles with a blank label are untitled, a link is an arrow and a relay a pill, neither of which a title could name.

/// A quay: on the root, the tile Hub, two tiles with no title (`a`, `b`), a link between them and the pocket P; on P's board,
/// Deep (open) and a tile with no title (`far`, open, so a relay can stand for it).
@MainActor struct Quay {
    let p = ShapeID(), hub = ShapeID(), a = ShapeID(), b = ShapeID(), tie = ShapeID(), far = ShapeID(), deep = ShapeID()

    var file: CanvasFile {
        func tile(_ id: ShapeID, _ label: String, x: CGFloat, y: CGFloat = 150, open: Bool = false) -> AnyShapeRecord {
            var record = AnyShapeRecord(ShapeRecord(id: id, Tile(CGRect(x: x, y: y, width: 120, height: 80), label: label)))
            if open { record.meta[Open.self] = true }
            return record
        }
        var pocket = AnyShapeRecord(ShapeRecord(id: p, Pocket(CGRect(x: 400, y: 400, width: 100, height: 100))))
        pocket[Nickname.self] = "P"
        let link = AnyShapeRecord(ShapeRecord(id: tie, Link(from: a, to: b)))
        return CanvasFile(root: CanvasDocument(shapes: [tile(hub, "Hub", x: 400), tile(a, "", x: 150), tile(b, "", x: 150, y: 300), link, pocket]),
                          children: [p: CanvasDocument(shapes: [tile(far, "", x: 150, open: true), tile(deep, "Deep", x: 400, open: true)])])
    }

    func editor(log: EdgeLog = EdgeLog(), _ more: [any CanvasPlugin] = []) throws -> CanvasEditor {
        let editor = try drawEditor([TopologyPlugin(), PocketsPlugin(), namedPockets, relaysPlugin()] + more, log: log)
        editor.replaceFile(with: file)
        return editor
    }

    /// What Mentions would call a shape with no title, for a test with a plugin that says.
    static let labels = Contributor(id: "labels") { registrar in
        registrar.drawLabels { record, _ in record.typed(as: Tile.self).map { "tile at \(Int($0.props.frame.minX))" } }
    }
}

/// An id as a script writes it.
private func mark(_ id: ShapeID) -> String { "#\(id)" }

@MainActor let drawIDTests = Suite("draw: ids name shapes that have no title", [
    test("an edge's end may be an id: the arrow is drawn, and the row says which shape (its id) and calls it by the id as written") {
        let q = Quay()
        let editor = try q.editor()
        let result = try drawn("edge \"Hub\" -> \(mark(q.a))", on: editor)
        expectEqual(rows(result), [["line": 1, "did": "connected", "kind": "link", "from": "Hub", "to": .string(mark(q.a)), "toId": .string(q.a.description)]])
        expectEqual(messages(result), [])
        expectEqual(editor.linkEnds().count, 2, "the tie, and the arrow")
        expectEqual(editor.linkEnds().last?.from, q.hub)
        expectEqual(editor.linkEnds().last?.to, q.a)
    },
    test("an edge between two untitled shapes, by id; written again it is unchanged, with the same row, and lower case is the same id") {
        let q = Quay()
        let editor = try q.editor()
        let script = "edge \(mark(q.b)) -> \(mark(q.a))"
        let first = try drawn(script, on: editor)
        expectEqual(rows(first).first?["did"], "connected")
        expectEqual(rows(first).first?["fromId"], .string(q.b.description))
        expectEqual(rows(first).first?["toId"], .string(q.a.description))
        let again = try drawn(script, on: editor)
        expectEqual(rows(again), rows(first).map { row in
            var row = row
            row["did"] = "unchanged"
            return row
        })
        expectEqual(rows(try drawn(script.lowercased(), on: editor)).first?["did"], "unchanged")
        expectEqual(editor.linkEnds().count, 2, "the tie and the one arrow")
    },
    test("an end may be the id of a shape that has a title: the row calls it by the title and says the id") {
        let q = Quay()
        let editor = try q.editor()
        let result = try drawn("edge \(mark(q.hub)) -> \(mark(q.a))", on: editor)
        expectEqual(rows(result), [["line": 1, "did": "connected", "kind": "link", "from": "Hub", "to": .string(mark(q.a)),
                                    "fromId": .string(q.hub.description), "toId": .string(q.a.description)]])
        expectEqual(rows(try drawn("edge \"Hub\" -> \(mark(q.a))", on: editor)).first?["did"], "unchanged", "one shape, named either way")
    },
    test("a shape named by its id and by its title in one script is one shape: two statements of it are duplicate") {
        let q = Quay()
        let editor = try q.editor()
        let both = try refused("""
            tile "Hub" size: 130x90
            tile \(mark(q.hub)) size: 140x90
            """, on: editor)
        expectEqual(both.reason, "duplicate")
        expectEqual(both.data?["line"], 2)
        expectEqual(both.message, "\"Hub\" is written twice, here and on line 1")
        let reverse = try refused("""
            tile \(mark(q.hub)) size: 140x90
            tile "Hub" size: 130x90
            """, on: editor)
        expectEqual(reverse.reason, "duplicate")
        expectEqual(reverse.data?["line"], 2)
        let twice = try refused("""
            tile \(mark(q.a)) size: 140x90
            tile \(mark(q.a)) size: 150x90
            """, on: editor)
        expectEqual(twice.reason, "duplicate")
        expectEqual(twice.message, "\(mark(q.a)) is written twice, here and on line 1")
        let edges = try refused("""
            edge "Hub" -> \(mark(q.a))
            edge \(mark(q.hub)) -> \(mark(q.a))
            """, on: editor)
        expectEqual(edges.reason, "duplicate", "the same pair of shapes, however each end is named")
        expectEqual(editor.document.shapes.count, 5, "nothing drawn")
    },
    test("a shape statement that names an id restates that shape: its placement and size change it, its kind must be the statement's, and it never makes a shape") {
        let q = Quay()
        let editor = try q.editor()
        let before = try require(editor.document[q.a]?.box)
        let result = try drawn("tile \(mark(q.a)) right of \"Hub\" size: 100x60", on: editor)
        let row = try require(rows(result).first)
        expectEqual(row["did"], "moved")
        expectEqual(row["id"], .string(q.a.description))
        expectEqual(row["title"], nil, "it has none")
        expectEqual(editor.document.shapes.count, 5, "no shape made")
        let after = try require(editor.document[q.a]?.box)
        expect(after.minX > (try require(editor.document[q.hub]?.box)).maxX, "right of Hub")
        expect(after != before)
        expectEqual(after.size, CGSize(width: 100, height: 60))
        expectEqual(try refused("card \(mark(q.a))", on: editor).reason, "wrong_kind")
        // It can be given a title; the next run knows it so.
        let titled = try drawn("tile \(mark(q.a)) title: \"Wharf\"", on: editor)
        expectEqual(rows(titled).first?["did"], "renamed")
        expectEqual(rows(titled).first?["title"], "Wharf")
        let again = try drawn("tile \"Wharf\"", on: editor)
        expectEqual(rows(again).first?["did"], "unchanged")
        expectEqual(rows(again).first?["id"], .string(q.a.description))
    },
    test("delete by id takes the shape, and says its id; delete edge takes the arrows between ends named by id or title") {
        let q = Quay()
        let editor = try q.editor()
        _ = try drawn("edge \"Hub\" -> \(mark(q.a))", on: editor)
        let edge = try drawn("delete edge \"Hub\" -> \(mark(q.a))", on: editor)
        expectEqual(rows(edge).map { $0["did"] }, ["deleted"])
        expectEqual(editor.linkEnds().count, 1, "the tie stays")
        let tied = try drawn("delete edge \(mark(q.a)) -> \(mark(q.b))", on: editor)
        expectEqual(rows(tied), [["line": 1, "did": "deleted", "kind": "link", "from": .string(mark(q.a)), "to": .string(mark(q.b)),
                                  "fromId": .string(q.a.description), "toId": .string(q.b.description)]],
                    "a deleted arrow's ends are called by the id as written, and the row says which shapes they were")
        expectEqual(editor.linkEnds().count, 0)
        let result = try drawn("delete \(mark(q.b))", on: editor)
        expectEqual(rows(result), [["line": 1, "did": "deleted", "kind": "tile", "id": .string(q.b.description)]])
        expectEqual(editor.document[q.b], nil)
        expectEqual(try refused("delete \(mark(q.a))\ndelete \(mark(q.a))", on: editor).reason, "duplicate")
        expectEqual(editor.document[q.a] != nil, true, "the refused run deleted nothing")
    },
    test("a placement may name a shape by its id; in may name its holder by its id") {
        let q = Quay()
        let editor = try q.editor()
        let result = try drawn("tile \"Beside\" right of \(mark(q.a))", on: editor)
        expectEqual(rows(result).first?["did"], "created")
        let beside = try require(editor.document.shapes.first { $0.typed(as: Tile.self)?.props.label == "Beside" }?.box)
        expect(beside.minX >= (try require(editor.document[q.a]?.box)).maxX, "right of a")
        let inside = try drawn("tile \"Inner\" in \(mark(q.p))", on: editor)
        expectEqual(inside["on"]?["board"], .string(q.p.description), "drawn on the board the pocket holds")
        expect(editor.file[BoardID(owner: q.p)].shapes.contains { $0.typed(as: Tile.self)?.props.label == "Inner" }, "on P's board")
        expectEqual(try refused("tile \(mark(q.a)) right of \(mark(q.a))", on: editor).reason, "circular")
        expectEqual(try refused("tile \"New\" in \(mark(q.a))", on: editor).reason, "cannot_contain")
    },
    test("an id that names no shape is unknown_id, at its line, with nothing drawn; a malformed one is not_an_id") {
        let q = Quay()
        let editor = try q.editor()
        let nobody = mark(ShapeID())
        let before = editor.document
        for script in ["edge \"Hub\" -> \(nobody)", "edge \(nobody) -> \"Hub\"", "delete \(nobody)", "delete edge \(nobody) -> \"Hub\"",
                       "tile \(nobody)", "tile \"New\" right of \(nobody)", "tile \"New\" in \(nobody)"] {
            let error = try refused("tile \"Fine\"\n" + script, on: editor)
            expectEqual(error.reason, "unknown_id", script)
            expectEqual(error.data?["line"], 2, script)
        }
        let one = try refused("edge \"Hub\" -> \(nobody)", on: editor)
        expectEqual(one.message, "there's no shape with the id \(nobody)")
        expectEqual(one.hint, "it may have been deleted: run the query that gave it again")
        expectEqual(editor.document, before, "nothing drawn")
        expectEqual(try refused("edge \"Hub\" -> #nope", on: editor).reason, "not_an_id")
        expectEqual(try refused("delete #12", on: editor).reason, "not_an_id")
    },
    test("an id names only a shape a title could: an arrow's, and a pill's, are refused with invalid_value, and no arrow is matched through them") {
        let q = Quay()
        let editor = try q.editor()
        _ = try drawn("edge \"Hub\" -> \"Deep\"", on: editor)
        let relay = try require(editor.relays().first)
        for id in [q.tie, relay.id] {
            for script in ["edge \"Hub\" -> \(mark(id))", "delete \(mark(id))", "tile \"New\" right of \(mark(id))", "tile \"New\" in \(mark(id))"] {
                expectEqual(try refused(script, on: editor).reason, "invalid_value", script)
            }
        }
        expectEqual(try refused("edge \"Hub\" -> \(mark(q.tie))", on: editor).message, "\(mark(q.tie)) is a link, which a script can't name")
        expectEqual(editor.linkEnds().count, 2, "the tie and the arrow into Hub's relay, nothing more")
    },
    test("an id of a shape the script deletes names no shape once it has") {
        let q = Quay()
        let editor = try q.editor()
        let gone = try refused("delete \(mark(q.a))\nedge \"Hub\" -> \(mark(q.a))", on: editor)
        expectEqual(gone.reason, "unknown_id")
        expectEqual(gone.message, "an edge is drawn to \(mark(q.a)), which this script deletes")
        expectEqual(gone.data?["line"], 2)
        let restated = try refused("tile \(mark(q.a)) size: 100x60\ndelete \(mark(q.a))", on: editor)
        expectEqual(restated.reason, "unknown_id", "a delete comes first, whatever the order")
    },
    test("a shape on another board: an edge to its id goes through a relay, called what Mentions calls the shape, as an edge to a title does") {
        let q = Quay()
        let editor = try q.editor([Quay.labels])
        let result = try drawn("edge \(mark(q.a)) -> \(mark(q.far))", on: editor)
        let relay = try require(editor.relays().first)
        expectEqual(relay.props.stands.map(\.shape), [q.far])
        expectEqual(relay.props.says, "tile at 150", "the label the maker is handed: what Mentions would call it")
        expectEqual(rows(result).map { $0["did"] }, ["created", "connected"])
        expectEqual(rows(result)[0]["id"], .string(relay.id.description))
        expectEqual(rows(result)[1], ["line": 1, "did": "connected", "kind": "link", "from": .string(mark(q.a)), "to": .string(mark(q.far)), "via": "relay",
                                     "fromId": .string(q.a.description), "toId": .string(q.far.description)])
        let again = try drawn("edge \(mark(q.a)) -> \(mark(q.far))", on: editor)
        expectEqual(rows(again).map { $0["did"] }, ["unchanged"], "found where the relay is")
        expectEqual(editor.relays().count, 1)
        // For anything else but an edge, a shape on another board is where the run draws, as a title's is; two boards are several_boards.
        let there = try drawn("tile \"Near\" right of \(mark(q.far))", on: editor)
        expectEqual(there["on"]?["board"], .string(q.p.description))
        expectEqual(try refused("tile \"New\" right of \(mark(q.far))\ntile \"Other\" right of \"Hub\"", on: editor).reason, "several_boards")
        expectEqual(try refused("delete \(mark(q.far))\ndelete \(mark(q.a))", on: editor).reason, "several_boards")
    },
    test("without a plugin that says what a shape with no title is called, the pill is called by its kind's name, and the id is a pill's label nowhere else") {
        let q = Quay()
        let editor = try q.editor()
        _ = try drawn("edge \(mark(q.a)) -> \(mark(q.far))", on: editor)
        let says = try require(editor.relays().first?.props.says)
        expect(says.hasPrefix("Untitled "), says)
        expect(!says.contains("#"), says)
    },
    test("share: may name its host by id") {
        let q = Quay()
        let editor = try q.editor()
        let result = try drawn("""
            edge \(mark(q.a)) -> "Deep"
            edge "Hub" -> "Deep" share: \(mark(q.a))
            """, on: editor)
        expectEqual(editor.relays().count, 1, "one relay for Deep")
        let linked = rows(result).filter { $0["did"] == "connected" }
        expectEqual(linked.last?["shared"], true)
        expectEqual(linked.last?["sharedWith"], .string(mark(q.a)), "the host as the row calls it: it has no title")
        let again = try drawn("""
            edge \(mark(q.a)) -> "Deep"
            edge "Hub" -> "Deep" share: \(mark(q.a))
            """, on: editor)
        expectEqual(rows(again).map { $0["did"] }, ["unchanged", "unchanged"])
        expectEqual(rows(again).last?["sharedWith"], .string(mark(q.a)))
    },
    test("a dry run's created row has no id, a real run's has; restated rows have it either way; one undo takes the run back") {
        let q = Quay()
        let editor = try q.editor()
        let script = "tile \"Dock\" below \(mark(q.b))\ntile \(mark(q.a)) right of \"Hub\""
        let placed = editor.document[q.a]?.box
        let dry = try drawn(script, on: editor, ["--dry-run"])
        expectEqual(rows(dry).map { $0["did"] }, ["created", "moved"])
        expectEqual(rows(dry)[0]["id"], nil, "the shape it would make has no id yet")
        expectEqual(rows(dry)[1]["id"], .string(q.a.description))
        let real = try drawn(script, on: editor)
        let made = try require(editor.document.shapes.first { $0.typed(as: Tile.self)?.props.label == "Dock" })
        expectEqual(rows(real)[0]["id"], .string(made.id.description))
        editor.undo()
        expectEqual(editor.document[made.id], nil, "one undo step takes the shape back")
        expectEqual(editor.document[q.a]?.box, placed, "and the move")
    },
    test("two shapes with one title, each restated by its own id, are two shapes: both move, and both can be retitled in one run") {
        let w = Twins()
        let editor = try w.editor()
        let moved = try drawn("tile \(mark(w.t1)) below \"Hub\"\ntile \(mark(w.t2)) right of \"Hub\"", on: editor)
        expectEqual(rows(moved).map { $0["did"] }, ["moved", "moved"])
        let renamed = try drawn("tile \(mark(w.t1)) title: \"Twin 1\"\ntile \(mark(w.t2)) title: \"Twin 2\"", on: editor)
        expectEqual(rows(renamed).map { $0["did"] }, ["renamed", "renamed"])
        expectEqual(Set(editor.document.shapes.compactMap { $0.typed(as: Tile.self)?.props.label }), ["Twin 1", "Twin 2", "Hub", ""])
    },
    test("restating one of two shapes called the same by its id does not make their title name it for a later statement of the run") {
        let w = Twins()
        let editor = try w.editor()
        expectEqual(try refused("edge \"Hub\" -> \"Twin\"", on: editor).reason, "ambiguous_title")
        let after = try refused("tile \(mark(w.t1)) below \"Hub\"\nedge \"Hub\" -> \"Twin\"", on: editor)
        expectEqual(after.reason, "ambiguous_title", "two shapes are still called Twin")
        // A title only one shape has still names it, and an id of it is the same shape.
        expectEqual(try refused("tile \(mark(w.hub)) right of \"Twin\"", on: editor).reason, "ambiguous_title")
        expectEqual(try refused("tile \(mark(w.hub)) size: 100x60\ntile \"Hub\" size: 90x60", on: editor).reason, "duplicate")
    },
    test("an id that names a shape on a deleted subboard's board names no shape once the run deletes it") {
        let q = Quay()
        let editor = try q.editor()
        for script in ["delete \"P\"\nedge \(mark(q.a)) -> \(mark(q.far))", "delete \"P\"\ndelete edge \(mark(q.a)) -> \(mark(q.far))"] {
            let error = try refused(script, on: editor)
            expectEqual(error.reason, "unknown_id", script)
            expectEqual(error.data?["line"], 2, script)
        }
        expect(editor.document[q.p] != nil, "nothing was deleted")
    },
    test("share: names its host by an id that is checked as an edge's end is: no shape, an arrow, and a shape of another board are refused") {
        let q = Quay()
        let editor = try q.editor()
        let nobody = mark(ShapeID())
        let cases: [(String, String)] = [(nobody, "unknown_id"), (mark(q.tie), "invalid_value"), (mark(q.far), "several_boards")]
        for (host, reason) in cases {
            let error = try refused("edge \"Hub\" -> \"Deep\" share: \(host)", on: editor)
            expectEqual(error.reason, reason, host)
            expectEqual(error.data?["line"], 1, host)
        }
        expectEqual(editor.relays().count, 0, "nothing drawn")
    },
    test("an untitled shape a run brings an issue to is named in the warning by its id, which a later script can name it by") {
        let q = Quay()
        let crowd = Crowd()
        let editor = try q.editor([crowdPlugin(crowd)])
        crowd.editor = editor
        let said = messages(try drawn("edge \"Hub\" -> \(mark(q.b))", on: editor))
        let crowded = try require(said.first { $0.contains("links") }, "a crowded warning: \(said)")
        expect(crowded.hasPrefix("\(mark(q.b)): "), "named by its id: \(crowded)")
    },
    test("the hint for an id the script deletes does not say to delete it later, since a delete is done first") {
        let q = Quay()
        let editor = try q.editor()
        let error = try refused("edge \(mark(q.a)) -> \(mark(q.far))\ndelete \"P\"", on: editor)
        expectEqual(error.reason, "unknown_id")
        expectEqual(error.hint, "leave it out, or leave the delete out: deletes are done before the statements that name shapes")
    },
])

/// Two tiles called the same, one with no title and a third, on the root.
@MainActor private struct Twins {
    let t1 = ShapeID(), t2 = ShapeID(), a = ShapeID(), hub = ShapeID()

    func editor() throws -> CanvasEditor {
        let editor = try drawEditor([TopologyPlugin(), PocketsPlugin(), namedPockets, relaysPlugin()])
        func tile(_ id: ShapeID, _ label: String, x: CGFloat, y: CGFloat) -> AnyShapeRecord {
            AnyShapeRecord(ShapeRecord(id: id, Tile(CGRect(x: x, y: y, width: 120, height: 80), label: label)))
        }
        editor.replaceFile(with: CanvasFile(root: CanvasDocument(shapes: [tile(t1, "Twin", x: 0, y: 0), tile(t2, "Twin", x: 300, y: 0),
                                                                          tile(a, "", x: 0, y: 300), tile(hub, "Hub", x: 600, y: 0)]), children: [:]))
        return editor
    }
}
