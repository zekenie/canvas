import Canvas
import SwiftUI

// Constraints: what a place accepts. A container (a frame, a subboard for the board it owns) and the root board hold
// constraints, each a few words turned into a stored query, and every shape within a constraint's reach must match it.
// A shape moved in that doesn't is refused; one a person makes there is made to fit; one already inside that doesn't
// is an error. Nothing here knows a kind: a kind opts in with `constrainable()`, and a type's lists reach the
// containers of it through `InheritedConstraints`.

/// Constraints, as a plugin: the property a kind opts into and the root's file value, the index of what every place
/// accepts and what breaks it (`editor.constraintIndex`), the one writer (`editor.constraintWriter`), and the answers to
/// the core's admission (a move into a constraint's reach refused) and placement fit (a placed shape made to fit). Its
/// issues are `ConstraintValidationPlugin`'s, a plugin value of its own, so a list without Validation leaves them out.
/// Needs Queries, whose standing queries the index holds, and Topology, whose containment tree it climbs.
public struct ConstraintsPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { .constraints }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.declare(ConstraintsProperty.self)
        registrar.declare(file: RootConstraintsProperty.self)
        registrar.service { ConstraintIndex(editor: $0) }
        registrar.service { ConstraintWriter(editor: $0) }
        registrar.admission { admission in
            admission.context.service(ConstraintIndex.self)?.judge(admission) ?? .admits
        }
        registrar.placementFit { fit in
            fit.context.service(ConstraintIndex.self)?.fit(fit)
        }
    }
}

/// Constraints' faces, a plugin value of its own after Constraints, Validation, the detail panel, the adornments, the context
/// menus, the slash commands and the query translation, so a list without them leaves it out: the funnel chip on a container,
/// the Rules tab's sections (a container's, and a holder's: a type's), `/constrain` and `/unconstrain`, and the menu items that
/// do what the panel's buttons do. List it after the plugin that gives a container its types (their chips come first).
public struct ConstraintFacesPlugin: ListedPlugin {
    public init() {}
    public nonisolated static let id: PluginID = "constraint-faces"
    public var id: PluginID { Self.id }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.service { ConstraintBoxes(editor: $0) }
        registrar.service { ConstraintBoard(editor: $0) }
        // The pill on the board's row, top leading, and its popover; nothing until the board has a constraint.
        registrar.hostOverlay(alignment: .topLeading) { editor, exit in BoardFunnel(editor: editor, onExit: exit) }
        registerConstraintFunnel(into: &registrar)
        registerConstraintPanels(into: &registrar)
        registerConstraintCommands(into: &registrar)
        registerConstraintMenus(into: &registrar)
    }
}
