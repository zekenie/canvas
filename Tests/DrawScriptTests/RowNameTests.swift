import DrawScript
import TestKit

// A row of a shape, named with a dot outside the quotes (titles hold dots): `"orders".customer_id` in an edge's ends and in
// `delete`, `."POST /orders"` quoted, an id's row in one word (`#…​.id`), a path's last shape's row (`"shop" > "orders".id`);
// a dot with nothing after it refused; and `delete edge` names whole shapes.

@MainActor let rowNameTests = Suite("Rows by name", [
    test("an edge's ends may name rows: bare, quoted, after an id and after a path, and are written back so") {
        guard case .edge(let edge) = try parse(#"edge "orders".customer_id -> "customers".id label: keyed"#) else { throw RequireFailed() }
        expectEqual(edge.from, .title("orders"))
        expectEqual(edge.fromRow, "customer_id")
        expectEqual(edge.to, .title("customers"))
        expectEqual(edge.toRow, "id")
        expectEqual(edge.written, #""orders".customer_id -> "customers".id"#)
        expectEqual(edge.attributes.map(\.key), ["label"])
        guard case .edge(let quoted) = try parse(#"edge "orders API"."POST /orders/{id}/refunds" -> "refunds""#) else { throw RequireFailed() }
        expectEqual(quoted.fromRow, "POST /orders/{id}/refunds")
        expectEqual(quoted.toRow, nil)
        expectEqual(quoted.written, #""orders API"."POST /orders/{id}/refunds" -> "refunds""#)
        let id = "7C1E2A04-4B9E-4E0C-9D8C-5B0E7F3A2C11"
        guard case .edge(let byID) = try parse("edge #\(id).id <- \"shop\" > \"orders\".customer_id") else { throw RequireFailed() }
        expectEqual(byID.to, .id(id))
        expectEqual(byID.toRow, "id")
        expectEqual(byID.from, .path(ShapePath(head: .title("shop"), rest: ["orders"])))
        expectEqual(byID.fromRow, "customer_id")
        expectEqual(byID.written, "#\(id).id <- \"shop\" > \"orders\".customer_id")
    },
    test("a title with dots in it is the title: the row is what's after the quotes") {
        guard case .edge(let edge) = try parse(#"edge "api.shop.dev".id -> "v1.2""#) else { throw RequireFailed() }
        expectEqual(edge.from, .title("api.shop.dev"))
        expectEqual(edge.fromRow, "id")
        expectEqual(edge.to, .title("v1.2"))
        expectEqual(edge.toRow, nil)
    },
    test("delete takes a row of a shape, and a whole shape as before") {
        expectEqual(try parse(#"delete "orders".legacy_note"#), .delete(.row(.title("orders"), row: "legacy_note")))
        expectEqual(try parse(#"delete "orders""#), .delete(.shape(.title("orders"))))
        expectEqual(try parse(#"delete "shop" > "orders"."legacy note""#),
                    .delete(.row(.path(ShapePath(head: .title("shop"), rest: ["orders"])), row: "legacy note")))
    },
    test("a dot with no row after it is refused, saying how to write one; delete edge takes no rows") {
        let dangling = parseError(#"edge "orders". -> "customers""#)
        expectEqual(dangling?.reason, .syntax)
        expectEqual(dangling?.hint, #"write "orders".id"#)
        let rows = parseError(#"delete edge "orders".customer_id -> "customers".id"#)
        expectEqual(rows?.reason, .unsupported)
        expectEqual(rows?.hint, #"write delete edge "orders" -> "customers", which takes every edge between them, keys too"#)
    },
])
