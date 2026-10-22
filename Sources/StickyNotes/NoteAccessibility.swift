import Canvas
import Mentions
import Types

extension ShapeRegistrar where Definition == StickyNoteDefinition {
    /// What VoiceOver reads as a note's value: its words, each mention read as its shape's name as it is
    /// now (else the name it holds), with no "@"; nothing for a note with none. Its title and kind are
    /// Titles' and the core's, said before it ("Checkout, Note"). A relationship type drawn as a pill keeps its words but draws
    /// none of them, so it says none.
    mutating func noteAccessibility() {
        accessibility { note, editor in
            if editor.rowBook?.pill(of: note.id) != nil { return AccessibleTraits() }
            let labels = editor.service(MentionState.self)?.labels
            return AccessibleTraits(value: note.props.text.reading { id, stored in labels?.label(of: id) ?? stored }.text)
        }
    }
}
