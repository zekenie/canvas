import AppKit
import Canvas
import CanvasTesting
import CanvasUI
import Composition
import DetailPanel
import Geometry
import Selection
import StickyNotes
import SwiftUI
import TableOfContents
import TestKit

/// The app's window over the welcome board, unshown: the canvas with the shipped detail panel in
/// an `.inspector`, wired by a `CanvasFocus` as the app wires them (InspectorHost).
@MainActor
final class BoardWindow {
    let editor = ShippedPlugins.makeEditor(scheduler: TaskScheduler())
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
    let focus = CanvasFocus()
    let host: NSHostingView<InspectorHost>
    let canvas: CanvasView

    init() throws {
        host = NSHostingView(rootView: InspectorHost(editor: editor, focus: focus, showsDetails: true))
        host.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        canvas = try require(focus.canvas, "the representable hands its canvas view to the focus")
        window.settle()
    }

    /// The table of contents' list, if the panel shows it.
    var contents: NSTableView? { host.descendants(NSTableView.self).first { $0.isTableOfContents } }
    /// Its rows, less its header.
    var rows: Int { max(0, (contents?.numberOfRows ?? 0) - 1) }
    var canvasHasKeyboard: Bool { window.firstResponder === canvas }
    var notes: [ShapeID] { editor.document.shapes.filter { $0.kind == StickyNote.kind }.map(\.id) }
    /// The panel header's back button, while there's a selection to go back to.
    var backButton: NSButton? { host.descendants(NSButton.self).first { $0.isInPanelHeader(of: host) } }
}

extension NSView {
    /// In the detail panel's header, the top 44 points (`DetailStyle.headerHeight`) of the window's
    /// content, where the back button is.
    func isInPanelHeader(of host: NSView) -> Bool { convert(bounds, to: host).maxY <= 44 }
}

extension NSTableView {
    /// The table of contents' list, as opposed to a list in a shape's panel (a checklist): the one
    /// whose first row is a section header, its "Board" or "Selection".
    var isTableOfContents: Bool {
        guard let outline = self as? NSOutlineView, outline.numberOfRows > 0 else { return false }
        return outline.delegate?.outlineView?(outline, isGroupItem: outline.item(atRow: 0) as Any) == true
    }
}

@MainActor let contentsPanelTests = Suite("Table of contents in the panel", [
    test("with nothing selected the panel is the table of contents: the notes, each arrow under its note") {
        let w = try BoardWindow()
        w.window.spin { w.rows == 6 }
        expect(w.editor.viewportSize.width > 0 && w.editor.viewportSize.height > 0, "the canvas knows its size: \(w.editor.viewportSize)")
    },
    test("selecting one shape shows its details instead; several, their header over the list of just them") {
        let w = try BoardWindow()
        w.window.spin { w.rows == 6 }
        w.editor.selection = w.notes[0]
        w.window.spin { w.contents == nil }
        w.editor.selectedShapeIDs = [w.notes[1], w.notes[2]]
        w.window.spin { w.rows == 2 }
        let header = try require(w.editor.detailPanel).selectionSummary(of: [w.notes[1], w.notes[2]].compactMap { w.editor.document[$0] })
        expectEqual(header.title, "2 Shapes")
        w.editor.selection = nil
        w.window.spin { w.rows == 6 }
    },
    test("the pointer on a note on the canvas tints the note's row, and only that; leaving the canvas takes the tint away") {
        let w = try BoardWindow()
        w.window.spin { w.rows == 6 }
        let list = try require(w.contents)
        let note = w.notes[1]
        let row = list.rect(ofRow: 2)                          // under the header, the notes in document order
        let probe = CGPoint(x: row.maxX - 30, y: row.midY)     // past the text
        let plain = snapshot(list)
        let box = try require(w.editor.document[note]?.box)
        let point = w.canvas.convert(w.editor.camera.toView(CGPoint(x: box.midX, y: box.midY)), to: nil)
        w.canvas.mouseMoved(with: w.window.mouse(.mouseMoved, at: CGPoint(x: point.x, y: w.host.frame.height - point.y), clicks: 0, time: 1))
        expectEqual(w.editor.hovered, note)
        w.window.spin { pixel(snapshot(list), at: probe) != pixel(plain, at: probe) }
        let hovering = snapshot(list)
        expectEqual(changedPixels(plain, hovering, in: list.bounds) - changedPixels(plain, hovering, in: row), 0, "only the note's row changes")
        w.canvas.mouseExited(with: try require(NSEvent.enterExitEvent(with: .mouseExited, location: point, modifierFlags: [], timestamp: 2,
                                                                      windowNumber: w.window.windowNumber, context: nil, eventNumber: 0,
                                                                      trackingNumber: 0, userData: nil)))
        expectEqual(w.editor.hovered, nil)
        w.window.spin { changedPixels(plain, snapshot(list), in: row) == 0 }
    },
    test("a row takes the panel to its note; the header's back button brings the list back, and the view as it was") {
        let w = try BoardWindow()
        w.window.spin { w.rows == 6 }
        expect(w.backButton == nil, "no header with nothing selected")
        let start = w.editor.camera
        try require(w.editor.tableOfContents).select([w.notes[1]])
        w.window.spin { w.contents == nil && w.backButton != nil }     // the note's own panel, and a way back
        w.window.spin { w.editor.camera != start }                      // zooming to the note
        try require(w.backButton).performClick(nil)
        expectEqual(w.editor.selectedShapeIDs, [])
        w.window.spin { w.rows == 6 }
        w.window.spin { w.editor.camera == start }
        expect(!w.editor.canGoBack, "nothing further back")
    },
    test("the back button in several shapes' header goes back to one of them, and from it to the board") {
        let w = try BoardWindow()
        w.window.spin { w.rows == 6 }
        w.editor.selection = w.notes[0]
        w.editor.selectedShapeIDs = [w.notes[1], w.notes[2]]
        w.window.spin { w.rows == 2 && w.backButton != nil }
        try require(w.backButton).performClick(nil)
        expectEqual(w.editor.selectedShapeIDs, [w.notes[0]])
        w.window.spin { w.contents == nil && w.backButton != nil }
        try require(w.backButton).performClick(nil)
        w.window.spin { w.rows == 6 }
        expect(w.backButton == nil)
    },
    test("Escape in the list gives the keyboard back to the canvas, where tool shortcuts work again") {
        let w = try BoardWindow()
        w.window.spin { w.rows == 6 }
        w.window.makeFirstResponder(try require(w.contents))
        w.window.settle()
        expect(!w.canvasHasKeyboard)
        w.window.pressEscape()
        w.window.spin { w.canvasHasKeyboard }
        w.window.press("o")
        expectEqual(w.editor.currentToolID, ToolID(placing: "ellipse"))
    },
])
