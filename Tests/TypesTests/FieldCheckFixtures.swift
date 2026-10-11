import Canvas
import CanvasTesting
import Foundation
import Types

// The check's own types, beside the shared ones (`FieldFixtures`): one for each way a schema asks for
// or limits a value that the plan's table does not draw, as fixed ids and schema texts.

enum CheckFixtures {
    private static func id(_ n: Int) -> ShapeID {
        ShapeID(UUID(uuidString: String(format: "0E5B1A10-0000-4000-8000-%012X", n))!)
    }

    static let contactID = id(1), deepID = id(2), pricingID = id(3), shopID = id(4), treeID = id(5), unionsID = id(6)
    static let pairsID = id(7), ruleID = id(8), strictID = id(9), listsID = id(10), peerID = id(11), crewID = id(12), stampID = id(13), momentsID = id(14)

    private static func uri(_ id: ShapeID) -> String { FieldFixtures.uri(of: id) }

    /// "At least one of a phone or an email", and a card that needs its code.
    static let contact: FieldFixtures.TypeText = (contactID, "Contact", "A contact has a phone or an email.", #"""
    {
      "type": "object",
      "properties": {
        "name": { "type": "string" },
        "phone": { "type": "string" },
        "email": { "type": "string", "format": "email" },
        "card": { "type": "string" },
        "cvv": { "type": "string" }
      },
      "required": ["name"],
      "anyOf": [{ "required": ["phone"] }, { "required": ["email"] }],
      "dependentRequired": { "card": ["cvv"] }
    }
    """#)

    /// A group in a list in a group: `team › members › 1 › age`.
    static let deep: FieldFixtures.TypeText = (deepID, "Deep", "A team of members.", #"""
    {
      "type": "object",
      "properties": {
        "team": {
          "type": "object",
          "properties": {
            "title": { "type": "string" },
            "members": {
              "type": "array",
              "minItems": 1,
              "items": {
                "type": "object",
                "properties": {
                  "name": { "type": "string" },
                  "age": { "type": "integer", "minimum": 0 }
                },
                "required": ["name", "age"]
              }
            }
          },
          "required": ["title"]
        }
      }
    }
    """#)

    /// A type whose `$defs` another type refers into.
    static let pricing: FieldFixtures.TypeText = (pricingID, "Pricing", "Money.", #"""
    {
      "type": "object",
      "$defs": { "money": { "type": "number", "minimum": 0 } },
      "properties": { "list": { "$ref": "#/$defs/money" } }
    }
    """#)

    /// A price that is a part of Pricing, a boss that is an Employee and an address that is Address.
    static let shop: FieldFixtures.TypeText = (shopID, "Shop", "A shop.", #"""
    {
      "type": "object",
      "properties": {
        "price": { "$ref": "\#(uri(pricingID))#/$defs/money" },
        "boss": { "$ref": "\#(uri(FieldFixtures.employeeID))" },
        "address": { "$ref": "\#(uri(FieldFixtures.addressID))" }
      }
    }
    """#)

    /// A type that refers to itself.
    static let tree: FieldFixtures.TypeText = (treeID, "Tree", "A tree.", #"""
    {
      "type": "object",
      "properties": {
        "name": { "type": "string" },
        "child": { "$ref": "\#(uri(treeID))" }
      }
    }
    """#)

    static let unions: FieldFixtures.TypeText = (unionsID, "Unions", "A size that is a number or text.", #"""
    {
      "type": "object",
      "properties": {
        "size": { "anyOf": [{ "type": "number" }, { "type": "string" }] },
        "payment": {
          "anyOf": [
            { "type": "object", "properties": { "cardNumber": { "type": "string" } }, "required": ["cardNumber"] },
            { "type": "string" }
          ]
        }
      }
    }
    """#)

    /// Named pairs, the names at most five characters, and at least one pair.
    static let pairs: FieldFixtures.TypeText = (pairsID, "Pairs", "Labels.", #"""
    {
      "type": "object",
      "properties": {
        "labels": {
          "type": "object",
          "additionalProperties": { "type": "string" },
          "propertyNames": { "maxLength": 5 },
          "minProperties": 1
        }
      }
    }
    """#)

    /// Rules across fields: one note that holds a may not hold b, and a oneOf that two forms can fit.
    static let rule: FieldFixtures.TypeText = (ruleID, "Exclusive", "Either a or b.", #"""
    {
      "type": "object",
      "properties": {
        "a": { "type": "number" },
        "b": { "type": "number" },
        "flag": { "type": "boolean" }
      },
      "not": { "required": ["a", "b"] },
      "oneOf": [
        { "properties": { "a": { "minimum": 1 } } },
        { "properties": { "a": { "maximum": 5 } } }
      ],
      "if": { "properties": { "flag": { "const": true } } },
      "then": { "properties": { "ghost": { "maxLength": 1 } } }
    }
    """#)

    /// Every group says no other names.
    static let strict: FieldFixtures.TypeText = (strictID, "Strict", "A strict note.", #"""
    {
      "type": "object",
      "properties": {
        "name": { "type": "string" },
        "box": {
          "type": "object",
          "properties": { "width": { "type": "number" } },
          "additionalProperties": false,
          "maxProperties": 1
        },
        "items": {
          "type": "array",
          "items": { "type": "object", "properties": { "a": { "type": "string" } }, "additionalProperties": false }
        }
      },
      "additionalProperties": false,
      "propertyNames": { "maxLength": 4 }
    }
    """#)

    /// Lists: a needed list of at least one, one of at least two, a list not needed with a minimum, a code
    /// that breaks two rules, and a needed yes or no, choice and a name no field has.
    static let lists: FieldFixtures.TypeText = (listsID, "Lists", "Lists.", #"""
    {
      "type": "object",
      "properties": {
        "one": { "type": "array", "items": { "type": "string" }, "minItems": 1 },
        "two": { "type": "array", "items": { "type": "string" }, "minItems": 2 },
        "maybe": { "type": "array", "items": { "type": "string" }, "minItems": 2 },
        "code": { "type": "string", "pattern": "^[a-z]+$", "minLength": 5 },
        "done": { "type": "boolean" },
        "mode": { "const": "fixed" },
        "tags": { "type": "array", "items": { "type": "string", "maxLength": 1 } },
        "qty": { "type": "number" },
        "when": { "type": "string", "format": "date" },
        "anything": {}
      },
      "required": ["one", "two", "done", "mode", "ghost"]
    }
    """#)

    /// Builds on Person and restates `name` with a limit and not as needed.
    static let peer: FieldFixtures.TypeText = (peerID, "Peer", "A peer is a person with a short name.", #"""
    {
      "type": "object",
      "properties": { "name": { "type": "string", "minLength": 3 } }
    }
    """#)

    /// A crew: line items of a mug count, each with a price a crew needs.
    static let crew: FieldFixtures.TypeText = (crewID, "Crew", "A crew.", #"""
    {
      "type": "object",
      "properties": {
        "rows": {
          "type": "array",
          "items": { "type": "object", "properties": { "label": { "type": "string" }, "price": { "type": "number" } }, "required": ["price"] }
        }
      }
    }
    """#)

    /// The formats the validator is given beyond email and date: a date and time, a time of day, a link and a UUID.
    static let moments: FieldFixtures.TypeText = (momentsID, "Moments", "Times and links.", #"""
    {
      "type": "object",
      "properties": {
        "at": { "type": "string", "format": "date-time" },
        "time": { "type": "string", "format": "time" },
        "site": { "type": "string", "format": "uri" },
        "ref": { "type": "string", "format": "uuid" }
      }
    }
    """#)

    /// A note of a type that uses the date and an `if` and `then` an empty note is not asked.
    static let stamp: FieldFixtures.TypeText = (stampID, "Stamp", "A stamp.", #"""
    {
      "type": "object",
      "properties": { "when": { "type": "string", "format": "date" } },
      "description": "stamp"
    }
    """#)
}

extension CanvasEditor {
    /// Adds the check's types beside the shared ones.
    func addCheckTypes(_ types: [FieldFixtures.TypeText]) {
        addFieldTypes(types)
    }

    /// A note that is each of `types`, holding `values`.
    @discardableResult
    func addNote(of types: [ShapeID], _ values: JSONObject = [:], words: String = "") -> ShapeID {
        let id = addInstance(words, of: types)
        if !values.isEmpty { setFieldValues(values, of: id) }
        return id
    }

    func setFieldValues(_ values: JSONObject, of id: ShapeID) {
        transact("Set Values") { $0.update(id) { $0[FieldValuesProperty.self] = FieldValues(values) } }
    }

    /// The whole check of a shape.
    func fullCheck(of id: ShapeID) -> FieldCheck {
        guard let record = file.record(id), let checks = fieldChecks else { return .clean }
        return checks.fullCheck(of: record)
    }
}
