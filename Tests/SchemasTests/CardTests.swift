import CoreGraphics
import Foundation
import Schemas
import TestKit

/// A schema of `count` string fields, `f1`…, with `extra` members at its root.
func flat(_ count: Int, extra: String = "") -> String {
    let properties = (1...max(1, count)).prefix(count).map { "\"f\($0)\": { \"type\": \"string\" }" }.joined(separator: ", ")
    return "{ \"properties\": { \(properties) }\(extra) }"
}

@MainActor let cardTests = Suite("Schema card", [
    test("each fixture's card, at its own height and 240 wide, as the spec's renders show it") {
        expectEqual(rows(fixture(1)), [])
        expectEqual(rows(fixture(2)), ["email* email", "phone* string", "description string"])
        expectEqual(rows(fixture(3)), ["name* string", "species* dog | cat | bird | fish | +1 enum", "birthYear integer", "coatColor string",
                                       "vaccinated boolean"])
        expectEqual(rows(fixture(4)), ["title* string", "author* string", "isbn string", "pages integer", "publishedOn date",
                                       "genre fiction | nonfiction | +2 enum", "inPrint boolean"])
        expectEqual(rows(fixture(5)), ["id* uuid", "firstName* string", "lastName* string", "email* email", "phone string", "company string",
                                       "+14 more"])
        expectEqual(rows(fixture(6)), ["id* string", "customer* { name · email }", "items* [ sku · quantity · price ]",
                                       "shippingAddress { street · city · +2 }", "status* pending | paid | +3 enum", "createdAt date-time"])
        expectEqual(rows(fixture(7)), ["name* string", "headquarters { address {…} · phone }", "founded integer", "tags string[]"])
        expectEqual(rows(fixture(8)), ["primaryAccountManagerEmailAddress* email", "annualContractValueInUnitedStatesDollars* number",
                                       "numberOfSeatsRequestedForNextBillingPeriod integer", "preferredInvoiceDeliveryMethodAndSchedule 4 values enum",
                                       "hasSignedTheUpdatedDataProcessingAgreement boolean"])
        expectEqual(rows(fixture(9)), ["total* { amount · currency } → money", "method* Card | +2 one of", "country string", "vatNumber string",
                                       "/^x-/ string", "Rules  if/then"])
        expectEqual(rows(fixture(10)), [])
    },
    test("the states: empty, invalid at its line and column, not an object; each title as the root says it") {
        @MainActor func layout(_ text: String) -> SchemaCardLayout { SchemaCardLayout(SchemaDocument(text), size: CGSize(width: 240, height: 89)) }
        expectEqual(layout(fixture(1)).state, .empty)
        expectEqual(layout(fixture(1)).stateLines, ["Describe it in the details panel", "“A pet: name, species, birth year…”"])
        expectEqual([layout(fixture(1)).title, layout(SchemaCard.starter).title], ["Untitled Schema", "Untitled Schema"])
        expectEqual(layout(fixture(1)).isUntitled, true)
        expectEqual(layout(fixture(10)).state, .invalid(line: 6, column: 35))
        expectEqual(layout(fixture(10)).stateLines, ["Invalid JSON · line 6, column 35", "Fix it in the details panel"])
        expectEqual(layout(fixture(10)).title, "Invoice")
        expectEqual(layout("[1, 2]").state, .notObject)
        expectEqual(layout("[1, 2]").stateLines, ["Not an object schema", "Fix it in the details panel"])
        expectEqual(layout(fixture(6)).state, .fields)
        expectEqual(layout(fixture(6)).title, "Order")
    },
    test("the overflow rule: 1 to 7 fields show all; 8 or more show 6 and how many more, never +1") {
        for count in 1...7 {
            let shown = rows(flat(count))
            expectEqual(shown.count, count, "\(count) fields")
            expect(!shown.contains { $0.hasSuffix("more") }, "\(count) fields")
        }
        for (count, more) in [(8, 2), (9, 3), (20, 14), (1000, 994)] {
            let shown = rows(flat(count))
            expectEqual(shown.count, 7, "\(count) fields")
            expectEqual(shown.last, "+\(more) more")
            expectEqual(shown[5], "f6 string")
        }
    },
    test("nested fields never take a row: a schema's height is its top-level count's, however deep") {
        expectEqual(SchemaCard.height(for: fixture(7)), 133, "four levels, four rows")
        let deep = (0..<40).reduce(#"{"type": "string"}"#) { inner, i in #"{"properties": {"level\#(i)": \#(inner), "sibling": {}}}"# }
        expectEqual(rows(deep), ["level39 { level38 {…} · sibling }", "sibling any"])
        expectEqual(SchemaCard.height(for: deep), 89, "two rows")
    },
    test("heights: 45 and 22 a row, at most 7 rows and the rules line; a state is 89") {
        expectEqual(fixtures.map { SchemaCard.height(for: $0.json) }, [89, 111, 155, 199, 199, 177, 133, 155, 177, nil])
        expectEqual((0...9).map { SchemaCardMetrics.height(rows: $0) }, [89, 67, 89, 111, 133, 155, 177, 199, 221, 243])
        expectEqual(SchemaCard.height(for: flat(7, extra: #", "allOf": []"#)), 221, "7 fields and the rules")
        expectEqual(rows(flat(7, extra: #", "allOf": []"#)).last, "Rules  allOf")
        expectEqual(rows(flat(8, extra: #", "if": {}, "then": {}, "not": {}"#)).suffix(2), ["+2 more", "Rules  if/then, not"])
        expectEqual(SchemaCard.height(for: "[1]"), 89)
        expectEqual(SchemaCard.height(for: "{ oops"), nil)
    },
    test("a frame the content didn't size shows what fits, by the same rule; a tiny one draws nothing inside") {
        expectEqual(rows(fixture(5), size: CGSize(width: 240, height: 130)), ["id* uuid", "firstName* string", "+18 more"])
        expectEqual(rows(fixture(3), size: CGSize(width: 240, height: 260)).count, 5, "taller: the same rows")
        expectEqual(rows(fixture(9), size: CGSize(width: 240, height: 155)).last, "/^x-/ string", "no room left for the rules")
        expectEqual(rows(fixture(6), size: CGSize(width: 240, height: 60)), [], "no room for a row")
        expectEqual(rows(fixture(6), size: CGSize(width: 240, height: 71)), ["+6 more"], "one row: only how many")
        for size in [CGSize(width: 10, height: 10), CGSize(width: 24, height: 300), CGSize(width: 0, height: 0), CGSize(width: 60, height: 400)] {
            _ = rows(fixture(6), size: size)
            _ = rows(fixture(8), size: size)
        }
    },
    test("widths: trays give way to counts, then to the type; names end in … inside their chips") {
        expectEqual(rows(fixture(6), size: CGSize(width: 180, height: 177)), [
            "id* string", "customer* { name · email }", "items* [ sku · quantity · +1 ]", "shippingAddress { 4 fields }",
            "status* pending | +4 enum", "createdAt date-time",
        ])
        expectEqual(rows(fixture(6), size: CGSize(width: 360, height: 177)), [
            "id* string", "customer* { name · email }", "items* [ sku · quantity · price ]",
            "shippingAddress { street · city · postalCode · country }", "status* pending | paid | shipped | delivered | cancelled enum",
            "createdAt date-time",
        ])
        // Too narrow for a tray: an object says so at the end instead (in the columns it has).
        expectEqual(rows(fixture(6), size: CGSize(width: 120, height: 177))[1...2], ["customer* object", "items* objec…"])
        let long = SchemaCardLayout(SchemaDocument(fixture(8)), size: CGSize(width: 240, height: 155)).rows
        expect(long.allSatisfy { $0.chip.maxX <= $0.frame.maxX }, "every chip in its row")
        expect(long[3].frame.maxX - long[3].chip.maxX >= 6 + 56, "the name leaves the tray its least")
    },
    test("type labels are cut to their columns, by characters") {
        let text = #"{ "properties": { "when": { "type": "string", "format": "a-very-long-format-name" } } }"#
        let cut = try require(rows(text).first)
        expect(cut.hasPrefix("when a-very-long-f") && cut.hasSuffix("…") && cut.count <= "when ".count + 15, cut)
        expectEqual(rows(text, size: CGSize(width: 480, height: 67)), ["when a-very-long-format-name"])
    },
    test("setSchema fits the height to the content in the same write, keeping the corner and width; not for a typo") {
        var card = SchemaCard(frame: CGRect(x: 10, y: 20, width: 300, height: 400))
        card.setSchema(fixture(6))
        expectEqual(card.frame, CGRect(x: 10, y: 20, width: 300, height: 177))
        expectEqual(card.schema, fixture(6))
        card.setSchema(fixture(10))
        expectEqual(card.frame.height, 177, "a text that isn't JSON leaves the frame")
        expectEqual(card.schema, fixture(10))
        card.setSchema("[]")
        expectEqual(card.frame.height, 89)
        card.prompt = "a pet"
        expectEqual(card.frame.height, 89)
    },
    test("a new card: the starter schema, 240 × 89, the empty card's height") {
        expectEqual(SchemaCard.defaultSize, CGSize(width: 240, height: 89))
        expectEqual(SchemaCard().schema, SchemaCard.starter)
        expectEqual(SchemaCard.height(for: SchemaCard.starter), 89)
        expectEqual(SchemaCard().prompt, "")
    },
    test("setTitle renames the schema, changing nothing else in its text") {
        func renamed(_ text: String, _ title: String) -> String {
            var card = SchemaCard(schema: text)
            card.setTitle(title)
            return card.schema
        }
        expectEqual(renamed(SchemaCard.starter, "Pet"), "{\n  \"title\": \"Pet\",\n  \"type\": \"object\",\n  \"properties\": {}\n}")
        expectEqual(renamed(#"{"type":"object"}"#, "Pet"), #"{"title":"Pet","type":"object"}"#)
        expectEqual(renamed("{}", "Pet"), #"{ "title": "Pet" }"#)
        expectEqual(renamed(#"{"title": "Old",  "x": 1}"#, #"New "quoted"\"#), #"{"title": "New \"quoted\"\\",  "x": 1}"#)
        expectEqual(renamed("{\n  \"title\": \"Pet\",\n  \"type\": \"object\"\n}", " "), "{\n  \"type\": \"object\"\n}")
        expectEqual(renamed(#"{"type": "object", "title": "Pet"}"#, ""), #"{"type": "object"}"#)
        expectEqual(renamed(#"{ "title": "Pet" }"#, ""), "{}")
        expectEqual(renamed(#"{"type": "object"}"#, ""), #"{"type": "object"}"#)
        expectEqual(renamed(fixture(10), "Bill"), fixture(10), "not JSON: left as it is")
        expectEqual(renamed("[1]", "Bill"), "[1]")
        for title in ["Pet", "Ünïcødé 😀", "line\nbreak"] {
            expectEqual(SchemaDocument(renamed(fixture(6), title)).title, title)
            expectEqual(SchemaDocument(renamed(fixture(6), title)).fields.map(\.name), SchemaDocument(fixture(6)).fields.map(\.name))
        }
    },
])
