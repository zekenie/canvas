import AppKit
import Canvas
import Connections
import Foundation

/// The relationship types that fit an arrow, as rows of the one list a release opens (Connections'): the taken ones first and
/// the open ones after a rule, each the type's pill as the arrow would wear it. A pick is `setRelationshipType`, its own undo
/// step ("Add Type"), a step after the press's "Add Arrow": one Undo returns to the plain arrow.
@MainActor
enum RelationshipMenus {
    /// The rows for `connection`, none with nothing to list. Each type is its name (`Untitled` for one with none) in its pill.
    /// What a row does is asked again when it is picked: an arrow deleted, or typed some other way, in the meantime, is left alone.
    static func choices(taken: [ShapeID], open: [ShapeID], for connection: ShapeID, in editor: CanvasEditor) -> [ConnectionChoice] {
        guard let types = editor.types else { return [] }
        func choice(_ type: ShapeID, setOff: Bool) -> ConnectionChoice {
            ConnectionChoice(title: TypesStyle.menuName(types.name(of: TypeLink(type))), pill: TypeChips.label(for: TypeLink(type), in: types),
                             isSetOff: setOff) { editor in
                guard (editor.shape(inFile: connection)?[IsAProperty.self] ?? []).isEmpty else { return }
                editor.setRelationshipType(type, of: [connection])
            }
        }
        return taken.map { choice($0, setOff: false) } + open.enumerated().map { choice($1, setOff: $0 == 0 && !taken.isEmpty) }
    }
}
