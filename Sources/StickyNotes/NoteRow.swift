import AppKit
import Canvas
import Mentions
import SwiftUI
import TableOfContents

extension ShapeRegistrar where Definition == StickyNoteDefinition {
    /// The note's row in the table of contents: its text on one line, each mention with its
    /// shape's name as it is now (or "Empty Note"), and a yellow note, or the color the note has. A rename of a shape it
    /// mentions remakes the row, and only the rows of notes that mention it.
    mutating func noteRow() {
        contentsRow(affected: MentionRows.affected) { note, context in
            ContentsLabel(context.plainText(note.props.text), placeholder: "Empty Note", color: context.color(of: note))
        }
    }
}

extension NoteStyle {
    /// A note's symbol wherever it's shown beside others' on a neutral surface: its row, the `@`
    /// picker, a list of what's connected to a shape, a pill in the panel's text.
    static let tint = NSColor.systemYellow
}
