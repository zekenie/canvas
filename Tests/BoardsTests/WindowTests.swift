import AppKit
import Boards
@_spi(Host) import Canvas
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
        let fold = path.frame(of: try require(path.folded, "\"…\", a button as the crumbs are"))
        expect(fold.minX > path.frame(of: path.buttons[0]).maxX && fold.maxX < path.frame(of: path.buttons[1]).minX, "between them")
        try path.click(1)
        expectEqual(editor.board, BoardID(owner: ids[3]))
        expectEqual(editor.selectedShapeIDs, [ids[4]])
    },
    test("\"…\" is drawn as the boards above around it are, in their gray, on a light pill and a dark one") {
        let (h, ids) = try chainHarness(depth: 5)
        let editor = try windowEditor(h.editor.file)
        let path = PathWindow(editor, rootName: "R")
        for id in ids { expect(editor.showBoard(BoardID(owner: id))) }
        path.window.spin { path.buttons.count == 2 && path.folded != nil }
        for (appearance, name) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            path.window.appearance = NSAppearance(named: appearance)
            path.window.settle()
            let image = snapshot(path.hosting), pixels = DeviceRGBPixels(image)
            let scale = CGFloat(image.pixelsWide) / path.hosting.bounds.width
            /// How strongly a view's ink stands out from the pill under it (its frame's commonest
            /// gray): 0 none, 1 black on white. On a dark pill the ink is light, so darkness can't say.
            @MainActor func ink(_ view: NSView) -> CGFloat {
                let frame = path.frame(of: view)
                var grays: [CGFloat] = []
                for y in Int(frame.minY * scale)..<Int(frame.maxY * scale) {
                    for x in Int(frame.minX * scale)..<Int(frame.maxX * scale) { grays.append(pixels[x, y]?.gray ?? 0) }
                }
                let buckets = Dictionary(grouping: grays) { ($0 * 32).rounded() }
                let pill = buckets.max { $0.value.count < $1.value.count }?.value.first ?? 0
                return grays.map { abs($0 - pill) }.max() ?? 0
            }
            let fold = ink(try require(path.folded)), root = ink(try require(path.buttons.first)), parent = ink(try require(path.buttons.last))
            expect(root > 0.2, "\(name): the root's crumb shows: \(root)")
            // A pull-down's "…" (a SwiftUI Menu) drew apart from them, 0.07 lighter on a light pill and
            // 0.1 on a dark one even in tertiary: it takes no style from around it.
            expect(abs(fold - root) < 0.02 && abs(fold - parent) < 0.02, "\(name): the crumbs' ink (\(root), \(parent)): \(fold)")
        }
    },
    test("the pill reaches exactly as far down as it says it covers (coveredHeight, what fits leave clear), with its \"…\" or without") {
        let nest = Nest()
        let (h, ids) = try chainHarness(depth: 5)
        for (editor, boards, folds) in [(try windowEditor(nest.file), [nest.dBoard, nest.pBoard], false),
                                        (try windowEditor(h.editor.file), ids.map { BoardID(owner: $0) }, true)] {
            let path = PathWindow(editor)
            for board in boards { expect(editor.showBoard(board)) }
            path.window.spin { !path.buttons.isEmpty && (path.folded != nil) == folds }
            path.window.settle()
            let covered = BoardPath.coveredHeight(on: editor.board)
            expect(covered > 20 && covered < 60, "\(covered)")
            let bitmap = snapshot(path.hosting)
            let background = pixel(bitmap, at: CGPoint(x: 1, y: path.hosting.bounds.height - 1))
            @MainActor func drawn(inRow y: CGFloat) -> Bool {
                stride(from: 0, to: path.hosting.bounds.width, by: 1).contains { pixel(bitmap, at: CGPoint(x: $0 + 0.5, y: y + 0.5)) != background }
            }
            let below = stride(from: covered, to: path.hosting.bounds.height, by: 1).filter(drawn(inRow:))
            expectEqual(below, [], "\(folds ? "folded" : "two crumbs"): nothing drawn from \(covered) points down")
            expect(drawn(inRow: covered - 1), "\(folds ? "folded" : "two crumbs"): the pill reaches the row above it")
        }
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
    test("the lock is drawn after the name of the crumb where the read-only part starts, once: not after the crumbs below it, nor on a path with none") {
        let nest = Nest()
        let h = try nestHarness(nest, [FreezingPlugin()])
        /// The path's pill over P's board (root › D › P) when `frozen` is frozen on its board, as drawn, and D's crumb button.
        @MainActor func measure(freezing frozen: [(ShapeID, BoardID)]) throws -> (pill: CGSize, crumb: CGFloat) {
            let file = h.editor.file
            let editor = try windowEditor(file, [FreezingPlugin()])
            for (shape, board) in frozen { editor.transact(on: board, "Freeze") { $0.update(shape) { $0[Frozen.self] = true } } }
            let path = PathWindow(editor)
            expect(editor.showBoard(nest.dBoard))
            expect(editor.showBoard(nest.pBoard))
            path.window.spin { path.buttons.count == 2 }
            path.window.settle()
            return (drawnSize(of: path.hosting), path.frame(of: path.buttons[1]).width)
        }
        let plain = try measure(freezing: [])
        let top = try measure(freezing: [(nest.d, .root)])              // D's board is read-only, and P's under it
        let below = try measure(freezing: [(nest.p, nest.dBoard)])       // only P's
        expect(top.crumb > plain.crumb + 5 && top.crumb < plain.crumb + 20, "the lock follows D's name, in D's crumb: \(plain.crumb), then \(top.crumb)")
        expectEqual(below.crumb, plain.crumb, "D's isn't read-only: no lock there")
        expect(top.pill.width > plain.pill.width + 5 && top.pill.width < plain.pill.width + 20, "one lock: \(plain.pill.width), then \(top.pill.width)")
        expect(abs(top.pill.width - below.pill.width) < 2, "one lock either way, though P's board is read-only too: \(top.pill.width), \(below.pill.width)")
        expectEqual(top.pill.height, plain.pill.height, "on the same line")
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
        path.window.spin { path.menuButtons.count == 3 }
        let rows = path.menuButtons.map(path.frame(of:))
        expectEqual(rows.count, 3, "the root's, front to back: D, with a disclosure triangle before it (its board's rows are under it), and A")
        let first = try require(rows.first)
        expect(first.minY > crumb.maxY + 6 && first.minY < crumb.maxY + 20, "6 points below the crumb, and the menu's padding: \(crumb), \(first)")
        expect(first.minX >= crumb.minX && first.minX < crumb.minX + 30, "lined up with it: \(crumb), \(first)")
        expect(rows[2].minY >= rows[1].maxY - 0.5, "one row under the other: \(rows)")
        try require(path.menuButtons.last).performClick(nil)
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
        try require(path.menuButtons.first).performClick(nil)       // front to back: C, B
        path.window.settle()
        expectEqual(path.editor.board, nest.pBoard, "C is on the board shown")
        expectEqual(path.editor.selectedShapeIDs, [nest.c])
        expectEqual(crumbs.openMenu, nil)
    },
    test("a row whose shape owns a board opens onto that board's rows, as in the table of contents; one picked there goes to its shape, on its board") {
        let nest = Nest()
        let path = try menuWindow(nest)
        expect(path.editor.showBoard(nest.dBoard))
        path.window.spin { path.buttons.count == 1 }
        let crumbs = try require(path.editor.boardCrumbs)
        crumbs.pointerEntered(crumb: .root)
        path.window.spin { path.menuButtons.count == 3 }            // D's triangle, and D; A
        path.menuButtons[0].performClick(nil)
        path.window.spin { path.menuButtons.count == 5 }            // and under D, P's triangle and P
        expect(path.frame(of: path.menuButtons[3]).minX > path.frame(of: path.menuButtons[1]).minX, "P's row in from D's")
        path.menuButtons[2].performClick(nil)
        path.window.spin { path.menuButtons.count == 7 }            // and under P, C and B
        path.menuButtons[5].performClick(nil)
        path.window.spin { path.editor.board == nest.pBoard }
        expectEqual(path.editor.selectedShapeIDs, [nest.b], "B, gone to on P's board")
        expectEqual(crumbs.openMenu, nil)
        path.editor.goBack()
        expectEqual(path.editor.board, nest.dBoard, "one step back")
    },
])

/// The menus shown on screen (each modal while it tracks), closed as soon as each has shown, and
/// where each was, in screen points.
@MainActor final class ShownMenus {
    private(set) var menus: [NSMenu] = []
    private(set) var frames: [CGRect] = []
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { [weak self] note in
            nonisolated(unsafe) let object = note.object          // posted on the main thread, as tracking begins
            MainActor.assumeIsolated {
                guard let menu = object as? NSMenu else { return }
                self?.menus.append(menu)
                RunLoop.main.perform(inModes: [.eventTracking, .common]) {
                    MainActor.assumeIsolated {
                        self?.frames += NSApp.windows.filter { $0.isVisible && $0.level == .popUpMenu }.map(\.frame)
                        self?.menus.last?.cancelTracking()
                    }
                }
            }
        }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }
}

/// Opens the real "…" menu, which shows on screen for a moment, so it runs only with
/// TEST_UI_MENUS=1 (see main.swift). What it holds is tested headlessly in `pathTests`.
@MainActor let menuTests = Suite("The path's menu, on screen", [
    test("a click on \"…\" shows the boards it folds, root side first, and choosing one goes up to it") {
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
        // With room below it for the menu, which AppKit would otherwise open upward.
        path.window.center()
        path.window.settle()
        let shown = ShownMenus()
        defer { shown.stop() }
        button.performClick(nil)
        path.window.spin { !shown.menus.isEmpty }
        let menu = try require(shown.menus.first, "the click showed a menu")
        expectEqual(shown.menus.count, 1)
        // Its window's top at the pill's bottom edge, where a crumb's menu starts (6 points below the
        // crumbs), lined up with the leading edge of "…".
        let fold = path.window.convertToScreen(button.convert(button.bounds, to: nil)), placed = try require(shown.frames.first)
        let pillBottom = path.window.convertToScreen(path.hosting.convert(path.hosting.bounds, to: nil)).maxY - BoardPath.coveredHeight(on: named.board)
        expect(abs(placed.maxY - pillBottom) <= 0.5 && abs(placed.maxY - (fold.minY - 6)) <= 0.5 && abs(placed.minX - fold.minX) <= 1,
               "at the pill's bottom edge, \(pillBottom), below \"…\" at \(fold), lined up with it: \(placed)")
        expectEqual(menu.items.map(\.title), ["A", "B", "C"])
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
    editor.nameRoot("Plans")
    let hosting = NSHostingView(rootView: BoardPath(editor: editor))
    hosting.sizingOptions = []
    hosting.frame = bounds
    let root = NSView(frame: bounds)
    root.addSubview(hosting)
    window.contentView = root
    expect(editor.showBoard(nest.dBoard))
    if !shown { expect(editor.showBoard(nest.pBoard)) }
    window.settle()
    return drawnSize(of: hosting)
}

/// How big what a view draws is, in points: the box around every pixel that isn't the view's corner's.
@MainActor private func drawnSize(of hosting: NSView) -> CGSize {
    let bounds = hosting.bounds
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
