import Canvas
import Checklists
import Mentions
import SwiftUI
import TableOfContents

extension ShapeRegistrar where Definition == StickyNoteDefinition {
    /// The note's row in the table of contents: its text on one line, each mention with its
    /// shape's name as it is now (or "Empty Note"), a yellow note, and its checklist's tally. A
    /// rename of a shape it mentions remakes the row, and only the rows of notes that mention it.
    mutating func noteRow() {
        contentsRow(affected: MentionRows.affected) { note, context in
            ContentsLabel(context.plainText(note.props.text), placeholder: "Empty Note", color: .yellow,
                          badge: note[ChecklistProperty.self]?.tally)
        }
    }
}
