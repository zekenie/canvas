// Modified from JSON Schema's 2020-12 meta-schemas (https://json-schema.org/draft/2020-12/schema and
// the vocabularies' under /draft/2020-12/meta/; BSD-3-Clause), flattened as vscode-json-languageservice
// flattens them (src/services/schemas/draft-2020-12-flat.ts; MIT). THIRD_PARTY_NOTICES.md.

/// JSON Schema 2020-12's meta-schema, the schema a schema is written against, as one document: all
/// that completing a schema as it's typed knows of JSON Schema, kept as data, so the code that
/// completes knows none of it. The official meta-schema and its seven vocabularies' are flattened
/// into one, their `$dynamicRef`s plain `$ref`s, as VS Code's JSON language service flattens them.
/// It's standard JSON Schema with the official rules and defaults, so it checks a schema as the
/// official one does (the core's `SchemaValidator` compiles it). What it adds is for completion:
/// - `properties` lists every keyword of every vocabulary in the order completion offers them: the
///   most used first, the identifiers (`$id`, `$anchor`, `$schema`, …) last, then the four 2020-12
///   keeps only so no one gives them another meaning, `"deprecated": true` as it marks them, which
///   completion never offers.
/// - Each keyword's `description` is a fragment that a person who doesn't know JSON Schema by heart
///   reads beside it ("Fewest characters").
/// - The values a keyword can be given by name are `oneOf` or `anyOf` branches of `{"const": …,
///   "description": …}`, in the order they're offered: the type names, the formats (first the six the
///   model is taught, `SchemaPrompts`) and the content encodings (those validation §8.3 points to,
///   RFC 4648's and quoted-printable; none for the identity encoding, which is no `contentEncoding`),
///   the last two with a branch that lets any other string through. Media types (a link to a note, `FieldKind.pointerMediaType`, first) and `$schema`'s URI
///   are `examples`.
/// - One annotation isn't JSON Schema's: `"x-canvas-when": {"type": ["string"]}` on a keyword says
///   it matters only in an object whose member `type` is, or lists, one of those (`minLength` on a
///   string). A keyword without one matters whatever the type.
public enum MetaSchema {
    /// The document, as JSON.
    public static let text = ##"""
    {
      "$schema": "https://json-schema.org/draft/2020-12/schema",
      "title": "JSON Schema",
      "type": ["object", "boolean"],
      "properties": {
        "title": { "description": "Short name for people", "type": "string" },
        "description": { "description": "What it's for, in a sentence or two", "type": "string" },
        "type": {
          "description": "Kind of value: string, object, array…",
          "anyOf": [
            { "$ref": "#/$defs/simpleTypes" },
            { "type": "array", "items": { "$ref": "#/$defs/simpleTypes" }, "minItems": 1, "uniqueItems": true }
          ]
        },
        "properties": {
          "description": "Fields, each with its schema",
          "x-canvas-when": { "type": ["object"] },
          "type": "object",
          "additionalProperties": { "$ref": "#" },
          "default": {}
        },
        "required": {
          "description": "Fields that must be present",
          "x-canvas-when": { "type": ["object"] },
          "$ref": "#/$defs/stringArray"
        },
        "items": {
          "description": "Schema for each item, after any prefixItems",
          "x-canvas-when": { "type": ["array"] },
          "$ref": "#"
        },
        "enum": { "description": "The only values allowed", "type": "array", "items": true },
        "const": { "description": "The one value allowed" },
        "default": { "description": "Value to use when none is given" },
        "format": {
          "description": "Kind of string: date, email, uri…",
          "x-canvas-when": { "type": ["string"] },
          "type": "string",
          "anyOf": [
            { "const": "date-time", "description": "Date and time, 2025-01-31T09:30:00Z" },
            { "const": "date", "description": "Calendar date, 2025-01-31" },
            { "const": "time", "description": "Time of day, 09:30:00Z" },
            { "const": "email", "description": "Email address" },
            { "const": "uri", "description": "Absolute URI, https://example.com" },
            { "const": "uuid", "description": "Universally unique identifier" },
            { "const": "duration", "description": "Length of time, P3DT4H" },
            { "const": "idn-email", "description": "Email address, international" },
            { "const": "hostname", "description": "Host name, example.com" },
            { "const": "idn-hostname", "description": "Host name, international" },
            { "const": "ipv4", "description": "IPv4 address, 192.0.2.1" },
            { "const": "ipv6", "description": "IPv6 address, 2001:db8::1" },
            { "const": "uri-reference", "description": "URI, or a path relative to one" },
            { "const": "iri", "description": "Absolute URI, Unicode allowed" },
            { "const": "iri-reference", "description": "URI or relative path, Unicode allowed" },
            { "const": "uri-template", "description": "URI template, /users/{id}" },
            { "const": "json-pointer", "description": "JSON Pointer, /items/0/name" },
            { "const": "relative-json-pointer", "description": "Relative JSON Pointer, 1/name" },
            { "const": "regex", "description": "Regular expression" },
            { "type": "string" }
          ]
        },
        "minimum": {
          "description": "Smallest number allowed",
          "x-canvas-when": { "type": ["number", "integer"] },
          "type": "number"
        },
        "maximum": {
          "description": "Largest number allowed",
          "x-canvas-when": { "type": ["number", "integer"] },
          "type": "number"
        },
        "exclusiveMinimum": {
          "description": "Number must be greater than this",
          "x-canvas-when": { "type": ["number", "integer"] },
          "type": "number"
        },
        "exclusiveMaximum": {
          "description": "Number must be less than this",
          "x-canvas-when": { "type": ["number", "integer"] },
          "type": "number"
        },
        "multipleOf": {
          "description": "Number must be a multiple of this",
          "x-canvas-when": { "type": ["number", "integer"] },
          "type": "number",
          "exclusiveMinimum": 0
        },
        "minLength": {
          "description": "Fewest characters",
          "x-canvas-when": { "type": ["string"] },
          "$ref": "#/$defs/nonNegativeIntegerDefault0"
        },
        "maxLength": {
          "description": "Most characters",
          "x-canvas-when": { "type": ["string"] },
          "$ref": "#/$defs/nonNegativeInteger"
        },
        "pattern": {
          "description": "Regular expression found anywhere in it",
          "x-canvas-when": { "type": ["string"] },
          "type": "string",
          "format": "regex"
        },
        "minItems": {
          "description": "Fewest items",
          "x-canvas-when": { "type": ["array"] },
          "$ref": "#/$defs/nonNegativeIntegerDefault0"
        },
        "maxItems": {
          "description": "Most items",
          "x-canvas-when": { "type": ["array"] },
          "$ref": "#/$defs/nonNegativeInteger"
        },
        "uniqueItems": {
          "description": "No two items may be equal",
          "x-canvas-when": { "type": ["array"] },
          "type": "boolean",
          "default": false
        },
        "additionalProperties": {
          "description": "Schema for unlisted fields; false forbids them",
          "x-canvas-when": { "type": ["object"] },
          "$ref": "#"
        },
        "$defs": {
          "description": "Schemas to reuse with $ref",
          "type": "object",
          "additionalProperties": { "$ref": "#" }
        },
        "$ref": {
          "description": "Reuse a schema, e.g. #/$defs/name",
          "type": "string",
          "format": "uri-reference"
        },
        "anyOf": { "description": "Must match at least one", "$ref": "#/$defs/schemaArray" },
        "oneOf": { "description": "Must match exactly one", "$ref": "#/$defs/schemaArray" },
        "allOf": { "description": "Must match all of these", "$ref": "#/$defs/schemaArray" },
        "not": { "description": "Must not match this", "$ref": "#" },
        "if": { "description": "Condition that picks then or else", "$ref": "#" },
        "then": { "description": "Must match when if matches", "$ref": "#" },
        "else": { "description": "Must match when if doesn't", "$ref": "#" },
        "examples": { "description": "Sample values that fit", "type": "array", "items": true },
        "prefixItems": {
          "description": "Schemas for the first items, in order",
          "x-canvas-when": { "type": ["array"] },
          "$ref": "#/$defs/schemaArray"
        },
        "contains": {
          "description": "Schema some item must match",
          "x-canvas-when": { "type": ["array"] },
          "$ref": "#"
        },
        "minContains": {
          "description": "Fewest items matching contains",
          "x-canvas-when": { "type": ["array"] },
          "$ref": "#/$defs/nonNegativeInteger",
          "default": 1
        },
        "maxContains": {
          "description": "Most items matching contains",
          "x-canvas-when": { "type": ["array"] },
          "$ref": "#/$defs/nonNegativeInteger"
        },
        "patternProperties": {
          "description": "Schemas for fields named by a pattern",
          "x-canvas-when": { "type": ["object"] },
          "type": "object",
          "additionalProperties": { "$ref": "#" },
          "propertyNames": { "format": "regex" },
          "default": {}
        },
        "propertyNames": {
          "description": "Schema every field name must match",
          "x-canvas-when": { "type": ["object"] },
          "$ref": "#"
        },
        "minProperties": {
          "description": "Fewest fields",
          "x-canvas-when": { "type": ["object"] },
          "$ref": "#/$defs/nonNegativeIntegerDefault0"
        },
        "maxProperties": {
          "description": "Most fields",
          "x-canvas-when": { "type": ["object"] },
          "$ref": "#/$defs/nonNegativeInteger"
        },
        "dependentRequired": {
          "description": "Fields needed when another is present",
          "x-canvas-when": { "type": ["object"] },
          "type": "object",
          "additionalProperties": { "$ref": "#/$defs/stringArray" }
        },
        "dependentSchemas": {
          "description": "Schemas applied when a field is present",
          "x-canvas-when": { "type": ["object"] },
          "type": "object",
          "additionalProperties": { "$ref": "#" },
          "default": {}
        },
        "unevaluatedProperties": {
          "description": "Schema for fields no other keyword covers",
          "x-canvas-when": { "type": ["object"] },
          "$ref": "#"
        },
        "unevaluatedItems": {
          "description": "Schema for items no other keyword covers",
          "x-canvas-when": { "type": ["array"] },
          "$ref": "#"
        },
        "readOnly": { "description": "Can be read but not changed", "type": "boolean", "default": false },
        "writeOnly": { "description": "Can be sent but is never returned", "type": "boolean", "default": false },
        "deprecated": { "description": "Should no longer be used", "type": "boolean", "default": false },
        "$comment": { "description": "Note for maintainers, never shown to users", "type": "string" },
        "contentMediaType": {
          "description": "Media type of the string's contents",
          "x-canvas-when": { "type": ["string"] },
          "type": "string",
          "examples": ["\##(FieldKind.pointerMediaType)", "application/json", "text/plain", "text/html", "text/markdown", "text/csv", "application/xml",
                       "image/png", "image/jpeg", "application/pdf", "application/jwt"]
        },
        "contentEncoding": {
          "description": "How the string encodes binary data",
          "x-canvas-when": { "type": ["string"] },
          "type": "string",
          "anyOf": [
            { "const": "base64", "description": "Letters, digits, + and /" },
            { "const": "base16", "description": "Hexadecimal" },
            { "const": "base32", "description": "Letters A–Z and digits 2–7" },
            { "const": "quoted-printable", "description": "Mostly ASCII, other bytes as =XX" },
            { "type": "string" }
          ]
        },
        "contentSchema": {
          "description": "Schema for the string's decoded contents",
          "x-canvas-when": { "type": ["string"] },
          "$ref": "#"
        },
        "$id": {
          "description": "URI that identifies this schema",
          "$comment": "Non-empty fragments not allowed.",
          "type": "string",
          "format": "uri-reference",
          "pattern": "^[^#]*#?$"
        },
        "$anchor": {
          "description": "Name to refer to it by, as #name",
          "type": "string",
          "pattern": "^[A-Za-z_][-A-Za-z0-9._]*$"
        },
        "$dynamicRef": { "description": "Reference resolved at runtime", "type": "string", "format": "uri-reference" },
        "$dynamicAnchor": {
          "description": "Name a $dynamicRef can resolve to",
          "type": "string",
          "pattern": "^[A-Za-z_][-A-Za-z0-9._]*$"
        },
        "$schema": {
          "description": "JSON Schema version, as a URI",
          "type": "string",
          "format": "uri",
          "examples": ["https://json-schema.org/draft/2020-12/schema"]
        },
        "$vocabulary": {
          "description": "Vocabularies a meta-schema uses",
          "type": "object",
          "propertyNames": { "type": "string", "format": "uri" },
          "additionalProperties": { "type": "boolean" }
        },
        "definitions": {
          "description": "Old name for $defs",
          "$comment": "\"definitions\" has been replaced by \"$defs\".",
          "type": "object",
          "additionalProperties": { "$ref": "#" },
          "deprecated": true,
          "default": {}
        },
        "dependencies": {
          "description": "Old form of the dependent* keywords",
          "$comment": "\"dependencies\" has been split and replaced by \"dependentSchemas\" and \"dependentRequired\" in order to serve their differing semantics.",
          "type": "object",
          "additionalProperties": {
            "anyOf": [{ "$ref": "#" }, { "$ref": "#/$defs/stringArray" }]
          },
          "deprecated": true,
          "default": {}
        },
        "$recursiveAnchor": {
          "description": "Old form of $dynamicAnchor",
          "$comment": "\"$recursiveAnchor\" has been replaced by \"$dynamicAnchor\".",
          "type": "string",
          "pattern": "^[A-Za-z_][-A-Za-z0-9._]*$",
          "deprecated": true
        },
        "$recursiveRef": {
          "description": "Old form of $dynamicRef",
          "$comment": "\"$recursiveRef\" has been replaced by \"$dynamicRef\".",
          "type": "string",
          "format": "uri-reference",
          "deprecated": true
        }
      },
      "$defs": {
        "schemaArray": { "type": "array", "minItems": 1, "items": { "$ref": "#" } },
        "nonNegativeInteger": { "type": "integer", "minimum": 0 },
        "nonNegativeIntegerDefault0": { "$ref": "#/$defs/nonNegativeInteger", "default": 0 },
        "simpleTypes": {
          "oneOf": [
            { "const": "string", "description": "Text" },
            { "const": "number", "description": "Any number" },
            { "const": "integer", "description": "Whole number" },
            { "const": "boolean", "description": "True or false" },
            { "const": "object", "description": "Group of named fields" },
            { "const": "array", "description": "List of values" },
            { "const": "null", "description": "The value null" }
          ]
        },
        "stringArray": { "type": "array", "items": { "type": "string" }, "uniqueItems": true, "default": [] }
      }
    }
    """##

    /// `text`, read once.
    public static let root: JSONNode = {
        do throws(JSONSyntaxError) {
            return try JSONReader.read(text)
        } catch {
            preconditionFailure("MetaSchema.text isn't JSON: \(error)")
        }
    }()
}
