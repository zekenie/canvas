import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import Mentions
import Selection
import StickyNotes
import TestKit
import Types

// Needed and wrong, as the check says them (slice 13): the whole panel, ring and all, from the real check, never
// `rowBook.checks` (D's `values-mark-*` states stay as the look of a mark alone). A state a board draws is named for its
// panel; the others say "-". The types sit far off the stage so a note is alone in view and its chip says what it is.
// The card with its red cell is the card's state (`Flow5-p6-wrong-cell`, GalleryCards.swift).

private let single = CGSize(width: 440, height: 340)
private let tallNote = CGSize(width: 440, height: 440)
private let wideStage = CGSize(width: 900, height: 520)

/// Board 5's Order, as panel 2 reads it: filled, a gift with no note.
private let filledOrder: JSONObject = [
    "customer": link(to: FieldFixtures.annLeeID, "Ann Lee"), "shippingAddress": ["street": "12 Main St", "city": "Leeds"],
    "lineItems": [["product": "Mug", "quantity": 2], ["product": "Plate", "quantity": 1]],
    "status": "paid", "tags": ["gift", "mugs"], "gift": true,
]

/// Twelve fields, the last an integer of at least 1: a wrong value in it is folded behind `+4 more`.
private let longType: FieldFixtures.TypeText = (rowsTypeID(61), "Long", "A long type has eleven text fields and a count of at least one.", """
    {"type": "object", "properties": {"f1": {"type": "string"}, "f2": {"type": "string"}, "f3": {"type": "string"}, "f4": {"type": "string"},
    "f5": {"type": "string"}, "f6": {"type": "string"}, "f7": {"type": "string"}, "f8": {"type": "string"}, "f9": {"type": "string"},
    "f10": {"type": "string"}, "f11": {"type": "string"}, "f12": {"type": "integer", "minimum": 1}}, "required": ["f11"]}
    """)

/// A rule across fields: at most one of the two.
private let eitherType: FieldFixtures.TypeText = (rowsTypeID(62), "Booking", "A booking is for a room or a desk, never both.", """
    {"type": "object", "properties": {"room": {"type": "string"}, "desk": {"type": "string"}}, "not": {"required": ["room", "desk"]}}
    """)

@MainActor
let checkStates: [GalleryState] = [
    GalleryState("Flow5-p6-needed-and-wrong", answers: "Flow5 p6", "an Order: `add customer` amber, `2 items` red and underlined, `add gift note` amber, the red ring round the note; nothing in the rows says why", size: tallNote) { stage in
        stage.editor.offstage([FieldFixtures.order, FieldFixtures.person, FieldFixtures.address])
        var values = filledOrder
        values["customer"] = nil
        values["lineItems"] = [["product": "Mug", "quantity": 0], ["product": "Plate", "quantity": 1]]
        stage.editor.instance(of: [FieldFixtures.orderID], words: "Order for Ann: two mugs, ships Friday.", values, at: CGPoint(x: 100, y: 40))
        stage.editor.selection = nil
        return canvas(stage)
    },
    GalleryState("Flow5-p2-gift-note-needed", answers: "Flow5 p2", "the filled Order, a gift: no ring, `add gift note` amber (a gift needs a note)", size: tallNote) { stage in
        stage.editor.offstage([FieldFixtures.order, FieldFixtures.person, FieldFixtures.address])
        stage.editor.offstagePeople()
        stage.editor.instance(of: [FieldFixtures.orderID], words: "Order for Ann: two mugs, ships Friday.", filledOrder, at: CGPoint(x: 100, y: 40))
        stage.editor.selection = nil
        return canvas(stage)
    },
    GalleryState("Flow3-p3-wrong-value", answers: "Flow3 p3", "a Person whose email is `ann@`: red with its wavy line, the red ring round the note", size: single) { stage in
        // The shared Person, whose email has the `email` format: `personThree`'s is plain text, which nothing is wrong for.
        stage.editor.offstage([FieldFixtures.person])
        stage.editor.instance(of: [FieldFixtures.personID], words: "Ann Lee, staff engineer since 2021.", ["name": "Ann Lee", "email": "ann@"])
        stage.editor.selection = nil
        return canvas(stage)
    },
    GalleryState("checks-order-empty", "a fresh Order, nothing filled: `add customer` and `add line items` amber, no ring, nothing red", size: tallNote) { stage in
        stage.editor.offstage([FieldFixtures.order, FieldFixtures.person, FieldFixtures.address])
        stage.editor.instance(of: [FieldFixtures.orderID], words: "A new order.", at: CGPoint(x: 100, y: 40))
        stage.editor.selection = nil
        return canvas(stage)
    },
    GalleryState("checks-typing-not-red", "the `ann@` note with the caret in its email (the same note as Flow3 p3): `ann@` in plain ink in the field's outline, no wavy line, no ring, until the caret leaves", size: single) { stage in
        stage.editor.offstage([FieldFixtures.person])
        let id = stage.editor.instance(of: [FieldFixtures.personID], words: "Ann Lee, staff engineer since 2021.", ["name": "Ann Lee", "email": "ann@"])
        // The row's own field has the caret, as a click on the value gives it: the render draws no value under it, so
        // setting `typing` alone would show an empty row.
        _ = stage.render(at: .zero)
        let row = try require(stage.editor.rowBook?.rows(of: id).first { $0.name == "email" }, "the email row")
        stage.editor.selection = id
        expect(stage.editor.beginEditing(id, at: CGPoint(x: row.valueRect.minX + 6, y: row.rect.midY)))
        expectEqual(stage.editor.fieldChecks?.typing?.path, FieldPath(field: "email"), "the field told the check")
        return canvas(stage)
    },
    GalleryState("checks-fold-wrong", "a wrong value folded away: `+4 more ›` is red, and the ring is round the note", size: wideStage) { stage in
        stage.editor.offstage([longType])
        stage.editor.instance(of: [longType.id], words: "A wrong one folded.", ["f11": "x", "f12": 0], at: CGPoint(x: 60, y: 30))
        stage.editor.instance(of: [longType.id], words: "A needed one folded.", ["f1": "x"], at: CGPoint(x: 480, y: 30))
        stage.editor.selection = nil
        return canvas(stage)
    },
    GalleryState("checks-gone-type", "a note of a type that is gone: its values kept, nothing red, nothing amber; the type whose JSON refers to the gone one has the orange ring", size: wideStage) { stage in
        stage.editor.offstage([FieldFixtures.address, FieldFixtures.person])
        stage.editor.instance(of: [FieldFixtures.addressID], words: "12 Main St, Leeds.", ["street": "12 Main St"], at: CGPoint(x: 60, y: 40))
        let order = stage.editor.addTypeNote(FieldFixtures.order.schema, text: MentionText(plain: FieldFixtures.order.words), title: FieldFixtures.order.title,
                                             frame: CGRect(x: 420, y: 40, width: 320, height: 300), id: FieldFixtures.orderID)
        stage.editor.transact("Delete") { $0.delete([FieldFixtures.addressID]) }
        _ = order
        stage.editor.selection = nil
        return canvas(stage)
    },
    GalleryState("checks-rule-ring", "a rule across fields broken (a room and a desk, never both): the ring round the note and no row marked", size: single) { stage in
        stage.editor.offstage([eitherType])
        stage.editor.instance(of: [eitherType.id], words: "A booking.", ["room": "12", "desk": "4"])
        stage.editor.selection = nil
        return canvas(stage)
    },
]
