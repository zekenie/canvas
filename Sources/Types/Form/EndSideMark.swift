import Adornments
import Canvas
import CoreGraphics

// `from` and `to` beside an end's arrow that has no name: the arrow between a type and a relationship type is the end of
// the relationship type's from or to side, and its words, if it has any, name the row on that side's notes. With none the
// arrow says which side it is in gray, where its name would be, and the word is gone as soon as a name is typed. Adornments'
// plain line of text above the arrow's anchor, remade when the relationship index names the arrow.

extension TypesStyle {
    /// The words beside an end's arrow that has no name.
    public static let endFrom = "from"
    public static let endTo = "to"
}

/// `from` or `to`, above the anchor of an end's arrow with no name. Not clicked.
public enum EndSideMark: Adornment {
    public static var placement: AdornmentPlacement { .aboveTopLeft }
    /// With the chips' order: an end's arrow is of nothing, so no chip is beside it.
    public static var order: Int { 100 }
}

extension EndSideMark {
    /// The mark of an arrow: nil unless it is the end of a relationship type and has no name.
    @MainActor
    static func label(for shape: AnyShapeRecord, in context: AdornmentContext) -> AdornmentLabel? {
        guard let relationships = context.service(RelationshipIndex.self), relationships.isActive,
              let end = relationships.end(shape.id), let sides = relationships.graph.ends.sides[end.type] else { return nil }
        let ends = end.side == .from ? sides.from : sides.to
        guard let named = ends.first(where: { $0.carrier == shape.id }), named.name == nil else { return nil }
        return .line(end.side == .from ? TypesStyle.endFrom : TypesStyle.endTo, ink: .secondary)
    }
}

@MainActor
func registerEndSideMark(into registrar: inout PluginRegistrar) {
    registrar.adornmentForEveryShape(EndSideMark.self, where: { $0.holds(RelationshipEndProperty.self) }) { shape, context in
        EndSideMark.label(for: shape, in: context)
    }
}
