import AppKit
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CoreGraphics
import Foundation
import Locking
import Mentions
import Selection
import StickyNotes
import TestKit
import Types

// The card a row with more in it opens, and the form in the panel (slices 11 and 12): the states of one track,
// added to `galleryStates` (GalleryTypesLook.swift). Each builds board 5's Order from the shared fixtures
// (`FieldFixtures`, in CanvasTesting), clicks a real row of a real note as a person does (`click`: the press and
// release on the row's value, which begins the note's editing there and asks for the card on the next turn; on a
// type's note, a locked note, the card opens at once) and draws the canvas, the card a subview of it, hung from
// that row. A wrong cell is red from the real check. The panel's states draw the form alone at 260 wide (`formPicture`).

private let stageSize = CGSize(width: 640, height: 400)
private let tallStage = CGSize(width: 640, height: 480)

/// The Order, Address, Person, Employee and the kinds' types as notes, out of view but for `visible`, Employee a Person.
@MainActor
private func addTypes(_ stage: GalleryStage, _ types: [FieldFixtures.TypeText], visible: ShapeID? = nil) {
    for (place, type) in types.enumerated() {
        let at = type.id == visible ? CGPoint(x: 40, y: 50) : CGPoint(x: 3000, y: 100 + CGFloat(place) * 300)
        let frame = CGRect(origin: at, size: CGSize(width: 320, height: 220))
        stage.editor.addTypeNote(type.schema, text: MentionText(plain: type.words), title: type.title, frame: frame, id: type.id)
    }
    if types.contains(where: { $0.id == FieldFixtures.employeeID }), types.contains(where: { $0.id == FieldFixtures.personID }) {
        stage.editor.addTypeLink(FieldFixtures.personID, to: FieldFixtures.employeeID)
    }
}

private let orderTypes = [FieldFixtures.person, FieldFixtures.address, FieldFixtures.employee, FieldFixtures.order]

/// A note that is each of the types, 320 wide at (40, 50), saying `words`.
@MainActor
private func instance(_ stage: GalleryStage, of types: [ShapeID], words: String = "Order for Ann: two mugs, ships Friday.", height: CGFloat = 220,
                      at origin: CGPoint = CGPoint(x: 40, y: 50)) -> ShapeID {
    let note = stage.editor.add(StickyNote(frame: CGRect(origin: origin, size: CGSize(width: 320, height: height)), text: MentionText(plain: words)))
    stage.editor.addTypeLink(types[0], to: note)
    for type in types.dropFirst() { stage.editor.addTypeLink(type, to: note) }
    return note
}

/// Order's values as board 5 draws them.
@MainActor
private func fillOrder(_ stage: GalleryStage, _ note: ShapeID, quantity: JSONValue = 1) {
    let writer = stage.editor.fieldWriter
    writer?.set(["street": "12 Main St", "city": "Leeds"], at: FieldPath(field: "shippingAddress"), of: note)
    writer?.set([["product": "Mug", "quantity": 2, "price": 12], ["product": "Plate", "quantity": quantity, "price": 9.5]], at: FieldPath(field: "lineItems"), of: note)
    writer?.set("paid", at: FieldPath(field: "status"), of: note)
    writer?.set(["gift", "mugs"], at: FieldPath(field: "tags"), of: note)
    writer?.set(true, at: FieldPath(field: "gift"), of: note)
}

/// A click on a row of `note` (a named field's, or the `nth` fold's) as a person's: the select tool's press and release on the
/// row's value (a fold's words), at the camera now. The note begins editing in that row and the card opens on the next turn;
/// on a type's note and a locked note it opens at once. The card hangs from that real row.
@MainActor
private func click(_ stage: GalleryStage, _ note: ShapeID, row name: String? = nil, fold nth: Int? = nil) throws {
    let rows = try require(stage.editor.rowBook).rows(of: note)
    let row: ShownRow
    if let nth {
        let folds = rows.filter { $0.path == nil }
        row = try require(folds.indices.contains(nth) ? folds[nth] : nil, "a fold")
    } else {
        row = try require(rows.first { $0.name == name }, "a row \(name ?? "")")
    }
    let x = row.valueRect == .zero ? row.rect.minX + 8 : row.valueRect.minX + 8
    let point = stage.viewPoint(CGPoint(x: x, y: row.rect.midY))
    stage.press(at: point)
    stage.release(at: point)
    stage.spin()
    stage.spin()
    expect(stage.editor.fieldCards?.openTarget != nil, "the click on \(name ?? "the fold") opened its card")
}

/// The card's form: the one the click opened.
@MainActor
private func openForm(_ stage: GalleryStage) throws -> FieldFormView {
    try require(stage.editor.fieldCards?.openForm, "an open card")
}

/// An Order with its values and its card open at `name` (the row's words), clicked on its real row.
@MainActor
private func orderCard(_ stage: GalleryStage, _ name: String, quantity: JSONValue = 1) throws -> GalleryOutput {
    addTypes(stage, orderTypes)
    let note = instance(stage, of: [FieldFixtures.orderID])
    fillOrder(stage, note, quantity: quantity)
    try click(stage, note, row: name)
    return .image(stage.picture())
}

/// A note of one of the kinds' types (KindsA or KindsB), its card open at `name` by a click on the row; or the type's own note, read.
@MainActor
private func kindsCard(_ stage: GalleryStage, _ name: String, of kind: FieldFixtures.TypeText, values: [(String, JSONValue)] = [], mode: FieldFormMode = .values) throws -> GalleryOutput {
    let (a, b) = FieldFixtures.everyKind
    addTypes(stage, [FieldFixtures.person, FieldFixtures.address, a, b], visible: mode == .kinds ? kind.id : nil)
    let note = mode == .kinds ? kind.id : instance(stage, of: [kind.id], words: "A note of every kind.")
    for (key, value) in values { stage.editor.fieldWriter?.set(value, at: FieldPath(field: key), of: note) }
    try click(stage, note, row: name)
    return .image(stage.picture())
}

/// A type's note, with its card open at `name`, read.
@MainActor
private func typeCard(_ stage: GalleryStage, of type: FieldFixtures.TypeText, _ name: String) throws -> GalleryOutput {
    addTypes(stage, orderTypes + [FieldFixtures.everyKind.b], visible: type.id)
    try click(stage, type.id, row: name)
    return .image(stage.picture())
}

/// A table of `columns` text columns, with a fixed id, for what no board type has.
private let tableID = ShapeID(UUID(uuidString: "0E5B1A08-0000-4000-8000-0000000000A8")!)

private func tableType(columns: Int) -> FieldFixtures.TypeText {
    let properties = (0..<columns).map { "\"\(["sku", "name", "color", "size", "stock", "note", "shelf", "bin"][$0 % 8])\": { \"type\": \"string\" }" }.joined(separator: ", ")
    return (tableID, "Stock", "A stock list of \(columns) columns.", "{ \"type\": \"object\", \"properties\": { \"rows\": { \"type\": \"array\", \"items\": { \"type\": \"object\", \"properties\": { \(properties) } } } } }")
}

@MainActor
let cardStates: [GalleryState] = [
    // Flow5
    GalleryState("Flow5-p4-open-row", answers: "Flow5 p4", "a click on the shipping address row: its card under Address's chip, street, city, `add postcode`; the row outlined", size: stageSize) { stage in
        try orderCard(stage, "shipping address")
    },
    GalleryState("Flow5-p5-list", answers: "Flow5 p5", "a click on line items: a table, the gray names, Mug and Plate, the `add` line", size: stageSize) { stage in
        try orderCard(stage, "line items")
    },
    GalleryState("Flow5-p6-wrong-cell", answers: "Flow5 p6", "the same with a quantity of 0: the cell red and underlined from the real check, `2 items` red behind the card", size: stageSize) { stage in
        try orderCard(stage, "line items", quantity: 0)
    },
    GalleryState("Flow5-p7-list-of-values", answers: "Flow5 p7", "tags: one column, a line each, the waiting line", size: stageSize) { stage in
        try orderCard(stage, "tags")
    },
    GalleryState("Flow5-p7-group", answers: "Flow5 p7", "a venue's two rows, name and city", size: stageSize) { stage in
        try kindsCard(stage, "venue", of: FieldFixtures.everyKind.a, values: [("venue", ["name": "The Loft", "city": "Leeds"])])
    },
    GalleryState("Flow5-p7-choices", answers: "Flow5 p7", "roles: a check by each picked one, then `None`", size: stageSize) { stage in
        try kindsCard(stage, "roles", of: FieldFixtures.everyKind.a, values: [("roles", ["engineer", "designer"])])
    },
    GalleryState("Flow5-p7-pairs", answers: "Flow5 p7", "labels: a name and a value on each line, a line waiting", size: stageSize) { stage in
        try kindsCard(stage, "labels", of: FieldFixtures.everyKind.b, values: [("labels", ["size": "L", "color": "red"])])
    },
    GalleryState("Flow5-p7-either", answers: "Flow5 p7", "a payment, a group or text: the two names across the top, the group's rows under the picked one", size: stageSize) { stage in
        try kindsCard(stage, "payment", of: FieldFixtures.everyKind.b, values: [("payment", ["cardNumber": "4242"])])
    },
    GalleryState("Flow5-p7-more", answers: "Flow5 p7", "a click on `+12 more ›`: the fold's card, the twelve rows past eight, all in view", size: stageSize) { stage in
        addTypes(stage, [FieldFixtures.wide(20)])
        let note = instance(stage, of: [FieldFixtures.wideID], words: "A type of twenty fields.", height: 260)
        for (place, name) in ["f9", "f12"].enumerated() { stage.editor.fieldWriter?.set(.string("value \(place + 1)"), at: FieldPath(field: name), of: note) }
        try click(stage, note, fold: 0)
        return .image(stage.picture())
    },
    GalleryState("Flow5-p7-from-type", answers: "Flow5 p7", "a click on `from Person`: the fold of the rows an Employee inherits, under Person's chip", size: stageSize) { stage in
        let parent: FieldFixtures.TypeText = (FieldFixtures.personID, "Person", "A person has a name, an email, a phone and a birthday.", fieldsSchema(["name", "email", "phone", "birthday"]))
        let child: FieldFixtures.TypeText = (FieldFixtures.employeeID, "Employee", "An employee has a role, a start date, a manager, a team, a desk and a badge.",
                                             fieldsSchema(["role", "startDate", "manager", "team", "desk", "badge"]))
        addTypes(stage, [parent, child])
        let note = instance(stage, of: [FieldFixtures.employeeID], words: "Bo Chen, from Leeds.")
        stage.editor.fieldWriter?.set("Bo Chen", at: FieldPath(field: "name"), of: note)
        try click(stage, note, fold: 0)
        return .image(stage.picture())
    },
    GalleryState("Flow5-p1-type-address", answers: "Flow5 p1", "a click on the Order type's shipping address row: Address's fields as names and kinds", size: stageSize) { stage in
        try typeCard(stage, of: FieldFixtures.order, "shipping address")
    },
    GalleryState("Flow5-p1-type-list", answers: "Flow5 p1", "a click on the Order type's line items row: the members as names and kinds, the needed dots", size: stageSize) { stage in
        try typeCard(stage, of: FieldFixtures.order, "line items")
    },

    // No board draws these
    GalleryState("card-back-line", "a row with more opened inside a fold's card: the line back, `‹ +3 more`, under it Address's chip and rows", size: stageSize) { stage in
        let bundle: FieldFixtures.TypeText = (rowsTypeID(60), "Bundle", "A bundle has eight text fields, tags, a venue and a shipping address.", """
            {"type": "object", "properties": {"a1": {"type": "string"}, "a2": {"type": "string"}, "a3": {"type": "string"}, "a4": {"type": "string"},
            "a5": {"type": "string"}, "a6": {"type": "string"}, "a7": {"type": "string"}, "a8": {"type": "string"},
            "tags": {"type": "array", "items": {"type": "string"}},
            "venue": {"type": "object", "properties": {"name": {"type": "string"}, "city": {"type": "string"}}},
            "shippingAddress": {"$ref": "\(FieldFixtures.uri(of: FieldFixtures.addressID))"}}}
            """)
        addTypes(stage, [FieldFixtures.person, FieldFixtures.address, bundle])
        let note = instance(stage, of: [bundle.id], words: "A bundle.", height: 260)
        stage.editor.fieldWriter?.set(["street": "12 Main St", "city": "Leeds"], at: FieldPath(field: "shippingAddress"), of: note)
        try click(stage, note, fold: 0)
        let form = try openForm(stage)
        let line = try require(form.sheet.lines.firstIndex { $0.name == "shipping address" }, "the shipping address line")
        form.activate(FieldStop(line: line, column: -1))
        stage.spin()
        return .image(stage.picture())
    },
    GalleryState("card-locked", "a locked note's card: a click on line items opens it to be read, the lines dimmed, no waiting line", size: stageSize) { stage in
        addTypes(stage, orderTypes)
        let note = instance(stage, of: [FieldFixtures.orderID])
        fillOrder(stage, note)
        stage.editor.lock([note])
        stage.editor.selection = nil
        try click(stage, note, row: "line items")
        return .image(stage.picture())
    },
    GalleryState("card-empty-list", "a list with nothing in it: the waiting line alone", size: stageSize) { stage in
        addTypes(stage, orderTypes)
        let note = instance(stage, of: [FieldFixtures.orderID])
        try click(stage, note, row: "tags")
        return .image(stage.picture())
    },
    GalleryState("card-gone-type", "the type deleted under an open card: the chip dashed and italic, `No fields` under it", size: stageSize) { stage in
        addTypes(stage, orderTypes)
        let note = instance(stage, of: [FieldFixtures.orderID])
        stage.editor.fieldWriter?.set(["street": "12 Main St"], at: FieldPath(field: "shippingAddress"), of: note)
        try click(stage, note, row: "shipping address")
        stage.editor.transact("Delete") { $0.delete([FieldFixtures.addressID]) }
        stage.spin()
        return .image(stage.picture())
    },
    GalleryState("card-above", "no room below its row: the note low in the window, the card hangs above the row", size: stageSize) { stage in
        addTypes(stage, orderTypes)
        let note = instance(stage, of: [FieldFixtures.orderID], at: CGPoint(x: 40, y: 250))
        fillOrder(stage, note)
        try click(stage, note, row: "line items")
        return .image(stage.picture())
    },
    GalleryState("card-edge", "the note at the right edge: the card held 8 points inside the window", size: stageSize) { stage in
        addTypes(stage, orderTypes)
        let note = instance(stage, of: [FieldFixtures.orderID], at: CGPoint(x: 330, y: 50))
        fillOrder(stage, note)
        try click(stage, note, row: "line items")
        return .image(stage.picture())
    },
    GalleryState("card-zoom-200", "the same card at 200%: its row is twice as large and the card is the size it was", size: stageSize) { stage in
        addTypes(stage, orderTypes)
        let note = instance(stage, of: [FieldFixtures.orderID])
        fillOrder(stage, note)
        stage.look(at: CGPoint(x: 20, y: 40), zoom: 2)
        try click(stage, note, row: "line items")
        return .image(stage.picture())
    },
    GalleryState("card-zoom-50", "the same card at 50%", size: stageSize) { stage in
        addTypes(stage, orderTypes)
        let note = instance(stage, of: [FieldFixtures.orderID])
        fillOrder(stage, note)
        stage.look(at: CGPoint(x: -20, y: 0), zoom: 0.5)
        try click(stage, note, row: "line items")
        return .image(stage.picture())
    },
    GalleryState("card-wide-table", "six columns: 144 points wider than four", size: stageSize) { stage in
        let type = tableType(columns: 6)
        addTypes(stage, [type])
        let note = instance(stage, of: [tableID], words: "A stock list.")
        let rows: [JSONValue] = (1...3).map { ["sku": .string("A\($0)"), "name": "Mug", "color": "red", "size": "L", "stock": .string("\($0 * 10)"), "note": "-"] }
        stage.editor.fieldWriter?.set(.array(rows), at: FieldPath(field: "rows"), of: note)
        try click(stage, note, row: "rows")
        return .image(stage.picture())
    },
    GalleryState("card-forty-items", "forty line items: 360 tall, the focused line scrolled into view under the names", size: tallStage) { stage in
        addTypes(stage, orderTypes)
        let note = instance(stage, of: [FieldFixtures.orderID])
        let items: [JSONValue] = (1...40).map { ["product": .string("Item \($0)"), "quantity": .number(Double($0)), "price": 9.5] }
        stage.editor.fieldWriter?.set(.array(items), at: FieldPath(field: "lineItems"), of: note)
        try click(stage, note, row: "line items")
        let form = try openForm(stage)
        form.focus(FieldStop(line: 30, column: 0))
        stage.spin()
        return .image(stage.picture())
    },
    GalleryState("card-fold-scrolled", "a fold of twenty rows: 320 tall, scrolled", size: tallStage) { stage in
        addTypes(stage, [FieldFixtures.wide(28)])
        let note = instance(stage, of: [FieldFixtures.wideID], words: "A type of twenty-eight fields.", height: 260)
        try click(stage, note, fold: 0)
        let form = try openForm(stage)
        form.focus(FieldStop(line: 17, column: 0))
        stage.spin()
        return .image(stage.picture())
    },
    GalleryState("card-type-either", "on a type's note: the two branch names across the top, the group's members", size: stageSize) { stage in
        try kindsCard(stage, "payment", of: FieldFixtures.everyKind.b, mode: .kinds)
    },
    GalleryState("card-type-pairs", "on a type's note: pairs, `name` and `value` with their kinds", size: stageSize) { stage in
        try kindsCard(stage, "labels", of: FieldFixtures.everyKind.b, mode: .kinds)
    },
    GalleryState("card-list-of-type", "on a type's note: rooms, each an Address: the table's names under Address's chip", size: stageSize) { stage in
        try kindsCard(stage, "rooms", of: FieldFixtures.everyKind.b, mode: .kinds)
    },

    // The form in the panel (`presentation: .panel`), alone, at the panel's width
    GalleryState("panel-fields-closed", "the form in the panel closed: one line, a triangle and the summary", size: panelSize) { stage in
        let form = try panelForm(stage, "shippingAddress", on: .order)
        return .image(stage.formPicture(form))
    },
    GalleryState("panel-fields-open", "the same opened: its rows under it, indented", size: panelSize) { stage in
        let form = try panelForm(stage, "shippingAddress", on: .order)
        form.activate(FieldStop(line: 0, column: -1))
        return .image(stage.formPicture(form))
    },
    GalleryState("panel-fields-list-of-groups", "line items in the panel: a line an item, the first opened to its rows, the `add` line", size: panelSize) { stage in
        let form = try panelForm(stage, "lineItems", on: .order)
        form.activate(FieldStop(line: 0, column: -1))
        form.activate(FieldStop(line: 1, column: -1))
        return .image(stage.formPicture(form))
    },
    GalleryState("panel-fields-problem", "a quantity of 0: the field and the item open by themselves and the cell is red, from the real check (no words in the form)", size: panelSize) { stage in
        let form = try panelForm(stage, "lineItems", on: .order, quantity: 0)
        return .image(stage.formPicture(form))
    },
    GalleryState("panel-fields-json", "a field no control suits: its JSON in a box, indented, monospaced", size: panelSize) { stage in
        let form = try panelForm(stage, "anything", on: .kindsB)
        return .image(stage.formPicture(form))
    },
    GalleryState("panel-fields-not-json", "the box with `{` in it after ⌘↩: kept, nothing written, `Not JSON` under it", size: panelSize) { stage in
        let form = try panelForm(stage, "anything", on: .kindsB)
        form.focusFirst()
        form.jsonEditor.selectAll(nil)
        form.jsonEditor.insertText("{", replacementRange: form.jsonEditor.selectedRange())
        stage.window.press("\r", code: 36, modifiers: .command)
        return .image(stage.formPicture(form))
    },
]

private let panelSize = CGSize(width: 260, height: 200)

/// What a panel state's note is an instance of.
private enum PanelNote {
    case order, kindsB
}

/// The form for `field` of a note of `type`, with its values as board 5 draws them, in the stage's window (so a box can have
/// the keyboard) at the panel's width.
@MainActor
private func panelForm(_ stage: GalleryStage, _ field: String, on type: PanelNote, quantity: JSONValue = 1) throws -> FieldFormView {
    let (a, b) = FieldFixtures.everyKind
    addTypes(stage, [FieldFixtures.person, FieldFixtures.address, FieldFixtures.order, a, b])
    let id = type == .order ? FieldFixtures.orderID : FieldFixtures.kindsBID
    let note = instance(stage, of: [id])
    if type == .order {
        fillOrder(stage, note, quantity: quantity)
    } else {
        stage.editor.fieldWriter?.set(["rate": 12.5, "tags": ["a", "b"], "on": true], at: FieldPath(field: "anything"), of: note)
    }
    let book = try require(stage.editor.fieldBook)
    let resolved = try require(book.fields(types: [id]).fields.first { $0.field.name == field }, field)
    let form = FieldFormView(editor: stage.editor, shape: note, root: .field(path: FieldPath(field: field), field: resolved, kind: book.kind(of: resolved)), mode: .values,
                             isReadOnly: false, presentation: .panel)
    form.frame = CGRect(x: 0, y: 0, width: panelSize.width, height: max(form.contentHeight, 1))
    stage.canvas.addSubview(form)
    return form
}

extension GalleryStage {
    /// The form alone, as the panel would hold it, `width` wide and as tall as it is, on the panel's background, in this appearance.
    func formPicture(_ form: FieldFormView, width: CGFloat = 260) -> NSBitmapImageRep {
        let scale: CGFloat = 2
        let size = CGSize(width: width, height: ceil(form.contentHeight) + 16)
        form.frame = CGRect(x: 8, y: 8, width: width - 16, height: ceil(form.contentHeight))
        form.layoutSubtreeIfNeeded()
        form.appearance = appearance
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        if let graphics = NSGraphicsContext(bitmapImageRep: rep) {
            appearance.performAsCurrentDrawingAppearance {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = graphics
                NSColor.windowBackgroundColor.setFill()
                CGRect(origin: .zero, size: size).fill()
                NSGraphicsContext.restoreGraphicsState()
            }
            graphics.flushGraphics()
        }
        // The form draws into the bitmap at its own place in its superview, so it is moved to the corner for it.
        let host = form.superview
        form.removeFromSuperview()
        let frame = NSView(frame: CGRect(origin: .zero, size: size))
        form.frame.origin = CGPoint(x: 8, y: 8)
        frame.addSubview(form)
        appearance.performAsCurrentDrawingAppearance { frame.cacheDisplay(in: frame.bounds, to: rep) }
        form.removeFromSuperview()
        host?.addSubview(form)
        return rep
    }
}
