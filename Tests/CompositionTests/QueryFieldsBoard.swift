import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import Connections
import CoreGraphics
import Foundation
import LanguageModels
import Mentions
import Queries
import Selection
import ShippedTesting
import StickyNotes
import TestKit
import Titles
import Types

// The live evaluation's third file (scripts/query-prompts, QueryLiveTests), for the questions about a
// note's field values: two types and six notes on one board, built with the shipped kinds as the other
// two files are, with fixed ids, `00000000-0000-4000-8000-0000000F00NN`. Each note's `is` and its
// `fieldValues` are set on its record, so the file needs no draw.
//
//     Person  …01  a type: name (text, titles the note), email, dob (a date a person calls "birthday");
//                  name is required
//     Order   …02  a type: number, customer (text), status (draft, paid or shipped), due (a
//                  date), total (a number), lineItems (a list of product and qty), gift (yes or no) and
//                  giftNote, which a gift asks for; number, customer, status and due are required
//     Ann Lee …11  a Person: dob 1990-05-02
//     Bo Park …12  a Person: dob 2001-11-30
//     Order 12 …21 an Order for Ann Lee: paid, due 2026-10-05, total 18, a Mug (2) and a Pen (1)
//     Order 13 …22 an Order for Bo Park: draft, due 2026-11-01, total "twelve" (text in a number's
//                  field: wrong), a Mug (1)
//     Order 14 …23 an Order for Ann Lee: draft, no due and no lines, a gift with no giftNote (so it needs
//                  its due, and is not wrong)
//     Standup …31  a note: "sync with @Ann Lee", a mention (not a link)
//
// And two relationship types, their ends and the relationships between the notes:
//
//     Placed by  …03  a relationship type from an Order to a Person (a `via` choice: web, phone or store); its
//                     ends: Order → Placed by named customer (Needed), Placed by → Person named orders
//     Friendship …04  a relationship type from a Person to a Person (a date, since); its ends: Person →
//                     Friendship and Friendship → Person, both named friends
//     …51 Order 12 → Ann Lee and …52 Order 13 → Bo Park, Placed by; Order 14 has none
//     …53 Ann Lee → Bo Park, Friendship since 2019-05-01
//     …54 Standup → Bo Park, Friendship: a note with no type is no Person, so this one is a misfit
//
// Order 12 and 13's `customer` says the same as their arrows; Order 14 has neither, so a question about who
// ordered what has one answer whether it is read from the text or from the arrows.

/// The evaluation's third file: its shapes' ids, and the file (`file(in:)`) in an editor of the shipped
/// plugins (`harness`).
@MainActor
enum QueryFieldsBoard {
    /// `…F00NN`: the file's id for `nn`.
    static func id(_ nn: UInt8) -> ShapeID {
        ShapeID(UUID(uuidString: String(format: "00000000-0000-4000-8000-0000000F00%02X", nn))!)
    }

    static let person = id(0x01), order = id(0x02)
    static let annLee = id(0x11), boPark = id(0x12)
    static let order12 = id(0x21), order13 = id(0x22), order14 = id(0x23)
    static let standup = id(0x31)
    static let placedBy = id(0x03), friendship = id(0x04)
    /// The relationship types' ends, then the relationships.
    static let placedByFrom = id(0x41), placedByTo = id(0x42), friendshipFrom = id(0x43), friendshipTo = id(0x44)
    static let order12Placed = id(0x51), order13Placed = id(0x52), annAndBo = id(0x53), standupAndBo = id(0x54)

    /// Every shape, in file order.
    static let fileOrder = [person, order, placedBy, friendship, annLee, boPark, order12, order13, order14, standup,
                            placedByFrom, placedByTo, friendshipFrom, friendshipTo, order12Placed, order13Placed, annAndBo, standupAndBo]

    static let personSchema = """
        {"type": "object", "properties": {"name": {"type": "string"}, "email": {"type": "string"}, \
        "dob": {"type": "string", "format": "date", "title": "birthday"}, "$title": {"x-canvas-from": "name"}}, \
        "required": ["name"]}
        """

    /// Order's schema: its `customer` is text, and `gift` asks for `giftNote` by an `if`.
    static var orderSchema: String {
        """
            {"type": "object", "properties": {"number": {"type": "string"}, "customer": {"type": "string"}, \
            "status": {"type": "string", "enum": ["draft", "paid", "shipped"]}, "due": {"type": "string", "format": "date"}, \
            "total": {"type": "number"}, \
            "lineItems": {"type": "array", "items": {"type": "object", "properties": {"product": {"type": "string"}, "qty": {"type": "number"}}}}, \
            "gift": {"type": "boolean"}, "giftNote": {"type": "string"}}, \
            "required": ["number", "customer", "status", "due"], \
            "allOf": [{"if": {"properties": {"gift": {"const": true}}}, "then": {"required": ["giftNote"]}}]}
            """
    }

    static let placedBySchema = """
        {"type": "object", "properties": {"via": {"type": "string", "enum": ["web", "phone", "store"]}}}
        """
    static let friendshipSchema = """
        {"type": "object", "properties": {"since": {"type": "string", "format": "date"}}}
        """

    /// The file: its notes in a row of columns, the types first.
    static func file(in registry: Registry) -> CanvasFile {
        var place = 0
        func note(_ id: ShapeID, _ title: String, _ text: MentionText = MentionText(plain: "")) -> ShapeRecord<StickyNote> {
            let origin = CGPoint(x: 80 + (place % 4) * 320, y: 80 + (place / 4) * 320)
            place += 1
            var note = ShapeRecord(id: id, StickyNote(frame: CGRect(origin: origin, size: StickyNote.defaultSize), text: text))
            note[TitleProperty.self] = title
            return note
        }
        func type(_ id: ShapeID, _ title: String, _ schema: String) -> AnyShapeRecord {
            var record = note(id, title)
            record[TypeSchemaProperty.self] = SchemaText(schema)
            return AnyShapeRecord(record)
        }
        func relationshipType(_ id: ShapeID, _ title: String, _ schema: String) -> AnyShapeRecord {
            var record = note(id, title)
            record[TypeSchemaProperty.self] = SchemaText(schema)
            record[RelationshipProperty.self] = true
            return AnyShapeRecord(record)
        }
        func instance(_ id: ShapeID, _ title: String, of type: ShapeID, _ values: JSONObject) -> AnyShapeRecord {
            var record = note(id, title)
            record[IsAProperty.self] = [TypeLink(type)]
            record[FieldValuesProperty.self] = FieldValues(values)
            return AnyShapeRecord(record)
        }
        let notes: [AnyShapeRecord] = [
            type(person, "Person", personSchema),
            type(order, "Order", orderSchema),
            relationshipType(placedBy, "Placed by", placedBySchema),
            relationshipType(friendship, "Friendship", friendshipSchema),
            instance(annLee, "Ann Lee", of: person, ["name": "Ann Lee", "dob": "1990-05-02"]),
            instance(boPark, "Bo Park", of: person, ["name": "Bo Park", "dob": "2001-11-30"]),
            instance(order12, "Order 12", of: order, [
                "number": "12", "customer": "Ann Lee", "status": "paid", "due": "2026-10-05", "total": 18,
                "lineItems": [["product": "Mug", "qty": 2], ["product": "Pen", "qty": 1]],
            ]),
            instance(order13, "Order 13", of: order, [
                "number": "13", "customer": "Bo Park", "status": "draft", "due": "2026-11-01", "total": "twelve",
                "lineItems": [["product": "Mug", "qty": 1]],
            ]),
            instance(order14, "Order 14", of: order, [
                "number": "14", "status": "draft", "gift": true,
            ]),
            AnyShapeRecord(note(standup, "Standup", MentionText([.text("sync with "), .mention(annLee, label: "Ann Lee")]))),
        ]
        /// An arrow made by the shipped connector between two of the notes, as a connection made by name is.
        func arrow(_ id: ShapeID, _ from: ShapeID, _ to: ShapeID, is relation: ShapeID? = nil, says: String = "", rule: EndRule? = nil,
                   values: JSONObject = [:]) -> AnyShapeRecord {
            let context = ShapeContext(document: CanvasDocument(shapes: notes), registry: registry)
            guard var arrow = registry.connection(ConnectionRequest(from: from, to: to, channel: NoteLink.id), in: context) else {
                preconditionFailure("the shipped connector connects \(from) to \(to)")
            }
            arrow = arrow.copy(as: id)
            if !says.isEmpty, var typed = arrow.typed(as: Arrow.self) {
                typed.props.text = MentionText(plain: says)
                arrow = AnyShapeRecord(typed)
            }
            if let relation { arrow[IsAProperty.self] = [TypeLink(relation)] }
            if let rule { arrow[RelationshipEndProperty.self] = rule }
            if !values.isEmpty { arrow[FieldValuesProperty.self] = FieldValues(values) }
            return arrow
        }
        return CanvasFile(root: CanvasDocument(shapes: notes + [
            arrow(placedByFrom, order, placedBy, says: "customer", rule: EndRule(needed: true, onlyOne: false)),
            arrow(placedByTo, placedBy, person, says: "orders"),
            arrow(friendshipFrom, person, friendship, says: "friends"),
            arrow(friendshipTo, friendship, person, says: "friends"),
            arrow(order12Placed, order12, annLee, is: placedBy, values: ["via": "web"]),
            arrow(order13Placed, order13, boPark, is: placedBy, values: ["via": "phone"]),
            arrow(annAndBo, annLee, boPark, is: friendship, values: ["since": "2019-05-01"]),
            arrow(standupAndBo, standup, boPark, is: friendship),
        ]))
    }

    /// The file in an editor of the shipped plugins, their clipboard on `pasteboard` (a test's own) and
    /// their model `model`: the board shown, in the story's viewport, nothing selected.
    static func harness(pasteboard: NSPasteboard, model: any LanguageModel = ScriptedLanguageModel()) throws -> EditorHarness {
        let registry = try ShippedPlugins.registry(pasteboard: pasteboard, model: model)
        let h = EditorHarness { CanvasEditor(registry: registry, file: file(in: registry), scheduler: $0) }
        h.editor.viewportDidResize(to: QueryStory.viewport)
        return h
    }
}

@MainActor let queryFieldsBoardTests = Suite("Query fields board", [
    test("the fields board: four types and six notes in file order, one incomplete, one wrong, a customer's name and a mention told apart, and the relationships") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let h = try QueryFieldsBoard.harness(pasteboard: pasteboard)
        let queries = try require(h.editor.queries)
        @MainActor func ids(_ query: String) throws -> [ShapeID] {
            try awaitResult { try await queries.run(QueryRequest(query, limit: QueryBudget.maxRows, properties: .none)) }.rows.map(\.id)
        }
        expectEqual(try ids("*"), QueryFieldsBoard.fileOrder)
        expectEqual(try ids("sticky-note[schema]"), [QueryFieldsBoard.person, QueryFieldsBoard.order, QueryFieldsBoard.placedBy, QueryFieldsBoard.friendship])
        expectEqual(try ids("sticky-note[relationship]"), [QueryFieldsBoard.placedBy, QueryFieldsBoard.friendship])
        expectEqual(try ids(#":is-a("Order")"#), [QueryFieldsBoard.order12, QueryFieldsBoard.order13, QueryFieldsBoard.order14])
        expectEqual(try ids(#":is-a("Person")"#), [QueryFieldsBoard.annLee, QueryFieldsBoard.boPark])

        // Order 14 needs its due and its customer and holds nothing wrong; Order 13's total is text in a number's field;
        // Standup's friendship with Bo is a misfit, which is an error too.
        expectEqual(try ids(":incomplete"), [QueryFieldsBoard.order14])
        expectEqual(try ids(":invalid"), [QueryFieldsBoard.order13, QueryFieldsBoard.standupAndBo])

        // The orders' customers are text, Standup's Ann Lee a mention: the one edge.
        expectEqual(try ids(#":mentions("Ann Lee")"#), [QueryFieldsBoard.standup])
        expectEqual(try ids(#":edge-to("Ann Lee", mention)"#), [QueryFieldsBoard.standup])
        expectEqual(try ids(#"[fieldValues.customer="Ann Lee"]"#), [QueryFieldsBoard.order12])

        // What the values say, as the queries read them.
        expectEqual(try ids(#"[fieldValues.lineItems.product="Mug"]"#), [QueryFieldsBoard.order12, QueryFieldsBoard.order13])
        expectEqual(try ids(#"[fieldValues.due<"2026-11-01"]"#), [QueryFieldsBoard.order12])
        expectEqual(try ids(#"[fieldValues.dob<"2000-01-01"]"#), [QueryFieldsBoard.annLee])

        // The relationships: who placed what, who is a friend, which one is a misfit.
        expectEqual(try ids(#"arrow:is-a("Placed by")"#), [QueryFieldsBoard.order12Placed, QueryFieldsBoard.order13Placed])
        expectEqual(try ids(#":start-of(arrow:is-a("Placed by"):ends-at("Ann Lee"))"#), [QueryFieldsBoard.order12])
        expectEqual(try ids(#":end-of(arrow:is-a("Placed by"):starts-at("Order 12"))"#), [QueryFieldsBoard.annLee])
        expectEqual(try ids(#"sticky-note:is-a("Order"):not([schema]):not(:start-of(arrow:is-a("Placed by")))"#), [QueryFieldsBoard.order14])
        expectEqual(try ids(#":end-of(arrow:is-a("Friendship"):starts-at("Ann Lee")), :start-of(arrow:is-a("Friendship"):ends-at("Ann Lee"))"#), [QueryFieldsBoard.boPark])
        expectEqual(try ids(#"arrow:is-a("Friendship")[fieldValues.since<"2020-01-01"]"#), [QueryFieldsBoard.annAndBo])
        expectEqual(try ids("arrow:misfit"), [QueryFieldsBoard.standupAndBo])
        expectEqual(try ids(#"sticky-note[relationship]:connected-to("Order", arrow)"#), [QueryFieldsBoard.placedBy])
        expectEqual(h.editor.selectedShapeIDs, [])
    },
])
