import AppKit
@_spi(Host) import Canvas
import CanvasRPC
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

/// A relationship whose far end reads `reading`, drawn to the pill `via` (the note itself for a note that is read directly).
private func relation(_ reading: EndReading, via: ShapeID? = nil) -> Relation {
    Relation(arrow: ShapeID(), type: ShapeID(), side: .from, far: ReadEnd(literal: via ?? reading.noteForTests, reading: reading))
}

extension EndReading {
    /// The note a reading names, for a fixture that reads it directly.
    var noteForTests: ShapeID? {
        switch self {
        case .note(let id), .notAdmitted(let id, _): id
        default: nil
        }
    }
}

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
            "customer": "Ann Lee",
            "guests": ["Ann Lee", "Bo Park"],
            "lineItems": [["product": "Mug", "quantity": 2], ["product": "Plate", "quantity": 1]],
            "rooms": [["city": "Leeds"], ["city": "York"], ["city": "Hull"]],
            "size": 12, "labels": ["size": "L", "color": "red"], "anything": ["x": 1], "payment": "cash", "count": 3,
        ])
        expectEqual(try t.content(id, "customer"), .text("Ann Lee"), "a field that named a note is text")
        expectEqual(try t.content(id, "guests"), .summary("Ann Lee, Bo Park"), "and a list of them a list of text")
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
            "customer": "Ann Lee", "shippingAddress": ["street": "12 Main St", "city": "Leeds"],
            "lineItems": [["product": "Mug", "quantity": 2], ["product": "Plate", "quantity": 1]],
            "status": "paid", "tags": ["gift", "mugs"], "gift": true,
        ])
        let rows = t.book.rows(of: id)
        expectEqual(rows.map(\.name), ["customer", "shipping address", "line items", "status", "tags", "gift", "gift note"])
        expectEqual(rows[0].content, .text("Ann Lee"))
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
    test("a type's long field name takes the row its kinds' words leave, not cut at its share with room beside it (paste 5: amount_ce…)") {
        let t = try Bench()
        let schema = #"{"type": "object", "properties": {"amount_in_minor_units": {"type": "integer"}, "currency": {"type": "string"}}, "required": ["amount_in_minor_units"]}"#
        let money = t.editor.addSlipType(schema, words: "Money.", at: CGPoint(x: 40, y: 900))
        let rows = t.book.rows(of: money)
        let long = try require(rows.first { $0.name.hasPrefix("amount") })
        expect(long.nameRect.width > TypesStyle.nameShare * long.rect.width, "past its share: \(long.nameRect.width) of \(long.rect.width)")
        expect(long.valueRect.minX > long.nameRect.maxX, "the kind's words still after it")
        // A note that is one keeps the same column, so a name is cut at the same place on both.
        let note = t.note([money], ["amount_in_minor_units": 1250, "currency": "EUR"])
        let noted = try require(t.book.rows(of: note).first { $0.name.hasPrefix("amount") })
        expect(noted.nameRect.width > TypesStyle.nameShare * noted.rect.width, "a note's too, cut where the type's is: \(noted.nameRect.width) of \(noted.rect.width)")
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
        let contents: [ShownRow.Content] = [.text("x"), .empty("add x"), .box(true), .choice("a"), .choice(nil), .summary("2 items"), .gone(ShapeID()), .fold("4 fields"), .fold(""), .related([], more: 0), .relationType(direction: "→", chips: [], more: 0)]
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
            [.plain, .plain, .wrong],                 // pills: a value, never needed
            [.plain, .plain, .plain],                 // a type's relation row: never marked
        ]
        for (content, looks) in zip(contents, expected) {
            expectEqual([nil, FieldClass.needed, .wrong].map { RowLook.of(content: content, mark: $0) }, looks, "\(content)")
            expectEqual(RowLook.of(content: content, mark: .warning), RowLook.of(content: content, mark: nil), "a warning draws nothing on \(content)")
        }
    },
    test("a row's pills are laid out from the column's left a gap apart, a live one for a note the app shows and a dashed one with the name it held for one it does not") {
        let t = try Bench()
        let ann = FieldFixtures.annLeeID, bo = FieldFixtures.boParkID
        guard case .related(let one, 0) = t.book.pills(of: [relation(.note(ann))], among: 1, width: 300) else { throw Failure("one pill") }
        expectEqual(one.count, 1)
        expectEqual(one[0].target, ann)
        expectEqual(one[0].x, 0)
        expect(one[0].width > 20, "a pill has a width")
        expect(one[0].isLive)
        expectEqual(one[0].label, "Ann Lee", "the name Mentions gives the note")
        guard case .related(let two, 0) = t.book.pills(of: [relation(.note(bo)), relation(.note(ann))], among: 2, width: 300) else { throw Failure("two pills") }
        expectEqual(two.map(\.target), [ann, bo], "by the name each shows")
        expectEqual(two[1].x, two[0].width + TypesStyle.pillGap)
        expect(two[1].x + two[1].width <= 300, "both fit in the column")
        let pill = ShapeID()
        t.editor.transact("Delete") { $0.delete([ann]) }
        guard case .related(let gone, _) = t.book.pills(of: [relation(.gone(called: "Ann Lee"), via: pill)], among: 1, width: 300) else { throw Failure("a pill") }
        expect(!gone[0].isLive, "a note that is gone is not live")
        expectEqual(gone[0].label, "Ann Lee", "the name it held")
        expectEqual(gone[0].target, nil)
        expectEqual(gone[0].destination, pill, "a click goes to the pill the arrow ends on")
        t.editor.undo()
        guard case .related(let back, _) = t.book.pills(of: [relation(.note(ann), via: pill)], among: 1, width: 300) else { throw Failure("a pill") }
        expect(back[0].isLive, "undo brings it back")
        expectEqual(back[0].destination, ann, "a live pill goes to its note, whatever pill it was read through")
    },
    test("every state of a far end is a pill: solid for a note, dashed for the rest, each with the words it holds, blank for a pill that stands for nothing") {
        let t = try Bench()
        let ann = FieldFixtures.annLeeID, pill = ShapeID()
        let states: [(EndReading, label: String, target: ShapeID?)] = [
            (.notAdmitted(ann, needs: "open"), "Ann Lee", ann),
            (.gone(called: "Acme"), "Acme", nil), (.gone(called: nil), FieldWords.noteGone, nil),
            (.unavailable(called: "Acme"), "Acme", nil), (.unavailable(called: nil), FieldWords.noteUnavailable, nil),
            (.query(called: "every client"), "every client", nil), (.empty, FieldWords.noteBlank, nil),
        ]
        for (state, label, target) in states {
            guard case .related(let shown, 0) = t.book.pills(of: [relation(state, via: pill)], among: 1, width: 300), let one = shown.first else { throw Failure("a pill for \(state)") }
            expect(!one.isLive, "\(state) is dashed")
            expectEqual(one.label, label, "\(state)")
            expectEqual(one.target, target)
            expectEqual(one.state, state)
            expectEqual(one.via, pill)
            expectEqual(one.destination, pill, "a dashed pill goes to the pill, never to a note")
            expect(!one.isWrong, "the check is not a pill's yet")
            expect(one.width > 4, "\(state) has a width")
        }
    },
    test("pills that do not fit are cut with `+N`, and what the row counts beyond its notes is counted in it; the first is always shown, cut to the column") {
        let t = try Bench()
        let ann = FieldFixtures.annLeeID, bo = FieldFixtures.boParkID
        guard case .related(let counted, let more) = t.book.pills(of: [relation(.note(ann)), relation(.note(bo))], among: 3, width: 300) else { throw Failure("pills") }
        expectEqual(counted.count, 2)
        expectEqual(more, 1, "the one that is no note is counted")
        let twelve = (0..<12).map { _ in relation(.note(ann)) }
        guard case .related(let cut, let rest) = t.book.pills(of: twelve, among: 12, width: 300) else { throw Failure("pills") }
        expect(rest > 0 && cut.count + rest == 12, "as many as fit, the rest counted: \(cut.count) and \(rest)")
        let last = try require(cut.last)
        expect(last.x + last.width + TypesStyle.pillGap + width("+\(rest)") <= 301, "the pills and the count fit the column")
        let long = String(repeating: "Ann Lee of the long name ", count: 12)
        t.editor.transact("Rename") { $0.update(ann) { $0[TitleProperty.self] = long } }
        guard case .related(let named, _) = t.book.pills(of: [relation(.note(ann))], among: 1, width: 120), t.editor.mentions?.resolve(ann).isLive == true else { throw Failure("a pill") }
        expect(named[0].width <= 120, "cut to the column")
    },
])
