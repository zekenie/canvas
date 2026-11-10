import Canvas
import CoreGraphics
import Selection
import Types

/// What a note's editor does with the keys that go on to another note (tldraw's adjacent notes): ⇧↩
/// puts a new note down beside the one being edited and edits it, and Tab and ⇧Tab edit the next and
/// previous note, once past the note's own rows.
@MainActor
final class NoteHops {
    private unowned let editor: CanvasEditor
    /// The note ⇧Tab went back to: its session starts at its last stop, its last row, as Tab came from there.
    private var startsAtEnd: ShapeID?

    init(editor: CanvasEditor) {
        self.editor = editor
    }

    /// ⇧↩ in `id`'s editor: a new note beside `id`, as ⇧↩ on the canvas with `id` selected puts one (Insert › New Shape Beside,
    /// `editor.insert`: where Placing puts a note's box beside a shape, the side that lands nearest, the right one
    /// first, in the container `id` is in, in the color `id` has of its own, tldraw's adjacent notes'); edited at
    /// once, one step, "Add Note". With nowhere to put it, or a board that takes nothing, nothing is put down and
    /// `id` shakes.
    func addNote(beside id: ShapeID) {
        if !editor.insert(ToolID(placing: StickyNote.kind), beside: [id]) { editor.refuseChanges(to: [id]) }
    }

    /// ⇧↩ typed into through a mirror (`editor.editingStandIn`): the note is on another board, so nothing is put down
    /// beside it and the mirror shakes, the note still edited. False, doing nothing, when the note is typed into itself.
    func refusesThroughStandIn() -> Bool {
        guard let standIn = editor.editingStandIn else { return false }
        editor.refuseChanges(to: [standIn])
        return true
    }

    /// Tab (`.next`) or ⇧Tab (`.previous`) past `id`'s last or first stop: the next or previous note in reading order,
    /// the order Tab steps in on the canvas, among the notes in `id`'s container (Selection's
    /// `shape(_:from:among:)`), wrapping, read-only ones passed over: `id`'s edit ends, and that note is
    /// selected, edited and brought into view if it isn't. Tab starts it at its words, ⇧Tab at its last row if it
    /// has rows (`startsAtLastRow`), so Tab and ⇧Tab undo each other; ⇧Tab to a relationship type's pill opens its
    /// card at its last stop rather than editing its name (the card is the pill's parts, after its name). False with
    /// no other note: the key does nothing in the text either.
    @discardableResult
    func editNote(_ direction: AdjacentDirection, from id: ShapeID) -> Bool {
        let editor = editor
        // Through a mirror there is no other note in reach: the key does nothing.
        guard editor.editingStandIn == nil else { return false }
        guard let next = editor.shape(direction, from: id, among: { $0.kind == StickyNote.kind && !editor.isReadOnly($0.id) }) else { return false }
        editor.endEditing()
        editor.selectedShapeIDs = [next]
        editor.revealIfOffscreen([next])
        // A relationship type's last stop is its card's last (its name, then the card): ⇧Tab comes back into the card there.
        if direction == .previous, editor.rowBook?.pill(of: next) != nil, editor.definitionCards?.open(next, fromEnd: true) == true { return true }
        startsAtEnd = direction == .previous ? next : nil
        editor.beginEditing(next)
        return true
    }

    /// Whether `id`'s session starts at its last row, as its editor is made: asked once, since only the session ⇧Tab
    /// began does.
    func startsAtLastRow(_ id: ShapeID) -> Bool {
        guard startsAtEnd == id else { return false }
        startsAtEnd = nil
        return true
    }
}

extension NoteHops: EditorService {
    /// A session ⇧Tab began that no editor took up (headless, or refused) starts nothing later.
    func editingDidEnd(_ id: ShapeID, in editor: CanvasEditor) {
        if startsAtEnd == id { startsAtEnd = nil }
    }
}
