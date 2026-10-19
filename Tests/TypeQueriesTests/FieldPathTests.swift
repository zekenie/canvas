import Canvas
import CanvasRPC
import CanvasTesting
import CoreGraphics
import Foundation
import Queries
import QueryLanguage
import TestKit
import Titles
import Types

// A path into a note's values (`[fieldValues.status="paid"]`) that no type of the file gives is a warning,
// `unknown_field`, and the query still answers: from the fields of every type, read through the chain.

private let orderID = FieldFixtures.orderID

private func orderType() -> AnyShapeRecord {
    var record = AnyShapeRecord(ShapeRecord(id: orderID, Memo(frame: CGRect(x: 40, y: 900, width: 240, height: 52))))
    record[TitleProperty.self] = "Order"
    record[TypeSchemaProperty.self] = SchemaText(FieldFixtures.order.schema)
    return record
}

private func order(_ n: Int, _ values: JSONObject = [:], is types: [ShapeID] = [orderID]) -> AnyShapeRecord {
    var record = memo(n, "Order \(n)")
    record[IsAProperty.self] = types.map(TypeLink.init)
    if !values.isEmpty { record[FieldValuesProperty.self] = FieldValues(values) }
    return record
}

@MainActor private func harness(_ shapes: [AnyShapeRecord], types: Bool = true) throws -> EditorHarness {
    try EditorHarness(plugins: typeQueryPlugins(), document: CanvasDocument(shapes: (types ? [orderType()] : []) + shapes))
}

@MainActor private func warnings(_ query: String, on h: EditorHarness) throws -> [String] {
    let result = try answer(query, on: h, properties: .none)
    return result.warnings.filter { $0.reason == .unknownField }.map(\.message)
}

@MainActor let fieldPathQueryTests = Suite("fieldValues paths in canvas query", [
    test("a field no type has is warned of, with the one it was near, and the query still answers") {
        let h = try harness([order(1, ["status": "paid"]), order(2, ["stauts": "paid"])])
        expectEqual(try warnings(#"[fieldValues.stauts="paid"]"#, on: h), ["No type in the file has fieldValues.stauts. Did you mean fieldValues.status?"])
        expectMatches([#"[fieldValues.stauts="paid"]"#: [2]], on: h)
        expectEqual(try warnings(#"[fieldValues.zzzzzz]"#, on: h), ["No type in the file has fieldValues.zzzzzz."], "nothing near, no suggestion")
    },
    test("a field a type gives is not warned of, at the top, through a list, another type's fields or past a gone type") {
        let h = try harness([order(1)])
        expectEqual(try warnings(#"[fieldValues.status]"#, on: h), [])
        expectEqual(try warnings(#"[fieldValues.lineItems.product="Mug"]"#, on: h), [], "a list's item's member")
        expectEqual(try warnings(#"[fieldValues.shippingAddress.city]"#, on: h), [], "the type Address isn't in this file, so nothing is known under it")
        expectEqual(try warnings(#"[fieldValues.giftNote][fieldValues.gift=true]"#, on: h), [])
    },
    test("a nested and a list step are checked where a type says the members") {
        let h = try harness([order(1)])
        expectEqual(try warnings(#"[fieldValues.lineItems.produt="x"]"#, on: h), ["No type in the file has fieldValues.lineItems.produt. Did you mean fieldValues.lineItems.product?"])
        expectEqual(try warnings(#"[fieldValues.customer.name]"#, on: h), ["No type in the file has fieldValues.customer.name."], "past text")
        expectEqual(try warnings(#"[fieldValues.status.x]"#, on: h), ["No type in the file has fieldValues.status.x."], "past a plain value")
    },
    test("a file with no types warns of every path, and a type's $-key is no field") {
        let h = try harness([memo(1, "Plain")], types: false)
        expectEqual(try warnings(#"[fieldValues.status]"#, on: h), ["No type in the file has fieldValues.status."])
        let titled = try harness([order(1)])
        titled.editor.transact { $0.update(orderID) { $0[TypeSchemaProperty.self] = SchemaText(#"{"type": "object", "properties": {"$title": {"const": "name"}, "name": {"type": "string"}}}"#) } }
        expectEqual(try warnings(#"[fieldValues.name]"#, on: titled), [])
    },
    test("nothing is said while any note lists a type that is gone, and a path is warned of again once its link is removed") {
        let ghost = ShapeID()
        let h = try harness([order(1), order(2, [:], is: [ghost])])
        expectEqual(try warnings(#"[fieldValues.stauts]"#, on: h), [], "the gone type's fields are unknown, and its notes' values are kept")
        h.editor.transact { $0.update(id(2)) { $0[IsAProperty.self] = [] } }
        expectEqual(try warnings(#"[fieldValues.stauts]"#, on: h).count, 1)
    },
    test("a type's edit moves what is known: a field added is no longer warned of") {
        let h = try harness([order(1)])
        expectEqual(try warnings(#"[fieldValues.nickname]"#, on: h).count, 1)
        h.editor.transact { $0.update(orderID) { $0[TypeSchemaProperty.self] = SchemaText(FieldFixtures.order.schema.replacingOccurrences(of: #""giftNote": { "type": "string" }"#, with: #""giftNote": { "type": "string" }, "nickname": { "type": "string" }"#)) } }
        expectEqual(try warnings(#"[fieldValues.nickname]"#, on: h), [])
    },
])
