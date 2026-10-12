import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import CoreGraphics
import Foundation
import Locking
import Mentions
import Selection
import StickyNotes
import Subboards
import TestKit
import TextEditing
import Titles
import Types

// The gallery's states for a pointer (slice 14): a field that points at another note, as board 5 draws it: the
// pill of panel 2 (white, a hairline, the live name, no symbol), panel 7's pills and `+1`, and the states no board
// draws (a target that is gone, one that is no longer a Person, a type that is gone, an untitled target, a locked
// note). The Persons sit far off the stage, so a note is alone in view. Named for the board panel each answers.

private let tallNote = CGSize(width: 440, height: 440)

/// Cy Lin and Di Fox: the third and fourth guests, so a row's `+1` has something to count.
private let cyLinID = ShapeID(UUID(uuidString: "0E5B1A0A-0000-4000-8000-0000000000AA")!)
private let diFoxID = ShapeID(UUID(uuidString: "0E5B1A0B-0000-4000-8000-0000000000AB")!)

/// Board 5's Order, as panel 2 reads it.
private let pointerOrder: JSONObject = [
    "customer": link(to: FieldFixtures.annLeeID, "Ann Lee"), "shippingAddress": ["street": "12 Main St", "city": "Leeds"],
    "lineItems": [["product": "Mug", "quantity": 2], ["product": "Plate", "quantity": 1]],
    "status": "paid", "tags": ["gift", "mugs"], "gift": true, "giftNote": "For Dana",
]

extension CanvasEditor {
    /// The Order of panel 2, over the types and the people off the stage.
    @discardableResult
    func pointerOrderNote(_ values: JSONObject = pointerOrder) -> ShapeID {
        offstage([FieldFixtures.order, FieldFixtures.person, FieldFixtures.address])
        offstagePeople()
        return instance(of: [FieldFixtures.orderID], words: "Order for Ann: two mugs, ships Friday.", values, at: CGPoint(x: 100, y: 40))
    }
}

/// The rows view over the note being edited, if any.
@MainActor private func rowsView(_ stage: GalleryStage) -> RowsView? { stage.canvas.descendants(RowsView.self).first }

extension GalleryStage {
    /// A note edited on its first row, a pointer's, with `typed` in it: the list of the notes it may point at open under the
    /// field. The field's text view, for the picture of its list.
    @MainActor func pick(in note: ShapeID, typing typed: String) throws -> EditingTextView {
        editor.selection = note
        expect(editor.beginEditing(note))
        window.press(String(UnicodeScalar(NSDownArrowFunctionKey)!), code: 125)
        window.type(typed)
        let rows = try require(rowsView(self), "the rows' view")
        return try require(rows.descendants(NSTextView.self).first { $0 is EditingTextView } as? EditingTextView, "a field with the keyboard")
    }

    /// The canvas with that field's list drawn under it.
    @MainActor func pictureWithList(of field: EditingTextView) throws -> NSBitmapImageRep {
        try pictureWithList(listRows(in: field.caretListWindow), below: field.convert(field.bounds, to: nil))
    }
}

/// A click on a row of `note` as a person's, at the right end of its value (off the pills), at the camera now: the note begins editing
/// in that row and the card opens on the next turn. The card hangs from that real row.
@MainActor private func openCard(_ stage: GalleryStage, _ note: ShapeID, row name: String) throws -> FieldFormView {
    let rows = try require(stage.editor.rowBook).rows(of: note)
    let row = try require(rows.first { $0.name == name }, "a row \(name)")
    let point = stage.viewPoint(CGPoint(x: row.valueRect.maxX - 6, y: row.rect.midY))
    stage.press(at: point)
    stage.release(at: point)
    stage.spin()
    stage.spin()
    return try require(stage.editor.fieldCards?.openForm, "the click on \(name) opened its card")
}

private let cyLin = link(to: cyLinID, "Cy Lin")

/// A note of KindsB over the types and the people off the stage: a customer and three guests.
@MainActor private func guestsNote(_ stage: GalleryStage, guests: [JSONValue]? = nil) -> ShapeID {
    stage.editor.offstage([FieldFixtures.everyKind.b, FieldFixtures.person, FieldFixtures.address])
    stage.editor.offstagePeople()
    stage.editor.instance(of: [FieldFixtures.personID], words: "Cy Lin", ["name": "Cy Lin"], at: CGPoint(x: 3600, y: 3400), id: cyLinID)
    return stage.editor.instance(of: [FieldFixtures.kindsBID], words: "A note of the other kinds.", [
        "customer": link(to: FieldFixtures.boParkID, "Bo Park"),
        "guests": .array(guests ?? [link(to: FieldFixtures.annLeeID, "Ann Lee"), link(to: FieldFixtures.boParkID, "Bo Park"), cyLin]),
    ], at: CGPoint(x: 100, y: 40))
}

/// An Order whose line items each point at a Product: Mug and Plate, notes of the file off the stage.
private let productID = ShapeID(UUID(uuidString: "0E5B1A0C-0000-4000-8000-0000000000AC")!)
private let mugID = ShapeID(UUID(uuidString: "0E5B1A0D-0000-4000-8000-0000000000AD")!)
private let plateID = ShapeID(UUID(uuidString: "0E5B1A0E-0000-4000-8000-0000000000AE")!)
private let stockOrderID = ShapeID(UUID(uuidString: "0E5B1A0F-0000-4000-8000-0000000000AF")!)

private let product: FieldFixtures.TypeText = (productID, "Product", "A product has a name and a price.",
                                               #"{"type": "object", "properties": {"name": {"type": "string"}, "price": {"type": "number"}}}"#)
private let stockOrder: FieldFixtures.TypeText = (stockOrderID, "Stock order", "A stock order lists the products it takes.", #"""
    {"type": "object", "properties": {"lineItems": {"type": "array", "items": {"type": "object", "properties": {
      "product": {"type": "string", "contentMediaType": "text/x-canvas-link", "contentSchema": {"$ref": "\#(FieldFixtures.uri(of: productID))"}},
      "quantity": {"type": "integer"}, "price": {"type": "number"}}}}}}
    """#)

@MainActor
let pointerStates: [GalleryState] = [
    GalleryState("Flow5-p2-pill", answers: "Flow5 p2", "the Order: `customer` is the pill `Ann Lee`, white with a hairline and no symbol; the rest as the panel draws it", size: tallNote) { stage in
        stage.editor.pointerOrderNote()
        stage.editor.selection = nil
        return canvas(stage)
    },
    GalleryState("Flow5-p7-pills", answers: "Flow5 p7", "KindsB's `guests`: the pills `Ann Lee` `Bo Park` `Cy Lin` and `+1`, the `customer` one pill", size: tallNote) { stage in
        stage.editor.offstage([FieldFixtures.everyKind.b, FieldFixtures.person, FieldFixtures.address])
        stage.editor.offstagePeople()
        stage.editor.instance(of: [FieldFixtures.personID], words: "Cy Lin", ["name": "Cy Lin"], at: CGPoint(x: 3600, y: 3400), id: cyLinID)
        stage.editor.instance(of: [FieldFixtures.personID], words: "Di Fox", ["name": "Di Fox"], at: CGPoint(x: 3900, y: 3400), id: diFoxID)
        stage.editor.instance(of: [FieldFixtures.kindsBID], words: "A note of the other kinds.", [
            "customer": link(to: FieldFixtures.boParkID, "Bo Park"),
            "guests": [link(to: FieldFixtures.annLeeID, "Ann Lee"), link(to: FieldFixtures.boParkID, "Bo Park"), link(to: cyLinID, "Cy Lin"), link(to: diFoxID, "Di Fox")],
        ], at: CGPoint(x: 100, y: 40))
        stage.editor.selection = nil
        return canvas(stage)
    },
    GalleryState("Flow5-p3-picker", answers: "Flow5 p3", "the Order edited, `an` typed in the customer row: the list under it, a name and the board's at the right, the first highlighted (no kind's symbol)", size: tallNote) { stage in
        stage.editor.offstage([FieldFixtures.order, FieldFixtures.person, FieldFixtures.address])
        let team = stage.editor.add(Subboard(frame: CGRect(x: 3000, y: 3600, width: 200, height: 120)), title: "Team")
        let clients = stage.editor.add(Subboard(frame: CGRect(x: 3300, y: 3600, width: 200, height: 120)), title: "Clients")
        for (name, board, place) in [("Ann Lee", team, 0.0), ("Anders Holm", clients, 0.0), ("Dana Novak", clients, 1.0)] {
            var note = ShapeRecord(StickyNote(frame: CGRect(x: 40 + place * 260, y: 40, width: 200, height: 200), text: ""))
            note[TitleProperty.self] = name
            note[IsAProperty.self] = [TypeLink(FieldFixtures.personID)]
            let record = AnyShapeRecord(note)
            stage.editor.transact(on: BoardID(owner: board), "Add Person") { $0.insert(record) }
        }
        var values = pointerOrder
        values["customer"] = nil
        let order = stage.editor.instance(of: [FieldFixtures.orderID], words: "Order for Ann: two mugs, ships Friday.", values, at: CGPoint(x: 100, y: 40))
        let field = try stage.pick(in: order, typing: "an")
        return .image(try stage.pictureWithList(of: field))
    },
    GalleryState("pointer-gone", answers: "Flow5 p7", "Ann deleted: the pill is dashed with the name it held, the orange ring, nothing red", size: tallNote) { stage in
        let order = stage.editor.pointerOrderNote()
        _ = order
        stage.editor.transact("Delete") { $0.delete([FieldFixtures.annLeeID]) }
        stage.editor.selection = nil
        return canvas(stage)
    },
    GalleryState("pointer-not-one", answers: "Flow5 p6", "Ann no longer a Person: the pill red with its wavy line, the red ring round the note", size: tallNote) { stage in
        stage.editor.pointerOrderNote()
        stage.editor.transact("Take Person off") { $0.update(FieldFixtures.annLeeID) { $0[IsAProperty.self] = nil } }
        stage.editor.selection = nil
        return canvas(stage)
    },
    GalleryState("pointer-type-gone", answers: "Flow5 p7", "Person deleted: the customer row is the dashed `Person` chip, the value kept, no ring", size: tallNote) { stage in
        stage.editor.pointerOrderNote()
        stage.editor.transact("Delete") { $0.delete([FieldFixtures.personID]) }
        stage.editor.selection = nil
        return canvas(stage)
    },
    GalleryState("pointer-untitled", answers: "Flow5 p2", "an untitled Person: the pill reads her first line", size: tallNote) { stage in
        stage.editor.offstage([FieldFixtures.order, FieldFixtures.person, FieldFixtures.address])
        stage.editor.instance(of: [FieldFixtures.personID], words: "Ann Lee, staff engineer.\nShe started in 2021.", ["name": "Ann Lee"],
                              at: CGPoint(x: 3000, y: 3400), id: FieldFixtures.annLeeID)
        stage.editor.instance(of: [FieldFixtures.orderID], words: "Order for Ann.", pointerOrder, at: CGPoint(x: 100, y: 40))
        stage.editor.selection = nil
        return canvas(stage)
    },
    GalleryState("pointer-read-only", answers: "Flow5 p2", "the Order locked: the same pill, nothing outlined", size: tallNote) { stage in
        let order = stage.editor.pointerOrderNote()
        stage.editor.lock([order])
        stage.editor.selection = nil
        return canvas(stage)
    },
    GalleryState("pointer-card-list", answers: "Flow5 p7", "the guests card: a pill a line, `Ann Lee` `Bo Park` `Cy Lin`, the `add` line waiting; the row outlined behind it", size: tallNote) { stage in
        let note = guestsNote(stage)
        _ = try openCard(stage, note, row: "guests")
        return .image(stage.picture())
    },
    GalleryState("pointer-card-picking", answers: "Flow5 p3", "the same with `bo` typed on the waiting line: the list of the notes of the type under the line, Bo Park first", size: tallNote) { stage in
        let note = guestsNote(stage)
        let form = try openCard(stage, note, row: "guests")
        form.focus(FieldStop(line: 3, column: 0))
        stage.window.type("bo")
        return .image(try stage.pictureWithList(of: form.cellEditor))
    },
    GalleryState("pointer-panel", answers: "Flow5 p2", "the note's panel: the customer a pill on the panel's own ground, guests a triangle and its pills", size: tallNote) { stage in
        let note = guestsNote(stage)
        return .image(try stage.panelPicture(of: note))
    },
    GalleryState("pointer-in-table", answers: "Flow5 p5", "line items whose product is a pointer: Mug and Plate pills in the product cells, the gray names, the `add` line", size: tallNote) { stage in
        stage.editor.offstage([stockOrder, product])
        for (id, name, place) in [(mugID, "Mug", 0.0), (plateID, "Plate", 1.0)] {
            stage.editor.instance(of: [productID], words: name, ["name": .string(name)], at: CGPoint(x: 3600 + place * 300, y: 3400), id: id)
        }
        let note = stage.editor.instance(of: [stockOrderID], words: "An order for the shop.", [
            "lineItems": [["product": link(to: mugID, "Mug"), "quantity": 2, "price": 12], ["product": link(to: plateID, "Plate"), "quantity": 1, "price": 9.5]],
        ], at: CGPoint(x: 100, y: 40))
        _ = try openCard(stage, note, row: "line items")
        return .image(stage.picture())
    },
]
