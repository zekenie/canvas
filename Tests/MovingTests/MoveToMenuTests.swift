import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import ContextMenus
import CoreGraphics
import Selection
import TableOfContents
import TestKit

// Move To ▸ in the selection's menu, read with a secondary click and chosen as a click would: nothing goes on
// screen. It offers what a row dropped on that frame or subboard would be taken to (`Drop`), and moves there
// as that drop does.

@MainActor private func menuHarness(_ file: CanvasFile) throws -> EditorHarness {
    try droppingHarness(file)
}

@MainActor private func menu(_ h: EditorHarness, on id: ShapeID, selecting ids: [ShapeID]? = nil) throws -> NSMenu {
    h.editor.selectedShapeIDs = ids ?? [id]
    let frame = h.frame(of: id) ?? .zero
    return try require(h.secondaryClick(at: CGPoint(x: frame.midX, y: frame.midY)))
}

/// The lines of the Move To submenu, indented once, or nil if the menu has none.
@MainActor private func moveItems(_ menu: NSMenu) -> [String]? {
    let outline = menu.outline
    guard let at = outline.firstIndex(of: "Move To ▸") else { return nil }
    return Array(outline[(at + 1)...].prefix { $0.hasPrefix("  ") }).map { String($0.dropFirst(2)) }
}

@MainActor let moveToMenuTests = Suite("Move To ▸", [
    test("lists the frames and subboards the selection can go to, the nearest first; picking one is the drop's move, one step, Move; undo restores") {
        let near = ShapeID(), far = ShapeID(), p = ShapeID(), s = ShapeID()
        let h = try menuHarness(CanvasFile(root: board(box(s, 0, 0), corral(near, at(300, 0, 400, 400)), corral(far, at(3000, 0, 400, 400)),
                                                        pocket(p, 1200, 0)), children: [p: board()]))
        let items = try require(moveItems(try menu(h, on: s)))
        expectEqual(items.count, 3, "\(items)")
        let before = h.file
        try menu(h, on: s).choose("Move To", items[0])
        expectEqual(h.editor.holder(of: s), near, "the nearest")
        expectEqual(h.editor.undoHistory.undoName, "Move")
        let reference = try menuHarness(CanvasFile(root: board(box(s, 0, 0), corral(near, at(300, 0, 400, 400)), corral(far, at(3000, 0, 400, 400)),
                                                                pocket(p, 1200, 0)), children: [p: board()]))
        expect(reference.drop([s], on: near, .on))
        expectEqual(h.frame(of: s), reference.frame(of: s), "where the table of contents' drop puts it")
        h.editor.undo()
        try expectFile(h, before, "where it was")
    },
    test("a subboard is offered and takes the shape onto its board") {
        let p = ShapeID(), s = ShapeID()
        let h = try menuHarness(CanvasFile(root: board(box(s, 0, 0), pocket(p, 400, 0)), children: [p: board()]))
        let items = try require(moveItems(try menu(h, on: s)))
        expectEqual(items.count, 1)
        try menu(h, on: s).choose("Move To", items[0])
        expectEqual(h.editor.document[s], nil, "gone from the board shown")
        expect(h.file[BoardID(owner: p)][s] != nil, "on the subboard's board")
    },
    test("the enclosing board is offered from inside a subboard") {
        let p = ShapeID(), s = ShapeID()
        let h = try menuHarness(CanvasFile(root: board(pocket(p, 400, 0)), children: [p: board(box(s, 0, 0))]))
        expect(h.editor.showBoard(BoardID(owner: p)))
        let items = try require(moveItems(try menu(h, on: s)))
        expectEqual(items.count, 1, "\(items)")
        try menu(h, on: s).choose("Move To", items[0])
        expect(h.file[.root][s] != nil, "on the root board")
    },
    test("every enclosing board is offered with a title, not only the root") {
        let outer = ShapeID(), inner = ShapeID(), s = ShapeID()
        let h = try menuHarness(CanvasFile(root: board(pocket(outer, 400, 0)), children: [outer: board(pocket(inner, 400, 0)), inner: board(box(s, 0, 0))]))
        expect(h.editor.showBoard(BoardID(owner: inner)))
        let items = try require(moveItems(try menu(h, on: s)))
        expectEqual(items.count, 2, "\(items)")
        expect(items.allSatisfy { !$0.isEmpty }, "the board of the outer subboard is named by its owner, which is not on the board shown: \(items)")
    },
    test("several shapes move together, in one step") {
        let f = ShapeID(), a = ShapeID(), b = ShapeID()
        let h = try menuHarness(CanvasFile(root: board(box(a, 0, 0, size: 60), box(b, 100, 0, size: 60), corral(f, at(400, 0, 600, 400)))))
        let items = try require(moveItems(try menu(h, on: a, selecting: [a, b])))
        try menu(h, on: a, selecting: [a, b]).choose("Move To", items[0])
        expectEqual(h.editor.holder(of: a), f)
        expectEqual(h.editor.holder(of: b), f)
        expectEqual(h.editor.undoHistory.undoName, "Move")
        h.editor.undo()
        expectEqual(h.editor.holder(of: a), nil)
        expectEqual(h.editor.holder(of: b), nil)
    },
    test("a place the shape can't go is not offered: the frame it is in, one too small, itself, one it holds, a locked one") {
        let big = ShapeID(), small = ShapeID(), inner = ShapeID(), s = ShapeID(), locked = ShapeID()
        let h = try menuHarness(CanvasFile(root: board(corral(big, at(0, 0, 800, 800)), corral(inner, at(500, 500, 100, 100), in: big),
                                                        box(s, 50, 50, in: big), corral(small, at(2000, 0, 50, 50)), corral(locked, at(3000, 0, 400, 400)))))
        h.freeze([locked])
        let outline = try require(moveItems(try menu(h, on: s)))
        expectEqual(outline.count, 1, "only the inner frame is left: \(outline)")
        // The frame holding the shape goes nowhere it holds.
        expectEqual(moveItems(try menu(h, on: big)).map(\.count) ?? 0, 0, "a frame is not offered itself or what it holds")
    },
    test("at most twenty places") {
        var records = [box(ShapeID(), 0, 0)]
        let s = records[0].id
        for i in 0..<25 { records.append(corral(ShapeID(), at(300 + CGFloat(i) * 500, 0, 400, 400))) }
        let h = try menuHarness(CanvasFile(root: CanvasDocument(shapes: records)))
        expectEqual(try require(moveItems(try menu(h, on: s))).count, 20)
    },
    test("no submenu where nothing admits the selection") {
        let s = ShapeID()
        let h = try menuHarness(CanvasFile(root: board(box(s, 0, 0))))
        expectEqual(moveItems(try menu(h, on: s)), nil)
    },
])
