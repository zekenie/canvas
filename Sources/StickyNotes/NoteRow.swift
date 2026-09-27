import Canvas
import Checklists
import SwiftUI
import TableOfContents

extension ShapeRegistrar where Definition == StickyNoteDefinition {
    /// The note's row in the table of contents: its text on one line (or "Empty Note"), a yellow
    /// note, and its checklist's tally.
    mutating func noteRow() {
        contentsRow { note in
            ContentsLabel(note.props.text, placeholder: "Empty Note", color: .yellow, badge: note[ChecklistProperty.self]?.tally)
        }
    }
}
