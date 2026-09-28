@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Keyboard
import Selection
import TableOfContents
import TestKit

// Rows that read shapes on other boards (a ref's row shows the name of a widget anywhere in the
// file): kept per board, they're made again on going back to a board as it was left when what they
// read changed meanwhile, and on the board shown when a commit takes what they read with a board.

private func widget(_ id: ShapeID, _ name: String) -> AnyShapeRecord {
    AnyShapeRecord(ShapeRecord(id: id, Widget(CGRect(x: 0, y: 0, width: 100, height: 60), name: name)))
}
private func pocket(_ id: ShapeID) -> AnyShapeRecord { AnyShapeRecord(ShapeRecord(id: id, Pocket(CGRect(x: 0, y: 200, width: 100, height: 60)))) }
private func ref(_ id: ShapeID, to target: ShapeID) -> AnyShapeRecord { AnyShapeRecord(ShapeRecord(id: id, Ref(to: target))) }

/// A root holding widget A, pocket P and a ref to W; P's board holds a ref to A and pocket Q; Q's
/// holds widget W.
private struct Refs {
    let a = ShapeID(), p = ShapeID(), toW = ShapeID(), toA = ShapeID(), q = ShapeID(), w = ShapeID()
    var file: CanvasFile {
        CanvasFile(root: CanvasDocument(shapes: [widget(a, "A"), pocket(p), ref(toW, to: w)]),
                   children: [p: CanvasDocument(shapes: [ref(toA, to: a), pocket(q)]), q: CanvasDocument(shapes: [widget(w, "W")])])
    }
    var pBoard: BoardID { BoardID(owner: p) }
}

@MainActor private func rename(_ editor: CanvasEditor, _ id: ShapeID, _ name: String) {
    editor.transact("Rename") { $0.update(id, as: Widget.self) { $0.props.name = name } }
}

@MainActor let affectedBoardsTests = Suite("Table of contents: rows that read other boards", [
    test("going back to a board as it was left, a row that reads a shape renamed on another board meanwhile is made again, and no other row") {
        let refs = Refs()
        let editor = try refsEditor([PocketsPlugin()], file: refs.file)
        expect(editor.showBoard(refs.pBoard))
        expectEqual(editor.contents.entries.outline, ["→ A", "pocket"])
        expect(editor.showBoard(.root))
        rename(editor, refs.a, "Renamed")
        _ = editor.contents.entries
        let made = editor.contents.rowsMade, refsMade = refRowsMade, revision = editor.file.revision(of: refs.pBoard)
        expect(editor.showBoard(refs.pBoard))
        expectEqual(editor.file.revision(of: refs.pBoard), revision, "the board is as it was left")
        expectEqual(editor.contents.entries.outline, ["→ Renamed", "pocket"])
        expectEqual(editor.contents.rowsMade, made, "its rows are taken back")
        expectEqual(refRowsMade, refsMade + 1, "and the ref's alone made again")
        expect(editor.showBoard(.root))
        expect(editor.showBoard(refs.pBoard))
        expectEqual(editor.contents.entries.outline, ["→ Renamed", "pocket"])
        expectEqual(refRowsMade, refsMade + 1, "nothing it reads changed since: going back makes nothing")
    },
    test("a shape deleted on another board, and its deletion undone from there, show on going back") {
        let refs = Refs()
        let editor = try refsEditor([PocketsPlugin()], file: refs.file)
        expect(editor.showBoard(refs.pBoard))
        _ = editor.contents.entries
        expect(editor.showBoard(.root))
        editor.transact("Delete") { $0.delete([refs.a]) }
        expect(editor.showBoard(refs.pBoard))
        expectEqual(editor.contents.entries.outline, ["→ nothing", "pocket"])
        editor.undo()
        expectEqual(editor.board, .root, "undo shows the deletion's board")
        expect(editor.showBoard(refs.pBoard))
        expectEqual(editor.contents.entries.outline, ["→ A", "pocket"])
    },
    test("on the board shown, a row that reads a shape on a board a deletion takes is made again, and so is it when that's undone") {
        let refs = Refs()
        let editor = try refsEditor([PocketsPlugin()], file: refs.file)
        expectEqual(editor.contents.entries.outline, ["A", "pocket", "→ W"])
        editor.transact("Delete") { $0.delete([refs.p]) }
        expectEqual(editor.contents.entries.outline, ["A", "→ nothing"], "W went with Q's board, under P's")
        editor.undo()
        expectEqual(editor.contents.entries.outline, ["A", "pocket", "→ W"])
    },
    test("a commit on a board that isn't shown remakes the rows that read what it changed, there and on going back") {
        let refs = Refs()
        let editor = try refsEditor([PocketsPlugin()], file: refs.file)
        expect(editor.showBoard(refs.pBoard))
        _ = editor.contents.entries
        expect(editor.showBoard(.root))
        _ = editor.contents.entries
        editor.transact(on: BoardID(owner: refs.q), "Rename") { $0.update(refs.w, as: Widget.self) { $0.props.name = "Far" } }
        expectEqual(editor.contents.entries.outline, ["A", "pocket", "→ Far"])
        expect(editor.showBoard(refs.pBoard))
        editor.transact(on: BoardID(owner: refs.q), "Rename") { $0.update(refs.w, as: Widget.self) { $0.props.name = "Farther" } }
        let made = editor.contents.rowsMade
        expect(editor.showBoard(.root))
        expectEqual(editor.contents.entries.outline, ["A", "pocket", "→ Farther"])
        expectEqual(editor.contents.rowsMade, made, "the root was taken back as it was left, its ref's row made again")
    },
    test("after a file put in place that shows another board, a row kept for a board as it was reads what the new file renamed") {
        let refs = Refs(), r = ShapeID()
        let file = CanvasFile(root: CanvasDocument(shapes: refs.file.root.shapes + [pocket(r)]), children: refs.file.children)
        let editor = try refsEditor([PocketsPlugin()], file: file)
        expect(editor.showBoard(refs.pBoard))
        expectEqual(editor.contents.entries.outline, ["→ A", "pocket"])
        expect(editor.showBoard(.root))
        _ = editor.contents.entries
        expect(editor.showBoard(BoardID(owner: r)))
        _ = editor.contents.entries
        // R gone, A renamed, P's board as it was: R's board can't be shown, so the root is.
        let replaced = CanvasFile(root: CanvasDocument(shapes: [widget(refs.a, "Renamed"), pocket(refs.p), ref(refs.toW, to: refs.w)]),
                                  children: editor.file.children)
        editor.replaceFile(with: replaced)
        expectEqual(editor.board, .root)
        expectEqual(editor.contents.entries.outline, ["Renamed", "pocket", "→ W"])
        let revision = editor.file.revision(of: refs.pBoard)
        expect(editor.showBoard(refs.pBoard))
        expectEqual(editor.file.revision(of: refs.pBoard), revision)
        expectEqual(editor.contents.entries.outline, ["→ Renamed", "pocket"])
    },
])
