import Canvas
import CanvasTesting
import Composition
import Foundation
import TestKit

@MainActor let shippedSchemaTests = Suite("Shipped schemas", [
    // What an agent (and, one day, validation) is told a sticky note is: pinned, like the report.
    test("the sticky note's schema") {
        let registry = try ShippedPlugins.registry()
        let schema = try require(registry.schema(for: "sticky-note"))
        expectEqual(String(decoding: schema.data, as: UTF8.self), stickyNoteSchema)
    },
    test("a task card's schema: titled statuses, an optional due date, a bounded estimate, and its color's default") {
        let registry = try ShippedPlugins.registry()
        let json = try require(registry.schema(for: "task-card")).json
        let properties = try require(json["properties"]?.objectValue)
        expectEqual(properties["status"]?["oneOf"], [["const": "todo", "title": "To Do"], ["const": "doing", "title": "In Progress"],
                                                     ["const": "blocked", "title": "Blocked"], ["const": "done", "title": "Done"]])
        expectEqual(properties["priority"]?["oneOf"]?.arrayValue?.compactMap { $0["title"]?.stringValue }, ["Low", "Medium", "High"])
        expectEqual(properties["due"], ["type": "string", "format": "date-time"])
        expectEqual(properties["estimate"]?["minimum"], 0)
        expectEqual(properties["color"]?["default"], ["red": 0.2, "green": 0.48, "blue": 0.96])
        expectEqual(json["required"], ["frame"])
    },
    test("an arrow's ends are one of two objects, and both are required") {
        let registry = try ShippedPlugins.registry()
        let json = try require(registry.schema(for: "arrow")).json
        expectEqual(json["properties"]?["start"], ["$ref": "#/$defs/arrows.terminal"])
        expectEqual(json["required"], ["start", "end"])
        let terminal = try require(json["$defs"]?["arrows.terminal"]?["oneOf"]?.arrayValue)
        expectEqual(terminal.map { $0["required"] }, [["free"], ["bound"]])
        expectEqual(terminal[1]["properties"]?["bound"]?["properties"]?["shapeID"], ["$ref": "#/$defs/core.shape-id"])
    },
    // What checking a shape reads is what a board writes of it (the encoder that makes it isn't
    // the board's), and every shipped kind's fixture holds up against its kind's schema.
    test("every shipped kind's fixture holds up against its schema, and its properties as one object are what the board writes") {
        let registry = try ShippedPlugins.registry()
        let codec = BoardCodec(registry: registry)
        for kind in registry.kinds {
            let version = try require(codec.version(of: kind))
            let data = try Data(contentsOf: URL(fileURLWithPath: "Tests/CompositionTests/Fixtures/kinds/\(kind.rawValue).v\(version).json"))
            let record = try codec.decodeRecord(props: data, kind: kind, version: version)
            expectEqual(registry.schemaViolations(of: record), [], "\(kind)")
            var json = try require(record.propertiesJSON)
            for key in registry.properties(for: kind) { json[key.rawValue] = nil }
            expectEqual(json, try JSONDecoder().decode(JSONValue.self, from: data).objectValue, "\(kind)")
        }
    },
    // Each kind's fixture is how boards write it: every key it writes is a property of its schema,
    // and every property the schema requires is there.
    test("every shipped kind's schema describes what its fixture holds, and every $ref in it resolves") {
        let registry = try ShippedPlugins.registry()
        let codec = BoardCodec(registry: registry)
        for kind in registry.kinds {
            let json = try require(registry.schema(for: kind)).json
            let version = try require(codec.version(of: kind))
            let fixture = try Data(contentsOf: URL(fileURLWithPath: "Tests/CompositionTests/Fixtures/kinds/\(kind.rawValue).v\(version).json"))
            let written = try require(try JSONDecoder().decode(JSONValue.self, from: fixture).objectValue)
            let properties = Set(try require(json["properties"]?.objectValue).keys)
            let required = Set((json["required"]?.arrayValue ?? []).compactMap(\.stringValue))
            expect(Set(written.keys).isSubset(of: properties), "\(kind) writes \(Set(written.keys).subtracting(properties))")
            expect(required.isSubset(of: written.keys), "\(kind) requires \(required.subtracting(written.keys))")
            expectEqual(danglingReferences(in: json), [], "\(kind)")
        }
    },
])

private let stickyNoteSchema = """
{
  "$defs" : {
    "checklists.item" : {
      "additionalProperties" : false,
      "properties" : {
        "id" : {
          "format" : "uuid",
          "type" : "string"
        },
        "isDone" : {
          "default" : false,
          "type" : "boolean"
        },
        "text" : {
          "default" : "",
          "type" : "string"
        }
      },
      "required" : [
        "id"
      ],
      "title" : "Checklist item",
      "type" : "object"
    },
    "core.point" : {
      "description" : "[x, y]",
      "items" : false,
      "minItems" : 2,
      "prefixItems" : [
        {
          "type" : "number"
        },
        {
          "type" : "number"
        }
      ],
      "type" : "array"
    },
    "core.rect" : {
      "description" : "[[x, y], [width, height]], in world units",
      "items" : false,
      "minItems" : 2,
      "prefixItems" : [
        {
          "$ref" : "#/$defs/core.point"
        },
        {
          "$ref" : "#/$defs/core.size"
        }
      ],
      "type" : "array"
    },
    "core.size" : {
      "description" : "[width, height]",
      "items" : false,
      "minItems" : 2,
      "prefixItems" : [
        {
          "type" : "number"
        },
        {
          "type" : "number"
        }
      ],
      "type" : "array"
    }
  },
  "$id" : "tag:infinite-canvas,2026:kinds/sticky-note",
  "$schema" : "https://json-schema.org/draft/2020-12/schema",
  "additionalProperties" : false,
  "properties" : {
    "checklist" : {
      "default" : [

      ],
      "items" : {
        "$ref" : "#/$defs/checklists.item"
      },
      "type" : "array",
      "x-canvas-owner" : "checklists"
    },
    "frame" : {
      "$ref" : "#/$defs/core.rect"
    },
    "locked" : {
      "type" : "boolean",
      "x-canvas-owner" : "locking"
    },
    "text" : {
      "default" : "",
      "description" : "What the note says.",
      "type" : "string"
    },
    "title" : {
      "description" : "What the shape is called.",
      "maxLength" : 80,
      "minLength" : 1,
      "type" : "string",
      "x-canvas-owner" : "titles"
    }
  },
  "required" : [
    "frame"
  ],
  "title" : "Sticky note",
  "type" : "object"
}
"""
