import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import Selection
import SwiftUI
import TableOfContents
import TestKit

/// The list's width in the window, about the detail panel's.
let listWidth: CGFloat = 260

/// The table of contents in an NSHostingView beside a canvas view, in an unshown window
/// (CanvasTesting drives it: `spin`, `press`). The editor keeps real time, so SwiftUI's updates and
/// the hand-back land while the main run loop runs.
@MainActor
final class ContentsWindow {
    let editor: CanvasEditor
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
    let canvas: CanvasView
    private(set) var hosting: NSView!
    /// How often the list handed the keyboard back.
    private(set) var exits = 0

    init(_ editor: CanvasEditor) {
        self.editor = editor
        canvas = CanvasView(editor: editor)
        canvas.frame = CGRect(x: listWidth, y: 0, width: 1000 - listWidth, height: 700)
        let contents = TableOfContentsView(editor: editor) { [unowned self] in
            exits += 1
            window.makeFirstResponder(canvas)
        }
        hosting = NSHostingView(rootView: contents)
        hosting.frame = CGRect(x: 0, y: 0, width: listWidth, height: 700)
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 1000, height: 700))
        root.addSubview(canvas)
        root.addSubview(hosting)
        window.contentView = root
        window.settle()
    }

    var table: NSTableView? { hosting.descendants(NSTableView.self).first }
    /// The list's rows, less its header.
    var rows: Int { max(0, (table?.numberOfRows ?? 0) - 1) }
    var canvasHasKeyboard: Bool { window.firstResponder === canvas }

    /// Gives the list the keyboard, as a click on a row does.
    func focusList() throws {
        let table = try require(table, "no list")
        window.makeFirstResponder(table)
        window.settle()
    }
}

@MainActor let windowTests = Suite("Table of contents in a window", [
    test("an empty board says so, and has no list") {
        let w = ContentsWindow(try contentsEditor(scheduler: TaskScheduler()))
        expect(w.table == nil)
        w.editor.add(Widget(name: "First"))
        w.window.spin { w.table != nil }
        expectEqual(w.rows, 1)    },
    test("one row per shape, under a header; selecting on the canvas lists just the selection") {
        let editor = try contentsEditor(scheduler: TaskScheduler())
        let (a, b, _) = threeWidgets(editor)
        let w = ContentsWindow(editor)
        w.window.spin { w.rows == 3 }
        editor.selectedShapeIDs = [b]
        w.window.spin { w.rows == 1 }
        editor.selectedShapeIDs = [a, b]
        w.window.spin { w.rows == 2 }
        editor.selectedShapeIDs = []
        w.window.spin { w.rows == 3 }
    },
    test("the list shows the selection as selected rows") {
        let editor = try contentsEditor(scheduler: TaskScheduler())
        let (_, b, _) = threeWidgets(editor)
        let w = ContentsWindow(editor)
        w.window.spin { w.rows == 3 }
        editor.contents.select([b])             // as a click on its row does: the list stays whole
        w.window.spin { w.table?.selectedRowIndexes.count == 1 }
        expectEqual(w.rows, 3)
        expectEqual(w.table?.selectedRow, 2, "B, under the header")
    },
    test("the canvas view tells the editor its size") {
        let w = ContentsWindow(try contentsEditor(scheduler: TaskScheduler()))
        expectEqual(w.editor.viewportSize, CGSize(width: 1000 - listWidth, height: 700))
        w.canvas.setFrameSize(CGSize(width: 600, height: 500))
        expectEqual(w.editor.viewportSize, CGSize(width: 600, height: 500))
    },
    test("Escape in the list gives the keyboard back to the canvas") {
        let editor = try contentsEditor(scheduler: TaskScheduler())
        _ = threeWidgets(editor)
        let w = ContentsWindow(editor)
        w.window.spin { w.rows == 3 }
        try w.focusList()
        expect(!w.canvasHasKeyboard)
        w.window.pressEscape()
        w.window.spin { w.canvasHasKeyboard }
        expectEqual(w.exits, 1)
    },
    test("Delete in the list deletes the selected shapes") {
        let editor = try contentsEditor(scheduler: TaskScheduler())
        let (a, b, c) = threeWidgets(editor)
        let w = ContentsWindow(editor)
        w.window.spin { w.rows == 3 }
        editor.contents.select([b])
        w.window.spin { w.table?.selectedRowIndexes.count == 1 }
        try w.focusList()
        w.window.pressDelete()
        w.window.spin { editor.document[b] == nil }
        expectEqual(editor.document.shapes.map(\.id), [a, c])
    },
    test("hiding the list while it has the keyboard gives the keyboard back to the canvas") {
        let editor = try contentsEditor(scheduler: TaskScheduler())
        _ = threeWidgets(editor)
        let w = ContentsWindow(editor)
        w.window.spin { w.rows == 3 }
        try w.focusList()
        w.hosting.isHidden = true
        w.window.spin { w.canvasHasKeyboard }
        expectEqual(w.exits, 1)
    },
])
