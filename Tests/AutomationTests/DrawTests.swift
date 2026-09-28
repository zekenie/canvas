import Automation
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CoreGraphics
import Foundation
import Geometry
import TestKit

// `canvas draw` over fixtures: the editor's view is (100, 100) to (900, 700), its middle
// (500, 400); a card is 100 × 60, a tile 120 × 80; a normal gap is 80.

@MainActor let drawingTests = Suite("Drawing", [
    test("an untitled shape alone lands in the middle of the view; the result says what and where") {
        let editor = try drawEditor()
        let result = try drawn("card", on: editor)
        expectEqual(rows(result), [["line": 1, "did": "created", "kind": "card", "title": "Card, 100 × 60", "at": [[450, 370], [100, 60]],
                                    "inView": true]])
        expectEqual(result["warnings"], [])
        expectEqual(result["dryRun"], nil)
        expectEqual(editor.document.shapes.count, 1)
        expectEqual(editor.revision, 1)
    },
    test("titled shapes placed against one another, drawn together in the middle of the view") {
        let editor = try drawEditor()
        let result = try drawn(threeShapes, on: editor)
        expectEqual(rows(result), [
            ["line": 1, "did": "created", "kind": "tile", "title": "Hub", "at": [[340, 290], [120, 80]], "inView": true],
            ["line": 2, "did": "created", "kind": "tile", "title": "East", "at": [[540, 290], [120, 80]], "inView": true],
            ["line": 3, "did": "created", "kind": "card", "title": "AB", "at": [[350, 450], [100, 60]], "inView": true],
        ])
        expectEqual(shape("Hub", in: editor)?.typed(as: Tile.self)?.props.label, "Hub")
        expectEqual(shape("AB", in: editor)?[Nickname.self], "AB")
        expectEqual(editor.revision, 1, "one commit")
    },
    test("the script can come as the positional argument, or from standard input as -") {
        let editor = try drawEditor()
        expectEqual(rows(try run(["draw", "tile"], on: editor).get()).first?["did"], "created")
        expectEqual(rows(try run(["draw", "-"], on: editor, input: "tile right of board\ncard below board\n").get()).map { $0["kind"] }, ["tile", "card"])
        expectEqual(editor.document.shapes.count, 3)
    },
    test("a statement about a title the board has changes that shape: what it says, and where, on the axis it speaks for") {
        let editor = try drawEditor()
        _ = try drawn(threeShapes, on: editor)
        let revision = editor.revision
        expectEqual(rows(try drawn(#"tile "East" finish: glossy"#, on: editor)),
                    [["line": 1, "did": "updated", "kind": "tile", "title": "East", "at": [[540, 290], [120, 80]], "inView": true]])
        expectEqual(shape("East", in: editor)?.typed(as: Tile.self)?.props.finish, .glossy)
        // Level with AB's middle (480), and where it was across.
        expectEqual(rows(try drawn(#"tile "East" level with "AB""#, on: editor)).first?["at"], [[540, 440], [120, 80]])
        expectEqual(rows(try drawn(#"tile "East" level with "AB""#, on: editor)).first?["did"], "unchanged")
        expectEqual(editor.revision, revision + 2, "a run that changes nothing commits nothing")
        expectEqual(editor.document.shapes.count, 3)
    },
    test("a script run twice changes nothing the second time") {
        let editor = try drawEditor()
        _ = try drawn(threeShapes, on: editor)
        let revision = editor.revision
        let again = try drawn(threeShapes, on: editor)
        expectEqual(rows(again).map { $0["did"] }, ["unchanged", "unchanged", "unchanged"])
        expectEqual(rows(again).map { $0["at"] }, [[[340, 290], [120, 80]], [[540, 290], [120, 80]], [[350, 450], [100, 60]]])
        expectEqual(editor.revision, revision)
        expectEqual(editor.document.shapes.count, 3)
    },
    test("a value written without what reading it makes afresh (an item's id) is unchanged when the shape has it; changed, it's replaced") {
        let editor = try drawEditor()
        let script = #"tile "Hub" steps: [{"text": "Plan"}, {"text": "Build"}]"#
        _ = try drawn(script, on: editor)
        let steps = try require(shape("Hub", in: editor)?[Steps.self])
        expectEqual(steps.map(\.text), ["Plan", "Build"])
        let revision = editor.revision
        expectEqual(rows(try drawn(script, on: editor)).map { $0["did"] }, ["unchanged"])
        expectEqual(editor.revision, revision)
        expectEqual(shape("Hub", in: editor)?[Steps.self], steps, "the same ids")
        let fewer = try drawn(#"tile "Hub" steps: [{"text": "Plan"}]"#, on: editor)
        expectEqual(rows(fewer).map { $0["did"] }, ["updated"])
        expectEqual(shape("Hub", in: editor)?[Steps.self]?.map(\.text), ["Plan"])
        let unchanged = try drawn(#"tile "Hub" steps: [{"text": "Plan"}] finish: matte"#, on: editor)
        expectEqual(rows(unchanged).map { $0["did"] }, ["unchanged"], "matte, as it was")
    },
    test("title: renames; the next run knows the shape by its new title") {
        let editor = try drawEditor()
        _ = try drawn(threeShapes, on: editor)
        expectEqual(rows(try drawn(#"tile "East" title: "West""#, on: editor)),
                    [["line": 1, "did": "renamed", "kind": "tile", "title": "West", "was": "East", "at": [[540, 290], [120, 80]], "inView": true]])
        expectEqual(shape("West", in: editor)?.typed(as: Tile.self)?.props.label, "West")
        expectEqual(rows(try drawn(#"tile "West" finish: glossy"#, on: editor)).first?["did"], "updated")
        let taken = try refused(#"tile "Hub" title: "West""#, on: editor)
        expectEqual(taken.reason, "duplicate")
        expectEqual(taken.message, #""West" is taken: the board has a shape called that"#)
        let new = try refused(#"tile "New" title: "Old""#, on: editor)
        expectEqual(new.reason, "unsupported")
        expectEqual(new.hint, #"the title goes after the kind, in quotes: tile "Old""#)
        // The rename is for the next run: this one still knows it by its old title.
        let both = try drawn(#"""
        tile "Hub" title: "Core"
        tile "North" above "Hub"
        """#, on: editor)
        expectEqual(rows(both).map { $0["did"] }, ["renamed", "created"])
    },
    test("a title worked out from a shape names it, and a change that would change that title is refused") {
        let editor = try drawEditor()
        _ = try drawn("card", on: editor)
        let renames = try refused(#"card "Card, 100 × 60" size: 200x100"#, on: editor)
        expectEqual(renames.reason, "renames")
        expectEqual(renames.message, #"size: 200x100 would rename "Card, 100 × 60" to "Card, 200 × 100""#)
        let typo = try refused(#"tile "T" below "Card, 100 x 60""#, on: editor)
        expectEqual(typo.reason, "unknown_title")
        expectEqual(typo.hint, #"did you mean "Card, 100 × 60"?"#)
        // A statement about a title the board doesn't have makes a shape: a typo, most likely.
        let made = try drawn(#"card "Card, 100 x 60" text: hi"#, on: editor, ["--dry-run"])
        expectEqual(rows(made).first?["did"], "created")
        expectEqual(messages(made).first, #"created "Card, 100 x 60"; the board has "Card, 100 × 60" — to change that one, write its title exactly"#)
        let named = try drawn(#"card "Card, 100 × 60" title: "Ace""#, on: editor)
        expectEqual(rows(named).first?["was"], "Card, 100 × 60")
        expectEqual(rows(named).first?["title"], "Ace")
        expectEqual(rows(try drawn(#"card "Ace" size: 200x100"#, on: editor)).first?["did"], "moved")
    },
    test("delete edge after a delete of one of its ends asks for what the delete already does, as the other way round") {
        for (lines, gone) in [([#"delete "Hub""#, #"delete edge "Hub" -> "AB""#], "Hub"), ([#"delete edge "Hub" -> "AB""#, #"delete "Hub""#], "Hub"),
                              ([#"delete "AB""#, #"delete edge "AB" <-> "Hub""#], "AB")] {
            let editor = try drawEditor()
            _ = try drawn(threeShapes + "\n" + #"edge "Hub" -> "AB""#, on: editor)
            let result = try drawn(lines.joined(separator: "\n"), on: editor)
            expectEqual(rows(result).map { $0["did"] }, ["deleted", "deleted"], "\(lines)")
            expectEqual(links(in: editor), [], "\(lines)")
            expect(shape(gone, in: editor) == nil, "\(lines)")
            expectEqual(editor.document.shapes.count, 2, "\(lines)")
        }
        // One that names no edge drawn still says so.
        let editor = try drawEditor()
        _ = try drawn(threeShapes + "\n" + #"edge "Hub" -> "AB""#, on: editor)
        let none = try refused("delete \"Hub\"\ndelete edge \"Hub\" -> \"East\"", on: editor)
        expectEqual(none.reason, "nothing_to_delete")
        expectEqual(none.message, #"nothing is drawn from one to the other of "Hub" -> "East""#)
    },
    test("a delete removes the shape and every connection with an end on it; delete edge removes the connections between two") {
        let editor = try drawEditor()
        _ = try drawn(threeShapes + #"""

        edge "Hub" -> "East"
        edge "AB" -> "Hub"
        edge "East" -> "AB"
        """#, on: editor)
        expectEqual(links(in: editor), ["Hub -> East", "AB -> Hub", "East -> AB"])
        expectEqual(rows(try drawn(#"delete "Hub""#, on: editor)), [
            ["line": 1, "did": "deleted", "kind": "tile", "title": "Hub"],
            ["line": 1, "did": "deleted", "kind": "link", "from": "Hub", "to": "East"],
            ["line": 1, "did": "deleted", "kind": "link", "from": "AB", "to": "Hub"],
        ])
        expectEqual(links(in: editor), ["East -> AB"])
        expectEqual(rows(try drawn(#"delete edge "East" -> "AB""#, on: editor)),
                    [["line": 1, "did": "deleted", "kind": "link", "from": "East", "to": "AB"]])
        expectEqual(links(in: editor), [])
        expectEqual(try refused(#"delete edge "East" -> "AB""#, on: editor).reason, "nothing_to_delete")
        let missing = try refused(#"delete "Hub""#, on: editor)
        expectEqual(missing.reason, "unknown_title")
        expectEqual(editor.document.shapes.count, 2)
    },
    test("a delete takes a connection with only one end on the shape too, its other end free") {
        let editor = try drawEditor()
        _ = try drawn(threeShapes + "\n" + #"edge "Hub" -> "East""#, on: editor)
        let hub = try require(shape("Hub", in: editor)), east = try require(shape("East", in: editor))
        let loose = AnyShapeRecord(ShapeRecord(Link(from: hub.id, to: nil)))
        let elsewhere = AnyShapeRecord(ShapeRecord(Link(from: nil, to: east.id)))
        editor.transact {
            $0.insert(loose)
            $0.insert(elsewhere)
        }
        expectEqual(rows(try drawn(#"delete "Hub""#, on: editor)), [
            ["line": 1, "did": "deleted", "kind": "tile", "title": "Hub"],
            ["line": 1, "did": "deleted", "kind": "link", "from": "Hub", "to": "East"],
            ["line": 1, "did": "deleted", "kind": "link"],
        ])
        expectEqual(editor.document[loose.id], nil)
        expect(editor.document[elsewhere.id] != nil, "one on another shape stays")
    },
    test("a delete and a statement for the same title in one script: the delete first, then it's drawn anew, of any kind") {
        let editor = try drawEditor()
        _ = try drawn(threeShapes, on: editor)
        let redrawn = try drawn(#"""
        delete "AB"
        tile "AB" below "Hub"
        """#, on: editor)
        expectEqual(rows(redrawn).map { $0["did"] }, ["deleted", "created"])
        expectEqual(shape("AB", in: editor)?.kind, Tile.kind)
        let gone = try refused(#"""
        delete "AB"
        tile "Q" below "AB"
        """#, on: editor)
        expectEqual(gone.reason, "unknown_title")
        expectEqual(gone.message, #""Q" is placed against "AB", which this script deletes"#)
    },
])

@MainActor let edgeDrawingTests = Suite("Drawing edges", [
    test("an edge connects two shapes; the same statement again changes nothing, and one that says more changes only that") {
        let log = EdgeLog()
        let editor = try drawEditor(log: log)
        _ = try drawn(threeShapes, on: editor)
        let hub = try require(shape("Hub", in: editor)), east = try require(shape("East", in: editor))
        expectEqual(rows(try drawn(#"edge "Hub" -> "East""#, on: editor)),
                    [["line": 1, "did": "connected", "kind": "link", "from": "Hub", "to": "East"]])
        let request = try require(log.requests.last)
        expectEqual(request, EdgeRequest(from: hub.id, to: east.id, fromName: #""Hub""#, toName: #""East""#, written: #""Hub" -> "East""#))
        expectEqual(log.existing.last, .some(nil))
        let revision = editor.revision
        expectEqual(rows(try drawn(#"edge "Hub" -> "East""#, on: editor)).first?["did"], "unchanged")
        expectEqual(editor.revision, revision)
        expectEqual(rows(try drawn(#"edge "Hub" -> "East" tone: warm"#, on: editor)),
                    [["line": 1, "did": "reconnected", "kind": "link", "from": "Hub", "to": "East", "tone": "warm"]])
        expectEqual(rows(try drawn(#"edge "East" <- "Hub" tone: warm"#, on: editor)).first?["did"], "unchanged", "the same edge, written the other way")
        expectEqual(rows(try drawn(#"edge "Hub" <-> "East" tone: warm"#, on: editor)).first?["did"], "reconnected")
        // One drawn either way is found either way, and asked for the way it's drawn.
        expectEqual(rows(try drawn(#"edge "East" <-> "Hub""#, on: editor)).first?["did"], "unchanged")
        expectEqual(log.requests.last?.from, hub.id)
        expectEqual(links(in: editor), ["Hub -> East"])
    },
    test("an edge may end on a shape the same script draws; sides are passed on, and one facing away is said") {
        let log = EdgeLog()
        let editor = try drawEditor(log: log)
        _ = try drawn(threeShapes, on: editor)
        let result = try drawn(#"""
        tile "South" below "East"
        edge "East" -> "South"
        edge "AB" -> "East" from: left to: bottom
        """#, on: editor)
        expectEqual(rows(result).map { $0["did"] }, ["created", "connected", "connected"])
        expectEqual(links(in: editor), ["East -> South", "AB -> East"])
        expectEqual(log.requests.last?.fromSide, .left)
        expectEqual(log.requests.last?.toSide, .bottom)
        expectEqual(messages(result),
                    [#"from: left: "East" is right of "AB", so the line leaves "AB" by its right side — name a side that faces "East", or leave from: out"#])
        let arriving = try drawn(#"edge "AB" -> "East" to: top"#, on: editor)
        expectEqual(messages(arriving),
                    [#"to: top: "AB" is below "East", so the line arrives at "East" on its bottom side — name a side that faces "AB", or leave to: out"#])
    },
    test("what the edge maker refuses is refused on the edge's line, and nothing else the script drew is kept") {
        let editor = try drawEditor()
        _ = try drawn(threeShapes, on: editor)
        let icy = try refused(#"""
        tile "South" below "East"
        edge "Hub" -> "South" tone: icy
        """#, on: editor)
        expectEqual(icy.reason, "invalid_value")
        expectEqual(icy.message, "a link can't be icy")
        expectEqual(icy.data?["line"], 2)
        expectEqual(icy.data?["statement"], #"edge "Hub" -> "South" tone: icy"#)
        expectEqual(shape("South", in: editor), nil)
        expectEqual(try refused(#"edge "Hub" -> "Hub""#, on: editor).reason, "cannot_connect")
        let unknown = try refused(#"edge "Hub" -> "East" colour: red"#, on: editor)
        expectEqual(unknown.reason, "unknown_attribute")
        expectEqual(unknown.hint, "an edge takes from:, to:, tone:")
        expectEqual(try refused(#"edge "Hub" -> "Nope""#, on: editor).reason, "unknown_title")
        expectEqual(try refused(#"""
        edge "Hub" -> "East"
        edge "East" <-> "Hub"
        """#, on: editor).reason, "duplicate")
    },
    test("two connections drawn between two shapes are ambiguous") {
        let editor = try drawEditor()
        _ = try drawn(threeShapes, on: editor)
        let hub = try require(shape("Hub", in: editor)), east = try require(shape("East", in: editor))
        link(hub, east, in: editor)
        link(hub, east, in: editor)
        let ambiguous = try refused(#"edge "Hub" -> "East""#, on: editor)
        expectEqual(ambiguous.reason, "ambiguous_edge")
        expectEqual(ambiguous.message, #""Hub" -> "East" is drawn 2 times"#)
        expectEqual(ambiguous.hint, #"write delete edge "Hub" -> "East" above this line to replace them"#)
        let replaced = try drawn(#"""
        delete edge "Hub" -> "East"
        edge "Hub" -> "East" tone: cool
        """#, on: editor)
        expectEqual(rows(replaced).map { $0["did"] }, ["deleted", "deleted", "connected"])
        expectEqual(links(in: editor), ["Hub -> East"])
    },
])

@MainActor let drawRunTests = Suite("Drawing runs", [
    test("one commit per run; nothing at all when anything's wrong") {
        let editor = try drawEditor()
        _ = try drawn(threeShapes, on: editor)
        let revision = editor.revision
        let wrong = try refused(#"""
        tile "A" below "AB"
        tile "B" right of "Nope"
        """#, on: editor)
        expectEqual(wrong.reason, "unknown_title")
        expectEqual(wrong.data?["line"], 2)
        expectEqual(wrong.data?["statement"], #"tile "B" right of "Nope""#)
        expectEqual(editor.revision, revision)
        expectEqual(editor.document.shapes.count, 3)
    },
    test("a dry run says what the run would, and changes nothing") {
        let editor = try drawEditor()
        _ = try drawn(threeShapes, on: editor)
        let revision = editor.revision
        let script = #"""
        tile "South" below "East"
        edge "East" -> "South"
        tile "Hub" finish: glossy
        """#
        let dry = try drawn(script, on: editor, ["--dry-run"])
        expectEqual(dry["dryRun"], true)
        expectEqual(editor.revision, revision)
        expectEqual(editor.document.shapes.count, 3)
        let real = try drawn(script, on: editor)
        expectEqual(real["dryRun"], nil)
        expectEqual(rows(real), rows(dry))
        expectEqual(editor.document.shapes.count, 5)
        // A dry run that would fail fails the same.
        expectEqual(try refused(#"tile "Hub" rank: 0.5"#, on: editor, ["--dry-run"]).reason, "invalid_value")
    },
    test("problems that don't depend on one another are all found, each with its line and statement; the first leads") {
        let editor = try drawEditor()
        _ = try drawn(threeShapes, on: editor)
        let error = try refused(#"""
        crad "A"
        tile "B" colr: red
        tile "C" right of "Nope"
        tile "D" finish: shiny
        """#, on: editor)
        expectEqual(error.reason, "unknown_kind")
        expectEqual(error.message, "there's no kind of shape called crad")
        expectEqual(error.hint, "did you mean card? the kinds drawn here: card, tile")
        expectEqual(error.data?["line"], 1)
        expectEqual(error.data?["statement"], #"crad "A""#)
        let all = error.data?["errors"]?.arrayValue ?? []
        expectEqual(all.map { $0["reason"] }, ["unknown_kind", "unknown_attribute", "unknown_title", "invalid_value"])
        expectEqual(all.map { $0["line"] }, [1, 2, 3, 4])
        expectEqual(all[1]["message"], #""B" is a tile and has colr:, which isn't one of a tile's attributes"#)
        expectEqual(all[1]["hint"], "a tile takes size:, gap:, overlap:, style:, title:, finish:, pinned:, rank:, steps:")
        expectEqual(all[3]["hint"], "finish: takes matte|glossy")
        // What follows from a problem isn't another: "E" isn't drawn, so nothing says it's missing.
        let one = try refused(#"""
        crad "E"
        tile "F" right of "E"
        """#, on: editor)
        expectEqual(one.data?["errors"], nil)
        // Lines that can't be read are all found too.
        let unread = try refused(#"""
        tile "A" rigth of "Hub"
        tile "B
        """#, on: editor)
        expectEqual(unread.reason, "syntax")
        expectEqual(unread.data?["errors"]?.arrayValue?.count, 2)
    },
    test("a drag under way leaves the board alone; an edit under way ends first, if the script changes that shape") {
        let editor = try drawEditor()
        _ = try drawn(threeShapes, on: editor)
        editor.session = TranslatingSession(ids: [], from: .zero, in: editor)
        let busy = try refused("tile", on: editor)
        expectEqual(busy.reason, "busy")
        expectEqual(busy.message, "someone is dragging on this board")
        editor.session = nil
        let card = try require(shape("AB", in: editor))
        expect(editor.beginEditing(card.id))
        _ = try drawn(#"tile "Z" right of "East""#, on: editor)
        expectEqual(editor.editingShapeID, card.id, "the script doesn't touch it")
        _ = try drawn(#"card "AB" text: hi"#, on: editor, ["--dry-run"])
        expectEqual(editor.editingShapeID, card.id, "a dry run changes nothing")
        _ = try drawn(#"card "AB" text: hi"#, on: editor)
        expectEqual(editor.editingShapeID, nil)
        expectEqual(shape("AB", in: editor)?.typed(as: Card.self)?.props.text, "hi")
    },
    test("an edit under way isn't ended by a run that fails, or that leaves the shape as it is") {
        let editor = try drawEditor()
        _ = try drawn(threeShapes, on: editor)
        let card = try require(shape("AB", in: editor))
        expect(editor.beginEditing(card.id))
        let failed = try refused("card \"AB\" text: hi\ntile \"U1\"\ntile \"U2\"", on: editor)
        expectEqual(failed.reason, "unplaced")
        expectEqual(editor.editingShapeID, card.id, "the run failed while placing")
        // An edge that can't be drawn is found only as the run's applied.
        let edge = try refused("card \"AB\" text: hi\nedge \"Hub\" -> \"AB\" tone: icy", on: editor)
        expectEqual(edge.reason, "invalid_value")
        expectEqual(editor.editingShapeID, card.id, "the run failed while applying")
        expectEqual(shape("AB", in: editor)?.typed(as: Card.self)?.props.text, "")
        expectEqual(links(in: editor), [])
        expectEqual(rows(try drawn(#"card "AB" below "Hub""#, on: editor)).first?["did"], "unchanged")
        expectEqual(editor.editingShapeID, card.id, "the run leaves it as it is")
        _ = try drawn(#"card "AB" text: hi"#, on: editor)
        expectEqual(editor.editingShapeID, nil)
    },
    test("a read-only shape is refused only a change that would happen: unchanged is fine, and so is what makes it writable") {
        let editor = try drawEditor([FreezingPlugin()])
        _ = try drawn(threeShapes + "\n" + #"edge "Hub" -> "AB""#, on: editor)
        let east = try require(shape("East", in: editor))
        editor.freeze([east.id])
        let refusedChange = try refused(#"tile "East" finish: glossy"#, on: editor)
        expectEqual(refusedChange.reason, "read_only")
        expectEqual(refusedChange.message, #""East" is read-only (locked, say), so it stays as it is"#)
        expectEqual(rows(try drawn(#"tile "East""#, on: editor)).first?["did"], "unchanged")
        expectEqual(rows(try drawn(#"tile "East" right of "Hub""#, on: editor)).first?["did"], "unchanged")
        let east2 = try refused(#"delete "East""#, on: editor)
        expectEqual(east2.reason, "read_only")
        expectEqual(east2.message, #""East" is read-only (locked, say), so it can't be deleted"#)
        expectEqual(rows(try drawn(#"tile "East" frozen: false finish: glossy"#, on: editor)).first?["did"], "updated")
        expectEqual(shape("East", in: editor)?.typed(as: Tile.self)?.props.finish, .glossy)
        let connection = try require(editor.document.shapes.first { $0.kind == Link.kind })
        editor.freeze([connection.id])
        expectEqual(try refused(#"edge "Hub" -> "AB" tone: warm"#, on: editor).reason, "read_only")
        expectEqual(rows(try drawn(#"edge "Hub" -> "AB""#, on: editor)).first?["did"], "unchanged")
        let hub = try refused(#"delete "Hub""#, on: editor)
        expectEqual(hub.reason, "read_only")
        expectEqual(hub.message, #"one of "Hub"'s connections is read-only (locked, say), so "Hub" can't be deleted with it"#)
        let edge = try refused(#"delete edge "Hub" -> "AB""#, on: editor)
        expectEqual(edge.reason, "read_only")
        expectEqual(edge.message, #"one of the connections delete edge "Hub" -> "AB" removes is read-only (locked, say), so it can't be deleted"#)
    },
    test("without a plugin that names shapes, titles can't be used; without one that makes edges, edges can't be drawn") {
        let bare = try makeEditor()
        expectEqual(rows(try drawn("tile", on: bare)).first?["title"], nil)
        expectEqual(try refused(#"tile "A""#, on: bare).reason, "no_names")
        expectEqual(try refused(#"tile right of "A""#, on: bare).reason, "no_names")
        expectEqual(try refused(#"delete "A""#, on: bare).reason, "no_names")
        expectEqual(try refused(#"edge "A" -> "B""#, on: bare).reason, "no_edges")
        let named = try makeEditor([namesPlugin()])
        _ = try drawn(threeShapes, on: named)
        expectEqual(try refused(#"edge "Hub" -> "East""#, on: named).reason, "no_edges")
        expectEqual(try refused(#"delete edge "Hub" -> "East""#, on: named).reason, "no_edges")
        expectEqual(rows(try drawn(#"delete "Hub""#, on: named)).count, 1)
    },
])

@MainActor let drawPlacingTests = Suite("Drawing: where shapes go", [
    test("view and board are boxes to place against: the window's part of the board, and every shape that stays") {
        let editor = try drawEditor()
        expectEqual(try refused(#"tile "X" right of board"#, on: editor).reason, "unknown_title")
        expectEqual(rows(try drawn(#"tile "Legend" inside view top-right"#, on: editor)).first?["at"], [[740, 140], [120, 80]])
        let column = try drawn(#"tile "Col" right of board"#, on: editor)
        expectEqual(rows(column).first?["at"], [[940, 140], [120, 80]])
        expectEqual(rows(column).first?["inView"], false)
        let windowless = try makeEditor(drawPlugins(), viewport: .zero)
        let noView = try refused(#"tile "X" inside view top-right"#, on: windowless)
        expectEqual(noView.reason, "no_view")
        let anchored = try drawn("tile", on: windowless)
        expectEqual(rows(anchored).first?["at"], [[40, 60], [120, 80]], "centered where the camera is")
        expectEqual(rows(anchored).first?["inView"], nil)
        expectEqual(anchored["warnings"], [])
    },
    test("a shape moved inside or on another paints above it; a new one drawn inside a new one goes in after it") {
        let editor = try drawEditor()
        let small = tile("Small", CGRect(x: 700, y: 500, width: 120, height: 80), in: editor)
        let zone = tile("Zone", CGRect(x: 0, y: 0, width: 600, height: 400), in: editor)
        expectEqual(rows(try drawn(#"tile "Small" inside "Zone" top-left"#, on: editor)).first?["at"], [[40, 40], [120, 80]])
        expect(try require(editor.document.index(of: small.id)) > require(editor.document.index(of: zone.id)), "above the zone")
        _ = try drawn(#"""
        tile "In" inside "Z2" top-left
        tile "Z2" size: 600x400 right of "Zone"
        """#, on: editor)
        let inner = try require(shape("In", in: editor)), outer = try require(shape("Z2", in: editor))
        expectEqual(inner.box, CGRect(x: 720, y: 40, width: 120, height: 80))
        expect(try require(editor.document.index(of: inner.id)) > require(editor.document.index(of: outer.id)), "above its zone")
    },
    test("a restated shape placed against one in a zone that paints above it is raised above the zone, as inside raises one") {
        // Drawn before the zone, the notes paint under it: the first is moved inside, the rest
        // against it.
        let editor = try drawEditor()
        let notes = ["Queue", "Worker", "Retry"].enumerated().map { index, title in
            tile(title, CGRect(x: 1000 + 200 * CGFloat(index), y: 500, width: 120, height: 80), in: editor)
        }
        let away = tile("Away", CGRect(x: 1000, y: 800, width: 120, height: 80), in: editor)
        let zone = tile("Backend", CGRect(x: 0, y: 0, width: 900, height: 320), in: editor)
        let result = try drawn(#"""
        tile "Queue" inside "Backend" top-left
        tile "Worker" right of "Queue"
        tile "Retry" right of "Worker" (gap: 440)
        """#, on: editor)
        expectEqual(rows(result).map { $0["did"] }, ["moved", "moved", "moved"])
        expectEqual(rows(result).map { $0["at"] }, [[[40, 40], [120, 80]], [[240, 40], [120, 80]], [[800, 40], [120, 80]]])
        expectEqual(messages(result), [#""Retry" hangs over the edge of "Backend" — make "Backend" bigger, or place "Retry" elsewhere"#])
        let zoneAt = try require(editor.document.index(of: zone.id))
        for note in notes {
            expect(try require(editor.document.index(of: note.id)) > zoneAt, "\(note.typed(as: Tile.self)!.props.label) is above the zone")
        }
        // Placed against one in the zone but landing clear of it, a shape stays where it paints.
        expectEqual(rows(try drawn(#"tile "Away" right of "Queue" (gap: 1500)"#, on: editor)).first?["did"], "moved")
        expect(try require(editor.document.index(of: away.id)) < require(editor.document.index(of: zone.id)), "still under the zone, which it isn't in")
    },
    test("a neighbor where a smaller shape lands is in the way, however much bigger: a zone holds what the shape is placed against") {
        let editor = try drawEditor()
        tile("A", CGRect(x: 0, y: 0, width: 200, height: 200), in: editor)
        tile("B", CGRect(x: 280, y: 0, width: 200, height: 200), in: editor)
        let result = try drawn(#"tile "R" right of "A""#, on: editor)
        expectEqual(rows(result).first?["at"], [[520, 60], [120, 80]])
        expectEqual(rows(result).first?["pushedPast"], ["B"])
        expectEqual(messages(result),
                    [#""R" was pushed right past "B" to keep clear of it, so it no longer sits against "A" — place it on another side, or say overlap: allow"#])
    },
    test("a restated shape lined up with one in the next column stays in its own: the region it already sits in is a zone") {
        let cases: [(String, JSON)] = [(#"tile "T1" level with "T5" top"#, [[50, 70], [200, 100]]),
                                       (#"tile "T1" top level with "T5""#, [[50, 120], [200, 100]])]
        for (script, at) in cases {
            let editor = try drawEditor()
            // Drawn before its column, the card paints under it until it's restated.
            let card = tile("T1", CGRect(x: 50, y: 300, width: 200, height: 100), in: editor)
            let column = tile("ColA", CGRect(x: 0, y: 0, width: 300, height: 1000), in: editor)
            tile("ColB", CGRect(x: 340, y: 0, width: 300, height: 1000), in: editor)
            tile("T5", CGRect(x: 390, y: 120, width: 200, height: 100), in: editor)
            let result = try drawn(script, on: editor)
            expectEqual(rows(result).first?["did"], "moved", script)
            expectEqual(rows(result).first?["at"], at, script)
            expectEqual(rows(result).first?["pushedPast"], nil, script)
            expectEqual(messages(result), [], script)
            expect(try require(editor.document.index(of: card.id)) > require(editor.document.index(of: column.id)), "above its column: \(script)")
        }
        // Lined up where it hangs over the column's edge, it's drawn, and said to.
        let editor = try drawEditor()
        tile("ColA", CGRect(x: 0, y: 0, width: 300, height: 1000), in: editor)
        tile("ColB", CGRect(x: 340, y: 0, width: 300, height: 1000), in: editor)
        tile("T1", CGRect(x: 50, y: 300, width: 200, height: 100), in: editor)
        tile("T5", CGRect(x: 390, y: 20, width: 200, height: 100), in: editor)
        let over = try drawn(#"tile "T1" level with "T5" top"#, on: editor)
        expectEqual(rows(over).first?["at"], [[50, -30], [200, 100]])
        expectEqual(messages(over).first, #""T1" hangs over the edge of "ColA" — make "ColA" bigger, or place "T1" elsewhere"#)
        // Moved from elsewhere onto a neighbor, a restated shape is pushed past it, as a new one is.
        let moved = try drawEditor()
        tile("A", CGRect(x: 0, y: 0, width: 200, height: 200), in: moved)
        tile("B", CGRect(x: 280, y: 0, width: 200, height: 200), in: moved)
        tile("R", CGRect(x: 1000, y: 1000, width: 120, height: 80), in: moved)
        let pushed = try drawn(#"tile "R" right of "A""#, on: moved)
        expectEqual(rows(pushed).first?["at"], [[520, 60], [120, 80]])
        expectEqual(rows(pushed).first?["pushedPast"], ["B"])
    },
    test("a shape placed in the view sits on a region that holds all the view, and one in the board's corner on a region that holds other shapes; one in the view's corner is still in the way") {
        let editor = try drawEditor()
        tile("Frame", CGRect(x: 0, y: 0, width: 2000, height: 2000), in: editor)
        let legend = try drawn(#"tile "Legend" inside view top-right"#, on: editor)
        expectEqual(rows(legend).first?["at"], [[740, 140], [120, 80]])
        expectEqual(rows(legend).first?["pushedPast"], nil)
        expectEqual(messages(legend), [])
        let key = try drawn(#"tile "Key" inside view top-left"#, on: editor)
        expectEqual(rows(key).first?["at"], [[140, 140], [120, 80]])
        expectEqual(messages(key), [])
        let crowded = try drawn(#"tile "Note" inside view top-right"#, on: editor)
        expectEqual(rows(crowded).first?["pushedPast"], ["Legend"])
        let framed = try drawEditor()
        tile("Frame", CGRect(x: 0, y: 0, width: 2000, height: 1200), in: framed)
        tile("A", CGRect(x: 100, y: 100, width: 120, height: 80), in: framed)
        let corner = try drawn(#"tile "Legend" inside board top-right"#, on: framed)
        expectEqual(rows(corner).first?["at"], [[1840, 40], [120, 80]])
        expectEqual(rows(corner).first?["pushedPast"], nil)
        expect(!messages(corner).contains { $0.contains("hangs over") || $0.contains("pushed") }, "\(messages(corner))")
        // A lone shape that's the whole board holds nothing else, so it's in the way, never drawn over.
        let lone = try drawEditor()
        tile("Only", CGRect(x: 0, y: 0, width: 600, height: 400), in: lone)
        let over = try refused(#"tile "Legend" inside board top-right"#, on: lone)
        expectEqual(over.reason, "no_room")
        expectEqual(over.message, #""Legend" is inside board top-right, and there's no room left in board clear of "Only""#)
    },
    test("a shape moved inside a shape above it and made read-only in the same statement is raised first; one read-only in place is left be") {
        let log = RefusalLog()
        let editor = try drawEditor([FreezingPlugin(log: log)])
        let small = tile("S", CGRect(x: 700, y: 500, width: 120, height: 80), in: editor)
        let zone = tile("Zone", CGRect(x: 0, y: 0, width: 600, height: 400), in: editor)
        expectEqual(rows(try drawn(#"tile "S" inside "Zone" top-left frozen: true"#, on: editor)).first?["did"], "moved")
        expect(try require(editor.document.index(of: small.id)) > require(editor.document.index(of: zone.id)), "above the zone")
        expectEqual(shape("S", in: editor)?[Frozen.self], true)
        expectEqual(log.refusals, [], "nothing tried to change a read-only shape")
        // Read-only, where it's placed, under a shape it's inside: restated, it's unchanged, and
        // nothing tries to raise it.
        let under = tile("T", CGRect(x: 1040, y: 40, width: 120, height: 80), in: editor)
        let lid = tile("Lid", CGRect(x: 1000, y: 0, width: 600, height: 400), in: editor)
        editor.freeze([under.id])
        expectEqual(rows(try drawn(#"tile "T" inside "Lid" top-left"#, on: editor)).first?["did"], "unchanged")
        expect(try require(editor.document.index(of: under.id)) < require(editor.document.index(of: lid.id)), "still under it")
        expectEqual(log.refusals, [])
    },
    test("a shape placed on one that's moved inside another paints above both, whichever line comes first") {
        let badgeLine = #"tile "Badge" on "R" top-right overlap: allow"#, rLine = #"tile "R" inside "Z" top-left"#
        for script in [[badgeLine, rLine], [rLine, badgeLine]] {
            let editor = try drawEditor()
            let badge = tile("Badge", CGRect(x: 1000, y: 600, width: 120, height: 80), in: editor)
            let r = tile("R", CGRect(x: 700, y: 500, width: 120, height: 80), in: editor)
            let z = tile("Z", CGRect(x: 0, y: 0, width: 600, height: 400), in: editor)
            expectEqual(rows(try drawn(script.joined(separator: "\n"), on: editor)).map { $0["did"] }, ["moved", "moved"])
            let order = [badge, r, z].map { editor.document.index(of: $0.id) ?? -1 }
            expect(order[0] > order[1] && order[1] > order[2], "\(script): Badge, R and Z are at \(order)")
        }
        // A new shape on a restated one, moved inside a new zone written after it.
        let editor = try drawEditor()
        tile("Hub", CGRect(x: 0, y: 0, width: 120, height: 80), in: editor)
        let r = tile("R", CGRect(x: 700, y: 500, width: 120, height: 80), in: editor)
        _ = try drawn(#"""
        tile "Badge" on "R" top-right overlap: allow
        tile "R" inside "Zone" top-left
        tile "Zone" size: 600x400 below board
        """#, on: editor)
        let order = [shape("Badge", in: editor), r, shape("Zone", in: editor)].map { $0.flatMap { editor.document.index(of: $0.id) } ?? -1 }
        expect(order[0] > order[1] && order[1] > order[2], "Badge, R and Zone are at \(order)")
    },
    test("the view is where the camera is headed: a drawing just after the view starts to glide lands in the view it glides to") {
        let editor = CanvasEditor(registry: try drawEditor().registry, scheduler: ManualScheduler())
        editor.viewportDidResize(to: CGSize(width: 800, height: 600))
        editor.camera = Camera(origin: CGPoint(x: 100, y: 100))
        editor.animateCamera(to: Camera(origin: CGPoint(x: 1100, y: 100)), duration: .milliseconds(320))
        expectEqual(editor.camera.origin, CGPoint(x: 100, y: 100), "still where it started")
        let legend = try drawn(#"tile "Legend" inside view top-right"#, on: editor)
        expectEqual(rows(legend).first?["at"], [[1740, 140], [120, 80]])
        expectEqual(rows(legend).first?["inView"], true)
        // The one unplaced shape goes in the middle of that view.
        expectEqual(rows(try drawn("card", on: editor)).first?["at"], [[1450, 370], [100, 60]])
    },
    test("an obstacle too big to file cell by cell is still in the way") {
        let editor = try drawEditor()
        tile("Hub", CGRect(x: 200, y: 300, width: 120, height: 80), in: editor)
        tile("Wall", CGRect(x: -150_000, y: 420, width: 300_000, height: 100), in: editor)
        let result = try drawn(#"tile "Below" below "Hub""#, on: editor)
        expectEqual(rows(result).first?["pushedPast"], ["Wall"])
        expectEqual(rows(result).first?["at"], [[200, 584], [120, 80]])
    },
    test("a shape resized where it stays, over another, is drawn, with a warning") {
        let editor = try drawEditor()
        tile("A", CGRect(x: 200, y: 300, width: 120, height: 80), in: editor)
        tile("B", CGRect(x: 400, y: 300, width: 120, height: 80), in: editor)
        let result = try drawn(#"tile "A" size: 300x80"#, on: editor)
        expectEqual(rows(result).first?["did"], "moved")
        expectEqual(rows(result).first?["at"], [[200, 300], [300, 80]])
        expectEqual(messages(result), [#""A" was resized where it is, and now overlaps "B" — place it to move it clear"#])
    },
    test("a corner of a shape that isn't a rectangle is on its outline; a rectangle's is its own") {
        let editor = try drawEditor()
        editor.transact { $0.insert(AnyShapeRecord(ShapeRecord(Disc(CGRect(x: 0, y: 0, width: 200, height: 200))))) }
        tile("Hub", CGRect(x: 400, y: 0, width: 120, height: 80), in: editor)
        // The circle's top-right, (170.7, 29.3), not its bounds' (200, 0).
        let at = try require(rows(try drawn(#"tile "Mark" on "Disc, 200 × 200" top-right"#, on: editor)).first?["at"]?.arrayValue)
        let origin = try require(at.first?.arrayValue?.compactMap(\.numberValue))
        expect(abs(origin[0] - (100 + 100 / 2.squareRoot() - 60)) < 1e-6 && abs(origin[1] - (100 - 100 / 2.squareRoot() - 40)) < 1e-6, "\(origin)")
        expectEqual(rows(try drawn(#"tile "Pin" on "Hub" top-right overlap: allow"#, on: editor)).first?["at"], [[460, -40], [120, 80]])
    },
])

@MainActor let drawWarningTests = Suite("Drawing: warnings", [
    test("what a check finds on a shape drawn is a warning with its line and severity; the shape's drawn anyway") {
        let editor = try drawEditor(checks: true)
        let result = try drawn(#"""
        tile "G" finish: glossy
        card "AB" below "G"
        card "Ok" text: hello right of "AB"
        """#, on: editor)
        expectEqual(result["warnings"], [
            ["line": 1, "message": #""G": A glossy tile glares."#, "severity": "error", "attribute": "finish"],
            ["line": 2, "message": #""AB": A card says nothing."#, "severity": "warning", "attribute": "text"],
        ])
        expectEqual(editor.document.shapes.count, 3)
        expectEqual(try drawn(#"card "AB""#, on: editor)["warnings"], [], "an unchanged shape isn't checked again")
    },
    test("without a plugin that checks, a shape past its schema's bounds is drawn, with a warning") {
        let editor = try drawEditor()
        let result = try drawn(#"card "Robert""#, on: editor)
        let warning = try require(result["warnings"]?.arrayValue?.first)
        expectEqual(warning["severity"], "warning")
        expectEqual(warning["attribute"], "nickname")
        expect(warning["message"]?.stringValue?.contains("at most 3") == true, "\(warning)")
    },
    test("a shape pushed past another to keep clear of it says what it was pushed past") {
        let editor = try drawEditor()
        tile("Hub", CGRect(x: 200, y: 300, width: 120, height: 80), in: editor)
        tile("Q", CGRect(x: 400, y: 300, width: 120, height: 80), in: editor)
        let result = try drawn(#"tile "Why" right of "Hub""#, on: editor)
        expectEqual(rows(result).first?["at"], [[560, 300], [120, 80]])
        expectEqual(rows(result).first?["pushedPast"], ["Q"])
        expectEqual(messages(result),
                    [#""Why" was pushed right past "Q" to keep clear of it, so it no longer sits against "Hub" — place it on another side, or say overlap: allow"#])
    },
    test("what a pushed shape no longer sits against is the placement the push loosened: the one holding it from the side it left") {
        let editor = try drawEditor()
        tile("Hub", CGRect(x: 200, y: 300, width: 120, height: 80), in: editor)
        tile("Q", CGRect(x: 400, y: 300, width: 120, height: 80), in: editor)
        tile("B", CGRect(x: 1000, y: 300, width: 120, height: 80), in: editor)
        let result = try drawn(#"tile "N" left of "B" right of "Hub" level with "Hub""#, on: editor)
        expectEqual(rows(result).first?["at"], [[560, 300], [120, 80]])
        expectEqual(messages(result),
                    [#""N" was pushed right past "Q" to keep clear of it, so it no longer sits against "Hub" — place it on another side, or say overlap: allow"#])
    },
    test("a shape that moves along with one pushed says which, and what that one went past; only the one pushed lists it in pushedPast") {
        // N is pushed right past Q1 and Q2; D, centered below it, goes along, still where it says.
        let editor = try drawEditor()
        tile("Hub", CGRect(x: 200, y: 300, width: 120, height: 80), in: editor)
        tile("Q1", CGRect(x: 400, y: 300, width: 120, height: 80), in: editor)
        tile("Q2", CGRect(x: 560, y: 300, width: 120, height: 80), in: editor)
        let result = try drawn(#"""
        tile "N" right of "Hub"
        tile "D" below "N"
        """#, on: editor, ["--dry-run"])
        expectEqual(rows(result).map { $0["title"] }, ["N", "D"])
        expectEqual(rows(result)[0]["at"], [[720, 300], [120, 80]])
        expectEqual(rows(result)[0]["pushedPast"], ["Q1", "Q2"])
        expectEqual(rows(result)[1]["at"]?.arrayValue?.first, [720, 460])
        expectEqual(rows(result)[1]["pushedPast"], nil, "D wasn't kept clear of either itself")
        expectEqual(messages(result), [
            #""N" was pushed right past "Q1" to keep clear of it, so it no longer sits against "Hub" — place it on another side, or say overlap: allow"#,
            #""N" was pushed right past "Q2" to keep clear of it, so it no longer sits against "Hub" — place it on another side, or say overlap: allow"#,
            #""D" moved right along with "N", which was pushed past "Q1" and "Q2" to keep clear of them — place "N" on another side, or give "N" overlap: allow"#,
        ])
        expectEqual((result["warnings"]?.arrayValue ?? []).map { $0["line"] }, [1, 1, 2])
        // C, kept clear of W, goes right, still centered below T: nothing it says is loosened, and
        // it isn't "no longer centered" on anything. It takes T along, whose right of W now leaves
        // more room than it says.
        let board = try drawEditor()
        tile("A", CGRect(x: 400, y: 300, width: 120, height: 80), in: board)
        let dragged = try drawn(#"""
        tile "W" below "A"
        tile "T" right of "W" above "W"
        tile "C" below "T" size: 600x80
        """#, on: board)
        expectEqual(rows(dragged).map { $0["pushedPast"] }, [nil, nil, ["W"]])
        expectEqual(messages(dragged), [
            #""T" moved right along with "C", which was pushed past "W" to keep clear of it, so "T" no longer sits against "W" — place "C" on another side, or give "C" overlap: allow"#,
            #""C" was pushed right past "W" to keep clear of it — place it on another side, or say overlap: allow"#,
        ])
    },
    test("a shape placed against one in a zone isn't kept in the zone: hanging over its edge, it's drawn, with a warning") {
        let editor = try drawEditor()
        tile("Zone", CGRect(x: 0, y: 0, width: 600, height: 400), in: editor)
        tile("In", CGRect(x: 380, y: 40, width: 120, height: 80), in: editor)
        let result = try drawn(#"tile "Out" right of "In""#, on: editor)
        expectEqual(rows(result).first?["at"], [[580, 40], [120, 80]])
        expectEqual(rows(result).first?["pushedPast"], nil)
        expectEqual(messages(result), [#""Out" hangs over the edge of "Zone" — make "Zone" bigger, or place "Out" elsewhere"#])
        // Wholly in it, or inside it, it's said nothing.
        expectEqual(messages(try drawn(#"tile "Below" below "In" (gap: tight)"#, on: editor)), [])
        expectEqual(messages(try drawn(#"tile "Corner" inside "Zone" bottom-left"#, on: editor)), [])
    },
    test("a shape on a corner of one the script restates in place is where on puts it, and hangs over nothing") {
        for restated in [#"tile "API""#, #"tile "API" finish: glossy"#, #"tile "API" size: 200x100"#] {
            let editor = try drawEditor()
            tile("API", CGRect(x: 300, y: 300, width: 120, height: 80), in: editor)
            let result = try drawn(restated + "\n" + #"tile "Hot" on "API" top-right size: 40x40"#, on: editor)
            expectEqual(messages(result), [], restated)
            let api = try require(shape("API", in: editor)?.box)
            expectEqual(rows(result).last?["at"], [[.number(api.maxX - 20), 280], [40, 40]], restated)
        }
    },
    test("a list pushed past a wall says each member pushed past it was, and a member that only went along with the others went with the first") {
        let editor = try drawEditor()
        tile("Head", CGRect(x: 200, y: 0, width: 200, height: 200), in: editor)
        tile("Wall", CGRect(x: 180, y: 600, width: 240, height: 200), in: editor)
        let result = try drawn(#"""
        tile "One" below "Head" size: 240x200
        tile "Two" below "Head" size: 240x200
        tile "Three" below "Head" size: 240x200
        """#, on: editor, ["--dry-run"])
        expectEqual(rows(result).map { $0["pushedPast"] }, [["Wall"], ["Wall"], nil])
        expectEqual(messages(result), [
            #""One" was pushed down past "Wall" to keep clear of it, so it no longer sits against "Head" — place it on another side, or say overlap: allow"#,
            #""Two" was pushed down past "Wall" to keep clear of it — place it on another side, or say overlap: allow"#,
            #""Three" moved down along with "One", which was pushed past "Wall" to keep clear of it — place "One" on another side, or give "One" overlap: allow"#,
            "3 shapes landed outside the view — --reveal brings them into view",
        ])
        expectEqual((result["warnings"]?.arrayValue ?? []).map { $0["line"] }, [1, 2, 3, nil])
    },
    test("a new title nearly the same as one the board has is drawn, with a warning") {
        let editor = try drawEditor()
        tile("Deploy", CGRect(x: 200, y: 300, width: 120, height: 80), in: editor)
        let result = try drawn(#"tile "deploy" below "Deploy""#, on: editor)
        expectEqual(rows(result).first?["did"], "created")
        expectEqual(messages(result), [#"created "deploy"; the board has "Deploy" — to change that one, write its title exactly"#])
        // Among many names, of every length: the first near miss in the board's order, two letters
        // longer at most.
        for i in 0..<200 { tile("Name \(i)" + String(repeating: "x", count: i % 30), CGRect(x: 0, y: 1000 + 100 * i, width: 120, height: 80), in: editor) }
        tile("Deployment plan", CGRect(x: 400, y: 100, width: 120, height: 80), in: editor)
        tile("Deployment plans", CGRect(x: 560, y: 100, width: 120, height: 80), in: editor)
        let slip = try drawn(#"tile "Deploymnet pla" right of "Deployment plans""#, on: editor, ["--dry-run"])
        expectEqual(messages(slip), [#"created "Deploymnet pla"; the board has "Deployment plan" — to change that one, write its title exactly"#])
        expectEqual(messages(try drawn(#"tile "Deploymnet p" right of "Deployment plans""#, on: editor, ["--dry-run"])), [], "three letters short")
    },
    test("shapes that land outside the view are counted; --reveal brings them into view instead") {
        let editor = try drawEditor()
        tile("Hub", CGRect(x: 200, y: 300, width: 120, height: 80), in: editor)
        let far = try drawn(#"tile "Far" right of "Hub" (gap: 5000)"#, on: editor)
        expectEqual(rows(far).first?["inView"], false)
        expectEqual(far["warnings"], [["message": "1 shape landed outside the view — --reveal brings them into view", "severity": "warning"]])
        let camera = editor.camera
        let revealed = try drawn(#"tile "Farther" right of "Far""#, on: editor, ["--reveal"])
        expectEqual(revealed["warnings"], [])
        expect(editor.cameraTarget != camera, "the view eases to what was drawn")
        let bounds = try require(shape("Farther", in: editor)?.box)
        expect(editor.cameraTarget.toWorld(CGRect(origin: .zero, size: editor.viewportSize)).contains(bounds), "\(editor.cameraTarget)")
    },
])

@MainActor let drawRefusalTests = Suite("Drawing: what's refused", [
    test("a kind that isn't one, or that isn't drawn on its own") {
        let editor = try drawEditor()
        // A word from another language is told the kinds, and that a statement starts with one:
        // no kind here is like node, so no kind is named for it.
        let node = try refused(#"node "A""#, on: editor)
        expectEqual(node.reason, "unknown_kind")
        expectEqual(node.hint, #"the kinds drawn here: card, tile; a statement starts with its kind, as in <kind> "A""#)
        let connect = try refused(#"connect "A""#, on: editor)
        expectEqual(connect.hint, #"to join two shapes, write edge "A" -> "B"; the kinds drawn here: card, tile"#)
        let link = try refused("link", on: editor)
        expectEqual(link.reason, "not_placeable")
        expectEqual(link.hint, #"to join two shapes, write edge "A" -> "B""#)
        let box = try refused("box", on: editor)
        expectEqual(box.reason, "not_placeable")
        expectEqual(box.hint, "the kinds drawn here: card, tile")
    },
    test("a title the board has twice, or for a shape of another kind") {
        let editor = try drawEditor()
        tile("Twin", CGRect(x: 0, y: 0, width: 120, height: 80), in: editor)
        tile("Twin", CGRect(x: 200, y: 0, width: 120, height: 80), in: editor)
        let twins = try refused(#"tile "Twin" finish: glossy"#, on: editor)
        expectEqual(twins.reason, "ambiguous_title")
        expectEqual(twins.message, #"the board has 2 shapes called "Twin": a tile at 60,40 and a tile at 260,40"#)
        let kind = try refused(#"card "Twin""#, on: editor)
        expectEqual(kind.reason, "ambiguous_title")
        // One too far out to say to the unit is said as it is, never a crash.
        tile("Far", CGRect(x: 1e300, y: 0, width: 120, height: 80), in: editor)
        tile("Far", CGRect(x: 0, y: 400, width: 120, height: 80), in: editor)
        expectEqual(try refused(#"tile "Far" finish: glossy"#, on: editor).message,
                    #"the board has 2 shapes called "Far": a tile at 1e+300,40 and a tile at 60,440"#)
        tile("Solo", CGRect(x: 0, y: 200, width: 120, height: 80), in: editor)
        let wrong = try refused(#"card "Solo""#, on: editor)
        expectEqual(wrong.reason, "wrong_kind")
        expectEqual(wrong.message, #""Solo" is a tile on the board, not a card"#)
        expectEqual(wrong.hint, #"to change its kind, delete "Solo" and draw it again in the same script"#)
    },
    test("a title for a kind that can't have one") {
        let editor = try makeEditor([namesPlugin(nameable: [])])
        let tile = try refused(#"tile "A""#, on: editor)
        expectEqual(tile.reason, "untitlable")
        expectEqual(tile.message, #"a tile has no title, so it can't be called "A""#)
        let card = try refused(#"card "A""#, on: editor)
        expectEqual(card.message, #"a card's title is worked out from what it is, so it can't be called "A""#)
    },
    test("two statements about one title, and a shape placed against itself") {
        let editor = try drawEditor()
        let twice = try refused("tile \"A\"\ntile \"A\" finish: glossy", on: editor)
        expectEqual(twice.reason, "duplicate")
        expectEqual(twice.message, #""A" is written twice, here and on line 1"#)
        expectEqual(twice.data?["line"], 2)
        expectEqual(try refused(#"tile "A" right of "A""#, on: editor).reason, "circular")
    },
    test("attributes are read by their property's schema: words, numbers, true and false, dates, JSON, and null for the default") {
        let editor = try drawEditor()
        _ = try drawn(#"""
        tile "A" rank: 2 pinned: true finish: "glossy"
        card "AB" below "A" due: 2026-10-15 text: "Buy milk"
        """#, on: editor)
        let a = try require(shape("A", in: editor))
        expectEqual(a[Rank.self], 2)
        expectEqual(a[Pinned.self], true)
        expectEqual(a.typed(as: Tile.self)?.props.finish, .glossy)
        let ab = try require(shape("AB", in: editor))
        expectEqual(ab[Due.self], Date(timeIntervalSince1970: 1_792_022_400))
        expectEqual(ab.typed(as: Card.self)?.props.text, "Buy milk")
        _ = try drawn(#"tile "A" finish: null rank: null"#, on: editor)
        expectEqual(shape("A", in: editor)?.typed(as: Tile.self)?.props.finish, .matte)
        expectEqual(shape("A", in: editor)?[Rank.self], nil)
        let shiny = try refused(#"tile "A" finish: shiny"#, on: editor)
        expectEqual(shiny.reason, "invalid_value")
        expectEqual(shiny.message, #""A": finish: shiny isn't one of matte, glossy"#)
        expectEqual(try refused(#"tile "A" rank: 1.5"#, on: editor).message, #""A": rank: 1.5 isn't a whole number"#)
        expectEqual(try refused(#"tile "A" pinned: yes"#, on: editor).message, #""A": pinned: yes isn't true or false"#)
        expectEqual(try refused(#"card "AB" due: tomorrow"#, on: editor).reason, "invalid_value")
        // A bound isn't a refusal: rank 0 is drawn, and warned about.
        expect(messages(try drawn(#"tile "A" rank: 0"#, on: editor)).first?.contains("at least 1") == true)
    },
    test("JSON is held to its property's schema: a member it hasn't, or a value of the wrong type, is refused, not dropped") {
        let editor = try drawEditor()
        let member = try refused(#"tile "Hub" steps: [{"txt": "Plan"}]"#, on: editor)
        expectEqual(member.reason, "invalid_value")
        expectEqual(member.message, #""Hub": steps: txt isn't a member of item 1 (it has text)"#)
        expectEqual(member.hint, "did you mean text? steps: takes JSON [{text}]")
        let wrong = try refused(#"tile "Hub" steps: [{"text": 5}]"#, on: editor)
        expectEqual(wrong.reason, "invalid_value")
        expectEqual(wrong.message, #""Hub": steps: Steps › item 1 › text should be a string, not 5"#)
        expectEqual(try refused(#"tile "Hub" steps: {"text": "Plan"}"#, on: editor).reason, "invalid_value")
        expectEqual(editor.document.shapes.count, 0)
        // Null inside is the member's default, as a whole property's is.
        _ = try drawn(#"tile "Hub" steps: [{"text": null}]"#, on: editor)
        expectEqual(shape("Hub", in: editor)?[Steps.self]?.map(\.text), [""])
        // A member written as it is, but for one, is still refused, not read as the shape has it.
        expectEqual(try refused(#"tile "Hub" steps: [{"text": "", "done": true}]"#, on: editor).reason, "invalid_value")
    },
    test("a title a placement names that isn't one is never guessed to be the statement's own") {
        let editor = try drawEditor()
        tile("C", CGRect(x: 0, y: 0, width: 120, height: 80), in: editor)
        let nope = try refused(#"tile "E" right of "Nope""#, on: editor)
        expectEqual(nope.reason, "unknown_title")
        expectEqual(nope.hint, "a title is one the board has as the script starts, or one the script draws")
        // Nor a restated one's, which is the board's too.
        tile("E", CGRect(x: 200, y: 0, width: 120, height: 80), in: editor)
        let restated = try refused(#"tile "E" right of "Nope""#, on: editor)
        expectEqual(restated.reason, "unknown_title")
        expectEqual(restated.hint, "a title is one the board has as the script starts, or one the script draws")
        tile("Nop", CGRect(x: 400, y: 0, width: 120, height: 80), in: editor)
        expectEqual(try refused(#"tile "E" right of "Nope""#, on: editor).hint, #"did you mean "Nop"?"#, "another's is")
    },
    test("an attribute the kind hasn't says what it takes, and which kinds have it") {
        let editor = try drawEditor()
        _ = try drawn(threeShapes, on: editor)
        let other = try refused(#"card "AB" finsh: glossy"#, on: editor)
        expectEqual(other.reason, "unknown_attribute")
        expectEqual(other.message, #""AB" is a card and has finsh:, which isn't one of a card's attributes"#)
        let belongs = try refused(#"card "AB" finish: glossy"#, on: editor)
        expectEqual(belongs.hint, "a card takes size:, gap:, overlap:, style:, title:, due:, text:; finish: belongs to tile")
        let untitled = try refused("card rank: 2 below board", on: editor)
        expectEqual(untitled.message, "the card on line 1 has rank:, which isn't one of a card's attributes")
        expectEqual(try refused("// nothing to draw\n", on: editor).reason, "empty_script")
    },
    test("what a script can't write: the property a title is written to, coordinates, and a title on a new shape") {
        let editor = try drawEditor()
        _ = try drawn(threeShapes, on: editor)
        let naming = try refused(#"card "AB" nickname: Bo"#, on: editor)
        expectEqual(naming.reason, "unsupported")
        expectEqual(naming.hint, #"rename it with title: "…""#)
        let place = try refused("card frame: [[0, 0], [10, 10]]", on: editor)
        expectEqual(place.reason, "unsupported")
        expectEqual(place.message, "frame: says where the card on line 1 is, and there are no coordinates here")
        expectEqual(place.hint, "say where it goes with a placement, and how big with size:")
        let x = try refused(#"card "AB" x: 100 y: 200"#, on: editor)
        expectEqual(x.reason, "unsupported")
        expectEqual(x.message, #"x: would say where "AB" is, and there are no coordinates here"#)
        let width = try refused(#"card "AB" width: 300"#, on: editor)
        expectEqual(width.reason, "unsupported")
        expectEqual(width.hint, "size: <width>x<height>, as size: 300x200")
    },
    test("styles: each gives a shape what its kind takes; one that gives it nothing, or gives what nothing takes, is refused") {
        let editor = try drawEditor()
        let given = try drawn(#"""
        style shiny finish: glossy text: hi
        style big size: 300x200
        card "AB" style: shiny, big
        tile "T" style: shiny below "AB"
        """#, on: editor)
        expectEqual(rows(given).map { $0["at"] }, [[[350, 220], [300, 200]], [[440, 500], [120, 80]]])
        expectEqual(shape("AB", in: editor)?.typed(as: Card.self)?.props.text, "hi")
        expectEqual(shape("T", in: editor)?.typed(as: Tile.self)?.props.finish, .glossy)
        let nothing = try refused("style loud finish: glossy\ncard \"CD\" style: loud", on: editor)
        expectEqual(nothing.reason, "unknown_attribute")
        expectEqual(nothing.message, #""CD" is a card, and style loud gives it nothing it takes"#)
        let typo = try refused("style loud colr: red\ntile \"U\" style: loud", on: editor)
        expectEqual(typo.reason, "unknown_attribute")
        expectEqual(typo.message, "style loud has colr:, which is an attribute of nothing drawn here")
        expectEqual(typo.data?["line"], 1)
        expectEqual(typo.data?["statement"], "style loud colr: red")
    },
])

@MainActor let drawPointTests = Suite("Drawing's extension points", [
    test("each takes one plugin at most, and the report names them") {
        expectEqual(refusal { $0.drawNames(name: { _, _ in nil }, namingProperty: { _, _ in nil }, isDerived: { _, _ in false }, fold: fold) }, nil)
        do throws(RegistryError) {
            _ = try Registry(plugins: [AutomationPlugin(), namesPlugin(), Contributor(id: "more") { registrar in
                registrar.drawNames(name: { _, _ in nil }, namingProperty: { _, _ in nil }, isDerived: { _, _ in false }, fold: fold)
            }])
            expect(false, "two plugins name shapes")
        } catch {
            expectEqual(error.description, "names and more both claim draw names in DrawNames")
        }
        let registry = try drawEditor(checks: true).registry
        let report = registry.report.split(separator: "\n")
        for (plugin, point) in [("names", "draw names"), ("edges", "draw edges"), ("checks", "draw checks")] {
            expect(report.contains { $0.hasPrefix(plugin + " ") && $0.hasSuffix(" " + point) }, registry.report)
        }
    },
    test("an edge's attributes can't be the language's own keys") {
        expectEqual(refusal { registrar in
            registrar.drawEdges(kind: { _ in nil }, attributes: ["from"], sides: { _, _ in [:] }, ends: { _, _ in nil },
                                make: { _, _, _ throws(AutomationError) in throw AutomationError("no", reason: "no") })
        }, "DrawEdges: attribute from: the language keeps from: for itself")
        for key in ["line", "did", "kind"] {
            expectEqual(refusal { registrar in
                registrar.drawEdges(kind: { _ in nil }, attributes: [key], sides: { _, _ in [:] }, ends: { _, _ in nil },
                                    make: { _, _, _ throws(AutomationError) in throw AutomationError("no", reason: "no") })
            }, "DrawEdges: attribute \(key): a draw result's row has \(key) of its own")
        }
    },
])
