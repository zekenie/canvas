import Adornments
import Canvas
import Types

/// A type's rules on the board, as a count: "Rules 2" in the row above its top-left corner, after its pill and the
/// chips of the types it builds on, neutral and quiet. Each rule and the shapes it flags are in the type's Rules tab, so
/// the chip only says there are some: nothing to click (the owner's pick, B of the plan's two: no new point in Types and
/// no line on the note), none for a type with no rules of its own, and none on a skeleton (no adornment is drawn on one).
public enum RulesChip {}

extension RulesChip: Adornment {
    public static var placement: AdornmentPlacement { .aboveTopLeft }
    /// After what a type is called and what it builds on.
    public static var order: Order<Self> { .after(TypeChips.self) }
}

/// The chip, on the kinds whose shapes can be types: the count of the type's own rules, as the checks keep them read.
@MainActor
func registerRulesChip(into registrar: inout PluginRegistrar) {
    registrar.forShapes(holding: TypeSchemaProperty.self) { types in
        types.adornment(RulesChip.self) { shape, context in
            guard shape[TypeSchemaProperty.self] != nil, let checks = context.service(RuleChecks.self) else { return nil }
            let count = checks.rules(ofType: shape.id).count
            return count == 0 ? nil : AdornmentLabel(RulesStyle.rulesChip).counted(count)
        }
    }
}
