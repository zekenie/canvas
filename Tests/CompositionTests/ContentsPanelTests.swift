import AppKit
import Canvas
import CanvasTesting
import CanvasUI
import DetailPanel
import Geometry
import LanguageModels
import Selection
import ShippedTesting
import StickyNotes
import SwiftUI
import TableOfContents
import TestKit

/// The app's window over the sample board, unshown: the canvas with the shipped detail panel in
/// an `.inspector`, wired by a `CanvasFocus` as the app wires them (InspectorHost).
@MainActor
final class SampleWindow {
    let editor = ShippedPlugins.makeEditor(scheduler: TaskScheduler(), model: ScriptedLanguageModel())
    let window = BoardWindow(contentRect: CGRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
    let focus = CanvasFocus()
    let host: NSHostingView<InspectorHost>
    let canvas: CanvasView

    init() throws {
        host = NSHostingView(rootView: InspectorHost(editor: editor, focus: focus, showsDetails: true))
        host.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        window.editor = editor
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
    /// The table of contents' list, as opposed to a list in a shape's panel: the one
    /// whose first row is a section header, its "Board" or "Selection".
    var isTableOfContents: Bool {
        guard let outline = self as? NSOutlineView, outline.numberOfRows > 0 else { return false }
        return outline.delegate?.outlineView?(outline, isGroupItem: outline.item(atRow: 0) as Any) == true
    }
}

@MainActor let contentsPanelTests = Suite("Table of contents in the panel", [
    test("with nothing selected the panel is the table of contents: the notes, each arrow under its note") {
        let w = try SampleWindow()
        w.window.spin { w.rows == 6 }
        expect(w.editor.viewportSize.width > 0 && w.editor.viewportSize.height > 0, "the canvas knows its size: \(w.editor.viewportSize)")
    },
    test("selecting one shape shows its details instead; several, their header over the list of just them") {
        let w = try SampleWindow()
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
    test("from several shapes to none, the panel lists the board and AppKit logs no reentrant update") {
        let w = try SampleWindow()
        w.window.spin { w.rows == 6 }
        w.editor.selectedShapeIDs = [w.notes[1], w.notes[2]]
        w.window.spin { w.rows == 2 }
        let log = standardError {
            w.editor.selection = nil        // the list of two takes the board's rows as the panel lets it go
            w.window.spin { w.rows == 6 }
        }
        expect(!log.contains(tableReentrancyWarning), "AppKit logged: \(log)")
    },
    test("the pointer on a note on the canvas tints the note's row, and only that; leaving the canvas takes the tint away") {
        let w = try SampleWindow()
        w.window.spin { w.rows == 6 }
        let list = try require(w.contents)
        let note = w.notes[1]
        let row = list.rect(ofRow: 5)                          // under the header, the six notes front to back: the second is fifth
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
        let w = try SampleWindow()
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
        let w = try SampleWindow()
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
    test("in the panel, picking one row takes the list away and gives the canvas the keyboard, so Return opens its shape there") {
        let w = try SampleWindow()
        w.window.spin { w.rows == 6 }
        w.window.makeFirstResponder(try require(w.contents))
        w.window.settle()
        w.window.press(String(UnicodeScalar(UInt16(NSDownArrowFunctionKey))!), code: 125, modifiers: [.numericPad, .function])
        let note = try require(w.editor.selection, "↓ picks the first row")
        w.window.spin { w.contents == nil && w.canvasHasKeyboard }     // the note's panel; the row's own Return can't be pressed
        w.window.pressReturn()
        w.window.spin { w.editor.editingShapeID == note }
    },
    test("↓ held in the list picks a row; its repeats, once the canvas has the keyboard, don't move what it picked, while a fresh ↓ there does") {
        let w = try SampleWindow()
        w.window.spin { w.rows == 6 }
        w.window.makeFirstResponder(try require(w.contents))
        w.window.settle()
        let down = String(UnicodeScalar(UInt16(NSDownArrowFunctionKey))!)
        @MainActor func key(_ type: NSEvent.EventType, isRepeat: Bool = false) -> NSEvent {
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [.numericPad, .function], timestamp: 1, windowNumber: w.window.windowNumber,
                             context: nil, characters: down, charactersIgnoringModifiers: down, isARepeat: isRepeat, keyCode: 125)!
        }
        w.window.sendEvent(key(.keyDown))
        let note = try require(w.editor.selection, "↓ picks the first row")
        let origin = try require(w.editor.document[note]?.box).origin
        w.window.spin { w.contents == nil && w.canvasHasKeyboard }
        for _ in 0..<5 { w.window.sendEvent(key(.keyDown, isRepeat: true)) }
        expectEqual(w.editor.document[note]?.box?.origin, origin, "held on, the key moves nothing")
        expect(!w.editor.canUndo, "nor is it a step")
        w.window.sendEvent(key(.keyUp))
        w.window.sendEvent(key(.keyDown))
        expectEqual(w.editor.document[note]?.box?.origin, CGPoint(x: origin.x, y: origin.y + 1), "a fresh ↓ is the canvas's: the selection's nudge")
    },
    test("Escape in the list gives the keyboard back to the canvas, where tool shortcuts work again") {
        let w = try SampleWindow()
        w.window.spin { w.rows == 6 }
        w.window.makeFirstResponder(try require(w.contents))
        w.window.settle()
        expect(!w.canvasHasKeyboard)
        w.window.pressEscape()
        w.window.spin { w.canvasHasKeyboard }
        w.window.press("n")
        expectEqual(w.editor.currentToolID, ToolID(placing: "sticky-note"))
    },
])
