import Canvas
import CoreGraphics
import Selection

// A click on a relationship type's pill opens its card (`DefinitionCards`, Form's); a drag still moves it and a double-click
// still edits its name in place.

/// A click on the pill of a relationship type: what Selection's face answers for it.
struct DefinitionFace: Hashable, Sendable {
    let shape: ShapeID
}

@MainActor
func registerDefinitionFace(into registrar: inout PluginRegistrar) {
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
