import Adornments
import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Connections
import DetailPanel
import Foundation
import Keyboard
import Mentions
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
    test("registers the kind and the Schema tool, with its key; its contributions") {
        let registry = try Registry(plugins: schemaPlugins())
        let tool = try require(registry.tools.first { $0.id == ToolID(placing: SchemaCard.kind) })
        expectEqual([tool.label, tool.systemImage], ["Schema", "curlybraces"])
        expectEqual(registry.shortcut(forTool: tool.id)?.chord, "s")
        expectEqual(registry.report.split(separator: "\n").first { $0.hasPrefix("schemas") }.map(String.init), """
        schemas            service SchemaSync · overlay SchemaHighlightFrames · ShapePopovers · shape schema-card v1 · tool schema-card · \
        shortcut S → tool schema-card · ValidationRules → schema-card · ShapeTitles → schema-card · ContentsTitles → schema-card · \
        ContentsRows → schema-card · ShapeDetails → schema-card · ports schema-link → schema-card · mention text → schema-card · \
        mentionable → schema-card · ShapeDetails → schema-card · channel schema-link · edge type schema-link
        """)
    },
    test("needs validation, titles, the table of contents, the detail panel, ports and mentions installed") {
        let plugins = schemaPlugins()
        for (point, owner) in [("ValidationRules", PluginID.validation), ("ShapeTitles", .titles), ("ContentsTitles", .tableOfContents),
                               ("ShapeDetails", .detailPanel), ("ShapePorts", .ports), ("MentionTexts", .mentions)] {
            expectThrows(RegistryError.ownerNotInstalled(point: point, owner: owner, contributor: .schemas)) {
                _ = try Registry(plugins: plugins.filter { $0.id != owner })
            }
        }
    },
    test("its name is the schema's title, even half typed; blank is none") {
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
    test("its name is its title's pill, above its top-left corner, after the kind's {}; an untitled card has none, as an untitled note hasn't") {
        let editor = try schemaEditor()
        let order = editor.add(card(fixture(6)))
        let frames = editor.adornmentFrames(of: order)
        expectEqual(frames.map(\.adornment), [.of(TitlePill.self)])
        expectEqual(frames.first?.label, AdornmentLabel("Order", systemImage: "curlybraces"), "the kind's symbol, as its tool and its row have it")
        expectEqual(frames.first.map { [$0.rect.minX, $0.rect.minY, $0.rect.height] }, [40, 13, 18], "the row above the card")
        let untitled = editor.add(card(SchemaCard.starter, at: CGPoint(x: 400, y: 40)))
        expectEqual(editor.adornmentFrames(of: untitled).map(\.adornment), [])
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
    test("while its text isn't a JSON object, its name and its row are its last that was; the rules read the text; the card's size stays") {
        let editor = try schemaEditor()
        let id = editor.add(card(fixture(6), prompt: "an order"))
        let broken = String(fixture(6).dropLast(3))
        @MainActor func title() throws -> String? { editor.registry.title(of: try require(editor.document[id])) }
        for text in [broken, broken + "]", "[1]", "\"x\""] {
            editor.transact { $0.update(id, as: SchemaCard.self) { $0.props.schema.text = text } }
            expectEqual(try title(), "Order", text)
            let row = try contentsLabel(of: id, in: editor)
            expectEqual([row?.text, row?.badge], ["Order", "6"], text)
            expectEqual(editor.issues(id).map(\.severity), [.error], "the rules read the text itself")
            expectEqual(editor.schemaCard(id)?.frame.height, cardHeight(lines: 1), "its description's height, whatever the schema")
        }
        editor.transact { $0.update(id, as: SchemaCard.self) { $0.props.schema.text = fixture(2) } }
        expectEqual(try title(), "Contact", "a good text shows itself")
        expectEqual(try contentsLabel(of: id, in: editor)?.badge, "3")
        editor.transact { $0.update(id, as: SchemaCard.self) { $0.props.schema.text = "[1]" } }
        expectEqual(try contentsLabel(of: id, in: editor)?.badge, "3", "the three it showed last")
        // Deleted, what it showed goes with it: a card of its id, read again, shows only its text.
        editor.transact { $0.update(id, as: SchemaCard.self) { $0.props.schema.text = broken } }
        expectEqual(try title(), "Contact")
        editor.transact { $0.delete([id]) }
        let again = editor.add(card(broken), id: id)
        expectEqual(try require(editor.tableOfContents?.entries.first { $0.id == again }).label?.badge, nil, "forgotten with the card")
        // A card that was never a JSON object (a board opened so) has no count, and a name as far as its text says.
        let opened = editor.add(card(broken))
        expectEqual(editor.registry.title(of: try require(editor.document[opened])), "Order", "named as far as the text says")
        expectEqual(try require(editor.tableOfContents?.entries.first { $0.id == opened }).label?.badge, nil)
    },
    test("a board read again shows what its file holds: a card saved broken and fixed since, reverted, has no count, not the fix's") {
        let editor = try schemaEditor()
        let broken = String(fixture(2).dropLast(3))
        let id = editor.add(card(broken))
        let saved = editor.document
        editor.transact { $0.update(id, as: SchemaCard.self) { $0.props.schema.text = fixture(2) } }
        expectEqual(try contentsLabel(of: id, in: editor)?.badge, "3")
        editor.replaceDocument(with: saved)
        expectEqual(try contentsLabel(of: id, in: editor)?.badge, nil, "the fix is in no version of the file")
    },
    test("an edit to the schema is checked again: fixing the JSON clears its error") {
        let editor = try schemaEditor()
        let id = editor.add(card(fixture(10)))
        expectEqual(editor.issues(id).count, 1)
        editor.transact { $0.update(id, as: SchemaCard.self) { $0.props.schema.text = fixture(6) } }
        expectEqual(editor.issues(id), [])
    },
    test("props round-trip through JSON, the schema's text exactly as typed") {
        let props = SchemaCard(frame: CGRect(x: 1, y: 2, width: 300, height: 177), schema: SchemaText(fixture(10) + "\n\t// é"), prompt: "an order")
        expectEqual(try JSONDecoder().decode(SchemaCard.self, from: JSONEncoder().encode(props)), props)
        expectEqual(try JSONDecoder().decode(SchemaCard.self, from: Data(#"{"frame": [[0, 0], [240, 89]]}"#.utf8)).schema.text, SchemaCard.starter)
    },
    test("the kind's schema: its text is JSON Schema by media type, and no title of its own (the name is the schema's)") {
        let registry = try Registry(plugins: schemaPlugins())
        let json = try require(registry.schema(for: SchemaCard.kind)).json
        expectEqual(json["properties"]?["schema"]?["contentMediaType"], .string("application/schema+json"))
        // Its description is mention text, of schema cards alone.
        expectEqual(json["properties"]?["prompt"]?["$ref"], .string("#/$defs/mentions.text"))
        expectEqual(json["properties"]?["prompt"]?["x-canvas-mentions"], ["kinds": ["schema-card"]])
        expectEqual(json["properties"]?["schema"]?["type"], .string("string"))
        expectEqual(json["required"], .array([.string("frame")]))
        expect(json["properties"]?["title"] == nil, "a derived title: not the property Titles keeps for a named shape")
        let card = AnyShapeRecord(ShapeRecord(SchemaCard(frame: CGRect(x: 0, y: 0, width: 240, height: 177), schema: SchemaText(fixture(6)))))
        expectEqual(registry.schemaViolations(of: card), [], "a card keeps to its kind's schema")
    },
])
