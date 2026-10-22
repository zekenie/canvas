import Canvas
import CoreGraphics
import Selection

// A click on a relationship type's pill opens its card (`DefinitionCards`, Form's); a drag still moves it and a double-click
// still edits its name in place.

/// A click on the pill of a relationship type: what Selection's face answers for it.
struct DefinitionFace: Hashable, Sendable {
    let shape: ShapeID
}

extension TypesStyle {
    /// The pill's part (⌥Tab), and the command that opens a relationship's fields.
    public static let fields = "Fields"
}

@MainActor
func registerDefinitionFace(into registrar: inout PluginRegistrar) {
    // The same by keys: the pill is one part of itself, which opens the card as the click does.
    registrar.forShapes(holding: RelationshipProperty.self) { relationshipKinds in
        relationshipKinds.shapeParts(named: "DefinitionFace") { editor, record in
            guard editor.editingShapeID != record.id, record[RelationshipProperty.self] == true, editor.rowBook?.pill(of: record.id) != nil,
                  let frame = editor.frame(inFile: record.id) else { return [] }
            return [ShapePart(id: DefinitionFace(shape: record.id), title: TypesStyle.fields, rect: frame) { editor in
                editor.definitionCards?.open(record.id)
            }]
        }
    }
    registrar.shapeFaces(at: { (editor: CanvasEditor, record: AnyShapeRecord, point: CGPoint) -> DefinitionFace? in
        // A relationship type is drawn as a pill (`TypeRows.pill`), and the point is on the shape itself.
        guard editor.editingShapeID != record.id, record[RelationshipProperty.self] == true, editor.rowBook?.pill(of: record.id) != nil else { return nil }
        return DefinitionFace(shape: record.id)
    }, click: { face, editor in
        editor.definitionCards?.open(face.shape)
    }, doubleClick: { face, editor in
        // Its name is edited in place, as a double-click on a note edits it (and closes the card the first click opened); a locked one
        // can't be edited, and its card stays.
        guard !editor.isReadOnly(face.shape), let frame = editor.frame(inFile: face.shape) else { return }
        editor.beginEditing(face.shape, at: CGPoint(x: frame.midX, y: frame.midY))
    })
}
