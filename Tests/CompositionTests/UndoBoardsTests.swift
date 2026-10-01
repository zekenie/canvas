import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import Composition
import CoreGraphics
import Foundation
import LanguageModels
import Mentions
import StickyNotes
import SwiftUI
import TestKit

// Undo as the app counts it, on a file of several boards (CanvasTesting's pockets): one history for
// the file, whatever board is shown.

/// A board document of the shipped plugins and pockets, its clipboard on `pasteboard`, holding `file`
/// (put in place, so it's unedited).
@MainActor private func pocketsDocument(_ file: CanvasFile? = nil, pasteboard: NSPasteboard) throws -> BoardDocument {
    BoardDocument.configuration = BoardConfiguration(registry: try Registry(plugins: ShippedPlugins.plugins(pasteboard: pasteboard, model: ScriptedLanguageModel()) + [PocketsPlugin()])) { _ in
        AnyView(EmptyView())
    }
    let board = BoardDocument()
    if let file { board.editor.replaceFile(with: file) }
    return board
}

/// Note N on the root, beside pocket P; note M on P's board.
@MainActor private func noteAndPocket() -> (file: CanvasFile, n: ShapeID, p: ShapeID, m: ShapeID) {
    let n = ShapeRecord(StickyNote(frame: CGRect(x: 0, y: 0, width: 200, height: 200), text: "Outside"))
    let p = ShapeRecord(Pocket(CGRect(x: 300, y: 0, width: 160, height: 100)))
    let m = ShapeRecord(StickyNote(frame: CGRect(x: 0, y: 0, width: 200, height: 200), text: "Inside"))
    let file = CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(n), AnyShapeRecord(p)]),
                          children: [p.id: CanvasDocument(shapes: [AnyShapeRecord(m)])])
    return (file, n.id, p.id, m.id)
}

@MainActor private func move(_ board: BoardDocument, _ id: ShapeID, to x: CGFloat) {
    board.editor.transact("Move") { $0.update(id, as: StickyNote.self) { $0.frame.origin.x = x } }
}

@MainActor let undoBoardsTests = Suite("Undo across boards, as shipped", [
    test("the file's changes count by its steps on every board: undoing back to what was saved reads unedited, whatever board it shows") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let (file, n, p, m) = noteAndPocket()
        let board = try pocketsDocument(file, pasteboard: pasteboard)
        let url = scratchURL("boards.canvasboard")
        defer { try? FileManager.default.removeItem(at: url) }
        try save(board, to: url)
        expect(!board.isDocumentEdited)
        let saved = try board.data(ofType: boardType)

        move(board, n, to: 50)
        board.editor.showBoard(BoardID(owner: p))
        move(board, m, to: 50)
        board.editor.undo()
        expect(board.isDocumentEdited, "the root's step is still done")
        board.editor.undo()
        expectEqual(board.editor.board, .root)
        expect(!board.isDocumentEdited, "back to what was saved, from the pocket's board")
        board.editor.showBoard(BoardID(owner: p))
        board.editor.redo()
        expectEqual(board.editor.board, .root)
        expect(board.isDocumentEdited)
        board.editor.redo()
        expectEqual(board.editor.board, BoardID(owner: p))

        try save(board, to: url)
        expect(!board.isDocumentEdited)
        board.editor.undo()
        board.editor.undo()
        expectEqual(board.editor.board, .root)
        expect(board.isDocumentEdited, "past what was saved")
        board.editor.redo()
        board.editor.redo()
        expect(!board.isDocumentEdited, "and back to it, on the pocket's board")

        board.editor.undo()
        board.editor.undo()
        expectEqual(try board.data(ofType: boardType), saved, "undone, the file as it was first saved, byte for byte")
        board.editor.showBoard(.root)
        board.editor.transact("Delete") { $0.delete([p]) }
        expectEqual(board.editor.file.children, [:])
        board.editor.undo()
        expectEqual(try board.data(ofType: boardType), saved, "the pocket's board back with it")
        board.close()
    },
    test("Delete Hidden Shapes on several boards is one step that edits the file, and undoing it, from a board inside, writes the file as it was") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let p = ShapeID(), inside = ShapeID(), gadget = ShapeID(), deeper = ShapeID(), stray = ShapeID()
        func record(_ id: ShapeID, _ kind: String, _ index: String) -> String {
            #"{ "id" : "\#(id)", "index" : "\#(index)", "kind" : "\#(kind)", "props" : { "frame" : [[0, 0], [10, 10]] } }"#
        }
        // A gadget (no plugin has the kind) on the root and one on P's board.
        let json = """
        { "format" : 4, "versions" : { "kinds" : { "sticky-note" : 3, "pocket" : 0 } },
          "shapes" : [ \(record(p, "pocket", "a0")), \(record(stray, "gadget", "a1")) ],
          "boards" : { "\(p)" : { "shapes" : [ \(record(inside, "sticky-note", "a0")), \(record(gadget, "gadget", "a1")),
                                               \(record(deeper, "sticky-note", "a2")) ] } } }
        """
        let board = try pocketsDocument(pasteboard: pasteboard)
        try board.read(from: Data(json.utf8), ofType: boardType)
        expectEqual(Set(board.loadReport.keptAside.map(\.id)), [stray, gadget])
        let before = try board.data(ofType: boardType), file = board.editor.file
        expect(!board.isDocumentEdited)

        board.deleteHiddenShapes()
        expect(board.isDocumentEdited, "though the board shown is where it was")
        expectEqual(board.editor.undoHistory.undoName, "Delete Hidden Shapes")
        expectEqual(board.editor.file[BoardID(owner: p)].shapes.map(\.id), [inside, deeper])
        board.editor.undo()
        expect(!board.isDocumentEdited)
        expectEqual(board.editor.file, file)
        expectEqual(try board.data(ofType: boardType), before)

        // Shown from inside P, the root is reached whole.
        board.editor.showBoard(BoardID(owner: p))
        board.editor.redo()
        expectEqual(board.editor.board, .root, "the step was made on the root")
        board.editor.showBoard(BoardID(owner: p))
        board.editor.undo()
        board.editor.showBoard(BoardID(owner: p))
        board.deleteHiddenShapes()
        expectEqual(board.editor.document.shapes.map(\.id), [inside, deeper])
        expectEqual(board.editor.file.root.shapes.map(\.id), [p])
        board.editor.showBoard(.root)
        board.editor.undo()
        expectEqual(board.editor.board, BoardID(owner: p))
        expectEqual(board.editor.file, file)
        expectEqual(try board.data(ofType: boardType), before)
        expect(!board.isDocumentEdited)
        board.close()
    },
])
