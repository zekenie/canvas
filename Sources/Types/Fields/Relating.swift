import Canvas

// A relating kind is a kind whose shapes can be the arrows of a relationship: one that holds `endRule`.
// Types names no kind: the arrow calls `relating()` beside `typeable()`, and the services find the
// kinds by the property they hold.

/// An arrow's rule for the end it is, if it is one (Needed, Only one): `endRule`, an object, nothing
/// while both are false. It is the kind's opt-in, and an arrow that is no end holds it inertly; an end's
/// is read into the compiled end (`RelationshipEnd.rule`) and written by `editor.setEndRule`. Added to the kinds that opt in (`relating()`).
public enum RelationshipEndProperty {}

extension RelationshipEndProperty: ShapeProperty {
    public static let key: PropertyKey = RelationshipKeys.endRule
    public static var defaultValue: EndRule? { nil }
    public static func isNone(_ value: EndRule) -> Bool { value.isNone }
    public static var keywords: PropertyKeywords<EndRule> {
        PropertyKeywords().description("What a relationship type asks of the end this arrow is: needed (every note at the end has one), onlyOne (at most one). Inert on an arrow that is no end of a relationship type.")
    }
}

extension ShapeRegistrar {
    /// This kind's shapes can be the arrows of relationships: each may hold `endRule`, and its kind
    /// holds `is` and `fieldValues` (`typeable()`; `TypeWords.check`).
    public mutating func relating() {
        optIn(to: RelationshipEndProperty.self)
    }
}
