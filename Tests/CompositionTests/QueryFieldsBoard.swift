import AppKit
@_spi(Host) import Canvas
import CanvasTesting
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
// `fieldValues` are set on its record, a pointer's value written as the writer writes one (`FieldLink`),
// so the file needs no draw.
//
//     Person  …01  a type: name (text, titles the note), email, dob (a date a person calls "birthday");
//                  name is required
//     Order   …02  a type: number, customer (a link to a Person), status (draft, paid or shipped), due (a
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

    /// Every shape, in file order.
    static let fileOrder = [person, order, annLee, boPark, order12, order13, order14, standup]

    static let personSchema = """
        {"type": "object", "properties": {"name": {"type": "string"}, "email": {"type": "string"}, \
        "dob": {"type": "string", "format": "date", "title": "birthday"}, "$title": {"x-canvas-from": "name"}}, \
        "required": ["name"]}
        """

    /// Order's schema: its `customer` is the pointer to Person, and `gift` asks for `giftNote` by an `if`.
    static var orderSchema: String {
        let customer = #"{"type": "string", "contentMediaType": "\#(FieldKind.pointerMediaType)", "contentSchema": {"$ref": "\#(SchemaReferences.uri(of: person))"}}"#
        return """
            {"type": "object", "properties": {"number": {"type": "string"}, "customer": \(customer), \
            "status": {"type": "string", "enum": ["draft", "paid", "shipped"]}, "due": {"type": "string", "format": "date"}, \
            "total": {"type": "number"}, \
            "lineItems": {"type": "array", "items": {"type": "object", "properties": {"product": {"type": "string"}, "qty": {"type": "number"}}}}, \
            "gift": {"type": "boolean"}, "giftNote": {"type": "string"}}, \
            "required": ["number", "customer", "status", "due"], \
            "allOf": [{"if": {"properties": {"gift": {"const": true}}}, "then": {"required": ["giftNote"]}}]}
            """
    }

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
        func instance(_ id: ShapeID, _ title: String, of type: ShapeID, _ values: JSONObject) -> AnyShapeRecord {
            var record = note(id, title)
            record[IsAProperty.self] = [TypeLink(type)]
            record[FieldValuesProperty.self] = FieldValues(values)
            return AnyShapeRecord(record)
        }
        func link(_ target: ShapeID, _ name: String) -> JSONValue { FieldLink(target: target, stored: name).value }
        return CanvasFile(root: CanvasDocument(shapes: [
            type(person, "Person", personSchema),
            type(order, "Order", orderSchema),
            instance(annLee, "Ann Lee", of: person, ["name": "Ann Lee", "dob": "1990-05-02"]),
            instance(boPark, "Bo Park", of: person, ["name": "Bo Park", "dob": "2001-11-30"]),
            instance(order12, "Order 12", of: order, [
                "number": "12", "customer": link(annLee, "Ann Lee"), "status": "paid", "due": "2026-10-05", "total": 18,
                "lineItems": [["product": "Mug", "qty": 2], ["product": "Pen", "qty": 1]],
            ]),
            instance(order13, "Order 13", of: order, [
                "number": "13", "customer": link(boPark, "Bo Park"), "status": "draft", "due": "2026-11-01", "total": "twelve",
                "lineItems": [["product": "Mug", "qty": 1]],
            ]),
            instance(order14, "Order 14", of: order, [
                "number": "14", "customer": link(annLee, "Ann Lee"), "status": "draft", "gift": true,
            ]),
            AnyShapeRecord(note(standup, "Standup", MentionText([.text("sync with "), .mention(annLee, label: "Ann Lee")]))),
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
    test("the fields board: two types and six notes in file order, one incomplete, one wrong, links and a mention told apart") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let h = try QueryFieldsBoard.harness(pasteboard: pasteboard)
        let queries = try require(h.editor.queries)
        @MainActor func ids(_ query: String) throws -> [ShapeID] {
            try awaitResult { try await queries.run(QueryRequest(query, limit: QueryBudget.maxRows, properties: .none)) }.rows.map(\.id)
        }
        expectEqual(try ids("*"), QueryFieldsBoard.fileOrder)
        expectEqual(try ids("sticky-note[schema]"), [QueryFieldsBoard.person, QueryFieldsBoard.order])
        expectEqual(try ids(#":is-a("Order")"#), [QueryFieldsBoard.order12, QueryFieldsBoard.order13, QueryFieldsBoard.order14])
        expectEqual(try ids(#":is-a("Person")"#), [QueryFieldsBoard.annLee, QueryFieldsBoard.boPark])

        // Order 14 needs its due and holds nothing wrong; Order 13's total is text in a number's field.
        expectEqual(try ids(":incomplete"), [QueryFieldsBoard.order14])
        expectEqual(try ids(":invalid"), [QueryFieldsBoard.order13])

        // The orders' customers are links, Standup's Ann Lee a mention: two edges with one target.
        expectEqual(try ids(#":edge-to("Ann Lee", field-link)"#), [QueryFieldsBoard.order12, QueryFieldsBoard.order14])
        expectEqual(try ids(#":mentions("Ann Lee")"#), [QueryFieldsBoard.standup])
        expectEqual(try ids(#":edge-to("Ann Lee", mention)"#), [QueryFieldsBoard.order12, QueryFieldsBoard.order14, QueryFieldsBoard.standup])

        // What the values say, as the queries read them.
        expectEqual(try ids(#"[fieldValues.lineItems.product="Mug"]"#), [QueryFieldsBoard.order12, QueryFieldsBoard.order13])
        expectEqual(try ids(#"[fieldValues.due<"2026-11-01"]"#), [QueryFieldsBoard.order12])
        expectEqual(try ids(#"[fieldValues.dob<"2000-01-01"]"#), [QueryFieldsBoard.annLee])
        expectEqual(h.editor.selectedShapeIDs, [])
    },
])
