import Adornments
import AppKit
import Boards
@_spi(Host) import Canvas
import CanvasTesting
import ContextMenus
import CoreGraphics
import Selection
import SwiftUI
import TableOfContents
import TestKit
import Titles
import Topology

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

/// A harness on `file` whose corrals and pockets have titles (which name their rows too), with the containment tree a path
/// is read from: what tells places called alike apart.
@MainActor private func titledHarness(_ file: CanvasFile) throws -> EditorHarness {
    let titles = Contributor(id: "fixture-titles") { registrar in
        registrar.title(Corral.self)
        registrar.title(Pocket.self)
    }
    return try EditorHarness(plugins: [SelectionPlugin()] + movingPlugins(log: RefusalLog(), [TopologyPlugin(), AdornmentsPlugin(), TitlesPlugin(), titles]), file: file)
}

/// `record`, called `title`.
@MainActor private func titled(_ record: AnyShapeRecord, _ title: String) -> AnyShapeRecord {
    var record = record
    record[TitleProperty.self] = title
    return record
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
    test("a subboard is offered and takes the shape onto its board, where the window goes after it, the shape selected there") {
        let p = ShapeID(), s = ShapeID()
        let h = try menuHarness(CanvasFile(root: board(box(s, 0, 0), pocket(p, 400, 0)), children: [p: board()]))
        let items = try require(moveItems(try menu(h, on: s)))
        expectEqual(items.count, 1)
        try menu(h, on: s).choose("Move To", items[0])
        expect(h.file[BoardID(owner: p)][s] != nil, "on the subboard's board")
        expectEqual(h.editor.board, BoardID(owner: p))
        expectEqual(h.editor.selectedShapeIDs, [s])
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
    test("a place with no title is called what every path calls it, the placeholder its row shows, not its kind's name") {
        let s = ShapeID(), p = ShapeID()
        // A row with no text and a placeholder, as a shipped subboard's is, and the board's placeholder, as Boards keeps it.
        let placeholders = Contributor(id: "pocket-boards") { registrar in
            registrar.opensBoard(Pocket.self, placeholder: "Untitled Pocket", systemImage: "folder")
            registrar.contentsRow(Pocket.self) { _ in ContentsLabel("", placeholder: "Untitled Pocket") }
        }
        let h = try EditorHarness(plugins: [SelectionPlugin()] + movingPlugins(log: RefusalLog(), [BoardsPlugin(), placeholders]),
                                  file: CanvasFile(root: board(box(s, 0, 0), pocket(p, 400, 0)), children: [p: board()]))
        expectEqual(try require(moveItems(try menu(h, on: s))), ["Untitled Pocket"])
    },
    test("places called alike say their path, the frames each is inside, outermost first; places called apart keep their names") {
        // A frame is called "Pen" and its width.
        let s = ShapeID(), a = ShapeID(), b = ShapeID(), a1 = ShapeID(), b1 = ShapeID(), solo = ShapeID()
        let file = CanvasFile(root: board(box(s, 0, 0, size: 60), titled(corral(a, at(1000, 0, 800, 800)), "Pen 800"), titled(corral(b, at(2000, 0, 600, 600)), "Pen 600"),
                                          titled(corral(a1, at(1100, 100, 300, 300), in: a), "Pen 300"), titled(corral(b1, at(2100, 100, 300, 300), in: b), "Pen 300"),
                                          titled(corral(solo, at(3000, 0, 400, 400)), "Pen 400")))
        let h = try titledHarness(file)
        let items = try require(moveItems(try menu(h, on: s)))
        expectEqual(items, ["Pen 800 › Pen 300", "Pen 800", "Pen 600 › Pen 300", "Pen 600", "Pen 400"], "the two inside frames are alike; the rest are not, and keep their names")
        try menu(h, on: s).choose("Move To", items[2])
        expectEqual(h.editor.holder(of: s), b1, "the one under Pen 600")
    },
    test("a frame two subboards deep and the board of the first, called alike, are told apart by their paths") {
        let first = ShapeID(), second = ShapeID(), s = ShapeID(), frame = ShapeID()
        let file = CanvasFile(root: board(titled(pocket(first, 400, 0), "Pen")),
                              children: [first: board(titled(pocket(second, 400, 0), "Pen")),
                                         second: board(box(s, 0, 0, size: 60), titled(corral(frame, at(300, 0, 500, 500)), "Pen"))])
        let h = try titledHarness(file)
        expect(h.editor.showBoard(BoardID(owner: second)))
        let items = try require(moveItems(try menu(h, on: s)))
        // The frame, the first pocket's board (named by its owner) and the root: the frame and the first board are "Pen".
        expectEqual(items, ["Pen › Pen › Pen", "Pen", "Board"], "the frame is in the second pocket, which is on the first's board; the first board's owner is on the root")
        try menu(h, on: s).choose("Move To", items[1])
        expect(h.file[BoardID(owner: first)][s] != nil, "the board of the first pocket")
    },

    test("/move-to takes exactly the places the menu lists for the shapes selected, a block's: both refuse a corral too small for the box around them, a locked one, one that goes with them, and the one they are in") {
        let s = ShapeID(), t = ShapeID(), near = ShapeID(), small = ShapeID(), locked = ShapeID(), holder = ShapeID(), p = ShapeID(), moving = ShapeID()
        let h = try titledHarness(CanvasFile(root: board(box(s, 0, 0), box(t, 200, 0), titled(corral(near, at(0, 400, 600, 500)), "Near"),
                                                         titled(corral(small, at(800, 400, 250, 500)), "Small"), titled(corral(locked, at(1200, 400, 600, 500)), "Locked"),
                                                         titled(corral(holder, at(0, 1100, 800, 600)), "Holder"), box(moving, 100, 1200, in: holder),
                                                         titled(pocket(p, 2000, 0), "Plans")),
                                             children: [p: board()]))
        h.freeze([locked])
        let places: [(title: String, id: ShapeID)] = [("Near", near), ("Small", small), ("Locked", locked), ("Holder", holder), ("Plans", p)]
        for selection in [[s, t], [s, moving], [t], [moving]] {
            let listed = Set(moveItems(try menu(h, on: selection[0], selecting: selection)) ?? [])
            let taken = Set(places.filter { h.admits("move-to", onSelection: selection, $0.id) }.map(\.title))
            expectEqual(listed, taken, "the shapes \(selection.count) selected from \(String(describing: h.frame(of: selection[0])?.origin))")
        }
        expectEqual(Set(moveItems(try menu(h, on: s, selecting: [s, t])) ?? []), ["Near", "Holder", "Plans"], "not Small (250 across, the block 300), not Locked")
        expectEqual(Set(moveItems(try menu(h, on: moving, selecting: [moving])) ?? []), ["Near", "Small", "Plans"], "one box fits Small; not Holder, which holds it, nor Locked")
    },
])
