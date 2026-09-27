import Foundation

// Checking shapes against their kinds' schemas: what a shape is, as one JSON object, and where it
// breaks the schema that describes it.

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
        guard let validator = schemaValidators.validator(for: shape.kind, in: self), let json = shape.propertiesJSON else { return [] }
        return validator.violations(of: .object(json))
    }
}

/// Each kind's schema, compiled the first time a shape of it is checked: the registry never changes.
@MainActor
final class SchemaValidators {
    private var byKind: [ShapeKind: SchemaValidator] = [:]

    func validator(for kind: ShapeKind, in registry: Registry) -> SchemaValidator? {
        if let known = byKind[kind] { return known }
        guard let schema = registry.schema(for: kind) else { return nil }
        let validator = SchemaValidator(schema)
        byKind[kind] = validator
        return validator
    }
}
