import Canvas
import CanvasTesting
import CoreGraphics
import Selection
import TableOfContents
import TestKit

// A board's outline (`outline(of:)`): its rows as the list shows them there, read from any board,
// for a view of a board that isn't shown (the path's crumb menus).

/// Widgets A and B, a pin on A, and a pocket on the root; widgets C and D and a pin on C on the
/// pocket's board.
@MainActor func pinnedPocketFile() -> (file: CanvasFile, pocket: ShapeID, a: ShapeID, c: ShapeID) {
    let widget = { (x: Int, name: String) in ShapeRecord(Widget(CGRect(x: x, y: 0, width: 100, height: 60), name: name)) }
    let a = widget(0, "A"), b = widget(150, "B"), c = widget(0, "C"), d = widget(150, "D")
    let pocket = ShapeRecord(Pocket(CGRect(x: 0, y: 200, width: 100, height: 60)))
    let file = CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(a), AnyShapeRecord(ShapeRecord(Pin("on A", on: a.id))),
                                                        AnyShapeRecord(b), AnyShapeRecord(pocket)]),
                          children: [pocket.id: CanvasDocument(shapes: [AnyShapeRecord(c), AnyShapeRecord(ShapeRecord(Pin("on C", on: c.id))),
                                                                       AnyShapeRecord(d)])])
    return (file, pocket.id, a.id, c.id)
}

@MainActor let outlineTests = Suite("Table of contents: a board's outline", [
    test("a board's outline is the rows the list shows there, nested alike, read from any board") {
        let (file, pocket, _, _) = pinnedPocketFile()
        let editor = try contentsEditor([PocketsPlugin()], file: file)
        let inside = BoardID(owner: pocket)
        let rootRows = editor.contents.entries.outline
        expectEqual(rootRows, ["A", "  on A", "B", "pocket"])
        expectEqual(editor.contents.outline(of: inside).outline, ["C", "  on C", "D"], "the pocket's, from the root")
        expectEqual(editor.contents.outline(of: .root).outline, rootRows, "the board shown's too")
        editor.showBoard(inside)
        expectEqual(editor.contents.outline(of: inside).outline, editor.contents.entries.outline)
        expectEqual(editor.contents.outline(of: .root).outline, rootRows, "the root's, from the pocket")
        editor.add(Widget(name: "E"))
        expectEqual(editor.contents.outline(of: inside).outline, ["C", "  on C", "D", "E"], "the board shown's, as each commit leaves it")
    },
    test("it lists every shape of the board, whatever is selected, and leaves the marks out") {
        flag([])
        let (file, pocket, a, c) = pinnedPocketFile()
        let editor = try contentsEditor([PocketsPlugin(), flags], file: file)
        flag([a, c])
        editor.transact { $0.update(a, as: Widget.self) { $0.props.count = 1 } }     // so the flags are read
        editor.selectedShapeIDs = [a]
        expectEqual(editor.contents.entries.outline, ["A", "  on A", "B", "pocket"], "the list lists every shape, the selection too")
        expectEqual(editor.contents.entries.marks.first, ["Flagged"])
        expectEqual(editor.contents.outline(of: .root).outline, ["A", "  on A", "B", "pocket"])
        expect(editor.contents.outline(of: .root).marks.allSatisfy(\.isEmpty), "no marks")
        expect(editor.contents.outline(of: BoardID(owner: pocket)).marks.allSatisfy(\.isEmpty))
        flag([])
    },
    test("kept while its board is as it was: reading it again, or after a commit elsewhere, makes no row; a change on it makes them again") {
        let (file, pocket, a, _) = pinnedPocketFile()
        let editor = try contentsEditor([PocketsPlugin()], file: file)
        editor.showBoard(BoardID(owner: pocket))
        _ = editor.contents.entries
        _ = editor.contents.outline(of: .root)
        let made = editor.contents.rowsMade
        _ = editor.contents.outline(of: .root)
        editor.add(Widget(name: "E"))
        expectEqual(editor.contents.outline(of: .root).outline, ["A", "  on A", "B", "pocket"])
        _ = editor.contents.entries
        expectEqual(editor.contents.rowsMade, made + 1, "E's row, on the board shown, and none of the root's")
        editor.transact(on: .root, "Rename") { $0.update(a, as: Widget.self) { $0.props.name = "Apple" } }
        expectEqual(editor.contents.outline(of: .root).outline, ["Apple", "  on A", "B", "pocket"])
        expectEqual(editor.contents.rowsMade, made + 1 + 4, "the root's rows, made again")
    },
    test("a row that reads more than its shape is made again after a commit that did more than move shapes, so it shows what it reads now") {
        let widget = ShapeRecord(Widget(CGRect(x: 0, y: 0, width: 100, height: 60), name: "W"))
        let pocket = ShapeRecord(Pocket(CGRect(x: 0, y: 200, width: 100, height: 60)))
        let file = CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(ShapeRecord(Ref(to: widget.id))), AnyShapeRecord(pocket)]),
                              children: [pocket.id: CanvasDocument(shapes: [AnyShapeRecord(widget)])])
        let editor = try refsEditor([PocketsPlugin()], file: file)
        editor.showBoard(BoardID(owner: pocket.id))
        expectEqual(editor.contents.outline(of: .root).outline, ["→ W", "pocket"])
        editor.transact { $0.update(widget.id, as: Widget.self) { $0.props.name = "Walnut" } }
        expectEqual(editor.contents.outline(of: .root).outline, ["→ Walnut", "pocket"], "renamed on the board shown")
        let made = refRowsMade
        editor.transact { $0.update(widget.id, as: Widget.self) { $0.props.count = 3 } }
        expectEqual(editor.contents.outline(of: .root).outline, ["→ Walnut", "pocket"])
        expectEqual(refRowsMade, made + 1, "made again, and kept: its label is the same")
        editor.transact { $0.translate([widget.id], by: CGPoint(x: 10, y: 0)) }
        expectEqual(editor.contents.outline(of: .root).outline, ["→ Walnut", "pocket"])
        expectEqual(refRowsMade, made + 1, "a move names nothing anew: not made again")
        editor.transact(on: .root, "Move") { $0.translate([pocket.id], by: CGPoint(x: 0, y: 10)) }
        _ = editor.contents.outline(of: .root)
        expectEqual(refRowsMade, made + 2, "a move on its own board, which changes its revision, makes all its rows again")
    },
    test("an outline is kept only while its board is on the path: gone off it, it's made again") {
        let (file, pocket, _, _) = pinnedPocketFile()
        let editor = try contentsEditor([PocketsPlugin()], file: file)
        let inside = BoardID(owner: pocket)
        _ = editor.contents.outline(of: inside)
        let made = editor.contents.rowsMade
        _ = editor.contents.outline(of: inside)
        expectEqual(editor.contents.rowsMade, made, "kept")
        editor.showBoard(inside)
        editor.showBoard(.root)
        _ = editor.contents.entries
        let back = editor.contents.rowsMade
        _ = editor.contents.outline(of: inside)
        expectEqual(editor.contents.rowsMade, back + 3, "the pocket's board was left off the path")
    },
    test("a board with no rows has an empty outline") {
        let (file, pocket, _, _) = pinnedPocketFile()
        let editor = try contentsEditor([PocketsPlugin()], file: file)
        expectEqual(editor.contents.outline(of: BoardID(owner: ShapeID())).outline, [], "a board nobody owns")
        let inside = Set(editor.contents(of: BoardID(owner: pocket)).shapes.map(\.id))
        editor.transact(on: BoardID(owner: pocket), "Clear") { $0.delete(inside) }
        expectEqual(editor.contents.outline(of: BoardID(owner: pocket)).outline, [])
    },
])
