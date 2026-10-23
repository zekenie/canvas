@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CoreGraphics
import AppKit
import Draw
import Foundation
import TestKit

// `canvas draw` names a shape by a path when its title is not its alone: the containers it is in (a pen here, for a frame; a
// pocket, for a subboard), outermost first, then its title (`"Payments" > "Checkout"`, `#<id> > "Checkout"` for a container with
// no title, `board > "Checkout"` for a shape in no container on the board the run draws on). A path matches every shape whose
// chain ends with its parts, each directly inside the one before. Two shapes may share a title in different containers; a lone
// title that two have is `ambiguous_title`, and every message names such a shape by its path.

/// The file these tests draw on:
///
///     root:     pen Payments (tile Checkout, tile Refund, pocket Archive: tile OldA)
///               pen Billing  (tile Checkout, tile Invoice, pocket Archive: tile OldB)
///               pen (no title) (tile Checkout)
///               pocket Plans: tile Checkout, pen Payments (tile Checkout), pen Sprint (tile Checkout, tile Task)
///               tile Checkout, tile Solo
@MainActor struct Org {
    let payments = ShapeID(), billing = ShapeID(), untitled = ShapeID(), plans = ShapeID()
    let paymentsCheckout = ShapeID(), refund = ShapeID(), billingCheckout = ShapeID(), invoice = ShapeID(), untitledCheckout = ShapeID()
    let archiveA = ShapeID(), archiveB = ShapeID(), oldA = ShapeID(), oldB = ShapeID()
    let plansCheckout = ShapeID(), plansPayments = ShapeID(), plansPaymentsCheckout = ShapeID()
    let sprint = ShapeID(), sprintCheckout = ShapeID(), task = ShapeID()
    let checkout = ShapeID(), solo = ShapeID()

    private static func tile(_ id: ShapeID, _ label: String, _ x: CGFloat, _ y: CGFloat) -> AnyShapeRecord {
        AnyShapeRecord(ShapeRecord(id: id, Tile(CGRect(x: x, y: y, width: 100, height: 60), label: label)))
    }

    private static func pen(_ id: ShapeID, _ label: String, _ x: CGFloat, _ y: CGFloat) -> AnyShapeRecord {
        AnyShapeRecord(ShapeRecord(id: id, Pen(CGRect(x: x, y: y, width: 500, height: 300), label: label)))
    }

    private static func pocket(_ id: ShapeID, _ name: String, _ x: CGFloat, _ y: CGFloat) -> AnyShapeRecord {
        var record = AnyShapeRecord(ShapeRecord(id: id, Pocket(CGRect(x: x, y: y, width: 100, height: 100))))
        record[Nickname.self] = name
        return record
    }

    func editor(_ more: [any CanvasPlugin] = []) throws -> CanvasEditor {
        let editor = try drawEditor([pens, PocketsPlugin(), namedPockets] + more)
        let root = CanvasDocument(shapes: [
            Self.pen(payments, "Payments", 0, 0), Self.tile(paymentsCheckout, "Checkout", 80, 40), Self.tile(refund, "Refund", 220, 40),
            Self.pocket(archiveA, "Archive", 360, 40),
            Self.pen(billing, "Billing", 600, 0), Self.tile(billingCheckout, "Checkout", 680, 40), Self.tile(invoice, "Invoice", 820, 40),
            Self.pocket(archiveB, "Archive", 960, 40),
            Self.pen(untitled, "", 1200, 0), Self.tile(untitledCheckout, "Checkout", 1240, 40),
            Self.pocket(plans, "Plans", 0, 400),
            Self.tile(checkout, "Checkout", 0, 800), Self.tile(solo, "Solo", 200, 800),
        ])
        let plansBoard = CanvasDocument(shapes: [
            Self.tile(plansCheckout, "Checkout", 0, 0),
            Self.pen(plansPayments, "Payments", 0, 100), Self.tile(plansPaymentsCheckout, "Checkout", 20, 140),
            Self.pen(sprint, "Sprint", 600, 100), Self.tile(sprintCheckout, "Checkout", 620, 140), Self.tile(task, "Task", 740, 140),
        ])
        editor.replaceFile(with: CanvasFile(root: root, children: [
            plans: plansBoard,
            archiveA: CanvasDocument(shapes: [Self.tile(oldA, "Old", 0, 0)]),
            archiveB: CanvasDocument(shapes: [Self.tile(oldB, "Old", 0, 0)]),
        ]))
        func hold(_ held: [ShapeID], in pen: ShapeID, on board: BoardID) {
            editor.transact(on: board) { $0.setContainer(held, to: pen) }
        }
        hold([paymentsCheckout, refund, archiveA], in: payments, on: .root)
        hold([billingCheckout, invoice, archiveB], in: billing, on: .root)
        hold([untitledCheckout], in: untitled, on: .root)
        hold([plansPaymentsCheckout], in: plansPayments, on: BoardID(owner: plans))
        hold([sprintCheckout, task], in: sprint, on: BoardID(owner: plans))
        return editor
    }
}

/// The container a shape is in on its own board.
@MainActor private func holder(of id: ShapeID, in editor: CanvasEditor) -> ShapeID? {
    guard let board = editor.file.board(containing: id) else { return nil }
    return editor.file[board].container(of: id, containingKinds: editor.registry.containingKinds)
}

@MainActor private func glossy(_ editor: CanvasEditor, _ id: ShapeID) -> Bool {
    editor.file.record(id)?.typed(as: Tile.self)?.props.finish == .glossy
}

@MainActor let drawPathTests = Suite("draw: paths", [
    test("a path names the shape in the container that has that title, whatever other shapes are called alike; the row says which") {
        let org = Org(), editor = try org.editor()
        let result = try drawn(#"tile "Payments" > "Checkout" finish: glossy"#, on: editor)
        expectEqual(rows(result).map { $0["did"] }, ["updated"])
        expectEqual(rows(result).first?["id"], .string(org.paymentsCheckout.description))
        expectEqual(rows(result).first?["title"], "Checkout", "a row says the title, as it did")
        expect(glossy(editor, org.paymentsCheckout))
        for other in [org.billingCheckout, org.untitledCheckout, org.checkout, org.plansPaymentsCheckout, org.plansCheckout, org.sprintCheckout] {
            expect(!glossy(editor, other), "\(other) is another shape")
        }
        let billing = try drawn(#"tile "Billing" > "Checkout" finish: glossy"#, on: editor)
        expectEqual(rows(billing).first?["id"], .string(org.billingCheckout.description))
        expectEqual(editor.board, .root, "the window didn't move")
        let again = try drawn(#"tile "Billing" > "Checkout" finish: glossy"#, on: editor)
        expectEqual(rows(again).map { $0["did"] }, ["unchanged"])
    },
    test("a path matches the shapes whose chain ends with its parts: the container's own container may be left out, or named") {
        let org = Org(), editor = try org.editor()
        for (index, path) in [#""Sprint" > "Task""#, #""Plans" > "Sprint" > "Task""#].enumerated() {
            let result = try drawn("tile \(path) finish: glossy", on: editor)
            expectEqual(rows(result).first?["id"], .string(org.task.description), path)
            expectEqual(result["on"]?["board"], .string(org.plans.description), "the run draws on the board the shape is on: \(path)")
            expectEqual(rows(result).map { $0["did"] }, [index == 0 ? "updated" : "unchanged"])
        }
        // "Payments" is on the root and on Plans' board: the board the run draws on is the window's, which has one.
        let root = try drawn(#"tile "Payments" > "Checkout" finish: glossy"#, on: editor)
        expectEqual(rows(root).first?["id"], .string(org.paymentsCheckout.description))
        // The path through the subboard says the other one.
        let plans = try drawn(#"tile "Plans" > "Payments" > "Checkout" finish: glossy"#, on: editor)
        expectEqual(rows(plans).first?["id"], .string(org.plansPaymentsCheckout.description))
        expectEqual(plans["on"]?["board"], .string(org.plans.description))
        expect(glossy(editor, org.plansPaymentsCheckout) && !glossy(editor, org.sprintCheckout))
        // A subboard's board's shapes in no container are directly inside the subboard.
        let top = try drawn(#"tile "Plans" > "Checkout" finish: glossy"#, on: editor)
        expectEqual(rows(top).first?["id"], .string(org.plansCheckout.description))
        expect(!glossy(editor, org.sprintCheckout) && !glossy(editor, org.checkout))
    },
    test("an id may start a path, for a container with no title; board is the top of the board the run draws on") {
        let org = Org(), editor = try org.editor()
        let byID = try drawn("tile #\(org.untitled) > \"Checkout\" finish: glossy", on: editor)
        expectEqual(rows(byID).first?["id"], .string(org.untitledCheckout.description))
        let packed = try drawn("tile #\(org.untitled)>\"Checkout\" finish: matte", on: editor)
        expectEqual(rows(packed).map { $0["did"] }, ["updated"], "no spaces needed")
        let top = try drawn(#"tile board > "Checkout" finish: glossy"#, on: editor)
        expectEqual(rows(top).first?["id"], .string(org.checkout.description), "the Checkout in no container on the root")
        expect(!glossy(editor, org.paymentsCheckout))
        // The board is the one the run draws on: the window's, here the root, and Plans' when the script says so.
        let plans = try drawn(#"tile board > "Checkout" finish: glossy"# + "\n" + #"tile "Task" below "Plans" > "Sprint""#, on: editor)
        expectEqual(plans["on"]?["board"], .string(org.plans.description))
        expectEqual(rows(plans).first?["id"], .string(org.plansCheckout.description), "Plans' Checkout, in no pen")
    },
    test("a lone title that two shapes of the board have is ambiguous: each is listed with its kind and its path, and the hint says to write one") {
        let org = Org(), editor = try org.editor()
        let error = try refused(#"tile "Checkout" finish: glossy"#, on: editor)
        expectEqual(error.reason, "ambiguous_title")
        let untitled = "#\(org.untitled)"
        expectEqual(error.message, #"the board has 4 shapes called "Checkout": a tile "Payments" > "Checkout", a tile "Billing" > "Checkout", a tile \#(untitled) > "Checkout" and a tile at 50,830"#)
        expectEqual(error.hint, #"write the path of the one you mean, as "Payments" > "Checkout", or its #id, which a query's row gives"#)
        expectEqual(error.data?["line"], 1)
        // Everywhere a lone title names a shape.
        for script in [#"edge "Checkout" -> "Solo""#, #"tile "N" right of "Checkout""#, #"delete "Checkout""#] {
            expectEqual(try refused(script, on: editor).reason, "ambiguous_title", script)
        }
        // The shapes of a path are ambiguous when two share the whole path, and say where each is.
        let twin = tile("Checkout", CGRect(x: 360, y: 140, width: 100, height: 60), in: editor).id
        editor.transact { $0.setContainer(twin, to: org.payments) }
        let twice = try refused(#"tile "Payments" > "Checkout""#, on: editor)
        expectEqual(twice.reason, "ambiguous_title")
        expectEqual(twice.message, #"the board has 2 shapes called "Payments" > "Checkout": a tile "Payments" > "Checkout" at 130,70 and a tile "Payments" > "Checkout" at 410,170"#)
        expectEqual(twice.hint, #"write the path of the one you mean, as "Payments" > "Checkout", or its #id, which a query's row gives"#)
        expect(!glossy(editor, org.paymentsCheckout), "nothing was drawn")
    },
    test("an id names one of two alike, and its row says the title; a path through nothing is unknown_title, with how far it got") {
        let org = Org(), editor = try org.editor()
        let byID = try drawn("tile #\(org.checkout) finish: glossy", on: editor)
        expectEqual(rows(byID).first?["id"], .string(org.checkout.description))
        let none = try refused(#"edge "Payments" > "Chekout" -> "Solo""#, on: editor)
        expectEqual(none.reason, "unknown_title")
        expectEqual(none.message, #"there's no shape called "Payments" > "Chekout""#)
        expectEqual(none.hint, #"did you mean "Checkout"?"#)
        let missing = try refused(#"edge "Payments" > "Invoice" -> "Solo""#, on: editor)
        expectEqual(missing.message, #"there's no shape called "Payments" > "Invoice""#)
        expectEqual(missing.hint, #""Payments" holds no shape called "Invoice""#)
        let head = try refused(#"delete "Nowhere" > "Checkout""#, on: editor)
        expectEqual(head.reason, "unknown_title")
        expectEqual(head.message, #"there's no shape called "Nowhere" > "Checkout" to delete"#)
        expectEqual(head.hint, #"a path starts with the frame or subboard its shapes are in, and none is called "Nowhere""#)
        let id = try refused(#"delete #00000000-0000-0000-0000-000000000000 > "Checkout""#, on: editor)
        expectEqual(id.reason, "unknown_title")
    },
    test("a shape statement named by a path makes the shape directly in the path's container, as in would; the container must be there") {
        let org = Org(), editor = try org.editor()
        let result = try drawn(#"tile "Payments" > "Fresh""#, on: editor)
        expectEqual(rows(result).map { $0["did"] }, ["created"])
        let fresh = try require(shape("Fresh", in: editor))
        expectEqual(holder(of: fresh.id, in: editor), org.payments)
        expectEqual(rows(result).first?["title"], "Fresh")
        let top = try drawn(#"tile board > "Top""#, on: editor)
        expectEqual(rows(top).map { $0["did"] }, ["created"])
        expectEqual(holder(of: try require(shape("Top", in: editor)).id, in: editor), nil, "in no container")
        let sprint = try drawn(#"tile "Plans" > "Sprint" > "Sprinted""#, on: editor)
        expectEqual(sprint["on"]?["board"], .string(org.plans.description))
        expectEqual(holder(of: try require(editor.contents(of: BoardID(owner: org.plans)).shapes.first { $0.typed(as: Tile.self)?.props.label == "Sprinted" }).id, in: editor), org.sprint)
        let board = try drawn("tile \"Plans\" > \"Loose\"", on: editor)
        expectEqual(board["on"]?["board"], .string(org.plans.description))
        // Run again, it is the shape there.
        expectEqual(rows(try drawn(#"tile "Payments" > "Fresh""#, on: editor)).map { $0["did"] }, ["unchanged"])
        // A path makes nothing where there is no container, or where the container is one the script draws.
        let none = try refused(#"tile "Nowhere" > "X""#, on: editor)
        expectEqual(none.reason, "unknown_title")
        expectEqual(none.message, #"there's no shape called "Nowhere" to be in"#)
        let pen = try refused(#"pen "Fresh pen"# + "\"\n" + #"tile "Fresh pen" > "X""#, on: editor)
        expectEqual(pen.reason, "unsupported")
        expectEqual(pen.message, #""Fresh pen" is drawn by this script, and a shape goes in one already on the board"#)
        expectEqual(pen.data?["line"], 2)
        expectEqual(try refused(#"tile "Solo" > "X""#, on: editor).reason, "unknown_title", "a tile holds nothing")
    },
    test("two statements of one script are one shape only when they name the same shape or the same new path") {
        let org = Org(), editor = try org.editor()
        let same = try refused(#"tile "Payments" > "Fresh""# + "\n" + #"tile "Payments" > "Fresh" finish: glossy"#, on: editor)
        expectEqual(same.reason, "duplicate")
        expectEqual(same.message, #""Fresh" is written twice, here and on line 1"#)
        let byBoth = try refused(#"tile "Payments" > "Checkout""# + "\n" + #"tile "Payments" > "Checkout" finish: glossy"#, on: editor)
        expectEqual(byBoth.reason, "duplicate")
        let apart = try drawn(#"tile "Payments" > "Fresh""# + "\n" + #"tile "Billing" > "Fresh""# + "\n" + #"tile board > "Fresh""#, on: editor)
        expectEqual(rows(apart).map { $0["did"] }, ["created", "created", "created"], "three shapes of one title in three places")
        let fresh = editor.document.shapes.filter { $0.typed(as: Tile.self)?.props.label == "Fresh" }.map(\.id)
        expectEqual(Set(fresh.map { holder(of: $0, in: editor) }), [org.payments, org.billing, nil])
        // The path and `in` say one place: a shape restated both ways is one shape.
        let both = try refused(#"tile "Payments" > "Fresh" finish: glossy"# + "\n" + #"tile "Fresh" in "Payments" finish: glossy"#, on: editor)
        expectEqual(both.reason, "duplicate")
        // A lone title two of the script's own shapes have is ambiguous to the other statements: the path says which.
        let script = #"tile "Plans" > "Sprint" > "Twin""# + "\n" + #"tile "Plans" > "Payments" > "Twin""# + "\n"
        let ambiguous = try refused(script + #"tile "Other" right of "Twin""#, on: editor)
        expectEqual(ambiguous.reason, "ambiguous_title")
        expectEqual(ambiguous.message, #"the board has 2 shapes called "Twin": a tile "Plans" > "Sprint" > "Twin" and a tile "Plans" > "Payments" > "Twin""#)
        expectEqual(ambiguous.hint, #"write the path of the one you mean, as "Plans" > "Sprint" > "Twin""#, "a shape the script makes has no id yet")
        expectEqual(ambiguous.data?["line"], 3)
        let named = try drawn(script + #"tile "Other" right of "Plans" > "Sprint" > "Twin""#, on: editor)
        expectEqual(rows(named).map { $0["did"] }, ["created", "created", "created"])
    },
    test("an edge's ends, a delete and a placement's target take paths; an edge between two alike is drawn and found again") {
        let org = Org(), editor = try org.editor()
        let result = try drawn(#"edge "Payments" > "Checkout" -> "Billing" > "Checkout""#, on: editor)
        expectEqual(rows(result).map { $0["did"] }, ["connected"])
        let link = try require(editor.document.shapes.first { $0.typed(as: Link.self) != nil }?.typed(as: Link.self))
        expectEqual([link.props.from, link.props.to], [org.paymentsCheckout, org.billingCheckout])
        expectEqual(rows(result).first?["from"], "Checkout")
        let again = try drawn(#"edge "Payments" > "Checkout" -> "Billing" > "Checkout""#, on: editor)
        expectEqual(rows(again).map { $0["did"] }, ["unchanged"])
        // Placed against a path, and a shape by its path with an edge to another by its id.
        let placed = try drawn(#"tile "Refund" below "Payments" > "Checkout""# + "\n" + "edge \"Payments\" > \"Refund\" -> #\(org.checkout)", on: editor)
        expectEqual(rows(placed).map { $0["did"] }.first, "moved")
        expectEqual(links(in: editor).count, 2)
        // Deleting an edge by its ends, and a shape by its path: the other shapes alike are left.
        let gone = try drawn(#"delete edge "Payments" > "Checkout" -> "Billing" > "Checkout""#, on: editor)
        expectEqual(rows(gone).map { $0["did"] }, ["deleted"])
        expectEqual(links(in: editor).count, 1)
        let deleted = try drawn(#"delete "Payments" > "Checkout""#, on: editor)
        expectEqual(rows(deleted).map { $0["did"] }, ["deleted"])
        expectEqual(editor.document[org.paymentsCheckout], nil)
        expect(editor.document[org.billingCheckout] != nil && editor.document[org.checkout] != nil)
        let twice = try refused(#"delete "Billing" > "Invoice""# + "\n" + #"delete "Billing" > "Invoice""#, on: editor)
        expectEqual(twice.reason, "duplicate")
        expectEqual(twice.message, #""Billing" > "Invoice" is deleted twice"#)
        let none = try refused(#"delete "Billing" > "Nothing""#, on: editor)
        expectEqual(none.message, #"there's no shape called "Billing" > "Nothing" to delete"#)
        // A shape the file has on another board, named by a path, is the shape there: an edge to it goes through a stand-in, or
        // is refused where nothing stands in.
        expectEqual(try refused(#"edge "Billing" > "Checkout" -> "Plans" > "Sprint" > "Task""#, on: editor).reason, "several_boards")
    },
    test("in \"F\" finds its own title inside F first, at any depth; failing that, one lying on F's board in no container is moved in; failing that, a new one is made in F") {
        let org = Org(), editor = try org.editor()
        // Checkout is on the board four times; the one inside Billing is the one.
        let inside = try drawn(#"tile "Checkout" in "Billing" finish: glossy"#, on: editor)
        expectEqual(rows(inside).map { $0["did"] }, ["updated"])
        expectEqual(rows(inside).first?["id"], .string(org.billingCheckout.description))
        expectEqual(holder(of: org.billingCheckout, in: editor), org.billing)
        // Loose on the board: moved in.
        let moved = try drawn(#"tile "Solo" in "Payments""#, on: editor)
        expectEqual(rows(moved).map { $0["did"] }, ["moved"])
        expectEqual(holder(of: org.solo, in: editor), org.payments)
        // Inside another frame: not moved out of it. A second Refund is made in Billing.
        let second = try drawn(#"tile "Refund" in "Billing""#, on: editor)
        expectEqual(rows(second).map { $0["did"] }, ["created"])
        expectEqual(holder(of: org.refund, in: editor), org.payments, "the first stays where it was")
        let made = editor.document.shapes.filter { $0.typed(as: Tile.self)?.props.label == "Refund" }
        expectEqual(made.count, 2)
        expectEqual(Set(made.map { holder(of: $0.id, in: editor) }), [org.payments, org.billing])
        // Run again, in Billing: it is the one there, and a lone title for it is ambiguous now.
        expectEqual(rows(try drawn(#"tile "Refund" in "Billing""#, on: editor)).map { $0["did"] }, ["unchanged"])
        let lone = try refused(#"tile "Refund" finish: glossy"#, on: editor)
        expectEqual(lone.reason, "ambiguous_title")
        expectEqual(lone.message, #"the board has 2 shapes called "Refund": a tile "Payments" > "Refund" and a tile "Billing" > "Refund""#)
        // Anywhere within a frame; nested too.
        let nested = try drawn(#"tile "Task" in "Plans" finish: glossy"#, on: editor)
        expectEqual(nested["on"]?["board"], .string(org.plans.description))
        expectEqual(rows(nested).first?["id"], .string(org.task.description), "on Plans' board, anywhere: in Sprint")
        expectEqual(holder(of: org.task, in: editor), org.sprint, "restated where it is")
        // On a subboard's board, two inside it at different depths are ambiguous.
        let twice = try refused(#"tile "Checkout" in "Plans""#, on: editor)
        expectEqual(twice.reason, "ambiguous_title")
        expectEqual(twice.message, #"the board has 3 shapes called "Checkout": a tile "Plans" > "Checkout", a tile "Plans" > "Payments" > "Checkout" and a tile "Plans" > "Sprint" > "Checkout""#)
    },
    test("in \"F\" with a shape in a frame inside F finds it there, and one of the same title loose beside is left") {
        let org = Org(), editor = try org.editor()
        let outer = pen("Outer", CGRect(x: 0, y: 1200, width: 800, height: 600), in: editor)
        let inner = pen("Inner", CGRect(x: 40, y: 1240, width: 300, height: 200), in: editor)
        let deep = tile("Deep", CGRect(x: 60, y: 1260, width: 100, height: 60), in: editor).id
        editor.transact { $0.setContainer(deep, to: inner) }
        editor.transact { $0.setContainer(inner, to: outer) }
        let loose = tile("Deep", CGRect(x: 900, y: 1200, width: 100, height: 60), in: editor).id
        let result = try drawn(#"tile "Deep" in "Outer" finish: glossy"#, on: editor)
        expectEqual(rows(result).first?["id"], .string(deep.description), "the one inside, at any depth, before the one loose on the board")
        expectEqual(holder(of: deep, in: editor), inner)
        expect(!glossy(editor, loose))
    },
    test("the other titles of a statement with in are found inside the frame first, then as anywhere else") {
        let org = Org(), editor = try org.editor()
        let result = try drawn(#"tile "Next" in "Billing" below "Checkout" (gap: tight) finish: glossy"#, on: editor)
        expectEqual(rows(result).map { $0["did"] }, ["created"])
        let next = try require(shape("Next", in: editor)), billing = try require(editor.document[org.billingCheckout])
        let nextBox = try require(next.box), billingBox = try require(billing.box)
        expect(nextBox.minY > billingBox.maxY, "below Billing's Checkout, not ambiguous among four")
        expectEqual(holder(of: next.id, in: editor), org.billing)
    },
    test("a rename is refused only for a title another shape directly beside it has: in the same frame, or on the board in no frame") {
        let org = Org(), editor = try org.editor()
        let beside = try refused(#"tile "Payments" > "Refund" title: "Checkout""#, on: editor)
        expectEqual(beside.reason, "duplicate")
        expectEqual(beside.message, #""Checkout" is taken: the frame has a shape called that"#)
        let loose = try refused(#"tile "Solo" title: "Checkout""#, on: editor)
        expectEqual(loose.message, #""Checkout" is taken: the board has a shape called that"#)
        // Another frame's, or another board's, is not beside it.
        let renamed = try drawn(#"tile "Payments" > "Refund" title: "Invoice""#, on: editor)
        expectEqual(rows(renamed).map { $0["did"] }, ["renamed"])
        expectEqual(rows(renamed).first?["was"], "Refund")
        expectEqual(editor.file.record(org.refund)?.typed(as: Tile.self)?.props.label, "Invoice")
        let task = try drawn(#"tile "Plans" > "Sprint" > "Task" title: "Solo""#, on: editor)
        expectEqual(rows(task).map { $0["did"] }, ["renamed"])
        // Another statement giving a shape beside it the title is refused too; one in another frame isn't.
        let twice = try refused(#"tile "Payments" > "Checkout" title: "Mine""# + "\n" + #"tile "Payments" > "Invoice" title: "Mine""#, on: editor)
        expectEqual(twice.reason, "duplicate")
        let apart = try drawn(#"tile "Payments" > "Checkout" title: "Mine""# + "\n" + #"tile "Billing" > "Invoice" title: "Mine""#, on: editor)
        expectEqual(rows(apart).map { $0["did"] }, ["renamed", "renamed"])
    },
    test("a message that names a shape whose title is not its alone names it by its path") {
        let log = RefusalLog()
        let org = Org(), editor = try org.editor([FreezingPlugin(log: log)])
        editor.freeze([org.paymentsCheckout, org.solo, org.checkout])
        let before = editor.document
        let locked = try refused(#"tile "Payments" > "Checkout" finish: glossy"#, on: editor)
        expectEqual(locked.reason, "read_only")
        expectEqual(locked.message, #""Payments" > "Checkout" is read-only (locked, say), so it stays as it is"#)
        let deleted = try refused(#"delete "Payments" > "Checkout""#, on: editor)
        expectEqual(deleted.message, #""Payments" > "Checkout" is read-only (locked, say), so it can't be deleted"#)
        // In no container on the board, a shape whose title is shared is board > "Title".
        let loose = try refused(#"tile board > "Checkout" finish: glossy"#, on: editor)
        expectEqual(loose.message, #"board > "Checkout" is read-only (locked, say), so it stays as it is"#)
        // A shape whose title is its alone keeps it.
        expectEqual(try refused(#"tile "Solo" finish: glossy"#, on: editor).message, #""Solo" is read-only (locked, say), so it stays as it is"#)
        expectEqual(editor.document, before, "nothing drawn")
    },
    test("a path with a kind that isn't the shape's is wrong_kind, said by the path") {
        let org = Org(), editor = try org.editor()
        let wrong = try refused(#"pen "Payments" > "Checkout""#, on: editor)
        expectEqual(wrong.reason, "wrong_kind")
        expectEqual(wrong.message, #""Payments" > "Checkout" is a tile on the board, not a pen"#)
        _ = org
    },
    test("a dry run reads paths and changes nothing; a run is one step") {
        let org = Org(), editor = try org.editor()
        let before = editor.document
        let step = editor.undoHistory.undoName
        let dry = try drawn(#"tile "Payments" > "Fresh""# + "\n" + #"tile "Billing" > "Checkout" finish: glossy"#, on: editor, ["--dry-run"])
        expectEqual(rows(dry).map { $0["did"] }, ["created", "updated"])
        expectEqual(editor.document, before)
        expectEqual(editor.undoHistory.undoName, step)
        _ = try drawn(#"tile "Payments" > "Fresh""# + "\n" + #"tile "Billing" > "Checkout" finish: glossy"#, on: editor)
        expectEqual(editor.undoHistory.undoName, "Draw")
        editor.undo()
        expectEqual(editor.document, before)
        _ = org
    },
    test("a path needs names, as a title does") {
        let org = Org()
        let editor = try makeEditor([pens, PocketsPlugin(), namedPockets]), source = try org.editor()
        editor.replaceFile(with: source.file)
        expectEqual(try refused(#"tile "Payments" > "Checkout""#, on: editor).reason, "no_names")
    },
])

/// A pen on the board, labeled.
@MainActor @discardableResult private func pen(_ label: String, _ frame: CGRect, in editor: CanvasEditor) -> ShapeID {
    let record = AnyShapeRecord(ShapeRecord(Pen(frame, label: label)))
    editor.transact { $0.insert(record) }
    return record.id
}

@MainActor let drawPathElsewhereTests = Suite("draw: paths, show and capture", [
    test("canvas show takes a title, a path or an id, as a script writes them; a bare title is a title as before") {
        let org = Org(), editor = try org.editor()
        let step = editor.undoHistory.undoName
        _ = try run(["show", "Plans"], on: editor).get()
        expectEqual(editor.board, BoardID(owner: org.plans))
        _ = try run(["show", "--root"], on: editor).get()
        let byPath = try run(["show", #""Billing" > "Archive""#], on: editor).get()
        expectEqual(editor.board, BoardID(owner: org.archiveB))
        expectEqual(byPath["title"], "Archive")
        _ = try run(["show", "--root"], on: editor).get()
        _ = try run(["show", #""Payments">"Archive""#], on: editor).get()
        expectEqual(editor.board, BoardID(owner: org.archiveA))
        _ = try run(["show", "--root"], on: editor).get()
        _ = try run(["show", "#\(org.archiveB)"], on: editor).get()
        expectEqual(editor.board, BoardID(owner: org.archiveB), "an id")
        _ = try run(["show", "--root"], on: editor).get()
        _ = try run(["show", #""Plans""#], on: editor).get()
        expectEqual(editor.board, BoardID(owner: org.plans), "a quoted title")
        expectEqual(editor.undoHistory.undoName, step, "showing a board is no step")
    },
    test("canvas show of a title two shapes have says to write the path or the id; a path through nothing is unknown_title") {
        let org = Org(), editor = try org.editor()
        guard case .failure(let ambiguous) = try run(["show", "Archive"], on: editor) else { return expect(false, "it showed one") }
        expectEqual(ambiguous.reason, "ambiguous_title")
        expectEqual(ambiguous.message, #"2 shapes that hold boards are called "Archive": a pocket "Payments" > "Archive" and a pocket "Billing" > "Archive""#)
        expectEqual(ambiguous.hint, #"write the path of the one you mean, as "Payments" > "Archive", or its #id, which a query's row gives"#)
        guard case .failure(let nothing) = try run(["show", #""Plans" > "Archive""#], on: editor) else { return expect(false, "it showed one") }
        expectEqual(nothing.reason, "unknown_title")
        expectEqual(nothing.message, #"there's no shape called "Plans" > "Archive""#)
        guard case .failure(let holds) = try run(["show", #""Payments" > "Refund""#], on: editor) else { return expect(false, "it showed one") }
        expectEqual(holds.reason, "cannot_contain")
        expectEqual(holds.message, #""Payments" > "Refund" is a tile, which holds no board"#)
        guard case .failure(let bad) = try run(["show", #""Payments" >"#], on: editor) else { return expect(false, "it showed one") }
        expectEqual(bad.reason, "invalid_params")
        expectEqual(editor.board, .root)
    },
])

/// A folder of the test's own for the pictures it takes, gone as the test ends.
@MainActor private func pictures() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("capture-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    afterThisTest { try? FileManager.default.removeItem(at: folder) }
    return folder
}

@MainActor let drawPathMoreTests = Suite("draw: paths, in, group, share, measure and capture", [
    test("in takes a path: the shape goes in the container there, and a title is found inside it first") {
        let org = Org(), editor = try org.editor()
        let result = try drawn(#"tile "Item" in "Plans" > "Payments""#, on: editor)
        expectEqual(result["on"]?["board"], .string(org.plans.description))
        let item = try require(editor.contents(of: BoardID(owner: org.plans)).shapes.first { $0.typed(as: Tile.self)?.props.label == "Item" })
        expectEqual(holder(of: item.id, in: editor), org.plansPayments)
        let inside = try drawn(#"tile "Checkout" in "Plans" > "Payments" finish: glossy"#, on: editor)
        expectEqual(rows(inside).first?["id"], .string(org.plansPaymentsCheckout.description), "its own title, inside the pen, before the other Checkouts")
        let holdsNone = try refused("tile \"Other\" in #\(org.untitled) > \"Checkout\"", on: editor)
        expectEqual(holdsNone.reason, "cannot_contain", "the path leads to a tile, which holds nothing")
        expectEqual(holdsNone.message, "#\(org.untitled.description.uppercased()) > \"Checkout\" is a tile, which holds no shapes")
    },
    test("group and ungroup name shapes by path; a lone title two shapes have is ambiguous") {
        let log = GroupLog()
        let org = Org(), editor = try org.editor([groupsPlugin(log)])
        let result = try drawn(#"group "Payments" > "Checkout" and "Payments" > "Refund""#, on: editor)
        expectEqual(rows(result).map { $0["did"] }, ["grouped"])
        expectEqual(rows(result).first?["shapes"], ["Checkout", "Refund"])
        expectEqual(log.calls.map(\.ids), [[org.paymentsCheckout, org.refund]])
        let gone = try drawn(#"ungroup "Payments" > "Refund""#, on: editor)
        expectEqual(rows(gone).map { $0["did"] }, ["ungrouped"])
        let twice = try refused(#"group "Payments" > "Checkout" and #\#(org.paymentsCheckout)"#, on: editor)
        expectEqual(twice.reason, "duplicate")
        expectEqual(try refused(#"group "Checkout" and "Solo""#, on: editor).reason, "ambiguous_title")
        let both = try refused(#"group "Billing" > "Invoice" and "Plans" > "Task""#, on: editor)
        expectEqual(both.reason, "several_boards")
    },
    test("share: takes a path for its host: the stand-in beside the shape it names") {
        let editor = try Harbor().editor([pens])
        let pen = AnyShapeRecord(ShapeRecord(Pen(CGRect(x: 0, y: 600, width: 1000, height: 600), label: "Pen")))
        let other = AnyShapeRecord(ShapeRecord(Pen(CGRect(x: 1200, y: 600, width: 600, height: 600), label: "Other")))
        editor.transact { $0.insert(pen); $0.insert(other) }
        let a = tile("A", CGRect(x: 40, y: 640, width: 120, height: 80), in: editor).id
        let b = tile("B", CGRect(x: 40, y: 820, width: 120, height: 80), in: editor).id
        let c = tile("C", CGRect(x: 40, y: 1000, width: 120, height: 80), in: editor).id
        let twin = tile("A", CGRect(x: 1240, y: 640, width: 120, height: 80), in: editor).id
        editor.transact { $0.setContainer([a, b, c], to: pen.id); $0.setContainer(twin, to: other.id) }
        let result = try drawn("""
            edge "Pen" > "A" -> "Deep"
            edge "Pen" > "B" -> "Deep" share: "Pen" > "A"
            """, on: editor)
        expectEqual(editor.relays().count, 1, "one relay for Deep, beside the Pen's A")
        let relay = try require(editor.relays().first)
        expectEqual(editor.linkEnds().map(\.from), [a, b])
        expectEqual(editor.linkEnds().map(\.to), [relay.id, relay.id])
        expectEqual(rows(result).last?["sharedWith"], "A")
        expectEqual(rows(result).last?["shared"], true)
        // The title alone is ambiguous between the two pens; the other pen's A has no relay beside it.
        expectEqual(try refused(#"edge "Pen" > "C" -> "Deep" share: "A""#, on: editor).reason, "ambiguous_title")
        let missing = try refused(#"edge "Other" > "A" -> "Deep" share: "Pen" > "B""#, on: editor)
        expectEqual(missing.reason, "invalid_value", "the host and the start are in different pens")
        let again = try drawn("""
            edge "Pen" > "A" -> "Deep"
            edge "Pen" > "B" -> "Deep" share: "Pen" > "A"
            """, on: editor)
        expectEqual(rows(again).map { $0["did"] }, ["unchanged", "unchanged"])
        expectEqual(rows(again).last?["sharedWith"], "A", "a run again says the same")
    },
    test("measure reads paths: the container is left out as in is, and two paths of one title are two shapes") {
        let editor = try drawEditor([pens, PocketsPlugin(), namedPockets])
        let script = #"tile "Payments" > "T""# + "\n" + #"tile "Billing" > "T""# + "\n" + #"tile board > "T" size: 200x100"#
        let measured = try run(["measure", "-"], on: editor, input: script).get()
        let shapes = try require(measured["shapes"]?.arrayValue)
        expectEqual(shapes.map { $0["title"] }, ["T", "T", "T"])
        expectEqual(shapes.map { $0["line"] }, [1, 2, 3])
        expectEqual(shapes.last?["size"], [200, 100])
        // The same path twice is one shape, written twice; an edge between two of them is laid with the shapes.
        guard case .failure(let twice) = try run(["measure", "-"], on: editor, input: #"tile "Payments" > "T""# + "\n" + #"tile "Payments" > "T""#) else {
            return expect(false, "measured one shape twice")
        }
        expectEqual(twice.reason, "duplicate")
        let linked = try run(["measure", "-"], on: editor, input: script + "\n" + #"edge "Payments" > "T" -> "Billing" > "T""#).get()
        expectEqual(linked["shapes"]?.arrayValue?.count, 3)
        // A lone title two of the script's shapes have is ambiguous to an edge, in a measure as in a draw.
        guard case .failure(let ambiguous) = try run(["measure", "-"], on: editor, input: script + "\n" + #"edge "T" -> "Billing" > "T""#) else {
            return expect(false, "measured an edge to one of three")
        }
        expectEqual(ambiguous.reason, "ambiguous_title")
        expectEqual(ambiguous.data?["line"], 4)
    },
    test("capture takes the same names for --shape and --in; an ambiguous title says to write the path or the id") {
        let org = Org(), editor = try org.editor(), folder = try pictures()
        let file = folder.appendingPathComponent("shape.png").path
        let paymentsPicture = try run(["capture", file, "--shape", #""Payments" > "Checkout""#], on: editor).get()
        let region = try require(paymentsPicture["region"]?.arrayValue)
        expectEqual(paymentsPicture["board"]?["shows"], "root")
        let billing = try run(["capture", file, "--shape", #"Billing>Checkout"#.replacingOccurrences(of: "Billing>Checkout", with: #""Billing" > "Checkout""#)], on: editor).get()
        expect(billing["region"] != .array(region), "a picture of the other Checkout")
        let boarded = try run(["capture", file, "--shape", #"board > "Checkout""#], on: editor).get()
        expect(boarded["region"] != billing["region"] && boarded["region"] != .array(region))
        let byID = try run(["capture", file, "--shape", "#\(org.untitled) > \"Checkout\""], on: editor).get()
        expect(byID["region"] != billing["region"])
        // A bare title is a title: Task is one shape, on Plans' board.
        let task = try run(["capture", file, "--shape", "Task"], on: editor).get()
        expectEqual(task["board"]?["shows"], .string(org.plans.description))
        guard case .failure(let ambiguous) = try run(["capture", file, "--shape", "Checkout"], on: editor) else { return expect(false, "pictured one of many") }
        expectEqual(ambiguous.reason, "ambiguous_title")
        expectEqual(ambiguous.hint, #"write the path of the one you mean, as "Payments" > "Checkout", or its #id, which a query's row gives"#)
        guard case .failure(let nothing) = try run(["capture", file, "--shape", #""Payments" > "Nothing""#], on: editor) else { return expect(false, "pictured nothing") }
        expectEqual(nothing.reason, "unknown_title")
        expectEqual(nothing.message, #"there's no shape called "Payments" > "Nothing""#)
        // --in names a subboard by a path, by an id, or by a title there is one of.
        let archive = try run(["capture", file, "--in", #""Billing" > "Archive""#], on: editor).get()
        expectEqual(archive["board"]?["shows"], .string(org.archiveB.description))
        let byTitle = try run(["capture", file, "--in", "Plans"], on: editor).get()
        expectEqual(byTitle["board"]?["shows"], .string(org.plans.description))
        guard case .failure(let two) = try run(["capture", file, "--in", "Archive"], on: editor) else { return expect(false, "pictured one of two") }
        expectEqual(two.reason, "ambiguous_title")
        expectEqual(two.message, #"2 shapes that hold boards are called "Archive": a pocket "Payments" > "Archive" and a pocket "Billing" > "Archive""#)
        expectEqual(two.hint, #"write the path of the one you mean, as "Payments" > "Archive", or its #id, which a query's row gives"#)
        guard case .failure(let bad) = try run(["capture", file, "--shape", #""Payments" >"#], on: editor) else { return expect(false, "pictured a bad name") }
        expectEqual(bad.reason, "invalid_params")
        // A path leading to a shape on another board than --in names is several boards.
        guard case .failure(let apart) = try run(["capture", file, "--in", "Plans", "--shape", #""Payments" > "Refund""#], on: editor) else { return expect(false, "pictured two boards") }
        expectEqual(apart.reason, "several_boards")
    },
])
