import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import Constraints
import CoreGraphics
import Frames
import LanguageModels
import Locking
import Mentions
import Selection
import SlashCommands
import ShippedTesting
import StickyNotes
import Subboards
import TableOfContents
import TestKit

// Dragging rows of the table of contents as shipped: a note's row dropped on a frame's row goes into the
// frame, on a subboard's onto its board (Moving places it, as `/move-to` would), above or below another
// note's is restacked there; a locked note's row and an arrow's don't drag.

/// A note, a second note, frame Groceries holding a third, and subboard Plans: the camera at the origin at
/// 100%, with a view, so a board a note goes onto has one to be placed in.
@MainActor private struct Desk {
    let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), model: ScriptedLanguageModel())
    let note: ShapeID, other: ShapeID, inside: ShapeID, groceries: ShapeID, plans: ShapeID

    init() {
        editor.viewportDidResize(to: CGSize(width: 1000, height: 700))
        note = editor.add(StickyNote(frame: CGRect(x: 100, y: 1000, width: 200, height: 200), text: "Eggs"))
        other = editor.add(StickyNote(frame: CGRect(x: 400, y: 1000, width: 200, height: 200), text: "Bread"))
        groceries = editor.add(Frame(frame: CGRect(x: 600, y: 100, width: 600, height: 500)), title: "Groceries")
        inside = editor.add(StickyNote(frame: CGRect(x: 640, y: 140, width: 200, height: 200), text: "Milk"))
        plans = editor.add(Subboard(frame: CGRect(x: 1400, y: 100, width: 240, height: 160)), title: "Plans")
        editor.transact { $0.settle([inside]) }
    }

    var contents: ContentsState { editor.tableOfContents! }

    /// Drags `id`'s row and drops it on `row` at `zone`: whether the list took it.
    func drop(_ id: ShapeID, on row: ShapeID, _ zone: ContentsDropZone) -> Bool {
        contents.beginDrag(from: id) && contents.drop(on: ContentsDropTarget(row: row, zone: zone))
    }

    func holder(of id: ShapeID) -> ShapeID? { editor.document.container(of: id, containingKinds: editor.registry.containingKinds) }
}

@MainActor let contentsDragShippedTests = Suite("Dragging rows of the table of contents, as shipped", [
    test("a note's row on a frame's row: in the frame, 40 in from its top-left and clear of what it holds, in front of it; Undo Move takes it back") {
        let d = Desk()
        expectEqual(d.holder(of: d.inside), d.groceries)
        let before = d.editor.file
        expect(d.drop(d.note, on: d.groceries, .on))
        expectEqual(d.holder(of: d.note), d.groceries)
        let box = try require(d.editor.document[d.note]?.box)
        expectEqual(box.minY, 140, "40 down from its top")
        expect(box.minX >= 840, "clear of Milk, at its top-left: \(box)")
        expect(d.editor.document.index(of: d.note)! > d.editor.document.index(of: d.inside)!, "listed first in the frame")
        expectEqual(d.editor.undoHistory.undoName, "Move")
        d.editor.undo()
        expectEqual(d.editor.file, before)
    },
    test("a note's row above another's: in front of it, Undo Reorder; below a note's in a frame: into the frame, just behind it") {
        let d = Desk()
        expect(d.drop(d.note, on: d.other, .above))
        expect(d.editor.document.index(of: d.note)! > d.editor.document.index(of: d.other)!)
        expectEqual(d.editor.undoHistory.undoName, "Reorder")
        expect(d.drop(d.other, on: d.inside, .below))
        expectEqual(d.holder(of: d.other), d.groceries)
        expect(d.editor.document.index(of: d.other)! < d.editor.document.index(of: d.inside)!, "behind Milk")
        expectEqual(d.editor.undoHistory.undoName, "Move")
    },
    test("a note's row on a subboard's row: onto its board, where the window goes after it, the note selected there; Undo Move brings it back to the root") {
        let d = Desk()
        expect(d.drop(d.note, on: d.plans, .on))
        expectEqual(d.editor.file.board(containing: d.note), BoardID(owner: d.plans))
        expectEqual(d.editor.board, BoardID(owner: d.plans))
        expectEqual(d.editor.selectedShapeIDs, [d.note])
        d.editor.undo()
        expectEqual(d.editor.board, .root)
        expectEqual(d.editor.file.board(containing: d.note), .root)
    },
    test("a locked note's row doesn't drag, nor an arrow's; nothing goes into a locked frame") {
        let d = Desk()
        d.editor.transact { $0.update(d.note) { $0[LockedProperty.self] = true } }
        expectEqual(d.contents.dragged(from: d.note), [])
        let arrow = d.editor.add(Arrow(start: .free(CGPoint(x: 100, y: 1500)), end: .free(CGPoint(x: 400, y: 1500))))
        expectEqual(d.contents.dragged(from: arrow), [])
        d.editor.transact { $0.update(d.groceries) { $0[LockedProperty.self] = true } }
        expect(d.contents.beginDrag(from: d.other))
        expect(!d.contents.admits(ContentsDropTarget(row: d.groceries, zone: .on)))
    },
    test("a frame, or a subboard, whose constraints refuse a note is no drop target for its row, as a locked one isn't: no highlight, no move, no step; a frame that takes it still does") {
        let d = Desk()
        let onlyFrames = ConstraintList([Constraint(says: "only frames", query: "frame")])
        d.editor.transact { transaction in
            transaction.update(d.groceries) { $0[ConstraintsProperty.self] = onlyFrames }
            transaction.update(d.plans) { $0[ConstraintsProperty.self] = onlyFrames }
        }
        let index = d.editor.constraintIndex
        expect(spinRunLoop(until: { index?.isSettled ?? true }, timeout: 5), "the constraints settle")
        let step = d.editor.undoHistory.undoName
        let move = try require(d.editor.slashCommands?.command(named: "move-to", for: .selection([d.note])))
        expect(!move.admits(d.groceries) && !move.admits(d.plans), "/move-to's picker offers neither")
        expect(d.contents.beginDrag(from: d.note))
        expect(!d.contents.admits(ContentsDropTarget(row: d.groceries, zone: .on)), "a frame that takes only frames")
        expect(!d.contents.admits(ContentsDropTarget(row: d.plans, zone: .on)), "a subboard whose board takes only frames")
        expect(!d.contents.admits(ContentsDropTarget(row: d.inside, zone: .above)), "among the rows of the frame")
        let before = d.editor.file
        expect(!d.contents.drop(on: ContentsDropTarget(row: d.groceries, zone: .on)))
        expectEqual(d.editor.file, before)
        expectEqual(d.editor.undoHistory.undoName, step, "no step")
        let free = d.editor.add(Frame(frame: CGRect(x: 100, y: 1400, width: 600, height: 400)), title: "Free")
        expect(move.admits(free), "/move-to offers it")
        expect(d.drop(d.note, on: free, .on), "a frame with no list takes it")
        expectEqual(d.holder(of: d.note), free)
    },
    test("a drop the try admitted before the answer landed, and the commit refuses once it has, is no drop: the list says so, nothing moves, no step") {
        let d = Desk()
        let onlyFrames = ConstraintList([Constraint(says: "only frames", query: "frame")])
        d.editor.transact("Constrain") { $0.update(d.groceries) { $0[ConstraintsProperty.self] = onlyFrames } }
        let index = try require(d.editor.constraintIndex)
        expect(index.isBusy, "the first answer is out")
        expect(d.contents.beginDrag(from: d.note))
        let target = ContentsDropTarget(row: d.groceries, zone: .on)
        expect(d.contents.admits(target), "no answer for the note yet: the try admits it")
        expect(spinRunLoop(until: { index.isSettled }, timeout: 5), "the constraints settle")
        let before = d.editor.file, step = d.editor.undoHistory.undoName
        expect(!d.contents.drop(on: target), "the commit is refused")
        expectEqual(d.editor.file, before)
        expectEqual(d.editor.undoHistory.undoName, step, "no step")
        expectEqual(d.contents.dragShapes, nil, "the drag is over")
    },
])
