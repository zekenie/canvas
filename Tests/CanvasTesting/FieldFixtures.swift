import Canvas
import Foundation

/// The types the rows, the card, the panel and the check are built against (board 5 of the wireframes),
/// as schema texts and fixed ids: strings and ids only, so every test target (TypesTests, StickyNotesTests,
/// the gallery, the benchmarks) reads the same texts and a state looks the same in rows, card, panel and
/// gallery. The ids are fixed so a type's color is fixed (`TypeColors`: Person blue, Address orange,
/// Employee purple, Order green, KindsA teal, KindsB magenta, Wide gold). A test adds them as types
/// (`fieldEditor()` in TypesTests does) and makes Employee a Person.
public enum FieldFixtures {
    /// A type as a note would hold it: its id, its title, its words and its JSON Schema.
    public typealias TypeText = (id: ShapeID, title: String, words: String, schema: String)

    public static let personID = ShapeID(UUID(uuidString: "0E5B1A01-0000-4000-8000-0000000000A1")!)
    public static let addressID = ShapeID(UUID(uuidString: "0E5B1A02-0000-4000-8000-0000000000A2")!)
    public static let employeeID = ShapeID(UUID(uuidString: "0E5B1A03-0000-4000-8000-0000000000A3")!)
    public static let orderID = ShapeID(UUID(uuidString: "0E5B1A04-0000-4000-8000-0000000000A4")!)
    public static let kindsAID = ShapeID(UUID(uuidString: "0E5B1A05-0000-4000-8000-0000000000A5")!)
    public static let kindsBID = ShapeID(UUID(uuidString: "0E5B1A06-0000-4000-8000-0000000000A6")!)
    public static let wideID = ShapeID(UUID(uuidString: "0E5B1A07-0000-4000-8000-0000000000A7")!)
    public static let namedPersonID = ShapeID(UUID(uuidString: "0E5B1A08-0000-4000-8000-0000000000A8")!)
    public static let namedEmployeeID = ShapeID(UUID(uuidString: "0E5B1A09-0000-4000-8000-0000000000A9")!)
    /// Two Persons (notes that are one), their ids fixed so a test and the gallery agree.
    public static let annLeeID = ShapeID(UUID(uuidString: "0E5B1A20-0000-4000-8000-0000000000B0")!)
    public static let boParkID = ShapeID(UUID(uuidString: "0E5B1A21-0000-4000-8000-0000000000B1")!)

    /// The `$ref` a type is referred to by: `urn:uuid:` and its id, lowercase.
    public static func uri(of id: ShapeID) -> String { "urn:uuid:" + id.rawValue.uuidString.lowercased() }

    /// A link to a note of a type, as a schema writes it (`contentMediaType`, `contentSchema`).
    private static func pointer(to id: ShapeID) -> String {
        #"{"type": "string", "contentMediaType": "text/x-canvas-link", "contentSchema": {"$ref": "\#(uri(of: id))"}}"#
    }

    /// A name and an email, the name needed.
    public static let person: TypeText = (personID, "Person", "A person has a name and an email. It must have a name.", #"""
    {
      "type": "object",
      "properties": {
        "name": { "type": "string" },
        "email": { "type": "string", "format": "email" }
      },
      "required": ["name"]
    }
    """#)

    public static let address: TypeText = (addressID, "Address", "An address has a street, a city and a postcode.", #"""
    {
      "type": "object",
      "properties": {
        "street": { "type": "string" },
        "city": { "type": "string" },
        "postcode": { "type": "string" }
      }
    }
    """#)

    /// Person's child: a role and a start date, on top of Person's two.
    public static let employee: TypeText = (employeeID, "Employee", "An employee is a person with a role and a start date.", #"""
    {
      "type": "object",
      "properties": {
        "role": { "type": "string" },
        "startDate": { "type": "string", "format": "date" }
      }
    }
    """#)

    /// Board 5: a customer (a link to a Person), a shipping Address, line items (each a product, a quantity
    /// of at least 1 and a price), a status, tags, and a gift note while it is a gift; a customer and a
    /// line item are needed.
    public static let order: TypeText = (orderID, "Order", "An order has a customer (a link to a Person), a shipping Address, line items (each a product, a quantity of at least 1 and a price), a status (draft, paid or shipped), tags, and a gift note if it's a gift. It must have a customer and a line item.", #"""
    {
      "type": "object",
      "properties": {
        "customer": \#(pointer(to: personID)),
        "shippingAddress": { "$ref": "\#(uri(of: addressID))" },
        "lineItems": {
          "type": "array",
          "items": {
            "type": "object",
            "properties": {
              "product": { "type": "string" },
              "quantity": { "type": "integer", "minimum": 1 },
              "price": { "type": "number" }
            },
            "required": ["product", "quantity"]
          }
        },
        "status": { "enum": ["draft", "paid", "shipped"] },
        "tags": { "type": "array", "items": { "type": "string" } },
        "gift": { "type": "boolean" },
        "giftNote": { "type": "string" }
      },
      "required": ["customer", "lineItems"],
      "if": { "properties": { "gift": { "const": true } }, "required": ["gift"] },
      "then": { "required": ["giftNote"] }
    }
    """#)

    /// Two types that between them hold one field of every row of the plan's "Every kind of field" table
    /// (and a few it does not draw), nine fields each so neither folds. KindsA: text, number, date, yes or
    /// no, a choice, several choices, a list of text, a group, another type's fields (Address). KindsB: a
    /// link to a Person, several, a list of groups, a list of Address's fields, either of two plain kinds,
    /// named pairs, what no control suits, either with a group in it, an integer.
    public static let everyKind: (a: TypeText, b: TypeText) = (
        (kindsAID, "KindsA", "Nine fields: one of each of the first kinds.", #"""
        {
          "type": "object",
          "properties": {
            "name": { "type": "string" },
            "price": { "type": "number" },
            "due": { "type": "string", "format": "date" },
            "done": { "type": "boolean" },
            "status": { "enum": ["draft", "paid", "shipped"] },
            "roles": { "type": "array", "items": { "enum": ["engineer", "designer", "manager"] }, "uniqueItems": true },
            "tags": { "type": "array", "items": { "type": "string" } },
            "venue": {
              "type": "object",
              "properties": { "name": { "type": "string" }, "city": { "type": "string" } }
            },
            "shippingAddress": { "$ref": "\#(uri(of: addressID))" }
          },
          "required": ["name"]
        }
        """#),
        (kindsBID, "KindsB", "Nine fields: one of each of the rest.", #"""
        {
          "type": "object",
          "properties": {
            "customer": \#(pointer(to: personID)),
            "guests": { "type": "array", "items": \#(pointer(to: personID)) },
            "lineItems": {
              "type": "array",
              "items": {
                "type": "object",
                "properties": { "product": { "type": "string" }, "quantity": { "type": "integer" } }
              }
            },
            "rooms": { "type": "array", "items": { "$ref": "\#(uri(of: addressID))" } },
            "size": { "anyOf": [{ "type": "number" }, { "type": "string" }] },
            "labels": { "type": "object", "additionalProperties": { "type": "string" } },
            "anything": {},
            "payment": {
              "anyOf": [
                { "type": "object", "properties": { "cardNumber": { "type": "string" } } },
                { "type": "string" }
              ]
            },
            "count": { "type": "integer" }
          }
        }
        """#)
    )

    /// A type of `count` text fields, `f1` to `f<count>`: what folds.
    public static func wide(_ count: Int) -> TypeText {
        let properties = (1...max(count, 1)).map { "\"f\($0)\": { \"type\": \"string\" }" }.joined(separator: ", ")
        let schema = count > 0 ? "{ \"type\": \"object\", \"properties\": { \(properties) } }" : #"{ "type": "object", "properties": {} }"#
        return (wideID, "Wide", "A type of \(count) fields.", schema)
    }

    /// Person that titles a note by its name: `$title` names `name`. (Ids of their own: `person` is compared
    /// whole by other suites, and Order's pointer points at its id.)
    public static let namedPerson: TypeText = (namedPersonID, "Person", "A person has a name and an email. It must have a name. The name is its title.", #"""
    {
      "type": "object",
      "properties": {
        "name": { "type": "string" },
        "email": { "type": "string", "format": "email" },
        "$title": { "x-canvas-from": "name" }
      },
      "required": ["name"]
    }
    """#)

    /// Employee on top of `namedPerson`: its own fields, and no `$title` of its own, so Person's reaches it.
    public static let namedEmployee: TypeText = (namedEmployeeID, "Employee", "An employee is a person with a role and a start date.", #"""
    {
      "type": "object",
      "properties": {
        "role": { "type": "string" },
        "startDate": { "type": "string", "format": "date" }
      }
    }
    """#)
}
