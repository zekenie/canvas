import Adornments
import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import DetailPanel
import Foundation
import Keyboard
import Ports
import Schemas
import Selection
import TableOfContents
import TestKit
import Titles
import Validation

/// The label of the card's row in the table of contents.
@MainActor func contentsLabel(of id: ShapeID, in editor: CanvasEditor) throws -> ContentsLabel? {
    try require(try require(editor.tableOfContents).entries.first { $0.id == id }).label
}

@MainActor let pluginTests = Suite("Schemas plugin", [
    test("S and a press place an empty schema card, 240 × 67, selected, in Select") {
        let h = try EditorHarness(plugins: schemaPlugins())
        expect(h.key("s"))
        h.press(at: CGPoint(x: 300, y: 300)); h.release()
        let record = try require(h.editor.document.shapes.first)
        expectEqual(record.box, CGRect(x: 180, y: 266.5, width: 240, height: 67))
        expectEqual(record.typed(as: SchemaCard.self)?.props, SchemaCard(frame: CGRect(x: 180, y: 266.5, width: 240, height: 67)))
        expectEqual(h.editor.selection, record.id)
        expectEqual(h.editor.currentToolID, .select)
        expectEqual(h.editor.issues(record.id), [], "an empty schema is a schema")
    },
    test("registers the kind and the Schema tool, with its key; its contributions") {
        let registry = try Registry(plugins: schemaPlugins())
        let tool = try require(registry.tools.first { $0.id == ToolID(placing: SchemaCard.kind) })
        expectEqual([tool.label, tool.systemImage], ["Schema", "curlybraces"])
        expectEqual(registry.shortcut(forTool: tool.id)?.chord, "s")
        expectEqual(registry.report.split(separator: "\n").first { $0.hasPrefix("schemas") }.map(String.init), """
        schemas            service SchemaSync · shape schema-card · tool schema-card · shortcut S → tool schema-card · \
        ValidationRules → schema-card · ShapeTitles → schema-card · ContentsTitles → schema-card · ContentsRows → schema-card · \
        ShapeDetails → schema-card · ports schema-link → schema-card · channel schema-link
        """)
    },
    test("needs validation, titles, the table of contents, the detail panel and ports installed") {
        let plugins = schemaPlugins()
        for (point, owner) in [("ValidationRules", PluginID.validation), ("ShapeTitles", .titles), ("ContentsTitles", .tableOfContents),
                               ("ShapeDetails", .detailPanel), ("ShapePorts", .ports)] {
            expectThrows(RegistryError.ownerNotInstalled(point: point, owner: owner, contributor: .schemas)) {
                _ = try Registry(plugins: plugins.filter { $0.id != owner })
            }
        }
    },
    test("its name is the schema's title, even half typed; blank is none, and draws as Untitled") {
        let editor = try schemaEditor()
        let order = editor.add(card(fixture(6)))
        let blank = editor.add(card(#"{"title": "  ", "properties": {}}"#))
        let invalid = editor.add(card(fixture(10)))
        expectEqual(editor.registry.title(of: try require(editor.document[order])), "Order")
        expectEqual(editor.registry.title(of: try require(editor.document[blank])), nil)
        expectEqual(editor.registry.title(of: try require(editor.document[invalid])), "Invoice")
        editor.transact { $0.update(order, as: SchemaCard.self) { $0.props.setTitle("Purchase") } }
        expectEqual(editor.registry.title(of: try require(editor.document[order])), "Purchase")
    },
    test("the card draws its name itself, so it shows no pill above it, as a subboard doesn't") {
        let editor = try schemaEditor()
        let order = editor.add(card(fixture(6)))
        expectEqual(editor.registry.title(of: try require(editor.document[order])), "Order")
        expectEqual(editor.adornmentFrames(of: order).map(\.adornment), [], "Titles places its pill only where the title shows one")
    },
    test("its row in the table of contents: the name or Untitled, curly braces, and how many top-level fields") {
        let editor = try schemaEditor()
        for text in [fixture(6), fixture(5), SchemaCard.starter, fixture(10), fixture(7)] { editor.add(card(text)) }
        let labels = try require(editor.tableOfContents).entries.map(\.label)
        expectEqual(labels.map { $0?.text }, ["Order", "Customer", "Untitled", "Invoice", "Organization"])
        expectEqual(labels.map { $0?.isPlaceholder }, [false, false, true, false, false])
        expectEqual(labels.map { $0?.systemImage }, Array(repeating: "curlybraces", count: 5))
        expectEqual(labels.map { $0?.badge }, ["6", "20", nil, nil, "4"])
    },
    test("rules: not JSON is an error at its line and column; a root that isn't an object is an error; required naming no property warns") {
        let editor = try schemaEditor()
        expectEqual(editor.issues(editor.add(card(fixture(6)))), [])
        expectEqual(editor.issues(editor.add(card(fixture(9)))), [], "then's required names a property of the root: fine")
        expectEqual(editor.issues(editor.add(card(fixture(10)))),
                    [.error("Invalid JSON: expected a property name at line 6, column 35.", field: "schema")])
        expectEqual(editor.issues(editor.add(card(""))), [.error("Invalid JSON: expected a value at line 1, column 1.", field: "schema")])
        expectEqual(editor.issues(editor.add(card("[1, 2]"))), [.error("A schema must be a JSON object.", field: "schema")])
        let missing = #"""
        { "properties": { "a": {}, "b": { "properties": { "c": {} }, "required": ["c", "d"] },
                          "list": { "type": "array", "items": { "properties": { "x": {} }, "required": ["y"] } } },
          "required": ["a", "zip", "zip"],
          "$defs": { "money": { "properties": { "amount": {} }, "required": ["currency"] } },
          "allOf": [ { "required": ["a"] } ] }
        """#
        expectEqual(editor.issues(editor.add(card(missing))), [
            .warning("“zip” is required, but isn’t a property.", field: "schema"),
            .warning("“d” is required, but isn’t a property of b.", field: "schema"),
            .warning("“y” is required, but isn’t a property of list[].", field: "schema"),
            .warning("“currency” is required, but isn’t a property of $defs/money.", field: "schema"),
        ])
        // A pattern may be what's required: no warning where there are patterns.
        expectEqual(editor.issues(editor.add(card(#"{"properties": {}, "patternProperties": {"^x": {}}, "required": ["xy"]}"#))), [])
        let many = "{ \"properties\": {}, \"required\": [\((0..<500).map { "\"n\($0)\"" }.joined(separator: ","))] }"
        expectEqual(editor.issues(editor.add(card(many))).count, 20)
    },
    test("a type that isn't JSON Schema's warns, where it is; the seven, lists of them, and no type don't") {
        let editor = try schemaEditor()
        let text = #"""
        { "type": "objekt",
          "properties": { "birthYear": { "type": "ninteger" }, "ok": { "type": ["string", "null"] }, "none": {},
                          "tags": { "type": "array", "items": { "type": ["strin", "strin", "null"] } } },
          "$defs": { "money": { "type": "numbr" } } }
        """#
        expectEqual(editor.issues(editor.add(card(text))), [
            .warning("“objekt” isn’t a JSON Schema type.", field: "schema"),
            .warning("“ninteger” in birthYear isn’t a JSON Schema type.", field: "schema"),
            .warning("“strin” in tags[] isn’t a JSON Schema type.", field: "schema"),
            .warning("“numbr” in $defs/money isn’t a JSON Schema type.", field: "schema"),
        ])
        expectEqual(editor.issues(editor.add(card(fixture(6)))), [])
        let many = "{ \"properties\": { \((0..<500).map { "\"n\($0)\": { \"type\": \"t\($0)\" }" }.joined(separator: ",")) } }"
        expectEqual(editor.issues(editor.add(card(many))).count, 20, "however many")
    },
    test("while its text isn't a JSON object, the card shows its last that was: rows, name, row, title; the rules read the text") {
        let editor = try schemaEditor()
        let id = editor.add(card(fixture(6)))
        let broken = String(fixture(6).dropLast(3))
        @MainActor func layout(_ id: ShapeID) throws -> SchemaCardLayout { SchemaCardLayout(try require(editor.document[id]?.typed(as: SchemaCard.self))) }
        @MainActor func title() throws -> String? { editor.registry.title(of: try require(editor.document[id])) }
        for text in [broken, broken + "]", "[1]", "\"x\""] {
            editor.transact { $0.update(id, as: SchemaCard.self) { $0.props.setSchema(text) } }
            let shown = try layout(id)
            expectEqual(shown.state, .fields, text)
            expectEqual(shown.stateLine, nil, "nothing said on the card: Validation's outline says it")
            expectEqual(shown.title, "Order", text)
            expectEqual(try title(), "Order", text)
            let row = try contentsLabel(of: id, in: editor)
            expectEqual([row?.text, row?.badge], ["Order", "6"], text)
            expectEqual(editor.issues(id).map(\.severity), [.error], "the rules read the text itself")
            if text == broken {
                expectEqual(shown.rows.map(\.text), rows(fixture(6)), "the rows as they were: a text that isn't JSON leaves the frame")
            }
        }
        expectEqual(editor.schemaCard(id)?.frame.height, 177, "JSON that isn't an object leaves the frame too: it still fits the rows shown")
        expectEqual(try layout(id).rows.map(\.text), rows(fixture(6)), "every row, none of them cut to a count")
        expectEqual(try layout(id).more, 0)
        editor.transact { $0.update(id, as: SchemaCard.self) { $0.props.setSchema(fixture(2)) } }
        expectEqual(try layout(id).title, "Contact", "a good text shows itself")
        expectEqual(try layout(id).rows.count, 3)
        editor.transact { $0.update(id, as: SchemaCard.self) { $0.props.setSchema("[1]") } }
        expectEqual([try layout(id).rows.count, try layout(id).more], [3, 0], "three rows still, never a lone \"+3 more\"")
        expectEqual(editor.schemaCard(id)?.frame.height, 111)
        // Deleted, what it showed goes with it: read again, the text is all there is to show.
        editor.transact { $0.update(id, as: SchemaCard.self) { $0.props.setSchema(broken) } }
        expectEqual(try layout(id).title, "Contact")
        let record = try require(editor.document[id]?.typed(as: SchemaCard.self))
        editor.transact { $0.delete([id]) }
        expectEqual(SchemaCardLayout(record).stateLine, "Invalid JSON", "forgotten with the card")
        // A card that was never a JSON object (a board opened so) says why it has no rows.
        let opened = editor.add(card(broken))
        let never = SchemaCardLayout(try require(editor.document[opened]?.typed(as: SchemaCard.self)))
        expectEqual(never.stateLine, "Invalid JSON")
        expectEqual(never.title, "Order", "named as far as the text says")
        expectEqual(try require(editor.tableOfContents?.entries.first { $0.id == opened }).label?.badge, nil)
    },
    test("a board read again shows what its file holds: a card saved broken and fixed since, reverted, has no rows, not the fix's") {
        let editor = try schemaEditor()
        let broken = String(fixture(2).dropLast(3))
        let id = editor.add(card(broken))
        let saved = editor.document
        editor.transact { $0.update(id, as: SchemaCard.self) { $0.props.setSchema(fixture(2)) } }
        @MainActor func layout() throws -> SchemaCardLayout { SchemaCardLayout(try require(editor.document[id]?.typed(as: SchemaCard.self))) }
        expectEqual(try layout().rows.count, 3)
        expectEqual(try contentsLabel(of: id, in: editor)?.badge, "3")
        editor.replaceDocument(with: saved)
        expectEqual(try layout().stateLine, "Invalid JSON", "the fix is in no version of the file")
        expectEqual(try layout().rows.count, 0)
        expectEqual(try contentsLabel(of: id, in: editor)?.badge, nil)
    },
    test("an edit to the schema is checked again: fixing the JSON clears its error") {
        let editor = try schemaEditor()
        let id = editor.add(card(fixture(10)))
        expectEqual(editor.issues(id).count, 1)
        editor.transact { $0.update(id, as: SchemaCard.self) { $0.props.setSchema(fixture(6)) } }
        expectEqual(editor.issues(id), [])
        expectEqual(editor.schemaCard(id)?.frame.height, 177)
    },
    test("props round-trip through JSON, the schema's text exactly as typed") {
        let props = SchemaCard(frame: CGRect(x: 1, y: 2, width: 300, height: 177), schema: fixture(10) + "\n\t// é", prompt: "an order")
        expectEqual(try JSONDecoder().decode(SchemaCard.self, from: JSONEncoder().encode(props)), props)
        expectEqual(try JSONDecoder().decode(SchemaCard.self, from: Data(#"{"frame": [[0, 0], [240, 89]]}"#.utf8)).schema, SchemaCard.starter)
    },
    test("the kind's schema: its text is JSON Schema by media type, and no title of its own (the name is the schema's)") {
        let registry = try Registry(plugins: schemaPlugins())
        let json = try require(registry.schema(for: SchemaCard.kind)).json
        expectEqual(json["properties"]?["schema"]?["contentMediaType"], .string("application/schema+json"))
        expectEqual(json["properties"]?["prompt"]?["type"], .string("string"))
        expectEqual(json["required"], .array([.string("frame")]))
        expect(json["properties"]?["title"] == nil, "a derived title: not the property Titles keeps for a named shape")
        let card = AnyShapeRecord(ShapeRecord(SchemaCard(frame: CGRect(x: 0, y: 0, width: 240, height: 177), schema: fixture(6))))
        expectEqual(registry.schemaViolations(of: card), [], "a card keeps to its kind's schema")
    },
])
