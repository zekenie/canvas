import Canvas
import CoreGraphics
import Foundation
import Schemas
import TestKit

/// How tall a card is with `lines` lines of description: 19 points a line, half a point spare
/// rounded up, and 16 above and below (a note's measure); one line at the least.
func cardHeight(lines: Int) -> CGFloat { CGFloat(max(lines, 1)) * 19 + 1 + 32 }

@MainActor let cardTests = Suite("Schema card", [
    test("a new card: the starter schema, no description, 240 × 52, a line's height") {
        expectEqual(SchemaCard.defaultSize, CGSize(width: 240, height: 52))
        expectEqual(SchemaCardMetrics.emptyHeight, cardHeight(lines: 1))
        expectEqual(SchemaCard().schema, SchemaCard.starter)
        expectEqual(SchemaCard().prompt, "")
        expectEqual([SchemaDocument(SchemaCard.starter).title], [nil])
        expectEqual(SchemaCard.untitled, "Untitled")
    },
    test("setPrompt fits the height to the description at the card's width, in the same write, keeping the corner and width; never under a line") {
        var card = SchemaCard(frame: CGRect(x: 10, y: 20, width: 240, height: 400))
        card.setPrompt("a pet in my household")
        expectEqual(card.frame, CGRect(x: 10, y: 20, width: 240, height: cardHeight(lines: 1)))
        expectEqual(card.prompt, "a pet in my household")
        card.setPrompt("a pet\nits name\nits species")
        expectEqual(card.frame.height, cardHeight(lines: 3))
        card.setPrompt("a pet\nits name\nits species\n")
        expectEqual(card.frame.height, cardHeight(lines: 4), "a last Return: room for the caret's line")
        card.setPrompt("")
        expectEqual(card.frame.height, cardHeight(lines: 1), "empty: a line's height")
        let long = String(repeating: "a pet with a name ", count: 20)
        card.setPrompt(long)
        let wrapped = card.frame.height
        expect(wrapped > cardHeight(lines: 5), "wrapped at its width: \(wrapped)")
        card.frame.size.width = 480
        card.setPrompt(long)
        expect(card.frame.height < wrapped, "wider, fewer lines")
        expectEqual(card.frame.origin, CGPoint(x: 10, y: 20))
        var narrow = SchemaCard(frame: CGRect(x: 0, y: 0, width: 20, height: 70))
        narrow.setPrompt("no room")
        expectEqual(narrow.frame.height, 70, "too narrow for text: its height as it was")
    },
    test("the schema is its text alone: writing it or renaming it leaves the card's size") {
        var card = SchemaCard(frame: CGRect(x: 0, y: 0, width: 240, height: 52))
        card.schema = fixture(6)
        card.setTitle("Purchase")
        expectEqual(card.frame, CGRect(x: 0, y: 0, width: 240, height: 52))
        expectEqual(SchemaDocument(card.schema).title, "Purchase")
    },
    test("a card made or given a description from properties (the command line's draw) is as tall as its description; a board read keeps what it saved") {
        let registry = try Registry(plugins: schemaPlugins())
        let long = (1...6).map { "line \($0)" }.joined(separator: "\n")
        let made = try registry.shape(SchemaCard.kind, properties: ["frame": [[40, 60], [240, 300]], "prompt": .string(long)])
        expectEqual(made.box, CGRect(x: 40, y: 60, width: 240, height: cardHeight(lines: 6)))
        let short = try registry.shape(made, setting: ["prompt": "a pet"])
        expectEqual(short.box?.height, cardHeight(lines: 1))
        let schemaOnly = try registry.shape(SchemaCard.kind, properties: ["frame": [[0, 0], [240, 300]], "schema": .string(fixture(6))])
        expectEqual(schemaOnly.box?.height, cardHeight(lines: 1), "no description: a line's height, whatever its schema")
        let codec = BoardCodec(registry: registry)
        let tall = ShapeRecord(SchemaCard(frame: CGRect(x: 0, y: 0, width: 240, height: 300), prompt: "a pet"))
        let read = try codec.decode(codec.encode(CanvasDocument(shapes: [AnyShapeRecord(tall)]))).document
        expectEqual(read.shapes.first?.box?.height, 300, "read as saved: nothing a person did")
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
    test("each title as the root says it, even half typed; blank is none") {
        expectEqual(SchemaDocument(fixture(1)).title, nil)
        expectEqual(SchemaDocument(fixture(6)).title, "Order")
        expectEqual(SchemaDocument(fixture(10)).title, "Invoice", "as far as the text says, before its error")
        expectEqual(SchemaDocument(#"{"title": "  "}"#).title, nil)
    },
])
