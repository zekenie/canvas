import Canvas

// A relationship type is a type (a shape that holds `schema`) that also holds one stored mark,
// `relationship`. The mark alone is inert; Remove Type takes both. The mark is not in the schema's
// text, so the sync never sees it. Types knows no kind: a kind opts in with `canBeRelationshipType()`,
// which the note calls beside `canBeType()`.

/// Whether a type is a relationship type: `true` on one, and nothing on the rest (`false` is none).
/// Added to the kinds that opt in (`canBeRelationshipType()`).
public enum RelationshipProperty {}

extension RelationshipProperty: ShapeProperty {
    public static let key: PropertyKey = "relationship"
    public static var defaultValue: Bool? { nil }
    public static func isNone(_ value: Bool) -> Bool { !value }
    public static var keywords: PropertyKeywords<Bool> {
        PropertyKeywords().description("True on a type that says what an arrow between two notes holds and which types it runs from and to: a relationship type. Inert on a shape with no schema.")
    }
}

/// The keys a check of the Type part names that a higher part declares the property of.
enum RelationshipKeys {
    /// An arrow's rule for the end it is (`RelationshipEndProperty`, Fields).
    static let endRule: PropertyKey = "endRule"
    /// A shape's values for its types' fields (`FieldValuesProperty`, Fields).
    static let fieldValues: PropertyKey = "fieldValues"
}

extension ShapeRegistrar {
    /// This kind's shapes can be relationship types: a type may hold the mark `relationship`. Needs
    /// `canBeType()` (`TypeWords.check`: the mark needs `schema`).
    public mutating func canBeRelationshipType() {
        optIn(to: RelationshipProperty.self)
    }
}

extension Registry {
    /// Whether the kind's shapes can be relationship types (`canBeRelationshipType()`).
    public func canBeRelationshipType(_ kind: ShapeKind) -> Bool {
        properties(for: kind).contains(RelationshipProperty.key)
    }

    /// Whether the kind's shapes can be the arrows of relationships: it holds `endRule` (`relating()`).
    /// A relating kind.
    public func relates(_ kind: ShapeKind) -> Bool {
        properties(for: kind).contains(RelationshipKeys.endRule)
    }
}
