import Canvas
import TestKit
import Types

// A path to a value in `fieldValues`: members by key, elements by stored index.

@MainActor let fieldPathTests = Suite("Field paths", [
    test("steps, the field, the parent and the root") {
        let path = FieldPath(field: "lineItems").index(1).key("quantity")
        expectEqual(path.steps, [.key("lineItems"), .index(1), .key("quantity")])
        expectEqual(path.field, "lineItems")
        expectEqual(path.parent, FieldPath(field: "lineItems").index(1))
        expectEqual(path.parent?.parent, FieldPath(field: "lineItems"))
        expectEqual(path.parent?.parent?.parent, FieldPath())
        expect(path.parent?.parent?.parent?.isRoot == true)
        expectEqual(FieldPath().parent, nil, "the root has no parent")
        expectEqual(FieldPath().field, nil)
        expectEqual(FieldPath([.index(0)]).field, nil, "a path that starts with an index names no row")
        expect(!path.isRoot)
        expectEqual(FieldPath(field: "a"), FieldPath([.key("a")]))
    },
    test("a path is a prefix of itself and of what is under it, and of nothing else") {
        let order = FieldPath(field: "lineItems"), cell = order.index(1).key("quantity")
        expect(order.isPrefix(of: cell))
        expect(order.isPrefix(of: order), "equal counts")
        expect(FieldPath().isPrefix(of: cell), "the root is above everything")
        expect(!cell.isPrefix(of: order))
        expect(!FieldPath(field: "gift").isPrefix(of: cell))
        expect(!order.index(0).isPrefix(of: order.index(1)))
    },
    test("a validator's path: members are keys, elements indexes") {
        let violation = SchemaViolation(path: [.member("lineItems"), .element(1), .member("quantity")], keyword: "minimum", message: "")
        expectEqual(FieldPath(violation.path), FieldPath(field: "lineItems").index(1).key("quantity"))
        expectEqual(FieldPath([JSONPathComponent]()), FieldPath())
    },
    test("the pointer is JSON Pointer's, with `~` and `/` escaped, and empty for the root") {
        expectEqual(FieldPath(field: "lineItems").index(1).key("quantity").pointer, "/lineItems/1/quantity")
        expectEqual(FieldPath(field: "a/b").key("c~d").pointer, "/a~1b/c~0d")
        expectEqual(FieldPath().pointer, "")
    },
])
