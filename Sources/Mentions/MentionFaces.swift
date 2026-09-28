import Canvas
import CoreGraphics
import Selection

/// A pill on the canvas, as a face (Selection's `ShapeFaces`): the shape whose text it's in, what
/// it names, whether that's live, and its center (world units), from which a click edits the shape.
struct MentionFace: Hashable, Sendable {
    let shape: ShapeID
    let target: ShapeID
    let isLive: Bool
    let center: CGPoint
}

/// The pills on the canvas, as faces, on any shape whose kind draws mention text (`MentionTexts`),
/// selected or not, live or not, but the one being edited, whose text view has its own:
/// - a click edits the shape from the pill (`beginEditing(_:at:)`), whose text view selects the
///   pill there: a pill is selected as text is, never followed on a single click. A read-only shape
///   (a locked one) isn't asked to, since a refused edit is a try to change it, and a click isn't;
///   a kind with no editing view (not `Editable`) refuses, so the click only selects the shape;
/// - a double-click on a live one goes to what it names (`goTo`), or into it for a kind followed so
///   (`MentionFollowing.opens`: a subboard shows its board), and Back comes back. On a shape
///   that's edited, the click before it opened the text view, which takes the second press, so
///   this is what the pill of a read-only shape, or of a kind with no editing view, does. On one
///   naming a shape that isn't there, nothing;
/// - a double-click on a live one naming a shape on another board of the file goes there too,
///   showing its board first (`goTo`: Back returns to the board left);
/// - the pointer over a live one hovers what it names (its outline, its row) if it's on the board
///   shown, and over one that isn't, or names a shape on another board, its shape.
@MainActor
func registerMentionFaces(into registrar: inout PluginRegistrar) {
    registrar.shapeFaces(at: { editor, shape, point in MentionFace.find(at: point, on: shape, in: editor) },
                         click: { face, editor in
                             if !editor.isReadOnly(face.shape) { editor.beginEditing(face.shape, at: face.center) }
                         },
                         doubleClick: { face, editor in
                             if face.isLive { editor.followMention(of: face.target) }
                         },
                         hovering: { face, editor in face.isLive && editor.document[face.target] != nil ? face.target : nil })
}

extension MentionFace {
    /// The pill under a world point on a shape, the last drawn if two touch there; nil off every
    /// pill, and on the shape being edited.
    @MainActor
    static func find(at point: CGPoint, on shape: AnyShapeRecord, in editor: CanvasEditor) -> MentionFace? {
        guard editor.editingShapeID != shape.id else { return nil }
        guard let pill = editor.mentionPills(of: shape.id).last(where: { $0.frame.contains(point) }) else { return nil }
        return MentionFace(shape: shape.id, target: pill.target, isLive: pill.isLive,
                           center: CGPoint(x: pill.frame.midX, y: pill.frame.midY))
    }
}
