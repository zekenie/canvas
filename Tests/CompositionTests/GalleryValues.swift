import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Find
import Foundation
import Locking
import Mentions
import Selection
import StickyNotes
import TestKit
import Titles
import Types

// The gallery's states for a note that is one (slice 11): its values in its rows as the plan's boards draw
// them, the row being typed in, a choice focused and its menu, the marks of the check (the look alone, through
// `rowBook.checks`: the whole panel with its ring is the check's own states), a value found, and the rows
// zoomed out and many. The types sit far off the stage, so a note is alone in view and its chip says what it is.
// Named for the board panel each answers: Main, Flow2 to Flow5.

private let single = CGSize(width: 440, height: 340)
private let tallNote = CGSize(width: 440, height: 440)
private let wideStage = CGSize(width: 900, height: 520)

/// The types go here: out of every state's view.
private let farOff = CGPoint(x: 3000, y: 3000)

/// Flow3 p2's Employee: the controls of the plan's second panel, in its order.
private let employeeControls: FieldFixtures.TypeText = (
    rowsTypeID(40), "Employee", "An employee has a name, an email, a birthday, a start date, whether they work remotely, and a role.",
    #"""
    {"type": "object", "properties": {
      "name": {"type": "string"}, "email": {"type": "string", "format": "email"}, "birthday": {"type": "string", "format": "date"},
      "startDate": {"type": "string", "format": "date"}, "remote": {"type": "boolean"},
      "role": {"enum": ["engineer", "designer", "manager"]}
    }, "required": ["name"]}
    """#)

private let speaker: FieldFixtures.TypeText = (rowsTypeID(41), "Speaker", "A speaker has a talk and a topic.", fieldsSchema(["talk", "topic"]))

/// Person with a phone: Flow4 p3.
private let personWithPhone: FieldFixtures.TypeText = (FieldFixtures.personID, "Person", "A person has a name, an email, a birthday and a phone.",
                                                       fieldsSchema(["name", "email", "birthday", "phone"], required: ["name"]))

extension CanvasEditor {
    /// A note that is each of the types, 200 x 200 at `origin`, saying `words` and holding `values`.
    @discardableResult
    func instance(of types: [ShapeID], words: String = "", _ values: JSONObject = [:], at origin: CGPoint = CGPoint(x: 100, y: 60),
                  id: ShapeID = ShapeID()) -> ShapeID {
        var note = ShapeRecord(id: id, StickyNote(frame: CGRect(origin: origin, size: CGSize(width: 200, height: 200)), text: MentionText(plain: words)))
        note[IsAProperty.self] = types.map(TypeLink.init)
        if !values.isEmpty { note[FieldValuesProperty.self] = FieldValues(values) }
        transact { $0.insert(AnyShapeRecord(note)) }
        return id
    }

    /// The types, off the stage.
    func offstage(_ types: [FieldFixtures.TypeText]) {
        for (place, type) in types.enumerated() { put(type, at: CGPoint(x: farOff.x + CGFloat(place) * 300, y: farOff.y)) }
    }
}

/// A problem at a path.
private func problem(_ path: FieldPath, _ kind: FieldClass) -> FieldProblem {
    FieldProblem(path: path, kind: kind, keyword: "gallery", place: [], message: "")
}

/// The rows' view of the note being edited, if any.
@MainActor
private func rowsView(_ stage: GalleryStage) -> RowsView? { stage.canvas.descendants(RowsView.self).first }

/// The world point on a row's value, `dx` in.
@MainActor
private func valuePoint(_ stage: GalleryStage, _ id: ShapeID, _ name: String, dx: CGFloat = 6) throws -> CGPoint {
    _ = stage.render(at: .zero)
    let row = try require(stage.editor.rowBook?.rows(of: id).first { $0.name == name }, "a row \(name)")
    return CGPoint(x: row.valueRect.minX + dx, y: row.rect.midY)
}

/// Begins editing a note on a row's value, as a click there does.
@MainActor
private func type(into stage: GalleryStage, _ id: ShapeID, _ name: String) throws {
    let point = try valuePoint(stage, id, name)
    stage.editor.selection = id
    expect(stage.editor.beginEditing(id, at: point))
}

@MainActor
let valueStates: [GalleryState] = [
    GalleryState("Flow2-p2-empty", answers: "Flow2 p2", "Ann's note is a Person: `add name`, `add email`, `add birthday`, faint italic", size: single) { stage in
        stage.editor.offstage([personThree])
        stage.editor.instance(of: [FieldFixtures.personID], words: "Ann Lee, staff engineer since 2021.")
        stage.editor.selection = nil
        return canvas(stage)
    },
    GalleryState("Main-p5-filled", answers: "Main 5", "the name filled, the email empty, the birthday a date as it reads: `Mar 3, 1990`", size: single) { stage in
        stage.editor.offstage([personThree])
        stage.editor.instance(of: [FieldFixtures.personID], words: "Ann Lee, staff engineer since 2021.", ["name": "Ann Lee", "birthday": "1990-03-03"])
        return canvas(stage)
    },
    GalleryState("Flow3-p1-typing", answers: "Flow3 p1", "the name row typed in: its value in a thin outline, the other rows faint (the caret is not drawn offscreen)", size: single) { stage in
        stage.editor.offstage([personThree])
        let id = stage.editor.instance(of: [FieldFixtures.personID], words: "Ann Lee, staff engineer since 2021.", ["name": "Ann Lee"])
        try type(into: stage, id, "name")
        return canvas(stage)
    },
    GalleryState("Flow3-p2-controls", answers: "Flow3 p2", "Employee: text, dates, a ticked box, and the role focused: `designer ▾` outlined", size: tallNote) { stage in
        stage.editor.offstage([employeeControls])
        let id = stage.editor.instance(of: [employeeControls.id], words: "Bo Park, designer.",
                                       ["name": "Bo Park", "email": "bo@acme.com", "birthday": "1988-06-12", "startDate": "2024-01-15", "remote": true, "role": "designer"],
                                       at: CGPoint(x: 100, y: 40))
        try type(into: stage, id, "name")
        for _ in 0..<8 where rowsView(stage)?.focusedRow != "role" { stage.window.press("\t", code: 48) }
        expectEqual(rowsView(stage)?.focusedRow, "role")
        return canvas(stage)
    },
    GalleryState("Flow3-p2-menu", answers: "Flow3 p2", "a click on the role: the menu it pops, a check by the stored one, a separator, None (outline)", isText: true) { stage in
        stage.editor.offstage([employeeControls])
        let id = stage.editor.instance(of: [employeeControls.id], words: "Bo Park, designer.", ["name": "Bo Park", "role": "designer"], at: CGPoint(x: 100, y: 40))
        stage.editor.selection = nil
        let point = stage.viewPoint(try valuePoint(stage, id, "role"))
        stage.press(at: point)
        stage.release(at: point)
        let menu = try require(stage.editor.menuToPopUp, "a menu")
        return .text(menu.menu.outline.joined(separator: "\n") + "\n")
    },
    GalleryState("Flow4-p2-two-types", answers: "Flow4 p2", "a note that is an Employee and a Speaker: Person's three rows, Employee's three, the speaker's two, each field once", size: tallNote) { stage in
        stage.editor.offstage([personThree, employeeThree, speaker])
        stage.editor.addTypeLink(FieldFixtures.personID, to: FieldFixtures.employeeID)
        stage.editor.instance(of: [FieldFixtures.employeeID, speaker.id], words: "Bo Park, designer, speaking in May.", ["name": "Bo Park", "talk": "Forms on a canvas"], at: CGPoint(x: 100, y: 40))
        return canvas(stage)
    },
    GalleryState("Flow4-p3-new-row", answers: "Flow4 p3", "Person gained a phone: Ann's note has an empty `add phone` row, her values as they were", size: single) { stage in
        stage.editor.offstage([personThree])
        stage.editor.instance(of: [FieldFixtures.personID], words: "Ann Lee, staff engineer since 2021.", ["name": "Ann Lee", "email": "ann@acme.com"])
        stage.editor.transact { $0.update(FieldFixtures.personID) { $0[TypeSchemaProperty.self] = SchemaText(personWithPhone.schema) } }
        return canvas(stage)
    },
    GalleryState("Flow4-p4-type-gone", answers: "Flow4 p4", "the Person type deleted: the note keeps its values and shows the type's dashed chip, no rows", size: single) { stage in
        stage.editor.offstage([personThree])
        stage.editor.instance(of: [FieldFixtures.personID], words: "Ann Lee, staff engineer since 2021.", ["name": "Ann Lee"])
        stage.editor.transact("Delete") { $0.delete([FieldFixtures.personID]) }
        return canvas(stage)
    },
    GalleryState("Flow5-p2-order", answers: "Flow5 p2", "an Order: the address and its items summarized, the status, the tags, a ticked box, `add gift note`; the customer's name as text", size: tallNote) { stage in
        stage.editor.offstage([FieldFixtures.order, FieldFixtures.person, FieldFixtures.address])
        stage.editor.instance(of: [FieldFixtures.orderID], words: "Ann's order.", orderValues, at: CGPoint(x: 100, y: 40))
        return canvas(stage)
    },
    GalleryState("Flow5-p7-values-a", answers: "Flow5 p7", "KindsA filled: text, number, date, box, choice, choices, list, group, another type's fields: every cell of the plan's `On a note` column", size: tallNote) { stage in
        stage.editor.offstage([FieldFixtures.everyKind.a, FieldFixtures.address])
        stage.editor.instance(of: [FieldFixtures.kindsAID], words: "A note of every kind.", [
            "name": "Ann", "price": 9.5, "due": "2026-03-03", "done": true, "status": "paid", "roles": ["engineer", "designer"], "tags": ["gift", "mugs"],
            "venue": ["name": "The Loft", "city": "Leeds"], "shippingAddress": ["street": "12 Main St", "city": "Leeds"],
        ], at: CGPoint(x: 100, y: 40))
        return canvas(stage)
    },
    GalleryState("Flow5-p7-values-b", answers: "Flow5 p7", "KindsB filled: a text, a list of text, a list of groups, a list of Address's fields, either, pairs, what no control suits, either with a group, an integer", size: tallNote) { stage in
        stage.editor.offstage([FieldFixtures.everyKind.b, FieldFixtures.person, FieldFixtures.address])
        stage.editor.instance(of: [FieldFixtures.kindsBID], words: "A note of the other kinds.", [
            "customer": "Bo Park", "guests": ["Ann Lee", "Bo Park"], "lineItems": [["product": "Mug", "quantity": 2], ["product": "Plate", "quantity": 1]],
            "rooms": [["street": "12 Main St", "city": "Leeds"]], "size": 12, "labels": ["size": "L", "colour": "red"], "anything": ["note": "x"],
            "payment": ["cardNumber": "4111"], "count": 3,
        ], at: CGPoint(x: 100, y: 40))
        return canvas(stage)
    },
    GalleryState("values-fold", answers: "Flow5 p7", "twenty fields: `+12 more ›` from the left edge; ten, four of them Person's: `from Person` and `4 fields ›`", size: wideStage) { stage in
        let parent: FieldFixtures.TypeText = (FieldFixtures.personID, "Person", "A person has a name, an email, a phone and a birthday.", fieldsSchema(["name", "email", "phone", "birthday"]))
        let child: FieldFixtures.TypeText = (FieldFixtures.employeeID, "Employee", "An employee has a role, a start date, a manager, a team, a desk and a badge.",
                                             fieldsSchema(["role", "startDate", "manager", "team", "desk", "badge"]))
        stage.editor.offstage([wideType(20, id: FieldFixtures.wideID, title: "Wide", words: "Twenty text fields."), parent, child])
        stage.editor.addTypeLink(FieldFixtures.personID, to: FieldFixtures.employeeID)
        stage.editor.instance(of: [FieldFixtures.wideID], words: "Twenty fields.", ["f1": "one", "f2": "two"], at: CGPoint(x: 60, y: 30))
        stage.editor.instance(of: [FieldFixtures.employeeID], words: "Bo Park.", ["role": "designer", "name": "Bo Park"], at: CGPoint(x: 480, y: 30))
        return canvas(stage)
    },
    GalleryState("values-long", "a long value is cut with an ellipsis at the column; a long list is cut and counted: `gift, mugs +2 ›`", size: single) { stage in
        stage.editor.offstage([FieldFixtures.everyKind.a, FieldFixtures.address])
        stage.editor.instance(of: [FieldFixtures.kindsAID], words: "Long values.", [
            "name": "A name that goes on and on past the end of the value column and keeps going",
            "tags": ["gift", "mugs", "plates", "candles", "bowls", "spoons", "forks", "knives", "glasses"],
        ], at: CGPoint(x: 100, y: 40))
        return canvas(stage)
    },
    GalleryState("values-focused-more", answers: "Flow5 p4", "a row with more in it focused: outlined, no card (the card is the form's)", size: single) { stage in
        stage.editor.offstage([FieldFixtures.everyKind.a, FieldFixtures.address])
        let id = stage.editor.instance(of: [FieldFixtures.kindsAID], words: "A note.", ["tags": ["gift", "mugs"], "venue": ["name": "The Loft", "city": "Leeds"]], at: CGPoint(x: 100, y: 40))
        try type(into: stage, id, "tags")
        stage.spin(0.05)
        return canvas(stage)
    },
    GalleryState("values-locked", "a locked note: the same rows", size: single) { stage in
        stage.editor.offstage([personThree])
        let id = stage.editor.instance(of: [FieldFixtures.personID], words: "Ann Lee.", ["name": "Ann Lee", "birthday": "1990-03-03"])
        stage.editor.lock([id])
        stage.editor.selection = nil
        return canvas(stage)
    },
    GalleryState("values-mark-wrong", answers: "Flow3 p3", "the look of a wrong value alone: `ann@` red with its wavy line (no ring: the check's own state draws the whole panel)", size: single) { stage in
        stage.editor.offstage([personThree])
        stage.editor.instance(of: [FieldFixtures.personID], words: "Ann Lee, staff engineer since 2021.", ["name": "Ann Lee", "email": "ann@", "birthday": "1990-03-03"])
        stage.editor.rowBook?.checks = { _ in FieldCheck(problems: [problem(FieldPath(field: "email"), .wrong)]) }
        stage.editor.selection = nil
        return canvas(stage)
    },
    GalleryState("values-mark-needed", answers: "Flow5 p6", "needed with no value: `add customer` amber; a wrong value inside a row: `2 items` red and underlined, its `›` gray", size: tallNote) { stage in
        stage.editor.offstage([FieldFixtures.order, FieldFixtures.person, FieldFixtures.address])
        var values = orderValues
        values["customer"] = nil
        values["lineItems"] = [["product": "Mug", "quantity": 0], ["product": "Plate", "quantity": 1]]
        stage.editor.instance(of: [FieldFixtures.orderID], words: "Ann's order.", values, at: CGPoint(x: 100, y: 40))
        stage.editor.rowBook?.checks = { _ in
            FieldCheck(problems: [problem(FieldPath(field: "customer"), .needed), problem(FieldPath(field: "lineItems").index(0).key("quantity"), .wrong),
                                  problem(FieldPath(field: "giftNote"), .needed)])
        }
        stage.editor.selection = nil
        return canvas(stage)
    },
    GalleryState("values-mark-fold", "a fold carries the worst mark of what it folds: `+12 more ›` red, and in the second note amber", size: wideStage) { stage in
        stage.editor.offstage([wideType(20, id: FieldFixtures.wideID, title: "Wide", words: "Twenty text fields.")])
        let wrong = stage.editor.instance(of: [FieldFixtures.wideID], words: "A wrong one folded.", ["f15": "x"], at: CGPoint(x: 60, y: 30))
        let needed = stage.editor.instance(of: [FieldFixtures.wideID], words: "A needed one folded.", ["f1": "x"], at: CGPoint(x: 480, y: 30))
        stage.editor.rowBook?.checks = { record in
            record.id == wrong ? FieldCheck(problems: [problem(FieldPath(field: "f15"), .wrong)]) : FieldCheck(problems: [problem(FieldPath(field: "f12"), .needed)])
        }
        _ = needed
        stage.editor.selection = nil
        return canvas(stage)
    },
    GalleryState("values-gone-type", "an Order whose Address is gone: the dashed chip in the shipping address row, its value kept", size: tallNote) { stage in
        stage.editor.offstage([FieldFixtures.order, FieldFixtures.person, FieldFixtures.address])
        stage.editor.instance(of: [FieldFixtures.orderID], words: "Ann's order.", orderValues, at: CGPoint(x: 100, y: 40))
        stage.editor.transact("Delete") { $0.delete([FieldFixtures.addressID]) }
        return canvas(stage)
    },
    GalleryState("values-found", "⌘F: a value found, its row's value marked", size: single) { stage in
        stage.editor.offstage([personThree])
        stage.editor.instance(of: [FieldFixtures.personID], words: "Ann Lee, staff engineer since 2021.", ["name": "Ann Lee", "birthday": "1990-03-03"])
        let find = try require(stage.editor.find)
        find.open()
        find.query = "lee"
        while find.isIndexing { stage.scheduler.advance(by: .zero) }
        _ = try awaitResult { await find.settled() }
        let out = canvas(stage)
        find.close()
        return out
    },
    GalleryState("values-zoomed-out", "notes that are one at 30%: two bars a row, the value's bar missing where the row is empty, red where it is wrong", size: CGSize(width: 560, height: 360)) { stage in
        stage.editor.offstage([FieldFixtures.order, FieldFixtures.person, FieldFixtures.address])
        stage.editor.instance(of: [FieldFixtures.orderID], words: "Ann's order.", orderValues, at: CGPoint(x: 40, y: 40))
        let ann = stage.editor.instance(of: [FieldFixtures.personID], words: "Ann Lee.", ["name": "Ann Lee", "email": "ann@"], at: CGPoint(x: 400, y: 40))
        stage.editor.rowBook?.checks = { record in record.id == ann ? FieldCheck(problems: [problem(FieldPath(field: "email"), .wrong)]) : .clean }
        stage.editor.selection = nil
        return canvas(stage, zoom: 0.3)
    },
    GalleryState("values-many", "a hundred and fifty notes that are one, at 40%: each draws its rows", size: CGSize(width: 1000, height: 800)) { stage in
        stage.editor.offstage([personThree])
        let people = ["Ann Lee", "Bo Park", "Cy Wu", "Di Fox", "Ed Roe"]
        var records: [AnyShapeRecord] = []
        for place in 0..<150 {
            var note = ShapeRecord(StickyNote(frame: CGRect(x: 30 + CGFloat(place % 10) * 250, y: 30 + CGFloat(place / 10) * 210, width: 200, height: 160),
                                              text: MentionText(plain: people[place % people.count])))
            note[IsAProperty.self] = [TypeLink(FieldFixtures.personID)]
            var values: JSONObject = ["name": .string(people[place % people.count])]
            if place % 3 == 0 { values["email"] = .string("p\(place)@acme.com") }
            note[FieldValuesProperty.self] = FieldValues(values)
            records.append(AnyShapeRecord(note))
        }
        stage.editor.transact("Add Notes") { transaction in records.forEach { transaction.insert($0) } }
        stage.editor.selection = nil
        return canvas(stage, zoom: 0.4)
    },
]

/// Board 5's Order, as panel 2 reads it.
private let orderValues: JSONObject = [
    "customer": "Ann Lee", "shippingAddress": ["street": "12 Main St", "city": "Leeds"],
    "lineItems": [["product": "Mug", "quantity": 2], ["product": "Plate", "quantity": 1]],
    "status": "paid", "tags": ["gift", "mugs"], "gift": true,
]
