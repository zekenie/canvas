import CanvasRPC
import CoreGraphics
import Foundation

/// A JSON Schema (draft 2020-12), held as the JSON it is. What `Registry.schema(for:)` hands out,
/// and what any type that can sit in a shape's props says it is (`SchemaDescribed`).
public struct JSONSchema: Hashable, Sendable {
    public let json: JSONObject
    public init(_ json: JSONObject) { self.json = json }

    /// As a board writes JSON: sorted and pretty-printed.
    public var data: Data { (try? BoardCodec.makeEncoder().encode(JSONValue.object(json))) ?? Data() }

    public static let dialect = "https://json-schema.org/draft/2020-12/schema"
}

/// A type whose JSON form a schema describes. The scalars, the core's geometry, arrays, sets,
/// optionals and dictionaries keyed by strings already are; a struct lists its properties
/// (`SchemaDefined`); a string enum titles its cases (`SchemaCases`); a type that codes itself by
/// hand writes its schema by hand.
public protocol SchemaDescribed {
    /// This type's schema, as it's written where it's used. Definitions it shares (a nested type
    /// with a `definition` name, the core's `rect`) go in `definitions`, and the result refers to
    /// them with `$ref`.
    static func schema(in definitions: inout SchemaDefinitions) -> JSONObject
}

extension SchemaDescribed {
    /// The schema on its own, with the definitions it uses under `$defs`.
    public static var jsonSchema: JSONSchema {
        var definitions = SchemaDefinitions()
        var json = schema(in: &definitions)
        if !definitions.json.isEmpty { json["$defs"] = .object(definitions.json) }
        return JSONSchema(json)
    }
}

/// The definitions a schema shares (its `$defs`), each named after the module that declares its
/// type (`mentions.text`, `arrows.terminal`; the core's geometry is `core.<name>`), so a type has
/// one name wherever it's described, and two modules' definitions never collide. Every `$ref` is
/// local (`#/$defs/...`). Each type is described once, however often it's used, and a type that
/// holds itself refers to its own definition.
public struct SchemaDefinitions {
    /// By full name.
    public private(set) var json: JSONObject = [:]
    /// The type each definition is of.
    private var types: [String: ObjectIdentifier] = [:]
    /// The structs being written out in place, outermost first: one that holds itself can't be.
    var inPlace: [ObjectIdentifier] = []
    /// Every struct described, in the order it was first met, for the registry to check their lists
    /// (`propertyListProblems`).
    private(set) var described: [any SchemaDefined.Type] = []
    private var describedIDs: Set<ObjectIdentifier> = []
    /// What can't be described: two types under one name, a struct that holds itself in place.
    var problems: [String] = []

    public init() {}

    /// A reference to the definition `name` of `type`, which `make` writes the first time.
    public mutating func reference(_ name: String, of type: Any.Type, _ make: (inout SchemaDefinitions) -> JSONObject) -> JSONObject {
        let module = String(reflecting: type).prefix { $0 != "." }.lowercased()
        return define("\(module).\(name)", of: type, make)
    }

    mutating func record(_ type: any SchemaDefined.Type) {
        if describedIDs.insert(ObjectIdentifier(type)).inserted { described.append(type) }
    }

    /// A reference to the core's definition `name`.
    mutating func core(_ name: String, of type: Any.Type, _ make: (inout SchemaDefinitions) -> JSONObject) -> JSONObject {
        define("core.\(name)", of: type, make)
    }

    private mutating func define(_ name: String, of type: Any.Type, _ make: (inout SchemaDefinitions) -> JSONObject) -> JSONObject {
        // The name as one step of a JSON Pointer, in a URI fragment: a `/`, `~` or `%` in it escaped,
        // so the reference finds it (`SchemaValidator` reads it back that way, as any validator does).
        let reference: JSONObject = ["$ref": .string(JSONPointer.fragment("/$defs/\(JSONPointer.escaped(name))"))]
        if let existing = types[name] {
            if existing != ObjectIdentifier(type) {
                problems.append("two types are defined as \(name) (\(type) is one); give one another definition name")
            }
            return reference
        }
        // Named before it's written, so a type that holds itself refers to it; and written on its own,
        // not in place, even inside a struct being written in place.
        types[name] = ObjectIdentifier(type)
        let outer = inPlace
        inPlace = []
        json[name] = .object(make(&self))
        inPlace = outer
        return reference
    }
}

// MARK: What's described already

extension String: SchemaDescribed {
    public static func schema(in _: inout SchemaDefinitions) -> JSONObject { ["type": "string"] }
}

extension Bool: SchemaDescribed {
    public static func schema(in _: inout SchemaDefinitions) -> JSONObject { ["type": "boolean"] }
}

extension Int: SchemaDescribed {
    public static func schema(in _: inout SchemaDefinitions) -> JSONObject { ["type": "integer"] }
}

/// Finite. A board saves NaN and the infinities as the strings "nan", "inf" and "-inf", so that a
/// save never fails, and the schema counts those as invalid.
extension Double: SchemaDescribed {
    public static func schema(in _: inout SchemaDefinitions) -> JSONObject { ["type": "number"] }
}

extension CGFloat: SchemaDescribed {
    public static func schema(in _: inout SchemaDefinitions) -> JSONObject { ["type": "number"] }
}

extension UUID: SchemaDescribed {
    public static func schema(in _: inout SchemaDefinitions) -> JSONObject { ["type": "string", "format": "uuid"] }
}

/// As a board writes it: ISO 8601, in UTC, to the second.
extension Date: SchemaDescribed {
    public static func schema(in _: inout SchemaDefinitions) -> JSONObject { ["type": "string", "format": "date-time"] }
}

extension ShapeID: SchemaDescribed {
    public static func schema(in definitions: inout SchemaDefinitions) -> JSONObject {
        definitions.core("shape-id", of: Self.self) { _ in
            ["type": "string", "format": "uuid", "description": "Another shape on the same board."]
        }
    }
}

extension CGPoint: SchemaDescribed {
    public static func schema(in definitions: inout SchemaDefinitions) -> JSONObject {
        definitions.core("point", of: Self.self) { _ in pair("[x, y]") }
    }
}

extension CGSize: SchemaDescribed {
    public static func schema(in definitions: inout SchemaDefinitions) -> JSONObject {
        definitions.core("size", of: Self.self) { _ in pair("[width, height]") }
    }
}

extension CGRect: SchemaDescribed {
    public static func schema(in definitions: inout SchemaDefinitions) -> JSONObject {
        definitions.core("rect", of: Self.self) { definitions in
            ["description": "[[x, y], [width, height]], in world units", "type": "array",
             "prefixItems": [.object(CGPoint.schema(in: &definitions)), .object(CGSize.schema(in: &definitions))],
             "items": false, "minItems": 2]
        }
    }
}

/// Two numbers, as CoreGraphics writes a point or a size.
private func pair(_ description: String) -> JSONObject {
    ["description": .string(description), "type": "array", "prefixItems": [["type": "number"], ["type": "number"]],
     "items": false, "minItems": 2]
}

extension Array: SchemaDescribed where Element: SchemaDescribed {
    public static func schema(in definitions: inout SchemaDefinitions) -> JSONObject {
        ["type": "array", "items": .object(Element.schema(in: &definitions))]
    }
}

/// In no particular order, and never the same element twice.
extension Set: SchemaDescribed where Element: SchemaDescribed {
    public static func schema(in definitions: inout SchemaDefinitions) -> JSONObject {
        ["type": "array", "items": .object(Element.schema(in: &definitions)), "uniqueItems": true]
    }
}

/// An object whose members, named anything, are each a value.
extension Dictionary: SchemaDescribed where Key == String, Value: SchemaDescribed {
    public static func schema(in definitions: inout SchemaDefinitions) -> JSONObject {
        ["type": "object", "additionalProperties": .object(Value.schema(in: &definitions))]
    }
}

/// As what it wraps: a property left out when nil is simply not required.
extension Optional: SchemaDescribed where Wrapped: SchemaDescribed {
    public static func schema(in definitions: inout SchemaDefinitions) -> JSONObject { Wrapped.schema(in: &definitions) }
}

/// A string enum, each case with a title: `oneOf` a `const` per case.
public protocol SchemaCases: CaseIterable, RawRepresentable, SchemaDescribed where RawValue == String {
    /// What the case is called in a schema.
    var schemaTitle: String { get }
}

extension SchemaCases {
    public static func schema(in _: inout SchemaDefinitions) -> JSONObject {
        ["type": "string",
         "oneOf": .array(allCases.map { ["const": .string($0.rawValue), "title": .string($0.schemaTitle)] })]
    }
}
