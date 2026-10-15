import Canvas
import CanvasTesting
import Foundation
import LanguageModels
import ShippedTesting
import TestKit

@MainActor let shippedSchemaTests = Suite("Shipped schemas", [
    // What an agent (and, one day, validation) is told a sticky note is: pinned, like the report.
    test("the sticky note's schema") {
        let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
        let schema = try require(registry.schema(for: "sticky-note"))
        expectEqual(String(decoding: schema.data, as: UTF8.self), stickyNoteSchema)
    },
    test("an arrow's ends are one of two objects, and both are required") {
        let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
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
        let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
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
        let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
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

private let stickyNoteSchema = #"""
{
  "$defs" : {
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
    },
    "mentions.text" : {
      "contentMediaType" : "text/x-canvas-mentions",
      "description" : "Text that may mention shapes. A mention is @[name](shape:ID): ID is the id of a shape in the same file (a UUID, any case), and name is what it was called when the text was written; the app shows the shape's current name, and this one only if the shape isn't there. In a name, \\] stands for ] and \\\\ for \\. In the text, \\@[ is a literal @[, and any backslashes just before @[ are doubled: \\\\@[ is one backslash, then a mention. @[](shape:ID) mentions a shape without a name. Anything else is text as written.",
      "type" : "string"
    },
    "types.field-values" : {
      "description" : "The values of the fields of the shape's types, by field name.",
      "type" : "object"
    },
    "types.type-link" : {
      "contentMediaType" : "text/x-canvas-type",
      "description" : "A type it is, by the id of the shape that is the type, which may be gone.",
      "format" : "uuid",
      "type" : "string"
    }
  },
  "$id" : "tag:infinite-canvas,2026:kinds/sticky-note",
  "$schema" : "https://json-schema.org/draft/2020-12/schema",
  "additionalProperties" : false,
  "properties" : {
    "color" : {
      "contentMediaType" : "text/x-canvas-color",
      "description" : "The shape's color: a named color, or a value as #RRGGBB.",
      "examples" : [
        "blue",
        "#4465E9"
      ],
      "type" : "string",
      "x-canvas-owner" : "colors"
    },
    "fieldValues" : {
      "$ref" : "#/$defs/types.field-values",
      "description" : "The values of the fields of the shape's types, by field name, as JSON. A value that is empty is not kept.",
      "x-canvas-owner" : "types"
    },
    "frame" : {
      "$ref" : "#/$defs/core.rect"
    },
    "is" : {
      "description" : "The types the shape is, by the ids of the shapes that are them, in the order they were added: a later one wins where two say the same.",
      "items" : {
        "$ref" : "#/$defs/types.type-link"
      },
      "type" : "array",
      "uniqueItems" : true,
      "x-canvas-owner" : "types"
    },
    "locked" : {
      "type" : "boolean",
      "x-canvas-owner" : "locking"
    },
    "public" : {
      "type" : "boolean",
      "x-canvas-owner" : "publishing"
    },
    "relationship" : {
      "description" : "True on a type that says what an arrow between two notes holds and which types it runs from and to: a relationship type. Inert on a shape with no schema.",
      "type" : "boolean",
      "x-canvas-owner" : "types"
    },
    "schema" : {
      "contentMediaType" : "application/schema+json",
      "description" : "A JSON Schema, as text, which makes the shape a type named by its title: its properties in the order written, kept as typed while it isn't JSON. A \"$ref\" to \"urn:uuid:\" and another type's id refers to that type.",
      "type" : "string",
      "x-canvas-owner" : "types"
    },
    "text" : {
      "$ref" : "#/$defs/mentions.text",
      "default" : "",
      "description" : "What the note says."
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
"""#
