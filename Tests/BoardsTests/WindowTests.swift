import AppKit
import Boards
import Canvas
import CanvasTesting
import CoreGraphics
import Selection
import SwiftUI
import TableOfContents
import TestKit

@MainActor func windowEditor(_ file: CanvasFile, _ more: [any CanvasPlugin] = []) throws -> CanvasEditor {
    try CanvasEditor(registry: Registry(plugins: boardsPlugins(more)), file: file, scheduler: TaskScheduler())
}

@MainActor let windowTests = Suite("The path in a window", [
    test("hidden on the root; below it, the root and each board above are buttons, and the board shown isn't") {
        let nest = Nest()
        let editor = try windowEditor(nest.file)
        let path = PathWindow(editor)
        expectEqual(path.buttons, [])
        expect(!path.drawsSomething, "nothing drawn")
        expect(editor.showBoard(nest.dBoard))
        path.window.spin { path.buttons.count == 1 }
        expect(path.drawsSomething)
        expect(editor.showBoard(nest.pBoard))
        path.window.spin { path.buttons.count == 2 }
        expectEqual(path.buttons.count, 2, "the root and D's board; P's, shown, isn't a button")
        expect(path.folded == nil)
    },
    test("a crumb shows its board and selects there the shape the path came through, one step back") {
        let nest = Nest()
        let editor = try windowEditor(nest.file)
        let path = PathWindow(editor)
        expect(editor.showBoard(nest.dBoard))
        expect(editor.showBoard(nest.pBoard))
        path.window.spin { path.buttons.count == 2 }
        try path.click(0)
        expectEqual(editor.board, .root)
        expectEqual(editor.selectedShapeIDs, [nest.d], "the drawer, not the pocket")
        path.window.spin { path.buttons.isEmpty }
        editor.goBack()
        expectEqual(editor.board, nest.pBoard)
        path.window.spin { path.buttons.count == 2 }
        try path.click(1)
        expectEqual(editor.board, nest.dBoard)
        expectEqual(editor.selectedShapeIDs, [nest.p])
    },
    test("past four crumbs, \"…\" holds the ones between") {
        let (h, ids) = try chainHarness(depth: 5)
        let editor = try windowEditor(h.editor.file)
        let path = PathWindow(editor, rootName: "")
        for id in ids { expect(editor.showBoard(BoardID(owner: id))) }
        path.window.spin { path.buttons.count == 2 }
        expectEqual(path.buttons.count, 2, "the root and the parent")
        expect(path.folded != nil)
        try path.click(1)
        expectEqual(editor.board, BoardID(owner: ids[3]))
        expectEqual(editor.selectedShapeIDs, [ids[4]])
    },
    test("a crumb is as wide as its name, on one line, up to 180 points: a longer one is cut short, a short one isn't widened") {
        let long = String(repeating: "Cupboard ", count: 25)
        for (shown, which) in [(true, "the board shown"), (false, "a board above")] {
            let a = try pill(named: "A", shown: shown), ab = try pill(named: "AB", shown: shown), cut = try pill(named: long, shown: shown)
            expect(ab.width > a.width && ab.width - a.width < 20, "\(which): a short name as wide as it is: \(a.width), then \(ab.width)")
            expect(cut.width - a.width > 120 && cut.width - a.width <= 180, "\(which): a long name cut short at 180 points: \(a.width), then \(cut.width)")
            expect(a.height > 0 && cut.height == a.height, "\(which): on one line: \(a.height), then \(cut.height)")
        }
    },
    test("the path redraws when another board is shown or its names change, never for a commit on the board shown") {
        let nest = Nest()
        let editor = try windowEditor(nest.file)
        let path = PathWindow(editor)
        expect(editor.showBoard(nest.dBoard))
        expect(editor.showBoard(nest.pBoard))
        path.window.spin { path.buttons.count == 2 }
        path.window.settle()
        let drawn = path.redrawn
        for step in 1...5 {
            editor.transact("Move") { $0.translate([nest.b], by: CGPoint(x: CGFloat(step), y: 0)) }
            path.window.settle()
        }
        expectEqual(path.redrawn, drawn, "five commits on the board shown")
        editor.goToEnclosingBoard()
        path.window.spin { path.redrawn > drawn }
        path.window.spin { path.buttons.count == 1 }
    },
])

/// The path's window over the nest, with the table of contents, inside P's board (root › D › P),
/// its crumbs in place.
@MainActor func menuWindow(_ nest: Nest, size: CGSize = CGSize(width: 900, height: 500)) throws -> PathWindow {
    let editor = try windowEditor(nest.file, [TableOfContentsPlugin()])
    let path = PathWindow(editor, size: size)
    expect(editor.showBoard(nest.dBoard))
    expect(editor.showBoard(nest.pBoard))
    path.window.spin { path.buttons.count == 2 }
    return path
}

@MainActor let menuWindowTests = Suite("The path's menus in a window", [
    test("the pointer on a crumb shows its menu below it, lined up with it: its board's rows, each a button that goes to its shape") {
        let nest = Nest()
        let path = try menuWindow(nest)
        let crumbs = try require(path.editor.boardCrumbs)
        let crumb = path.frame(of: try require(path.buttons.first))
        crumbs.pointerEntered(crumb: .root)
        path.window.spin { path.menuButtons.count == 2 }
        let rows = path.menuButtons.map(path.frame(of:))
        expectEqual(rows.count, 2, "the root's: A, and D")
        let first = try require(rows.first)
        expect(first.minY > crumb.maxY + 6 && first.minY < crumb.maxY + 20, "6 points below the crumb, and the menu's padding: \(crumb), \(first)")
        expect(first.minX >= crumb.minX && first.minX < crumb.minX + 30, "lined up with it: \(crumb), \(first)")
        expect(rows[1].minY >= first.maxY - 0.5, "one row under the other: \(rows)")
        try require(path.menuButtons.first).performClick(nil)
        path.window.spin { path.editor.board == .root }
        expectEqual(path.editor.selectedShapeIDs, [nest.a], "A, gone to on the root")
        expectEqual(crumbs.openMenu, nil)
    },
    test("the board shown's crumb has a menu too, its own shapes, and a menu stays inside the canvas") {
        let nest = Nest()
        let path = try menuWindow(nest, size: CGSize(width: 420, height: 300))
        let crumbs = try require(path.editor.boardCrumbs)
        crumbs.pointerEntered(crumb: nest.pBoard)
        path.window.spin { path.menuButtons.count == 2 }
        let rows = path.menuButtons.map(path.frame(of:))
        expect(rows.allSatisfy { $0.maxX <= 420 - 8 && $0.minX >= 8 }, "inside the canvas: \(rows)")
        try require(path.menuButtons.first).performClick(nil)
        path.window.settle()
        expectEqual(path.editor.board, nest.pBoard, "B is on the board shown")
        expectEqual(path.editor.selectedShapeIDs, [nest.b])
        expectEqual(crumbs.openMenu, nil)
    },
])

/// Opens the real "…" menu, which shows on screen for a moment, so it runs only with
/// TEST_UI_MENUS=1 (see main.swift). What it holds is tested headlessly in `pathTests`.
@MainActor let menuTests = Suite("The path's menu, on screen", [
    test("\"…\" lists the boards it folds, root side first, and choosing one goes up to it") {
        let (h, ids) = try chainHarness(depth: 5)
        for (id, name) in zip(ids, ["A", "B", "C", "D", "E"]) {
            _ = h.editor.showBoard(h.editor.file.board(containing: id)!)
            h.name(id, name)
        }
        let named = try windowEditor(h.editor.file)
        let path = PathWindow(named)
        for id in ids { expect(named.showBoard(BoardID(owner: id))) }
        path.window.spin { path.folded != nil }
        let button = try require(path.folded)
        RunLoop.main.add(Timer(timeInterval: 0, repeats: false) { _ in
            MainActor.assumeIsolated { button.menu?.cancelTracking() }
        }, forMode: .common)
        button.performClick(nil)
        let menu = try require(button.menu)
        expectEqual(menu.items.map(\.title).filter { !$0.isEmpty && $0 != "…" }, ["A", "B", "C"])
        menu.performActionForItem(at: menu.indexOfItem(withTitle: "B"))
        path.window.settle()
        expectEqual(named.board, BoardID(owner: ids[1]))
        expectEqual(named.selectedShapeIDs, [ids[2]])
    },
])

/// The path's pill as the app lays it out, over a canvas 900 points wide, with D named `name` and
/// D's board shown (`shown`, so D's crumb is the board shown) or P's (D's a button): its size, in
/// points, from where it's drawn.
@MainActor private func pill(named name: String, shown: Bool) throws -> CGSize {
    let nest = Nest()
    let h = try nestHarness(nest)
    h.name(nest.d, name)
    let editor = try windowEditor(h.editor.file)
    let bounds = CGRect(x: 0, y: 0, width: 900, height: 120)
    let window = NSWindow(contentRect: bounds, styleMask: [.titled], backing: .buffered, defer: false)
    let hosting = NSHostingView(rootView: BoardPath(editor: editor, rootName: "Plans"))
    hosting.sizingOptions = []
    hosting.frame = bounds
    let root = NSView(frame: bounds)
    root.addSubview(hosting)
    window.contentView = root
    expect(editor.showBoard(nest.dBoard))
    if !shown { expect(editor.showBoard(nest.pBoard)) }
    window.settle()
    let bitmap = snapshot(hosting)
    let background = pixel(bitmap, at: CGPoint(x: 2, y: 2))
    var xs: [Int] = [], ys: [Int] = []
    for y in 0..<Int(bounds.height) {
        let row = (0..<Int(bounds.width)).filter { pixel(bitmap, at: CGPoint(x: CGFloat($0), y: CGFloat(y))) != background }
        if let first = row.first, let last = row.last {
            xs += [first, last]
            ys.append(y)
        }
    }
    guard let left = xs.min(), let right = xs.max(), let top = ys.min(), let bottom = ys.max() else { return .zero }
    return CGSize(width: right - left + 1, height: bottom - top + 1)
}
