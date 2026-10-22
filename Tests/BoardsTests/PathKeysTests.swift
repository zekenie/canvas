import AppKit
import Boards
@_spi(Host) import Canvas
import CanvasTesting
import Selection
import SwiftUI
import TableOfContents
import TestKit
import Titles

// The path by keys: Go › Board Path gives the pill the keyboard, Left and Right walk its crumbs and
// "…", Return goes up, Down shows a crumb's menu and walks its rows, Escape backs out a level at a
// time, and a click still leaves the keyboard with the canvas.

/// A stand-in for the canvas: it takes the keyboard, as the canvas does, and is where the path hands it back.
@MainActor private final class StandInCanvas: NSView {
    override var acceptsFirstResponder: Bool { true }
}

/// The path hosted over a canvas stand-in in an unshown window, as the app hosts it, its `onExit`
/// giving the keyboard back to the stand-in (`CanvasFocus.take`).
@MainActor
final class KeyedPath {
    let editor: CanvasEditor
    let window: NSWindow
    let canvas: NSView
    let hosting: NSHostingView<BoardPath>
    let walk: KeyWalk
    private let box: CanvasBox
    /// What the rows are called in a walk, by shape.

    init(_ editor: CanvasEditor, rootName: String = "Plans", size: CGSize = CGSize(width: 900, height: 500)) {
        self.editor = editor
        editor.nameRoot(rootName)
        window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        let content = NSView(frame: CGRect(origin: .zero, size: size))
        let canvas = StandInCanvas(frame: content.bounds)
        self.canvas = canvas
        let box = CanvasBox()
        self.box = box
        hosting = NSHostingView(rootView: BoardPath(editor: editor, onExit: { [box] in box.take() }))
        hosting.sizingOptions = []
        hosting.frame = content.bounds
        content.addSubview(canvas)
        content.addSubview(hosting)
        window.contentView = content
        box.canvas = canvas
        let hosted = hosting
        let readers: [any FocusReader] = [
            .custom("path") { window in Self.read(window, editor: editor, hosting: hosted) },
            .canvas(canvas, selection: { [] }),
        ]
        walk = KeyWalk(window, editor: editor, readers: readers)
        window.makeFirstResponder(canvas)
        window.settle()
    }

    /// The keyboard, as the path has it: a crumb or "…", or a row of a menu; nil elsewhere.
    @MainActor
    static func read(_ window: NSWindow, editor: CanvasEditor, hosting: NSView) -> Focus? {
        guard let crumbs = editor.boardCrumbs, let responder = window.firstResponder as? NSView,
              responder === hosting || responder.isDescendant(of: hosting) else { return nil }
        let element: String, label: String
        if crumbs.menuKeyboard.row != nil {
            label = crumbs.menuKeyboard.rowName ?? "row"
            element = "row:\(label)"
        } else if let stop = crumbs.focus {
            switch stop {
            case .fold:
                label = "Boards between"
                element = "fold"
            case .crumb(let board):
                label = editor.name(of: board)
                element = "crumb:\(label)"
            }
        } else {
            return nil
        }
        let named = AccessibilityProbe.focused(in: window)
        return Focus(surface: "path", element: element, role: named.flatMap(AccessibilityProbe.role(of:)),
                     label: named.flatMap(AccessibilityProbe.label(of:)), isMarked: true)
    }

    /// Go › Board Path.
    func boardPath() {
        editor.perform(.boardPath)
        window.settle()
    }

    /// The buttons of the path, leading first, "…" among them by its place.
    func spinUntilCrumbs(_ count: Int) {
        window.spin { hosting.descendants(NSButton.self).count >= count }
    }
}

/// Holds the stand-in canvas for the path's `onExit`, which is made before it.
@MainActor private final class CanvasBox {
    weak var canvas: NSView?
    func take() { if let canvas { canvas.window?.makeFirstResponder(canvas) } }
}

@MainActor let pathKeysTests = Suite("The path by keys", [
    test("Go › Board Path takes the keyboard on the board shown's crumb, and Escape gives it back") {
        let nest = Nest()
        let editor = try windowEditor(nest.file, [TableOfContentsPlugin()])
        let path = KeyedPath(editor)
        expect(editor.showBoard(nest.dBoard))
        expect(editor.showBoard(nest.pBoard))
        path.window.settle()
        let crumbs = try require(editor.boardCrumbs)
        expect(path.window.firstResponder === path.canvas, "the canvas has it")
        path.boardPath()
        expectEqual(crumbs.focus, .crumb(nest.pBoard))
        expect(path.window.firstResponder !== path.canvas, "the pill has it")
        expectEqual(path.walk.focus.id, "path/crumb:Untitled Pocket")
        path.walk.expectEscapeLadder(["canvas"])
        expect(path.window.firstResponder === path.canvas)
        expectEqual(crumbs.focus, nil)
    },
    test("the command is dimmed on the root, where the path shows nothing") {
        let nest = Nest()
        let editor = try windowEditor(nest.file, [TableOfContentsPlugin()])
        let path = KeyedPath(editor)
        path.boardPath()
        expectEqual(editor.boardCrumbs?.focus, nil)
        expect(path.window.firstResponder === path.canvas)
    },
    test("Left and Right walk the crumbs and stop at the ends, each undoing the other") {
        let nest = Nest()
        let editor = try windowEditor(nest.file, [TableOfContentsPlugin()])
        let path = KeyedPath(editor)
        expect(editor.showBoard(nest.dBoard))
        expect(editor.showBoard(nest.pBoard))
        path.window.settle()
        path.boardPath()
        path.walk.go("path/crumb:Plans", by: .left)
        path.walk.expectAxis(down: .right, up: .left, over: ["path/crumb:Plans", "path/crumb:Untitled Drawer", "path/crumb:Untitled Pocket"])
        path.walk.expectShows([path.walk.focus])
    },
    test("\"…\" is a stop between the root and the parent, walked as the crumbs are") {
        let (h, ids) = try chainHarness(depth: 5)
        let editor = try windowEditor(h.editor.file, [TableOfContentsPlugin()])
        let path = KeyedPath(editor, rootName: "R")
        for (id, name) in zip(ids, ["A", "B", "C", "D", "E"]) {
            expect(editor.showBoard(try require(editor.file.board(containing: id))))
            editor.transact("Rename") { $0.update(id) { $0[TitleProperty.self] = name } }
        }
        for id in ids { expect(editor.showBoard(BoardID(owner: id))) }
        path.window.settle()
        path.boardPath()
        path.walk.go("path/crumb:R", by: .left)
        path.walk.expectAxis(down: .right, up: .left, over: ["path/crumb:R", "path/fold", "path/crumb:D", "path/crumb:E"])
    },
    test("Return goes up to the crumb's board, selecting the way you came, and the canvas has the keyboard") {
        let nest = Nest()
        let editor = try windowEditor(nest.file, [TableOfContentsPlugin()])
        let path = KeyedPath(editor)
        expect(editor.showBoard(nest.dBoard))
        expect(editor.showBoard(nest.pBoard))
        path.window.settle()
        path.boardPath()
        path.walk.press(.left)
        path.walk.press(.return)
        expectEqual(editor.board, nest.dBoard)
        expectEqual(editor.selectedShapeIDs, [nest.p])
        expect(path.window.firstResponder === path.canvas, "the keyboard went with it")
        path.boardPath()
        path.walk.press(.return)
        expectEqual(editor.board, nest.dBoard, "the board shown's crumb goes nowhere")
        path.walk.press(.escape)
        expect(path.window.firstResponder === path.canvas)
        editor.goBack()
    },
    test("Down shows the crumb's menu on its first row; Up and Down walk the rows, Right and Left open and close a row, Return picks") {
        let nest = Nest()
        let editor = try windowEditor(nest.file, [TableOfContentsPlugin()])
        let path = KeyedPath(editor)
        expect(editor.showBoard(nest.dBoard))
        path.window.settle()
        let crumbs = try require(editor.boardCrumbs)
        path.boardPath()
        path.walk.go("path/crumb:Plans", by: .left)
        expect(path.walk.press(.down).id.hasPrefix("path/row:"), "the menu's first row has the keyboard: \(path.walk.focus)")
        expectEqual(crumbs.openMenu, .root)
        let first = path.walk.focus.id
        // The root's rows, front to back: D (its board's rows are under it), A.
        let rows = path.walk.expectAxis(down: .down, up: .up, over: [first, "path/row:box"])
        expectEqual(rows.stops.count, 2)
        path.walk.go(first, by: .up)
        expectEqual(crumbs.menuKeyboard.row, nest.d)
        path.walk.press(.right)
        path.window.spin { crumbs.menuKeyboard.rowName != nil && path.walk.focus.id == first }
        expectEqual(path.walk.press(.down).id, "path/row:pocket", "D opened onto its board's rows: P")
        expectEqual(path.walk.press(.left).id, first, "Left goes up to the row it is nested under")
        expectEqual(path.walk.press(.left).id, first, "and closes it")
        expectEqual(path.walk.press(.down).id, "path/row:box", "D closed: A follows it")
        path.walk.press(.return)
        expectEqual(editor.board, .root)
        expectEqual(editor.selectedShapeIDs, [nest.a], "A, gone to")
        expectEqual(crumbs.openMenu, nil)
        expect(path.window.firstResponder === path.canvas)
    },
    test("Escape closes the menu onto its crumb, a second returns the keyboard to the canvas, keeping what was selected") {
        let nest = Nest()
        let editor = try windowEditor(nest.file, [TableOfContentsPlugin()])
        let path = KeyedPath(editor)
        expect(editor.showBoard(nest.dBoard))
        path.window.settle()
        editor.selectedShapeIDs = [nest.p]
        let crumbs = try require(editor.boardCrumbs)
        path.boardPath()
        path.walk.press(.down)
        expectEqual(crumbs.openMenu, nest.dBoard)
        path.walk.expectEscapeLadder(["path/crumb:Untitled Drawer", "canvas"])
        expectEqual(crumbs.openMenu, nil)
        expectEqual(editor.selectedShapeIDs, [nest.p])
        expectEqual(editor.board, nest.dBoard)
    },
    test("a click on a crumb or a row still leaves the keyboard with the canvas, and each stop shows and is named") {
        let nest = Nest()
        let editor = try windowEditor(nest.file, [TableOfContentsPlugin()])
        let path = KeyedPath(editor)
        expect(editor.showBoard(nest.dBoard))
        expect(editor.showBoard(nest.pBoard))
        path.window.settle()
        path.boardPath()
        path.walk.expectShows([Focus(surface: "path", element: "crumb:Untitled Pocket")])
        path.walk.press(.left)
        path.walk.expectShows([path.walk.focus])
        path.walk.press(.left)
        path.walk.expectShows([path.walk.focus])
        let crumb = try require(path.hosting.descendants(NSButton.self).min { path.hosting.convert($0.bounds, from: $0).minX < path.hosting.convert($1.bounds, from: $1).minX })
        crumb.performClick(nil)
        path.window.settle()
        expectEqual(editor.board, .root)
        expect(path.window.firstResponder === path.canvas, "a crumb clicked")
        expectEqual(editor.boardCrumbs?.focus, nil)
        expect(editor.showBoard(nest.dBoard))
        path.window.settle()
        path.boardPath()
        path.walk.press(.down)
        path.window.settle()
        let rowButton = try require(path.hosting.descendants(NSButton.self).last)
        rowButton.performClick(nil)
        path.window.settle()
        expect(path.window.firstResponder === path.canvas, "a row clicked")
        expectEqual(editor.boardCrumbs?.menuKeyboard.row, nil)
    },
    test("keys the path has no use for change nothing, and Tab leaves it") {
        let nest = Nest()
        let editor = try windowEditor(nest.file, [TableOfContentsPlugin()])
        let path = KeyedPath(editor)
        expect(editor.showBoard(nest.dBoard))
        path.window.settle()
        path.boardPath()
        let stop = path.walk.focus
        let revision = editor.revision, tool = editor.currentToolID
        for key in Chord.inert {
            path.walk.press(key)
            expectEqual(editor.revision, revision, "\(key) changed the board")
            expectEqual(editor.currentToolID, tool, "\(key) changed the tool")
            expectEqual(path.walk.focus.id, stop.id, "\(key) moved the keyboard")
        }
        // Tab and ⇧Tab move on, to the canvas, from a crumb and from a menu's row.
        for leave in [Chord.tab, .backTab] {
            expectEqual(path.walk.press(leave).id, "canvas")
            path.boardPath()
            path.walk.press(.down)
            expect(path.walk.focus.id.hasPrefix("path/row:"))
            expectEqual(path.walk.press(leave).id, "canvas")
            expectEqual(editor.boardCrumbs?.openMenu, nil, "the menu closed")
            path.boardPath()
        }
    },
    test("Caps Lock changes no key: the path walks, goes up, and Tab and Escape leave it as with it off") {
        let nest = Nest()
        let editor = try windowEditor(nest.file, [TableOfContentsPlugin()])
        let path = KeyedPath(editor)
        expect(editor.showBoard(nest.dBoard))
        expect(editor.showBoard(nest.pBoard))
        path.window.settle()
        path.boardPath()
        let start = path.walk.focus.id
        expectEqual(path.walk.press(Chord.left.capsLock).id, "path/crumb:Untitled Drawer")
        expectEqual(path.walk.press(Chord.right.capsLock).id, start)
        expectEqual(path.walk.press(Chord.down.capsLock).id, "path/row:Card", "Down opens the menu on the board shown's first row")
        expectEqual(path.walk.press(Chord.escape.capsLock).id, start, "Escape closes the menu onto its crumb")
        expectEqual(path.walk.press(Chord.tab.capsLock).id, "canvas")
        path.boardPath()
        expectEqual(path.walk.press(Chord.backTab.capsLock).id, "canvas")
        path.boardPath()
        path.walk.press(Chord.left.capsLock)
        path.walk.press(Chord.return.capsLock)
        expectEqual(editor.board, nest.dBoard, "Return goes up")
        path.boardPath()
        expectEqual(path.walk.press(Chord.escape.capsLock).id, "canvas")
    },
    test("another board shown while the pill has the keyboard gives it back to the canvas, whichever way the board changed") {
        let nest = Nest()
        let editor = try windowEditor(nest.file, [TableOfContentsPlugin()])
        let path = KeyedPath(editor)
        expect(editor.showBoard(nest.dBoard))
        expect(editor.showBoard(nest.pBoard))
        path.window.settle()
        let crumbs = try require(editor.boardCrumbs)
        // A menu item's goUp (the folded crumbs' menu is modal), then Back from the menu bar.
        for (change, note) in [({ _ = editor.goUp(to: nest.dBoard) }, "up to a board still on the path"), ({ _ = editor.goUp(to: .root) }, "up to the root, where the pill goes"),
                               ({ editor.goBack() }, "Back")] as [(() -> Void, String)] {
            expect(editor.showBoard(nest.dBoard))
            expect(editor.showBoard(nest.pBoard))
            path.window.settle()
            path.boardPath()
            expect(path.window.firstResponder !== path.canvas, "the pill has it before \(note)")
            change()
            path.window.settle()
            expect(path.window.firstResponder === path.canvas, "the canvas has it after \(note)")
            expectEqual(crumbs.focus, nil)
        }
        // From a menu's row too.
        expect(editor.showBoard(nest.dBoard))
        path.window.settle()
        path.boardPath()
        path.walk.press(.down)
        expect(crumbs.menuKeyboard.isTaken)
        editor.goBack()
        path.window.settle()
        expect(path.window.firstResponder === path.canvas, "the canvas has it after Back from a menu's row")
        expectEqual(crumbs.openMenu, nil)
    },
    test("a key with no stop to act on still lets Tab and Escape move on") {
        let nest = Nest()
        let editor = try windowEditor(nest.file, [TableOfContentsPlugin()])
        let path = KeyedPath(editor)
        expect(editor.showBoard(nest.dBoard))
        path.window.settle()
        let crumbs = try require(editor.boardCrumbs)
        for leave in [Chord.tab, .backTab, .escape] {
            path.boardPath()
            crumbs.focus = nil
            expect(path.window.firstResponder !== path.canvas, "the pill has the keyboard, on no stop")
            path.walk.press(.left)
            expect(path.window.firstResponder !== path.canvas, "Left does nothing")
            path.walk.press(leave)
            expect(path.window.firstResponder === path.canvas, "\(leave) moves on")
        }
    },
    test("the pointer resting on another crumb moves the menu and the keyboard in it to that menu's rows") {
        let nest = Nest()
        let editor = try windowEditor(nest.file, [TableOfContentsPlugin()])
        let path = KeyedPath(editor)
        expect(editor.showBoard(nest.dBoard))
        expect(editor.showBoard(nest.pBoard))
        path.window.settle()
        let crumbs = try require(editor.boardCrumbs)
        path.boardPath()
        path.walk.press(.left)
        path.walk.press(.down)
        expectEqual(crumbs.openMenu, nest.dBoard)
        expectEqual(crumbs.menuKeyboard.row, nest.p, "the way you came, on the drawer's board")
        crumbs.pointerEntered(crumb: .root)
        path.window.spin { crumbs.openMenu == .root && crumbs.menuKeyboard.row == nest.d }
        expectEqual(crumbs.openMenu, .root)
        expectEqual(crumbs.menuKeyboard.row, nest.d, "the root's menu has it, on the way you came")
        expectEqual(path.walk.press(.down).id, "path/row:box", "and Down walks that menu")
        expectEqual(crumbs.menuKeyboard.row, nest.a)
        path.walk.press(.return)
        expectEqual(editor.selectedShapeIDs, [nest.a], "Return picks a row of the menu shown")
    },
    test("Show Contents from an assistive app opens the menu with the keys on it, and Escape closes it") {
        let nest = Nest()
        let editor = try windowEditor(nest.file, [TableOfContentsPlugin()])
        let path = KeyedPath(editor)
        expect(editor.showBoard(nest.dBoard))
        path.window.settle()
        let crumbs = try require(editor.boardCrumbs)
        expect(path.window.firstResponder === path.canvas)
        expect(crumbs.openFromKeyboard(nest.dBoard))
        path.window.spin { crumbs.menuKeyboard.row != nil }
        expect(path.window.firstResponder !== path.canvas, "the pill's key view has the keyboard, which the menu is answered through")
        let first = path.walk.focus.id
        expect(first.hasPrefix("path/row:"), first)
        expectEqual(path.walk.press(.down).id, first, "the menu's one row")
        path.walk.press(.escape)
        expectEqual(crumbs.openMenu, nil)
        expectEqual(path.walk.press(.escape).id, "canvas")
    },
    test("assistive apps read the pill as a group, \"Board path\", whose value is where the keyboard is") {
        let nest = Nest()
        let editor = try windowEditor(nest.file, [TableOfContentsPlugin()])
        let path = KeyedPath(editor)
        expect(editor.showBoard(nest.dBoard))
        expect(editor.showBoard(nest.pBoard))
        path.window.settle()
        path.boardPath()
        let focused = try require(AccessibilityProbe.focused(in: path.window))
        expectEqual(AccessibilityProbe.role(of: focused), "AXGroup")
        expectEqual(AccessibilityProbe.label(of: focused), "Board path")
        expectEqual(AccessibilityProbe.value(of: focused), "Untitled Pocket", "where the keyboard is")
        path.walk.press(.left)
        path.walk.press(.down)
        expectEqual(AccessibilityProbe.value(of: try require(AccessibilityProbe.focused(in: path.window))), "pocket", "and the row the menu opened on: the way you came")
    },
])

