import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import Locking
import Mentions
import StickyNotes
import TestKit
import Types

// The card a row with more in it opens, and the form in the panel (slices 11 and 12): the states of one track,
// added to `galleryStates` (GalleryTypesLook.swift). Each builds board 5's Order from the shared fixtures
// (`FieldFixtures`, in CanvasTesting), opens the card through `editor.fieldCards.open` and draws the canvas,
// the card a subview of it. Until the rows on the note are merged the anchor is a rect `cardAnchor` lays in
// the value column of the note's row; the card hangs from it as it will hang from the real row's value.

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
private func instance(_ stage: GalleryStage, of types: [ShapeID], words: String = "Order for Ann: two mugs, ships Friday.", height: CGFloat = 220) -> ShapeID {
    let note = stage.editor.add(StickyNote(frame: CGRect(x: 40, y: 50, width: 320, height: height), text: MentionText(plain: words)))
    stage.editor.addTypeLink(types[0], to: note)
    for type in types.dropFirst() { stage.editor.addTypeLink(type, to: note) }
    return note
}

/// The value column of a note's `row`th row, a stand-in for the row's value the card hangs from.
@MainActor
private func cardAnchor(on note: ShapeID, row: Int, in stage: GalleryStage) -> CGRect {
    let frame = stage.editor.frame(inFile: note) ?? CGRect(x: 40, y: 50, width: 320, height: 220)
    return CGRect(x: frame.minX + 128, y: frame.minY + 52 + CGFloat(row) * 24, width: 180, height: 22)
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

/// Opens the card for `target` on `note`, hung from `rect` (the `row`th row's by default), and lets its turn pass.
@MainActor
private func open(_ stage: GalleryStage, _ note: ShapeID, _ target: FieldCardRequest.Target, row: Int = 0, mode: FieldFormMode = .values,
                  folded: [Resolved.Field] = [], at rect: CGRect? = nil) throws {
    let cards = try require(stage.editor.fieldCards)
    let anchor = rect ?? cardAnchor(on: note, row: row, in: stage)
    let request = FieldCardRequest(shape: note, target: target, mode: mode, isReadOnly: mode == .kinds, rowRect: anchor, folded: folded, closed: {}, tabbedOut: { _ in })
    expect(cards.open(request), "the card opens")
    stage.spin()
}

@MainActor
private func field(_ name: String) -> FieldCardRequest.Target { .field(FieldPath(field: name)) }

/// An Order with its values and its card open at `name`.
@MainActor
private func orderCard(_ stage: GalleryStage, _ name: String, row: Int, quantity: JSONValue = 1) throws -> GalleryOutput {
    addTypes(stage, orderTypes)
    let note = instance(stage, of: [FieldFixtures.orderID])
    fillOrder(stage, note, quantity: quantity)
    try open(stage, note, field(name), row: row)
    return .image(stage.picture())
}

/// A note of the kinds' types (KindsA and KindsB) with its card open at `name`.
@MainActor
private func kindsCard(_ stage: GalleryStage, _ name: String, row: Int = 0, values: [(String, JSONValue)] = [], mode: FieldFormMode = .values) throws -> GalleryOutput {
    let (a, b) = FieldFixtures.everyKind
    addTypes(stage, [FieldFixtures.person, FieldFixtures.address, a, b], visible: mode == .kinds ? FieldFixtures.kindsBID : nil)
    let note = mode == .kinds ? FieldFixtures.kindsBID : instance(stage, of: [FieldFixtures.kindsAID, FieldFixtures.kindsBID], words: "A note of every kind.")
    for (key, value) in values { stage.editor.fieldWriter?.set(value, at: FieldPath(field: key), of: note) }
    try open(stage, note, field(name), row: row, mode: mode)
    return .image(stage.picture())
}

/// A type's note, with its card open at `name`, read.
@MainActor
private func typeCard(_ stage: GalleryStage, of type: FieldFixtures.TypeText, _ name: String, row: Int) throws -> GalleryOutput {
    addTypes(stage, orderTypes + [FieldFixtures.everyKind.b], visible: type.id)
    try open(stage, type.id, field(name), row: row, mode: .kinds)
    return .image(stage.picture())
}

/// A table of `columns` text columns, with a fixed id, for what no board type has.
private let tableID = ShapeID(UUID(uuidString: "0E5B1A08-0000-4000-8000-0000000000A8")!)

private func tableType(columns: Int) -> FieldFixtures.TypeText {
    let properties = (0..<columns).map { "\"\(["sku", "name", "color", "size", "stock", "note", "shelf", "bin"][$0 % 8])\": { \"type\": \"string\" }" }.joined(separator: ", ")
    return (tableID, "Stock", "A stock list of \(columns) columns.", "{ \"type\": \"object\", \"properties\": { \"rows\": { \"type\": \"array\", \"items\": { \"type\": \"object\", \"properties\": { \(properties) } } } } }")
}

@MainActor
private func fieldsOf(_ stage: GalleryStage, _ type: ShapeID, _ range: (Resolved.Field) -> Bool) throws -> [Resolved.Field] {
    try require(stage.editor.fieldBook).fields(types: [type]).fields.filter(range)
}

@MainActor
let cardStates: [GalleryState] = [
    // Flow5
    GalleryState("Flow5-p4-open-row", answers: "Flow5 p4", "the shipping address row's card under Address's chip: street, city, `add postcode`", size: stageSize) { stage in
        try orderCard(stage, "shippingAddress", row: 1)
    },
    GalleryState("Flow5-p5-list", answers: "Flow5 p5", "line items as a table: the gray names, Mug and Plate, the `add` line", size: stageSize) { stage in
        try orderCard(stage, "lineItems", row: 2)
    },
    GalleryState("Flow5-p6-wrong-cell", answers: "Flow5 p6", "the same with a quantity of 0: red and underlined once the check is merged (until then plain)", size: stageSize) { stage in
        try orderCard(stage, "lineItems", row: 2, quantity: 0)
    },
    GalleryState("Flow5-p7-list-of-values", answers: "Flow5 p7", "tags: one column, a line each, the waiting line", size: stageSize) { stage in
        try orderCard(stage, "tags", row: 4)
    },
    GalleryState("Flow5-p7-group", answers: "Flow5 p7", "a venue's two rows, name and city", size: stageSize) { stage in
        try kindsCard(stage, "venue", row: 4, values: [("venue", ["name": "The Loft", "city": "Leeds"])])
    },
    GalleryState("Flow5-p7-choices", answers: "Flow5 p7", "roles: a check by each picked one, then `None`", size: stageSize) { stage in
        try kindsCard(stage, "roles", row: 3, values: [("roles", ["engineer", "designer"])])
    },
    GalleryState("Flow5-p7-pairs", answers: "Flow5 p7", "labels: a name and a value on each line, a line waiting", size: stageSize) { stage in
        try kindsCard(stage, "labels", row: 5, values: [("labels", ["size": "L", "color": "red"])])
    },
    GalleryState("Flow5-p7-either", answers: "Flow5 p7", "a payment, a group or text: the two names across the top, the group's rows under the picked one", size: stageSize) { stage in
        try kindsCard(stage, "payment", row: 6, values: [("payment", ["cardNumber": "4242"])])
    },
    GalleryState("Flow5-p7-more", answers: "Flow5 p7", "the fold's card: the twelve rows past eight, all in view", size: stageSize) { stage in
        addTypes(stage, [FieldFixtures.wide(20)])
        let note = instance(stage, of: [FieldFixtures.wideID], words: "A type of twenty fields.", height: 260)
        for (place, name) in ["f9", "f12"].enumerated() { stage.editor.fieldWriter?.set(.string("value \(place + 1)"), at: FieldPath(field: name), of: note) }
        let folded = Array(try fieldsOf(stage, FieldFixtures.wideID) { _ in true }.dropFirst(8))
        try open(stage, note, .fold, row: 6, folded: folded)
        return .image(stage.picture())
    },
    GalleryState("Flow5-p7-from-type", answers: "Flow5 p7", "the fold of the rows an Employee inherits, under Person's chip", size: stageSize) { stage in
        addTypes(stage, orderTypes)
        let note = instance(stage, of: [FieldFixtures.employeeID], words: "Bo Chen, from Leeds.")
        stage.editor.fieldWriter?.set("Bo Chen", at: FieldPath(field: "name"), of: note)
        let folded = try fieldsOf(stage, FieldFixtures.employeeID) { $0.introducedBy == FieldFixtures.personID }
        try open(stage, note, .fold, row: 2, folded: folded)
        return .image(stage.picture())
    },
    GalleryState("Flow5-p1-type-address", answers: "Flow5 p1", "on the Order type: Address's fields as names and kinds", size: stageSize) { stage in
        try typeCard(stage, of: FieldFixtures.order, "shippingAddress", row: 3)
    },
    GalleryState("Flow5-p1-type-list", answers: "Flow5 p1", "on the Order type: the line items' members as names and kinds, the needed dots", size: stageSize) { stage in
        try typeCard(stage, of: FieldFixtures.order, "lineItems", row: 4)
    },

    // No board draws these
    GalleryState("card-back-line", "a row with more opened inside a card: the line back, `‹ shipping address`, under it Address's chip and rows", size: stageSize) { stage in
        let (a, _) = FieldFixtures.everyKind
        addTypes(stage, [FieldFixtures.person, FieldFixtures.address, a])
        let note = instance(stage, of: [FieldFixtures.kindsAID], words: "A note of every kind.")
        stage.editor.fieldWriter?.set(["street": "12 Main St", "city": "Leeds"], at: FieldPath(field: "shippingAddress"), of: note)
        let folded = try ["name", "tags", "venue", "shippingAddress"].map { name in
            try require(try fieldsOf(stage, FieldFixtures.kindsAID) { $0.field.name == name }.first)
        }
        try open(stage, note, .fold, row: 6, folded: folded)
        let form = try require(stage.editor.fieldCards?.openForm)
        form.activate(FieldStop(line: 3, column: -1))
        stage.spin()
        return .image(stage.picture())
    },
    GalleryState("card-locked", "a locked note's card: to be read, the lines dimmed, no waiting line", size: stageSize) { stage in
        addTypes(stage, orderTypes)
        let note = instance(stage, of: [FieldFixtures.orderID])
        fillOrder(stage, note)
        stage.editor.lock([note])
        try open(stage, note, field("lineItems"), row: 2)
        return .image(stage.picture())
    },
    GalleryState("card-empty-list", "a list with nothing in it: the waiting line alone", size: stageSize) { stage in
        addTypes(stage, orderTypes)
        let note = instance(stage, of: [FieldFixtures.orderID])
        try open(stage, note, field("tags"), row: 4)
        return .image(stage.picture())
    },
    GalleryState("card-gone-type", "a field of a type that is gone: the chip dashed and italic, `No fields` under it", size: stageSize) { stage in
        addTypes(stage, orderTypes)
        let note = instance(stage, of: [FieldFixtures.orderID])
        stage.editor.fieldWriter?.set(["street": "12 Main St"], at: FieldPath(field: "shippingAddress"), of: note)
        stage.editor.transact("Delete") { $0.delete([FieldFixtures.addressID]) }
        try open(stage, note, field("shippingAddress"), row: 1)
        return .image(stage.picture())
    },
    GalleryState("card-above", "no room below its row: the card hangs above it", size: stageSize) { stage in
        addTypes(stage, orderTypes)
        let note = instance(stage, of: [FieldFixtures.orderID])
        fillOrder(stage, note)
        try open(stage, note, field("lineItems"), at: CGRect(x: 168, y: 340, width: 180, height: 22))
        return .image(stage.picture())
    },
    GalleryState("card-edge", "its row at the right edge: the card held 8 points inside the window", size: stageSize) { stage in
        addTypes(stage, orderTypes)
        let note = instance(stage, of: [FieldFixtures.orderID])
        fillOrder(stage, note)
        try open(stage, note, field("lineItems"), at: CGRect(x: 520, y: 100, width: 110, height: 22))
        return .image(stage.picture())
    },
    GalleryState("card-zoom-200", "the same card at 200%: its row is twice as large and the card is the size it was", size: stageSize) { stage in
        addTypes(stage, orderTypes)
        let note = instance(stage, of: [FieldFixtures.orderID])
        fillOrder(stage, note)
        stage.look(at: CGPoint(x: 20, y: 40), zoom: 2)
        try open(stage, note, field("lineItems"), row: 2)
        return .image(stage.picture())
    },
    GalleryState("card-zoom-50", "the same card at 50%", size: stageSize) { stage in
        addTypes(stage, orderTypes)
        let note = instance(stage, of: [FieldFixtures.orderID])
        fillOrder(stage, note)
        stage.look(at: CGPoint(x: -20, y: 0), zoom: 0.5)
        try open(stage, note, field("lineItems"), row: 2)
        return .image(stage.picture())
    },
    GalleryState("card-wide-table", "six columns: 144 points wider than four", size: stageSize) { stage in
        let type = tableType(columns: 6)
        addTypes(stage, [type])
        let note = instance(stage, of: [tableID], words: "A stock list.")
        let rows: [JSONValue] = (1...3).map { ["sku": .string("A\($0)"), "name": "Mug", "color": "red", "size": "L", "stock": .string("\($0 * 10)"), "note": "-"] }
        stage.editor.fieldWriter?.set(.array(rows), at: FieldPath(field: "rows"), of: note)
        try open(stage, note, field("rows"), row: 0)
        return .image(stage.picture())
    },
    GalleryState("card-forty-items", "forty line items: 360 tall, the focused line scrolled into view under the names", size: tallStage) { stage in
        addTypes(stage, orderTypes)
        let note = instance(stage, of: [FieldFixtures.orderID])
        let items: [JSONValue] = (1...40).map { ["product": .string("Item \($0)"), "quantity": .number(Double($0)), "price": 9.5] }
        stage.editor.fieldWriter?.set(.array(items), at: FieldPath(field: "lineItems"), of: note)
        try open(stage, note, field("lineItems"), row: 2)
        let form = try require(stage.editor.fieldCards?.openForm)
        form.focus(FieldStop(line: 30, column: 0))
        stage.spin()
        return .image(stage.picture())
    },
    GalleryState("card-fold-scrolled", "a fold of twenty rows: 320 tall, scrolled", size: tallStage) { stage in
        addTypes(stage, [FieldFixtures.wide(28)])
        let note = instance(stage, of: [FieldFixtures.wideID], words: "A type of twenty-eight fields.", height: 260)
        let folded = Array(try fieldsOf(stage, FieldFixtures.wideID) { _ in true }.dropFirst(8))
        try open(stage, note, .fold, row: 6, folded: folded)
        let form = try require(stage.editor.fieldCards?.openForm)
        form.focus(FieldStop(line: 17, column: 0))
        stage.spin()
        return .image(stage.picture())
    },
    GalleryState("card-type-either", "on a type's note: the two branch names across the top, the group's members", size: stageSize) { stage in
        try kindsCard(stage, "payment", row: 6, mode: .kinds)
    },
    GalleryState("card-type-pairs", "on a type's note: pairs, `name` and `value` with their kinds", size: stageSize) { stage in
        try kindsCard(stage, "labels", row: 5, mode: .kinds)
    },
    GalleryState("card-list-of-type", "on a type's note: rooms, each an Address: the table's names under Address's chip", size: stageSize) { stage in
        try kindsCard(stage, "rooms", row: 3, mode: .kinds)
    },
]
