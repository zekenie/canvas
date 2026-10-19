@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import Foundation
import TestKit

private let person = "urn:uuid:11111111-1111-1111-1111-111111111111"
private let pet = "urn:uuid:22222222-2222-2222-2222-222222222222"

/// A validator over `schema` whose outside schemas are `resources`, and the URIs it asked for, in
/// the order it asked.
private func validator(_ schema: JSONObject, _ resources: [String: JSONObject]) -> (SchemaValidator, asked: [String]) {
    var asked: [String] = []
    let validator = SchemaValidator(JSONSchema(schema)) { uri in
        asked.append(uri)
        return resources[uri].map { JSONSchema($0) }
    }
    return (validator, asked)
}

private func accepts<T: Sendable>(_ value: T) {}

@MainActor let schemaResolverTests = Suite("References to schemas outside the schema", [
    test("a ref to a schema outside is followed whole, and into a place of its own") {
        let resources: [String: JSONObject] = [person: [
            "type": "object", "title": "Person",
            "properties": ["name": ["type": "string", "maxLength": 3]],
            "$defs": ["age": ["type": "integer", "minimum": 0]],
        ]]
        let (whole, _) = validator(["properties": ["owner": ["$ref": .string(person)]]], resources)
        expectEqual(whole.problems, [])
        expectEqual(whole.violations(of: ["owner": ["name": "Ann"]]).map(\.description), [])
        expectEqual(whole.violations(of: ["owner": ["name": "Annabel"]]).map(\.description),
                    ["/owner/name maxLength: Owner › name is 7 characters long, and should be at most 3."])
        expectEqual(whole.violations(of: ["owner": 1]).map(\.keyword), ["type"])
        let (part, _) = validator(["properties": ["age": ["$ref": .string("\(person)#/$defs/age")]]], resources)
        expectEqual(part.problems, [])
        expectEqual(part.violations(of: ["age": 3]).map(\.description), [])
        expectEqual(part.violations(of: ["age": -1]).map(\.keyword), ["minimum"])
        let (empty, _) = validator(["properties": ["owner": ["$ref": .string("\(person)#")]]], resources)
        expectEqual(empty.violations(of: ["owner": 1]).map(\.keyword), ["type"], "an empty fragment is the whole resource")
        let (missing, _) = validator(["properties": ["age": ["$ref": .string("\(person)#/$defs/nowhere")]]], resources)
        expectEqual(missing.problems, ["the $ref at #/properties/age, \(person)#/$defs/nowhere, isn't in \(person)"])
        expectEqual(missing.violations(of: ["age": 1]).map(\.description),
                    ["/age $ref: Age can’t be checked: its schema refers to \(person)#/$defs/nowhere, which isn’t in it."])
    },
    test("a resource's own #/… refs are to itself, not to the schema that named it") {
        let resources: [String: JSONObject] = [person: [
            "$defs": ["name": ["type": "string", "maxLength": 3]],
            "properties": ["name": ["$ref": "#/$defs/name"]],
        ]]
        // The outside schema has a `$defs/name` of its own, which the resource's ref must not reach.
        let (v, _) = validator(["$defs": ["name": ["type": "integer"]], "properties": ["who": ["$ref": .string(person)], "n": ["$ref": "#/$defs/name"]]], resources)
        expectEqual(v.problems, [])
        expectEqual(v.violations(of: ["who": ["name": "Annabel"], "n": 1]).map(\.pointer), ["/who/name"])
        expectEqual(v.violations(of: ["who": ["name": "Ann"], "n": "x"]).map(\.pointer), ["/n"])
        // A resource without the place its own ref names is a problem where the resource is read from.
        let (broken, _) = validator(["$ref": .string(person)], [person: ["properties": ["a": ["$ref": "#/$defs/none"]]]])
        expectEqual(broken.problems, ["the $ref at \(person)#/properties/a, #/$defs/none, isn't in the schema"])
    },
    test("a type that refers to itself through a property ends with the value") {
        let resources: [String: JSONObject] = [person: [
            "type": "object",
            "properties": ["name": ["type": "string", "maxLength": 3], "friend": ["$ref": .string(person)]],
        ]]
        let (v, _) = validator(["$ref": .string(person)], resources)
        expectEqual(v.problems, [])
        expectEqual(v.violations(of: ["name": "Ann", "friend": ["name": "Bob", "friend": ["name": "Cassandra"]]]).map(\.pointer),
                    ["/friend/friend/name"])
        let (viaPet, asked) = validator(["$ref": .string(person)], [
            person: ["properties": ["pet": ["$ref": .string(pet)]]],
            pet: ["properties": ["owner": ["$ref": .string(person)]], "required": ["owner"]],
        ])
        expectEqual(viaPet.problems, [])
        expectEqual(viaPet.violations(of: ["pet": ["owner": ["pet": ["owner": [:]]]]]), [])
        expectEqual(viaPet.violations(of: ["pet": [:]]).map(\.keyword), ["required"])
        expectEqual(asked, [person, pet])
    },
    test("a loop across two resources, before the value is gone into, is marked and said") {
        let (v, _) = validator(["properties": ["x": ["$ref": .string(person)]]], [
            person: ["allOf": [["$ref": .string(pet)]]],
            pet: ["anyOf": [["$ref": .string(person)]]],
        ])
        expectEqual(v.problems.count, 1)
        expectEqual(v.violations(of: ["x": 1]).map(\.description),
                    ["/x $ref: X can’t be checked: its schema refers back to itself without end."])
        expectEqual(v.violations(of: [:]), [])
    },
    test("a schema that isn't there is a problem, and where a value meets it, can't be checked") {
        let (v, asked) = validator(["properties": ["owner": ["$ref": .string(person)]]], [:])
        expectEqual(v.problems, ["the $ref at #/properties/owner, \(person), can't be found"])
        expectEqual(v.violations(of: ["owner": 1]).map(\.description),
                    ["/owner $ref: Owner can’t be checked: its schema refers to \(person), which can’t be found."])
        expectEqual(v.violations(of: [:]), [])
        expectEqual(v.resources, [person], "listed though it wasn't there: when it appears, the validator is stale")
        expectEqual(asked, [person])
    },
    test("the resolver is asked once for each URI, however many refs name it, and resources lists them in the order met") {
        let resources: [String: JSONObject] = [person: ["type": "string"], pet: ["type": "integer"]]
        let schema: JSONObject = ["properties": [
            "a": ["$ref": .string(person)],
            "b": ["$ref": .string("\(pet)#")],
            "c": ["$ref": .string("\(person)#")],
            "d": ["items": ["$ref": .string(pet)]],
        ]]
        let (v, asked) = validator(schema, resources)
        expectEqual(asked, [person, pet], "properties are read in name order")
        expectEqual(v.resources, [person, pet])
        expectEqual(v.violations(of: ["a": "x", "b": 1, "c": "y", "d": [2]]), [])
        expectEqual(v.violations(of: ["a": 1, "b": "x"]).map(\.pointer), ["/a", "/b"])
        let (reversed, reversedAsked) = validator(["properties": ["a": ["$ref": .string(pet)], "b": ["$ref": .string(person)]]], resources)
        expectEqual(reversedAsked, [pet, person])
        expectEqual(reversed.resources, [pet, person])
        expectEqual(validator(["type": "string", "$defs": ["x": ["$ref": "#"]]], resources).0.resources, [], "a local ref asks nothing")
    },
    test("with no resolver the problems are as they were, word for word; and the validator stays Sendable") {
        let schema: JSONObject = ["properties": ["a": ["$ref": "https://example.com/schema"], "b": ["$ref": "#/$defs/missing"], "c": ["$ref": "urn:x#/y"], "d": ["$ref": ""]]]
        let without = SchemaValidator(JSONSchema(schema))
        expectEqual(without.problems, [
            "the $ref at #/properties/a, https://example.com/schema, isn't in the schema",
            "the $ref at #/properties/b, #/$defs/missing, isn't in the schema",
            "the $ref at #/properties/c, urn:x#/y, isn't in the schema",
            "the $ref at #/properties/d, , isn't in the schema",
        ])
        expectEqual(without.resources, [])
        expectEqual(without.violations(of: ["a": 1]).map(\.description),
                    ["/a $ref: A can’t be checked: its schema refers to https://example.com/schema, which isn’t in it."])
        accepts(without)
        let (with, _) = validator(["$ref": .string(person)], [person: ["type": "string"]])
        accepts(with)
        // A resolver that has nothing is not no resolver: what it was asked for can't be found.
        expectEqual(validator(["$ref": "urn:x#/y"], [:]).0.problems, ["the $ref at #, urn:x, can't be found"])
    },
    test("a ref that names the schema's own place by the resource it came from is local") {
        let (v, asked) = validator(["$ref": .string(person)], [person: ["$defs": ["s": ["type": "string"]], "$ref": .string("\(person)#/$defs/s")]])
        expectEqual(v.problems, [])
        expectEqual(v.violations(of: 1).map(\.keyword), ["type"])
        expectEqual(asked, [person])
    },
])
