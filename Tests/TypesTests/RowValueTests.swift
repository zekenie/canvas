import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import Mentions
import TestKit
import Titles
import Types

// The values of a note that is one, as its rows show them: every kind of field from the plan's table, empty
// and filled, over slips (which show rows where the memo shows none). Content only: the look is the check's
// mark and the note's own bitmaps' (StickyNotesTests' noteRowsTests).

@MainActor
private struct Bench {
    let editor: CanvasEditor
    var book: RowBook { editor.rowBook! }

    init(more: [any CanvasPlugin] = []) throws {
        editor = try rowFieldEditor(more: more)
        editor.addFieldSlips([FieldFixtures.everyKind.a, FieldFixtures.everyKind.b])
        editor.addFieldPeople()
    }

    /// A slip that is each of the types, with these values.
    @discardableResult
    func note(_ types: [ShapeID], _ values: JSONObject = [:], at origin: CGPoint = CGPoint(x: 40, y: 400)) -> ShapeID {
        let id = editor.addSlip("Ann", of: types, at: origin)
        set(id, values)
        return id
    }

    func set(_ id: ShapeID, _ values: JSONObject) {
        editor.transact { $0.update(id) { $0[FieldValuesProperty.self] = FieldValues(values) } }
    }

    func content(_ id: ShapeID, _ name: String) throws -> ShownRow.Content {
        try require(book.rows(of: id).first { $0.name == name }, "a row \(name)").content
    }

    func names(_ id: ShapeID) -> [String] { book.rows(of: id).map(\.name) }

    /// The names a link row's pills show, and how many more there are.
    func pills(_ id: ShapeID, _ name: String) throws -> (names: [String], more: Int) {
        guard case .links(let links, let more) = try content(id, name) else { throw Failure("\(name) is not links") }
        return (links.map { editor.fieldBook!.shown($0.link) }, more)
    }

    func shownLinks(_ id: ShapeID, _ name: String) throws -> [ShownLink] {
        guard case .links(let links, _) = try content(id, name) else { throw Failure("\(name) is not links") }
        return links
    }
}

/// What a test says when its setup is not what it expects.
private struct Failure: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

private let locale = Locale(identifier: "en_US")

/// A line's width as a row's text is set.
@MainActor private func width(_ text: String) -> CGFloat {
    (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: TypesStyle.rowFontSize)]).width
}

@MainActor let rowValueTests = Suite("Values in rows", [
    test("each kind of field reads as the plan's table says, empty and filled (KindsA)") {
        let t = try Bench()
        let id = t.note([FieldFixtures.kindsAID])
        expectEqual(t.names(id), ["name", "price", "due", "done", "status", "roles", "tags", "venue", "shipping address"], "nine fields, no fold")
        for name in ["name", "price", "due"] { expectEqual(try t.content(id, name), .empty("add \(name)"), "\(name), empty") }
        expectEqual(try t.content(id, "done"), .box(false), "a box never ticked is unticked")
        expectEqual(try t.content(id, "status"), .choice(nil))
        for (name, words) in [("roles", "add roles"), ("tags", "add tags"), ("venue", "add venue"), ("shipping address", "add shipping address")] {
            expectEqual(try t.content(id, name), .empty(words), "\(name) has no `›` while it is empty")
        }
        t.set(id, [
            "name": "Ann", "price": 9.5, "due": "2026-03-03", "done": true, "status": "paid",
            "roles": ["engineer", "designer"], "tags": ["gift", "mugs"],
            "venue": ["name": "The Loft", "city": "Leeds"], "shippingAddress": ["street": "12 Main St", "city": "Leeds"],
        ])
        expectEqual(try t.content(id, "name"), .text("Ann"))
        expectEqual(try t.content(id, "price"), .text("9.5"), "a number by its value")
        expectEqual(try t.content(id, "due"), .text(FieldText.shown("2026-03-03", as: .date, locale: locale)), "a date as shown")
        expectEqual(try t.content(id, "done"), .box(true))
        expectEqual(try t.content(id, "status"), .choice("paid"))
        expectEqual(try t.content(id, "roles"), .summary("engineer, designer"))
        expectEqual(try t.content(id, "tags"), .summary("gift, mugs"))
        expectEqual(try t.content(id, "venue"), .summary("The Loft, Leeds"))
        expectEqual(try t.content(id, "shipping address"), .summary("12 Main St, Leeds"))
        t.set(id, ["done": false, "status": "archived"])
        expectEqual(try t.content(id, "done"), .box(false), "an unticked box that was ticked once holds false, and looks the same")
        expectEqual(try t.content(id, "status"), .choice("archived"), "a value that is no option shows as itself")
    },
    test("each kind of field reads as the plan's table says, empty and filled (KindsB)") {
        let t = try Bench()
        let id = t.note([FieldFixtures.kindsBID])
        expectEqual(t.names(id), ["customer", "guests", "line items", "rooms", "size", "labels", "anything", "payment", "count"])
        for name in ["customer", "guests", "line items", "rooms", "size", "labels", "payment", "count"] {
            expectEqual(try t.content(id, name), .empty("add \(name)"), "\(name), empty")
        }
        expectEqual(try t.content(id, "anything"), .summary("edited as JSON in the panel"), "what no control suits says so, empty or not")
        t.set(id, [
            "customer": link(to: FieldFixtures.annLeeID, "Ann Lee"),
            "guests": [link(to: FieldFixtures.annLeeID, "Ann Lee"), link(to: FieldFixtures.boParkID, "Bo Park")],
            "lineItems": [["product": "Mug", "quantity": 2], ["product": "Plate", "quantity": 1]],
            "rooms": [["city": "Leeds"], ["city": "York"], ["city": "Hull"]],
            "size": 12, "labels": ["size": "L", "color": "red"], "anything": ["x": 1], "payment": "cash", "count": 3,
        ])
        expectEqual(try t.pills(id, "customer").names, ["Ann Lee"], "a pointer is its pill")
        expectEqual(try t.pills(id, "guests").names, ["Ann Lee", "Bo Park"])
        expectEqual(try t.pills(id, "guests").more, 0)
        expectEqual(try t.content(id, "line items"), .summary("2 items"))
        expectEqual(try t.content(id, "rooms"), .summary("3 items"))
        expectEqual(try t.content(id, "size"), .text("12"), "either of two plain kinds: the value, as it is")
        t.set(id, ["size": "L"])
        expectEqual(try t.content(id, "size"), .text("L"))
        t.set(id, ["labels": ["size": "L", "color": "red"]])
        expectEqual(try t.content(id, "labels"), .summary("color: red, +1"), "the first pair, then how many more")
        t.set(id, ["anything": ["x": 1]])
        expectEqual(try t.content(id, "anything"), .summary("edited as JSON in the panel"))
        t.set(id, ["payment": "cash"])
        expectEqual(try t.content(id, "payment"), .summary("cash"), "either with a branch that is not plain has a card: its summary")
        t.set(id, ["count": 3])
        expectEqual(try t.content(id, "count"), .text("3"))
    },
    test("board 5's Order reads as panel 2: the customer, a summary of the address and the items, the status, the tags, the box, the note still to add") {
        let t = try Bench()
        let id = t.note([FieldFixtures.orderID], [
            "customer": link(to: FieldFixtures.annLeeID, "Ann Lee"), "shippingAddress": ["street": "12 Main St", "city": "Leeds"],
            "lineItems": [["product": "Mug", "quantity": 2], ["product": "Plate", "quantity": 1]],
            "status": "paid", "tags": ["gift", "mugs"], "gift": true,
        ])
        let rows = t.book.rows(of: id)
        expectEqual(rows.map(\.name), ["customer", "shipping address", "line items", "status", "tags", "gift", "gift note"])
        guard case .links(let customer, 0) = rows[0].content, customer.count == 1 else { throw Failure("the customer is one pill") }
        expectEqual(customer[0].link, FieldLink(target: FieldFixtures.annLeeID, stored: "Ann Lee"))
        expectEqual(Array(rows.map(\.content).dropFirst()), [.summary("12 Main St, Leeds"), .summary("2 items"), .choice("paid"), .summary("gift, mugs"),
                                          .box(true), .empty("add gift note")])
        for row in rows {
            expect(row.valueRect.minX > row.nameRect.maxX && row.valueRect.maxX == row.rect.maxX, "\(row.name)'s value is in the column after its name")
            expect(!row.isNeeded, "a note's name has no dot: needed is the check's")
        }
    },
    test("a list cut to the column ends `+N`; the first item alone is kept whole and cut when it is drawn") {
        let t = try Bench()
        let id = t.note([FieldFixtures.kindsAID], ["tags": ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel"]])
        let row = try require(t.book.rows(of: id).first { $0.name == "tags" })
        guard case .summary(let text) = row.content else { throw Failure("a summary") }
        let room = row.valueRect.width - width("›") - TypesStyle.partGap
        expect(text.hasSuffix(" +3") || text.range(of: #" \+\d+$"#, options: .regularExpression) != nil, "ends with how many more: \(text)")
        expect(width(text) <= room + 1, "it fits: \(width(text)) in \(room)")
        let shown = text.components(separatedBy: " +")[0].components(separatedBy: ", ").count
        expectEqual(text, ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel"].prefix(shown).joined(separator: ", ") + " +\(8 - shown)")
        let long = String(repeating: "x", count: 60)
        t.set(id, ["tags": [.string(long), "b"]])
        guard case .summary(let first)? = t.book.rows(of: id).first(where: { $0.name == "tags" })?.content else { throw Failure("a summary") }
        expectEqual(first, "\(long) +1", "the first item alone, the rest counted")
        t.set(id, ["name": .string(String(repeating: "y", count: 2000))])
        guard case .text(let kept)? = t.book.rows(of: id).first(where: { $0.name == "name" })?.content else { throw Failure("text") }
        expect(kept.count <= RowBook.longestShown, "a long text is kept to a bound")
    },
    test("a default in the schema fills nothing in: an empty row stays empty") {
        let t = try Bench()
        let type = t.editor.addSlipType(#"{"type": "object", "properties": {"nick": {"type": "string", "default": "Annie"}, "done": {"type": "boolean", "default": true}}}"#,
                                        words: "Defaults.", at: CGPoint(x: 40, y: 900))
        let id = t.note([type])
        expectEqual(try t.content(id, "nick"), .empty("add nick"))
        expectEqual(try t.content(id, "done"), .box(false))
    },
    test("a note of two types has each field once, in the chain's order") {
        let t = try Bench()
        let id = t.note([FieldFixtures.employeeID, FieldFixtures.addressID])
        expectEqual(t.names(id), ["name", "email", "role", "start date", "street", "city", "postcode"])
        let both = t.note([FieldFixtures.personID, FieldFixtures.employeeID], at: CGPoint(x: 440, y: 400))
        expectEqual(t.names(both), ["name", "email", "role", "start date"], "a field both types name shows once")
    },
    test("the fold on a note: `+12 more`, and `from Person` over what a type builds on") {
        let t = try Bench()
        let wide = t.editor.addSlipType(FieldFixtures.wide(20).schema, words: "Wide.", at: CGPoint(x: 40, y: 900), id: FieldFixtures.wideID)
        let id = t.note([wide])
        let rows = t.book.rows(of: id)
        expectEqual(rows.map(\.name), (1...8).map { "f\($0)" } + ["+12 more"])
        expectEqual(rows.last?.content, .fold(""))
        t.set(id, ["f3": "x", "f15": "y"])
        expectEqual(try t.content(id, "f3"), .text("x"), "a field in view shows its value")
        expectEqual(t.names(id).count, 9, "a value in a folded row changes no row")
        let child = t.editor.addSlipType(FieldFixtures.wide(9).schema.replacingOccurrences(of: "\"f", with: "\"g"), words: "A child.", at: CGPoint(x: 440, y: 900))
        t.editor.addTypeLink(FieldFixtures.personID, to: child)
        let note = t.note([child], at: CGPoint(x: 440, y: 400))
        let nine = t.book.rows(of: note)
        expectEqual(nine.map(\.name), ["from Person"] + (1...9).map { "g\($0)" }, "eleven fields, two of them Person's")
        expectEqual(nine.first?.content, .fold("2 fields"))
        expectEqual(nine.first?.tick, FieldFixtures.personID)
    },
    test("a type that is gone leaves its notes no rows and keeps their values; undo brings them back") {
        let t = try Bench()
        let id = t.note([FieldFixtures.orderID], ["customer": "Ann Lee", "status": "paid"])
        expectEqual(t.names(id).count, 7)
        t.editor.removeType(FieldFixtures.orderID)
        expectEqual(t.book.rows(of: id), [], "no fields to show")
        expectEqual(t.editor.document[id]?[FieldValuesProperty.self], FieldValues(["customer": "Ann Lee", "status": "paid"]), "its values are kept")
        t.editor.undo()
        expectEqual(try t.content(id, "status"), .choice("paid"))
    },
    test("a field that is another type's fields, where the type is gone, is its dashed chip with the value kept; a summary again after undo") {
        let t = try Bench()
        let id = t.note([FieldFixtures.orderID], ["shippingAddress": ["street": "12 Main St", "city": "Leeds"], "rooms": 1])
        expectEqual(try t.content(id, "shipping address"), .summary("12 Main St, Leeds"))
        t.editor.removeType(FieldFixtures.addressID)
        expectEqual(try t.content(id, "shipping address"), .gone(FieldFixtures.addressID))
        expectEqual(t.editor.document[id]?[FieldValuesProperty.self]?.value(at: FieldPath(field: "shippingAddress").key("city")), "Leeds", "the value stays in the note")
        let b = t.note([FieldFixtures.kindsAID], ["shippingAddress": ["city": "Leeds"]], at: CGPoint(x: 440, y: 400))
        expectEqual(try t.content(b, "shipping address"), .gone(FieldFixtures.addressID), "every note that holds those fields")
        for _ in 0..<3 { t.editor.undo() }   // the second note's values, the note, and the type's removal
        expectEqual(try t.content(id, "shipping address"), .summary("12 Main St, Leeds"))
    },
    test("a value changed builds that shape's rows again and no other's; a move builds none and the rects follow") {
        let t = try Bench()
        let a = t.note([FieldFixtures.personID], ["name": "Ann"]), b = t.note([FieldFixtures.personID], ["name": "Bo"], at: CGPoint(x: 440, y: 400))
        _ = t.book.rows(of: a); _ = t.book.rows(of: b)
        let built = t.book.rowsShown
        _ = t.book.rows(of: a); _ = t.book.rows(of: b)
        expectEqual(t.book.rowsShown, built, "kept")
        t.set(a, ["name": "Anna"])
        expectEqual(try t.content(a, "name"), .text("Anna"))
        _ = t.book.rows(of: b)
        expectEqual(t.book.rowsShown, built + 1, "one shape's rows, not both")
        let before = try require(t.book.rows(of: b).first).rect
        let count = t.book.rowsShown
        t.editor.transact("Move") { $0.translate([b], by: CGPoint(x: 100, y: 50)) }
        let after = try require(t.book.rows(of: b).first).rect
        expectEqual(t.book.rowsShown, count, "a drag builds no row")
        expectEqual(after, before.offsetBy(dx: 100, dy: 50), "the rects are where the shape now is")
    },
    test("a value written on a board that is not shown lets that shape's kept rows go") {
        let t = try Bench(more: [PocketsPlugin()])
        let pocket = t.editor.add(Pocket(CGRect(x: 0, y: 900, width: 100, height: 100)))
        let a = t.note([FieldFixtures.personID], ["name": "Ann"])
        expectEqual(try t.content(a, "name"), .text("Ann"))
        let built = t.book.rowsShown
        expect(t.editor.showBoard(BoardID(owner: pocket)), "the pocket's board is shown")
        t.editor.transact(on: .root, "Rename") { $0.update(a) { $0[FieldValuesProperty.self] = FieldValues(["name": "Anna"]) } }
        expect(t.editor.showBoard(.root), "and back")
        expectEqual(try t.content(a, "name"), .text("Anna"), "read again, not kept")
        expectEqual(t.book.rowsShown, built + 1, "that shape's rows were built again, once")
    },
    test("a type's schema changing builds every instance's rows again") {
        let t = try Bench()
        let a = t.note([FieldFixtures.personID], ["name": "Ann"])
        expectEqual(t.names(a), ["name", "email"])
        t.editor.transact { $0.update(FieldFixtures.personID) { $0[TypeSchemaProperty.self] = SchemaText(#"{"type": "object", "properties": {"name": {"type": "string"}, "email": {"type": "string"}, "phone": {"type": "string"}}}"#) } }
        expectEqual(t.names(a), ["name", "email", "phone"])
        expectEqual(try t.content(a, "name"), .text("Ann"))
    },
    test("`RowLook.of` reads each content against each mark") {
        let contents: [ShownRow.Content] = [.text("x"), .empty("add x"), .box(true), .choice("a"), .choice(nil), .summary("2 items"), .gone(ShapeID()), .fold("4 fields"), .fold(""), .links([], more: 0)]
        let expected: [[RowLook]] = [
            // nil, needed, wrong
            [.plain, .plain, .wrong],                 // text
            [.empty, .needed, .empty],                // empty: nothing to be wrong about
            [.plain, .plain, .wrong],                 // a box is never needed
            [.plain, .plain, .wrong],                 // a choice
            [.empty, .needed, .empty],                // an empty choice
            [.plain, .neededInside, .wrong],          // a summary
            [.plain, .plain, .plain],                 // a gone type: never marked
            [.plain, .neededInside, .wrong],          // a fold
            [.plain, .neededInside, .wrong],
            [.plain, .plain, .wrong],                 // a pointer's pills: a value, never needed
        ]
        for (content, looks) in zip(contents, expected) {
            expectEqual([nil, FieldClass.needed, .wrong].map { RowLook.of(content: content, mark: $0) }, looks, "\(content)")
            expectEqual(RowLook.of(content: content, mark: .warning), RowLook.of(content: content, mark: nil), "a warning draws nothing on \(content)")
        }
    },
    test("a pointer is a pill for the note it points at, in the column from its left; a list is pills a gap apart") {
        let t = try Bench()
        let id = t.note([FieldFixtures.kindsBID], ["customer": link(to: FieldFixtures.annLeeID, "Ann Lee"),
                                                   "guests": [link(to: FieldFixtures.annLeeID, "Ann Lee"), link(to: FieldFixtures.boParkID, "Bo Park")]])
        let one = try t.shownLinks(id, "customer")
        expectEqual(one.count, 1)
        expectEqual(one[0].x, 0)
        expect(one[0].width > 20, "a pill has a width")
        expect(one[0].isLive)
        let two = try t.shownLinks(id, "guests")
        expectEqual(two.map(\.link.target), [FieldFixtures.annLeeID, FieldFixtures.boParkID])
        expectEqual(two[1].x, two[0].width + TypesStyle.linkGap)
        let value = try require(t.book.rows(of: id).first { $0.name == "guests" }).valueRect.width
        expect(two[1].x + two[1].width <= value, "both fit in the column")
    },
    test("a list that does not fit is cut with `+N`: what is not a token is counted in it, and a list of none is the text") {
        let t = try Bench()
        let id = t.note([FieldFixtures.kindsBID])
        let ann = link(to: FieldFixtures.annLeeID, "Ann Lee"), bo = link(to: FieldFixtures.boParkID, "Bo Park")
        t.set(id, ["guests": [ann, "someone", bo]])
        let counted = try t.pills(id, "guests")
        expectEqual(counted.names, ["Ann Lee", "Bo Park"])
        expectEqual(counted.more, 1, "the one that is no token is counted")
        t.set(id, ["guests": .array(Array(repeating: ann, count: 12))])
        let cut = try t.pills(id, "guests")
        expect(cut.more > 0 && cut.names.count + cut.more == 12, "as many as fit, the rest counted: \(cut)")
        let shown = try t.shownLinks(id, "guests"), room = try require(t.book.rows(of: id).first { $0.name == "guests" }).valueRect.width
        let last = try require(shown.last)
        expect(last.x + last.width + TypesStyle.linkGap + width("+\(cut.more)") <= room + 1, "the pills and the count fit the column")
        t.set(id, ["guests": ["someone", "no one"]])
        expectEqual(try t.content(id, "guests"), .text("someone, no one"), "no token: the text as stored")
    },
    test("a value in a pointer field that is no token reads as its text; a pill wider than the column is cut to it") {
        let t = try Bench()
        let id = t.note([FieldFixtures.kindsBID], ["customer": "Ann Lee"])
        expectEqual(try t.content(id, "customer"), .text("Ann Lee"), "the text as stored (the check calls it wrong)")
        let long = String(repeating: "Ann Lee of the long name ", count: 12)
        t.editor.transact("Rename") { $0.update(FieldFixtures.annLeeID) { $0[TitleProperty.self] = long } }
        t.set(id, ["customer": link(to: FieldFixtures.annLeeID, "Ann Lee")])
        let pill = try require(try t.shownLinks(id, "customer").first)
        let room = try require(t.book.rows(of: id).first { $0.name == "customer" }).valueRect.width
        expect(pill.width <= room, "cut to the column: \(pill.width) in \(room)")
    },
    test("a pointer's type that is gone is the type's dashed chip, the value kept; a target that is gone is a dashed pill with the name it held") {
        let t = try Bench()
        let id = t.note([FieldFixtures.kindsBID], ["customer": link(to: FieldFixtures.annLeeID, "Ann Lee"), "guests": [link(to: FieldFixtures.boParkID, "Bo Park")]])
        t.editor.transact("Delete") { $0.delete([FieldFixtures.annLeeID]) }
        let gone = try require(try t.shownLinks(id, "customer").first)
        expect(!gone.isLive, "a target that is gone is not live")
        expectEqual(gone.link.stored, "Ann Lee", "the name it held")
        expectEqual(try t.pills(id, "customer").names, ["Ann Lee"])
        t.editor.undo()
        expect(try require(try t.shownLinks(id, "customer").first).isLive, "undo brings it back")
        t.editor.removeType(FieldFixtures.personID)
        expectEqual(try t.content(id, "customer"), .gone(FieldFixtures.personID))
        expectEqual(try t.content(id, "guests"), .gone(FieldFixtures.personID))
        expectEqual(t.editor.document[id]?[FieldValuesProperty.self]?.value(at: FieldPath(field: "customer")), link(to: FieldFixtures.annLeeID, "Ann Lee"), "its value is kept")
    },
    test("a frame draws each pill straight into the context, none through an attachment's image, named as its note is now: a rename shows on the next frame") {
        let t = try Bench()
        let id = t.note([FieldFixtures.kindsBID], ["customer": link(to: FieldFixtures.annLeeID, "Ann Lee"),
                                                   "guests": [link(to: FieldFixtures.annLeeID, "Ann Lee"), link(to: FieldFixtures.boParkID, "Bo Park")]])
        let size = CGSize(width: 900, height: 900)
        #if DEBUG
        let straight = MentionDrawingCounts.pillsDrawnStraight
        #endif
        let before = renderBitmap(t.editor, size: size)
        #if DEBUG
        expectEqual(MentionDrawingCounts.pillsDrawnStraight, straight + 3, "the customer and two guests")
        #endif
        let customer = try require(t.book.rows(of: id).first { $0.name == "customer" })
        let pill = try require(try t.shownLinks(id, "customer").first)
        let drawn = CGRect(x: customer.valueRect.minX + pill.x, y: customer.rect.minY, width: pill.width, height: customer.rect.height)
        expect((Int(drawn.minX)..<Int(drawn.maxX)).contains { x in pixel(before, at: CGPoint(x: CGFloat(x), y: drawn.midY))[0] < 128 }, "the name's ink, in the pill")
        t.editor.transact("Rename") { $0.update(FieldFixtures.annLeeID) { $0[TitleProperty.self] = "Anna Lee" } }
        let after = renderBitmap(t.editor, size: size)
        expect(changedPixels(before, after, in: customer.rect) > 0, "the new name, on the frame after the rename")
        #if DEBUG
        expectEqual(MentionDrawingCounts.pillsDrawnStraight, straight + 6)
        #endif
        t.editor.undo()
        expectEqual(changedPixels(before, renderBitmap(t.editor, size: size), in: customer.rect), 0, "undone: as it was")
    },
    test("a target renamed lets go of the rows of the notes that point at it and nobody else's; a keystroke in its words that leaves its name lets go of none") {
        let t = try Bench()
        let pointing = t.note([FieldFixtures.kindsBID], ["customer": link(to: FieldFixtures.annLeeID, "Ann Lee")], at: CGPoint(x: 40, y: 400))
        let other = t.note([FieldFixtures.kindsBID], ["customer": link(to: FieldFixtures.boParkID, "Bo Park")], at: CGPoint(x: 340, y: 400))
        let plain = t.note([FieldFixtures.kindsBID], ["guests": ["x"]], at: CGPoint(x: 640, y: 400))
        for id in [pointing, other, plain] { _ = t.book.rows(of: id) }
        let built = t.book.rowsShown
        t.editor.transact("Words") { $0.update(FieldFixtures.annLeeID, as: RowSlip.self) { $0.props.text = MentionText(plain: "She is a person.") } }
        for id in [pointing, other, plain] { _ = t.book.rows(of: id) }
        expectEqual(t.book.rowsShown, built, "words below the name: nobody lets go of anything")
        t.editor.transact("Rename") { $0.update(FieldFixtures.annLeeID) { $0[TitleProperty.self] = "Anna Lee" } }
        for id in [pointing, other, plain] { _ = t.book.rows(of: id) }
        expectEqual(t.book.rowsShown, built + 1, "the rename: the one that points at her is built again, nobody else")
        expectEqual(try t.pills(pointing, "customer").names, ["Anna Lee"])
        expectEqual(try t.pills(other, "customer").names, ["Bo Park"])
    },
])
