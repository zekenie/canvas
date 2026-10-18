import AppKit
import Canvas
import Titles
import Types

// A relationship type is a pill (`TypeRows.pill`, Types'), not a note: a capsule in its type's solid color with its name,
// and `· 2` after it when it has fields, and none of a note's paper, words or rows (the words it keeps are not drawn).
// Types says what it is and how big; this draws that, lays it out about the middle of the frame it stores
// (`NoteLayout.pillFrame`) and, zoomed out, fills the capsule with no letters. Double-click edits its name in place.

@MainActor
extension StickyNoteDefinition {
    /// The capsule filled with the type's own color (as its title pill read), its text in that fill's ink.
    func renderPill(_ pill: TypePill, of shape: ShapeRecord<StickyNote>, in frame: CGRect, _ context: RenderContext) {
        let look = context.service(TypeIndex.self)?.look(of: shape.id)
        context.cg.setFillColor((look?.row ?? NoteStyle.pillFallback).cgColor)
        context.cg.addPath(NoteStyle.capsule(frame))
        context.cg.fillPath()
        // While the name is edited, the editing view draws it: what is drawn here is the capsule and the count.
        TypePills.draw(pill, ink: look?.rowInk ?? .white, in: frame, showsTitle: !context.isEditing, to: context.cg)
    }

    /// The editing view of a relationship type's pill: its name on one line; each change is written as the title in the
    /// editing session's step ("Name Relationship Type" where nothing else names it), Return and Escape end editing keeping
    /// it, and Tab does too and asks for the card that defines the type (`RelationshipHooks.openDefinition`). Nil for a
    /// note that is no pill.
    func pillEditor(for shape: ShapeRecord<StickyNote>, context: EditContext<StickyNote>) -> TypePillEditor? {
        guard let book = context.service(RowBook.self), let pill = book.pill(of: shape.id) else { return nil }
        let ink = context.service(TypeIndex.self)?.look(of: shape.id).rowInk ?? .white
        let editor = TypePillEditor(title: pill.title, ink: ink)
        let id = shape.id
        editor.typed = { text in
            let title = TitleProperty.folded(text)
            // A change that changes nothing (the same blank twice) is no step.
            guard context.shape?[TitleProperty.self] != title else { return }
            context.transact(TypesStyle.nameRelationshipType) { $0.update(id) { $0[TitleProperty.self] = title } }
        }
        editor.finished = { ending in
            context.end()
            if ending == .tab { _ = context.service(RelationshipHooks.self)?.openDefinition(id) }
        }
        return editor
    }
}
