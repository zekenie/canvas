import Foundation
import Geometry

// Checking shapes against their kinds' schemas: what a shape is, as one JSON object, where it
// breaks the schema that describes it, and a shape made from one.

extension AnyShapeRecord {
    /// Its properties, own and added, side by side in one object, each as a board writes it: what
    /// its kind's schema describes (`Registry.schema(for:)`), and what `Registry.schemaViolations(of:)`
    /// checks. Nil for a shape kept aside, which the app can't read.
    public var propertiesJSON: JSONObject? {
        let encoder = JSONValueEncoder()
        guard !isOpaque, case .object(var object)? = try? encoder.encode(props) else { return nil }
        for key in added.keys {
            guard let value = added[key] else { continue }
            let own = (value as? any Unboxing)?.unboxed ?? value
            if let json = try? encoder.encode(own) { object[key.rawValue] = json }
        }
        return object
    }
}

/// An added value's own value, so it's encoded as what it is (a title as a string) without an
/// encoder for the box around it: a note has three.
private protocol Unboxing {
    var unboxed: any Encodable { get }
}

extension Boxed: Unboxing {
    fileprivate var unboxed: any Encodable { value }
}

extension Registry {
    /// Where a shape breaks its kind's schema (`schema(for:)`): its properties, own and added, checked
    /// as one object (`propertiesJSON`), in the order the schema lists them. Empty when it holds up,
    /// and for a shape kept aside, or of a kind no plugin registers. Typed props always have the
    /// schema's shape, so what a shape the app holds can break are the bounds its properties declare
    /// (`maxLength`, `minimum`, `pattern`), and a number that isn't finite.
    public func schemaViolations(of shape: AnyShapeRecord) -> [SchemaViolation] {
        guard let validator = schemaValidators[shape.kind], let json = shape.propertiesJSON else { return [] }
        return validator.violations(of: .object(json))
    }

    /// A shape from its properties, own and added, side by side in one object: what its kind's
    /// schema describes (`schema(for:)`), as `AnyShapeRecord.propertiesJSON` writes it, at today's
    /// versions. For what writes shapes as JSON (the command line). A property the object leaves
    /// out, or gives as null, is as the kind has it (its `init()`, or an added property's default),
    /// unless it's required; and so is an added property given a value that's none (a blank title,
    /// `ShapeProperty.isNone`). It throws for a kind no plugin registers, a property the kind doesn't
    /// have, and a value that doesn't read as its property's type; one that breaks only its schema's
    /// bounds reads (`schemaViolations(of:)` finds it). A kind whose props hold something that
    /// follows from the rest puts it in step (`DerivedProps`: a schema card's height), so the shape
    /// may differ there from what the object says. The shape is in no document yet.
    public func shape(_ kind: ShapeKind, properties: JSONObject, id: ShapeID = ShapeID()) throws(ShapePropertiesError) -> AnyShapeRecord {
        guard let definition = definition(for: kind) else { throw .unknownKind(kind) }
        let own = Set(definition.ownPropertyNames), added = Set(self.properties(for: kind))
        var ownJSON: JSONObject = [:]
        var addedJSON: [PropertyKey: JSONValue] = [:]
        for (name, value) in properties {
            if own.contains(name) {
                ownJSON[name] = value
            } else if added.contains(PropertyKey(rawValue: name)) {
                if value != .null { addedJSON[PropertyKey(rawValue: name)] = value }
            } else {
                throw .unknownProperty(name, kind: kind)
            }
        }
        let encoder = BoardCodec.makeEncoder()
        var record: AnyShapeRecord
        do {
            record = AnyShapeRecord(id: id, kind: kind, props: try definition.kindCodec.decodeData(encoder.encode(JSONValue.object(ownJSON))),
                                    stackingKey: nil)
        } catch {
            throw .unreadable(BoardCodec.describe(error))
        }
        if let derived = definition as? any DerivedProps { derived.erasedDerive(&record) }
        // As a board's: a shape whose frame isn't finite could never be saved, so it never gets in.
        guard record.box?.isFinite ?? true else { throw .unreadable("its frame isn't finite") }
        for (key, value) in addedJSON {
            guard let codec = propertyTable.codecs[key] else { continue }
            do {
                let read = try codec.decodeData(encoder.encode(value))
                record.added[key] = codec.isNone(read) ? nil : read
            } catch {
                let why = BoardCodec.describe(error)
                throw .unreadable(why.isEmpty ? key.rawValue : "\(key): \(why)")
            }
        }
        return propertyTable.normalized(record)
    }
}

/// Why `Registry.shape(_:properties:)` made no shape.
public enum ShapePropertiesError: Error, Equatable, CustomStringConvertible {
    /// No installed plugin registers the kind.
    case unknownKind(ShapeKind)
    /// The kind has no such property of its own, and doesn't opt into one of that name.
    case unknownProperty(String, kind: ShapeKind)
    /// A value doesn't read as its property's type, or a required one is missing: where, and why.
    case unreadable(String)

    public var description: String {
        switch self {
        case .unknownKind(let kind): "no installed plugin defines \(kind) shapes"
        case .unknownProperty(let name, let kind): "\(kind) shapes have no property \(name)"
        case .unreadable(let why): why
        }
    }
}
