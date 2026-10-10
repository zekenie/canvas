import Canvas
import CanvasTesting
import TestKit
import Types

// Reading and setting a value at a path: pure.

private let order = FieldValues([
    "status": "paid",
    "lineItems": [["product": "Mug", "quantity": 2], ["product": "Plate", "quantity": 1]],
    "shippingAddress": ["city": "Leeds"],
    "tags": ["gift", "mugs"],
])

@MainActor let fieldAccessTests = Suite("Field value access", [
    test("a value is read at any depth: by key and by index; nothing where there is none or a step meets the other shape") {
        expectEqual(order.value(at: FieldPath(field: "status")), "paid")
        expectEqual(order.value(at: FieldPath(field: "lineItems").index(1).key("product")), "Plate")
        expectEqual(order.value(at: FieldPath(field: "lineItems").index(0).key("quantity")), 2)
        expectEqual(order.value(at: FieldPath(field: "shippingAddress").key("city")), "Leeds")
        expectEqual(order.value(at: FieldPath()), .object(order.values), "the root is the whole")
        expectEqual(order.value(at: FieldPath(field: "nope")), nil)
        expectEqual(order.value(at: FieldPath(field: "lineItems").index(2)), nil)
        expectEqual(order.value(at: FieldPath(field: "status").key("x")), nil, "a key into text")
        expectEqual(order.value(at: FieldPath(field: "tags").key("x")), nil, "a key into a list")
        expectEqual(order.value(at: FieldPath(field: "shippingAddress").index(0)), nil, "an index into a group")
    },
    test("setting makes the parents it needs: a key an object, an index an array") {
        let made = FieldValues().setting("Leeds", at: FieldPath(field: "shippingAddress").key("city"))
        expectEqual(made, FieldValues(["shippingAddress": ["city": "Leeds"]]))
        let items = FieldValues().setting("Mug", at: FieldPath(field: "lineItems").index(0).key("product"))
        expectEqual(items, FieldValues(["lineItems": [["product": "Mug"]]]))
        expectEqual(order.setting("Cup", at: FieldPath(field: "lineItems").index(0).key("product")).value(at: FieldPath(field: "lineItems").index(0)),
                    ["product": "Cup", "quantity": 2])
        expectEqual(order.setting("cancelled", at: FieldPath(field: "status")).value(at: FieldPath(field: "status")), "cancelled")
    },
    test("a path that starts with an index changes nothing, and removing under a parent of the other shape too") {
        expectEqual(order.setting("x", at: FieldPath([.index(0)])), order)
        expectEqual(order.setting(nil, at: FieldPath([.index(0)])), order)
        expectEqual(order.setting(nil, at: FieldPath(field: "status").key("city")), order, "nothing there to remove")
        expectEqual(order.setting(nil, at: FieldPath(field: "shippingAddress").index(0)), order)
        expectEqual(order.setting("x", at: FieldPath(field: "status").key("city")).value(at: FieldPath(field: "status").key("city")), "x", "a write replaces a parent of the other shape")
    },
    test("an index equal to the count appends, and so does one past it: no holes") {
        let tags = FieldPath(field: "tags")
        expectEqual(order.setting("new", at: tags.index(2)).value(at: tags), ["gift", "mugs", "new"])
        expectEqual(order.setting("new", at: tags.index(9)).value(at: tags), ["gift", "mugs", "new"])
        expectEqual(FieldValues().setting("a", at: tags.index(5)), FieldValues(["tags": ["a"]]))
    },
    test("empty removes, and every parent left empty goes too") {
        expectEqual(order.setting(nil, at: FieldPath(field: "status")).value(at: FieldPath(field: "status")), nil)
        expectEqual(order.setting("", at: FieldPath(field: "status")).value(at: FieldPath(field: "status")), nil, "text with no characters is empty")
        expectEqual(order.setting(.null, at: FieldPath(field: "status")).value(at: FieldPath(field: "status")), nil)
        let city = FieldPath(field: "shippingAddress").key("city")
        expectEqual(order.setting(nil, at: city).value(at: FieldPath(field: "shippingAddress")), nil, "the group it left empty goes")
        let only = FieldValues(["a": ["b": [["c": "x"]]]])
        expect(only.setting(nil, at: FieldPath(field: "a").key("b").index(0).key("c")).isEmpty, "every parent up the path")
        expectEqual(order.setting(false, at: FieldPath(field: "gift")).value(at: FieldPath(field: "gift")), false, "false is a value")
        expectEqual(order.setting(0, at: FieldPath(field: "n")).value(at: FieldPath(field: "n")), 0, "so is 0")
        expectEqual(order.setting(" ", at: FieldPath(field: "n")).value(at: FieldPath(field: "n")), " ", "and spaces")
    },
    test("empty at an index takes the element out and the rest shift up") {
        let tags = FieldPath(field: "tags")
        expectEqual(order.setting(nil, at: tags.index(0)).value(at: tags), ["mugs"])
        expectEqual(order.setting("", at: tags.index(1)).value(at: tags), ["gift"])
        let items = FieldPath(field: "lineItems")
        expectEqual(order.setting(nil, at: items.index(0)).value(at: items), [["product": "Plate", "quantity": 1]])
        expectEqual(order.setting(nil, at: items.index(5)).value(at: items), order.value(at: items), "an index past the end: nothing to take out")
        let both = order.setting(nil, at: tags.index(0)).setting(nil, at: tags.index(0))
        expectEqual(both.value(at: tags), nil, "the last one out takes the list")
    },
    test("a parent that holds the other shape of value is replaced: nothing is refused") {
        let text = FieldValues(["shippingAddress": "12 Main St"])
        expectEqual(text.setting("Leeds", at: FieldPath(field: "shippingAddress").key("city")), FieldValues(["shippingAddress": ["city": "Leeds"]]),
                    "a string where a group should be")
        let group = FieldValues(["tags": ["city": "x"]])
        expectEqual(group.setting("a", at: FieldPath(field: "tags").index(0)), FieldValues(["tags": ["a"]]), "an object where a list should be")
    },
    test("the root: an object is the new whole, nil clears it, anything else changes nothing") {
        expectEqual(order.setting(["a": "b"], at: FieldPath()), FieldValues(["a": "b"]))
        expect(order.setting(nil, at: FieldPath()).isEmpty)
        expectEqual(order.setting("text", at: FieldPath()), order)
    },
    test("the members no field names, in key order") {
        let editor = try fieldEditor()
        let resolved = try require(editor.fieldBook).fields(types: [FieldFixtures.personID])
        let values = FieldValues(["name": "Ann", "zeta": 1, "alpha": "x", "email": "a@b.c"])
        expectEqual(values.keys(unnamedBy: resolved), ["alpha", "zeta"])
        expectEqual(FieldValues().keys(unnamedBy: resolved), [])
        expectEqual(values.keys(unnamedBy: Resolved()), ["alpha", "email", "name", "zeta"])
    },
])
