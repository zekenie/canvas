import Canvas
import TestKit
import Types

// A row's name, and the step a write to it is called.

@MainActor let fieldNameTests = Suite("Field names", [
    test("a key is split into words in lower case") {
        let rows: [(String, String)] = [
            ("shippingAddress", "shipping address"), ("shipping_address", "shipping address"), ("shipping-address", "shipping address"),
            ("shipping address", "shipping address"), ("lineItems", "line items"), ("postalURL", "postal url"),
            ("HTTPServer", "http server"), ("address2", "address2"), ("address2Line", "address2 line"), ("x", "x"),
            ("name", "name"), ("Name", "name"), ("__a__b--c", "a b c"), ("URL", "url"), ("a1b", "a1b"),
        ]
        for (key, words) in rows {
            expectEqual(FieldName.words(of: ChainField(name: key, schema: .object([]))), words, key)
        }
        expectEqual(FieldName.words(of: ChainField(name: "_-_", schema: .null)), "_-_", "a key of only separators is as written")
    },
    test("a title wins as written; a blank one does not") {
        let titled = ChainField(name: "shippingAddress", schema: .object([SchemaMember(key: "title", value: .string("Ship To"))]))
        expectEqual(FieldName.words(of: titled), "Ship To")
        let blank = ChainField(name: "shippingAddress", schema: .object([SchemaMember(key: "title", value: .string("  "))]))
        expectEqual(FieldName.words(of: blank), "shipping address")
        let empty = ChainField(name: "lineItems", schema: .object([SchemaMember(key: "title", value: .string(""))]))
        expectEqual(FieldName.words(of: empty), "line items")
        let notText = ChainField(name: "lineItems", schema: .object([SchemaMember(key: "title", value: .number(3))]))
        expectEqual(FieldName.words(of: notText), "line items")
    },
    test("the step is Change and the name, each word capitalised") {
        expectEqual(FieldName.stepName(of: ChainField(name: "shippingAddress", schema: .null)), "Change Shipping Address")
        expectEqual(FieldName.stepName(of: ChainField(name: "email", schema: .null)), "Change Email")
        expectEqual(FieldName.stepName(of: ChainField(name: "postalURL", schema: .null)), "Change Postal Url")
        let titled = ChainField(name: "x", schema: .object([SchemaMember(key: "title", value: .string("ship to"))]))
        expectEqual(FieldName.stepName(of: titled), "Change Ship To")
    },
])
