import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Selection
import SwiftUI
import TableOfContents
import TestKit

// Dragging rows, headlessly: what a row's drag takes, where a drag over a row points, a drop that leaves
// shapes in their container restacking them (Reorder), one that takes them elsewhere handed to
// `ContentsMoves` with its place, rows of a board open under its owner's restacked on that board, and a
// closed row a drag rests on opening. Fixtures only: no kind and no mover the app ships.

/// What a mover was asked, and what it moved.
@MainActor final class MoveLog {
    var asked: [(shapes: [ShapeID], place: ContentsPlace)] = []
    var moved: [(shapes: [ShapeID], place: ContentsPlace)] = []
    var admits = true
}

/// A mover (`ContentsMoves`) that takes what `log.admits` says, and only notes what it's asked to move.
struct RecordingMoves: CanvasPlugin {
    let log: MoveLog
    var id: PluginID { "recording-moves" }
    func register(into registrar: inout PluginRegistrar) {
        let log = log
        registrar.contentsMoves(admits: { shapes, place, _ in
            log.asked.append((shapes, place))
            return log.admits
        }, move: { shapes, place, _ in log.moved.append((shapes, place)) })
    }
}

@MainActor private func ids(_ document: CanvasDocument) -> [ShapeID] { document.shapes.map(\.id) }

extension ContentsState {
    /// Drags `id`'s row (the selection's, if it's selected) and drops it on `row` at `zone`: whether it took it.
    @discardableResult
    func drag(_ id: ShapeID, to row: ShapeID, _ zone: ContentsDropZone) -> Bool {
        guard beginDrag(from: id) else { return false }
        return drop(on: ContentsDropTarget(row: row, zone: zone))
    }

    /// Whether a drag of `id`'s row would drop on `row` at `zone`.
    func admits(_ id: ShapeID, on row: ShapeID, _ zone: ContentsDropZone) -> Bool {
        beginDrag(from: id) && admits(ContentsDropTarget(row: row, zone: zone))
    }

    /// The row of `id` among `entries` (any depth), or a board's open under its owner's.
    func row(_ id: ShapeID, on board: BoardID? = nil) -> ContentsEntry? {
        func find(_ entries: [ContentsEntry]) -> ContentsEntry? {
            for entry in entries {
                if entry.id == id { return entry }
                if let found = find(entry.children ?? []) { return found }
            }
            return nil
        }
        return find(board.map(outline(of:)) ?? entries)
    }
}

@MainActor let dragTests = Suite("Table of contents: dragging rows", [
    test("a row's drag takes its shape; a selected row's, every selected shape that can move, in document order; none for a frozen shape, or one with no box") {
        let editor = try contentsEditor([FreezingPlugin()])
        let (a, b, c) = threeWidgets(editor)
        let tag = editor.add(CanvasTesting.Tag(target: a)), frozen = editor.add(Widget(name: "Frozen"))
        editor.freeze([frozen])
        let state = editor.contents
        expectEqual(state.dragged(from: b), [b])
        expectEqual(state.dragged(from: tag), [], "a tag has no box")
        expectEqual(state.dragged(from: frozen), [])
        editor.selectedShapeIDs = [c, frozen, a, tag]
        expectEqual(state.dragged(from: a), [a, c], "the selection's that move, back to front")
        expectEqual(state.dragged(from: b), [b], "an unselected row drags alone")
        expect(state.beginDrag(from: c))
        expectEqual(state.dragShapes, [a, c])
        expect(!state.beginDrag(from: tag), "no drag")
        expectEqual(state.dragShapes, [a, c], "the drag under way is as it was")
    },
    test("a selected row's drag takes the selected rows that show: one under a closed corral, with every shape listed, stays") {
        let editor = try corralEditor()
        let nest = NestedCorrals(in: editor)
        let state = editor.contents
        state.select([nest.c, nest.b])                      // as rows picked: every shape listed
        expectEqual(Set(editor.selectedShapeIDs), [nest.b, nest.c])
        expectEqual(state.dragged(from: nest.c), [nest.b, nest.c], "both rows show")
        state.setExpanded(try require(state.row(nest.inner)), false)
        expectEqual(state.dragged(from: nest.c), [nest.c], "B's row is under the closed inner corral")
        state.setExpanded(try require(state.row(nest.inner)), true)
        expectEqual(state.dragged(from: nest.c), [nest.b, nest.c])
    },
    test("where a drag points: a widget's row by halves; a corral's or a pocket's quarters above and below, its middle on it; below an open corral's, on it; below the open row of a shape that takes nothing, nowhere") {
        let editor = try corralEditor([PocketsPlugin()], file: CanvasFile(root: CanvasDocument(), children: [:]))
        let w = editor.add(Widget(CGRect(x: 0, y: 0, width: 100, height: 60), name: "W"))
        let nest = NestedCorrals(in: editor)
        let empty = editor.add(Corral(CGRect(x: 3000, y: 0, width: 400, height: 300)))
        let p = editor.add(Pocket(CGRect(x: 4000, y: 0, width: 200, height: 100)))
        editor.transact(on: BoardID(owner: p), "Add") { $0.insert(ShapeRecord(Widget(name: "Inside"))) }
        _ = editor.add(Pin("on W", on: w))
        let state = editor.contents
        @MainActor func zones(_ id: ShapeID) throws -> [ContentsDropZone?] {
            let row = try require(state.row(id))
            return [0.1, 0.4, 0.6, 0.9].map { state.target(onRow: row, at: $0)?.zone }
        }
        expectEqual(try zones(nest.c), [.above, .above, .below, .below])
        expectEqual(try zones(empty), [.above, .on, .on, .below])
        expectEqual(try zones(nest.outer), [.above, .on, .on, .on], "open, below it is above what it holds: in it")
        expectEqual(try zones(p), [.above, .on, .on, .below], "closed")
        state.setExpanded(try require(state.row(p)), true)
        expectEqual(try zones(p), [.above, .on, .on, .on])
        expectEqual(try zones(w), [.above, .above, .below, .below], "closed over its pin")
        state.setExpanded(try require(state.row(w)), true)
        expectEqual(try zones(w), [.above, .above, nil, nil], "open: below it is above its pin, which isn't where shapes go")
    },
    test("dropped above or below a row at its level: in front of its shape, or just behind it; one step, Reorder, that undo takes back; the drag is over") {
        let editor = try contentsEditor()
        let (a, b, c) = threeWidgets(editor)
        let state = editor.contents
        expect(state.drag(a, to: c, .above))
        expectEqual(ids(editor.document), [b, c, a], "listed first, in front of C")
        expectEqual(editor.undoHistory.undoName, "Reorder")
        expectEqual(state.dragShapes, nil)
        editor.undo()
        expectEqual(ids(editor.document), [a, b, c])
        expect(state.drag(c, to: a, .below))
        expectEqual(ids(editor.document), [c, a, b], "listed last, just behind A")
        expect(state.drag(c, to: b, .above))
        expectEqual(ids(editor.document), [a, b, c])
    },
    test("in a corral: among what it holds, in front of a corral it holds and all that one holds; it stays in its corral") {
        let editor = try corralEditor()
        let nest = NestedCorrals(in: editor)
        let state = editor.contents
        expect(state.drag(nest.a, to: nest.inner, .above))
        expectEqual(ids(editor.document), [nest.outer, nest.inner, nest.b, nest.a, nest.c])
        expectEqual(editor.holder(of: nest.a), nest.outer)
        expect(state.drag(nest.inner, to: nest.a, .above), "a corral takes what it holds along")
        expectEqual(ids(editor.document), [nest.outer, nest.a, nest.inner, nest.b, nest.c])
    },
    test("several selected rows dropped together keep their order among themselves") {
        let editor = try contentsEditor()
        let (a, b, c) = threeWidgets(editor)
        let d = editor.add(Widget(name: "D"))
        editor.selectedShapeIDs = [c, a]
        expect(editor.contents.drag(a, to: d, .above))
        expectEqual(ids(editor.document), [b, d, a, c])
        expectEqual(Set(editor.selectedShapeIDs), [a, c], "still selected")
        expect(editor.contents.drag(c, to: b, .below))
        expectEqual(ids(editor.document), [a, c, b, d])
    },
    test("not taken: beside itself or what it holds; on its own corral's row; beside a row nested under what it's pinned to, or a shape with no box; a drag that began in another list") {
        let editor = try corralEditor()
        let nest = NestedCorrals(in: editor)
        let w = editor.add(Widget(CGRect(x: 2000, y: 0, width: 100, height: 60), name: "W"))
        let pin = editor.add(Pin("on W", on: w)), tag = editor.add(CanvasTesting.Tag(target: w))
        let state = editor.contents
        expect(!state.admits(nest.c, on: nest.c, .above), "beside itself")
        expect(!state.admits(nest.outer, on: nest.b, .above), "beside what it holds")
        expect(!state.admits(nest.outer, on: nest.inner, .on), "into what it holds")
        expect(!state.admits(nest.a, on: nest.outer, .on), "into the corral it's in: it's there")
        expect(!state.admits(nest.c, on: pin, .above), "a pin's row is under what it's pinned to, not where it's stacked")
        expect(!state.admits(nest.c, on: tag, .below), "a tag has no box")
        expect(state.admits(nest.c, on: w, .above))
        let other = try corralEditor()
        let elsewhere = other.add(Widget(name: "Elsewhere"))
        expect(other.contents.beginDrag(from: elsewhere))
        expectEqual(state.dragShapes, nil, "another list's drag")
        expect(!state.admits(ContentsDropTarget(row: w, zone: .above)))
        expect(!state.drop(on: ContentsDropTarget(row: w, zone: .above)))
    },
    test("a drop that takes shapes elsewhere is ContentsMoves': none installed, it isn't taken; installed, asked with the shapes and the place, the move its own") {
        let log = MoveLog()
        let file = CanvasFile(root: CanvasDocument(), children: [:])
        let bare = try corralEditor([PocketsPlugin()], file: file)
        let bareNest = NestedCorrals(in: bare)
        expect(!bare.contents.admits(bareNest.c, on: bareNest.outer, .on), "nothing moves shapes into a corral")
        expect(bare.contents.admits(bareNest.c, on: bareNest.outer, .above), "but a restack at the top needs nothing")

        let editor = try corralEditor([PocketsPlugin(), RecordingMoves(log: log)], file: file)
        let nest = NestedCorrals(in: editor)
        let p = editor.add(Pocket(CGRect(x: 4000, y: 0, width: 200, height: 100)))
        let pBoard = BoardID(owner: p)
        let x = ShapeID()
        editor.transact(on: pBoard, "Add") { $0.insert(ShapeRecord(id: x, Widget(name: "X"))) }
        let state = editor.contents
        let before = editor.file
        expect(state.drag(nest.c, to: nest.outer, .on))
        expect(state.drag(nest.c, to: nest.b, .above))
        expect(state.drag(nest.a, to: nest.c, .below))
        expect(state.drag(nest.c, to: p, .on))
        expect(state.drag(nest.c, to: x, .above))
        expectEqual(log.moved.map(\.shapes), [[nest.c], [nest.c], [nest.a], [nest.c], [nest.c]])
        expectEqual(log.moved.map(\.place), [ContentsPlace(board: .root, container: nest.outer, position: .front),
                                             ContentsPlace(board: .root, container: nest.inner, position: .inFront(of: nest.b)),
                                             ContentsPlace(board: .root, container: nil, position: .behind(nest.c)),
                                             ContentsPlace(board: pBoard, container: nil, position: .front),
                                             ContentsPlace(board: pBoard, container: nil, position: .inFront(of: x))])
        expectEqual(editor.file, before, "the move is the mover's")
        log.admits = false
        expect(!state.admits(nest.c, on: nest.outer, .on), "a place the mover doesn't take")
    },
    test("rows of a board open under its owner's: restacked on that board, in one step that undo takes back; the board shown stays") {
        let p = ShapeID(), x = ShapeID(), y = ShapeID(), z = ShapeID()
        let pBoard = BoardID(owner: p)
        let file = CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(ShapeRecord(id: p, Pocket(CGRect(x: 0, y: 0, width: 200, height: 100))))]),
                              children: [p: CanvasDocument(shapes: [ShapeRecord(id: x, Widget(name: "X")), ShapeRecord(id: y, Widget(name: "Y")),
                                                                    ShapeRecord(id: z, Widget(name: "Z"))].map(AnyShapeRecord.init))])
        let editor = try contentsEditor([PocketsPlugin()], file: file)
        let state = editor.contents
        expect(state.drag(x, to: z, .above))
        expectEqual(ids(editor.file[pBoard]), [y, z, x])
        expectEqual(editor.board, .root)
        expectEqual(editor.undoHistory.undoName, "Reorder")
        expectEqual(state.outline(of: pBoard).map(\.id), [y, z, x], "its rows follow")
        editor.undo()
        expectEqual(ids(editor.file[pBoard]), [x, y, z])
    },
    test("a drag resting on a closed row that opens onto rows opens it after a while; one that moves off first, or onto a row's edge, doesn't") {
        let scheduler = ManualScheduler()
        let editor = try corralEditor([PocketsPlugin(), RecordingMoves(log: MoveLog())], scheduler: scheduler)
        let w = editor.add(Widget(CGRect(x: 0, y: 0, width: 100, height: 60), name: "W"))
        let p = editor.add(Pocket(CGRect(x: 4000, y: 0, width: 200, height: 100)))
        editor.transact(on: BoardID(owner: p), "Add") { $0.insert(ShapeRecord(Widget(name: "Inside"))) }
        let state = editor.contents
        let row = try require(state.row(p))
        expect(state.beginDrag(from: w))
        expectEqual(state.dragMoved(over: row, at: 0.5), ContentsDropTarget(row: p, zone: .on))
        expectEqual(state.dropZone(for: p), .on, "its ring shows")
        scheduler.advance(by: .milliseconds(600))
        state.dragLeft(row)
        expectEqual(state.dropZone(for: p), nil)
        scheduler.advance(by: .milliseconds(600))
        expect(!state.isExpanded(row), "it moved off first")
        state.dragMoved(over: row, at: 0.1)
        expectEqual(state.dropZone(for: p), .above)
        scheduler.advance(by: .seconds(1))
        expect(!state.isExpanded(row), "above it isn't on it")
        state.dragMoved(over: row, at: 0.5)
        scheduler.advance(by: .milliseconds(700))
        expect(state.isExpanded(row), "rested on it: open")
    },
    test("a drag's line and ring are observed per row: pointing moves them from row to row, and each row hears only its own") {
        let editor = try contentsEditor([RecordingMoves(log: MoveLog())])
        let (a, b, c) = threeWidgets(editor)
        let state = editor.contents
        @MainActor func reaches(_ id: ShapeID, _ change: () -> Void) -> Bool {
            let changed = Flag()
            withObservationTracking { _ = state.dropZone(for: id) } onChange: { changed.set() }
            change()
            return changed.isSet
        }
        expect(state.beginDrag(from: a))
        let rowB = try require(state.row(b)), rowC = try require(state.row(c))
        expect(reaches(b) { state.dragMoved(over: rowB, at: 0.2) })
        expect(!reaches(c) { state.dragMoved(over: rowB, at: 0.8) }, "from B's top to its bottom: B's alone")
        expectEqual(state.dropZone(for: b), .below)
        expect(reaches(b) { state.dragMoved(over: rowC, at: 0.2) }, "leaving B")
        expectEqual(state.dropZone(for: c), .above)
        expect(reaches(c) { state.dragLeft(rowC) })
        expectEqual(state.dropZone(for: c), nil)
    },
])
