import Canvas
import Colors
import CoreGraphics
import Draw
import Selection

/// What a note's editor does with the keys that go on to another note (tldraw's adjacent notes): ⇧↩
/// puts a new note down beside the one being edited and edits it, and Tab and ⇧Tab edit the next and
/// previous note.
@MainActor
final class NoteHops {
    private unowned let editor: CanvasEditor

    init(editor: CanvasEditor) {
        self.editor = editor
    }

    /// ⇧↩ in `id`'s editor: a new note, as the Note tool places one, beside `id` where Placing puts a
    /// note's box beside a shape (`Surroundings.near`: the side that lands nearest, the right one
    /// first), in the container `id` is in, in the color `id` has of its own (tldraw's copies its
    /// note's color); edited at once, one step, "Add Note". With no room beside it, or a board that
    /// takes nothing, nothing is put down and `id` shakes.
    func addNote(beside id: ShapeID) {
        guard let record = editor.document[id], let tool = editor.registry.placement(for: StickyNote.kind),
              let landing = Surroundings(on: editor.board, moving: tool.size, in: editor)?
                  .near(id, within: editor.shapeContext.container(of: id)) else {
            editor.refuseChanges(to: [id])
            return
        }
        let color = record[ColorProperty.self]
        let placement = color == nil ? tool : tool.mapping { note in
            var note = note
            note[ColorProperty.self] = color
            return note
        }
        editor.endEditing()
        // A group, as a press is for the Note tool: the step stays open while the new note is edited, so
        // what is typed into it is the one step, Add Note.
        editor.undoHistory.group("Add \(editor.registry.label(of: StickyNote.kind).name)") {
            editor.place(placement, in: landing.rect)
        }
    }

    /// Tab (`.next`) or ⇧Tab (`.previous`) in `id`'s editor: the next or previous note in reading order,
    /// the order Tab steps in on the canvas, among the notes in `id`'s container (Selection's
    /// `shape(_:from:among:)`), wrapping, read-only ones passed over: `id`'s edit ends, and that note is
    /// selected, edited and brought into view if it isn't. With no other note, nothing: the key does
    /// nothing in the text either.
    func editNote(_ direction: AdjacentDirection, from id: ShapeID) {
        let editor = editor
        guard let next = editor.shape(direction, from: id, among: { $0.kind == StickyNote.kind && !editor.isReadOnly($0.id) }) else { return }
        editor.endEditing()
        editor.selectedShapeIDs = [next]
        editor.beginEditing(next)
        editor.revealIfOffscreen([next])
    }
}

extension NoteHops: EditorService {}
