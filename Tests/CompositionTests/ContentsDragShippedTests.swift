import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Connections
import CoreGraphics
import Frames
import LanguageModels
import Locking
import Mentions
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
    test("a note's row on a subboard's row: onto its board, gone from the board shown, which stays; Undo Move brings it back") {
        let d = Desk()
        expect(d.drop(d.note, on: d.plans, .on))
        expectEqual(d.editor.document[d.note], nil)
        expectEqual(d.editor.file.board(containing: d.note), BoardID(owner: d.plans))
        expectEqual(d.editor.board, .root)
        d.editor.undo()
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
])
