import Canvas
import DetailPanel
import Mentions
import SwiftUI
import Titles
import Types

extension ShapeRegistrar where Definition == StickyNoteDefinition {
    /// The note's header in the detail panel: its title, renamed in place ("Note" while it has none); and, for a note that is a
    /// relationship type, its words, which its pill does not draw: what it says in words, from which the model writes its
    /// fields, in the type's Schema tab above the JSON (a kind's own sections come before every shape's).
    mutating func noteHeader() {
        details(header: { $note in TitleHeader($note) }) {
            DetailSection(NoteStyle.descriptionTitle, in: TypeSchemaTab.self) { $note in NoteDescription(note: $note) }
                .shownWhile { shape, _ in shape[RelationshipProperty.self] == true && shape[TypeSchemaProperty.self] != nil }
        }
    }
}

/// A relationship type's words, in its panel: mention text in the panel's box (pills, the `@` picker), each run of typing one
/// step, "Change Description". The type's sync (`TypeSync`) reads them as it reads a type's words on its note: once typing
/// pauses, or at once on Return or when the keyboard leaves the box, the model writes the fields from them (with what it is
/// told of a relationship type: who it relates is drawn as arrows, never a field), and the JSON under it and the pill's card
/// follow; while the model writes the words from fields the card changed, the box is read-only and dimmed.
struct NoteDescription: View {
    @ShapeBinding var note: StickyNote

    var body: some View {
        let sync = $note.service(TypeSync<TypeSchemaProperty>.self), id = $note.shapeID
        MentionTextArea($note, \.text, height: NoteStyle.descriptionHeight, onCommit: { [weak sync] in sync?.commit(id) })
            .detailUpdating(sync?.status(of: id) == .updating(.words))
    }
}

extension NoteStyle {
    /// The section a relationship type's words are in, in its Schema tab; its typing is "Change Description".
    static let descriptionTitle = "Description"
    /// The box's height: two of the panel's text areas, as a subboard's description has.
    static let descriptionHeight = DetailStyle.textAreaHeight * 2
}
