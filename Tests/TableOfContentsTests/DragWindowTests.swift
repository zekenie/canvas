import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import SwiftUI
import TableOfContents
import TestKit

// Dragging rows through the list itself, in an unshown window: the outline asks each dragged row what it
// carries (`pasteboardWriterForItem`, which begins the drag), and AppKit hands a drag over the rows to the
// outline, which a test reaches as AppKit does, with a drag of its own making, at a point on a row.

/// A drag over the list, as AppKit describes one to the view under it: what it carries, where it is.
final class RowDrag: NSObject, NSDraggingInfo {
    let pasteboard: NSPasteboard
    let source: AnyObject?
    let location: NSPoint
    let window: NSWindow

    init(pasteboard: NSPasteboard, source: AnyObject?, location: NSPoint, window: NSWindow) {
        self.pasteboard = pasteboard
        self.source = source
        self.location = location
        self.window = window
    }

    var draggingDestinationWindow: NSWindow? { window }
    var draggingSourceOperationMask: NSDragOperation { .every }
    var draggingLocation: NSPoint { location }
    var draggedImageLocation: NSPoint { location }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { pasteboard }
    var draggingSource: Any? { source }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}

    func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {
        var stop: ObjCBool = false
        for (index, item) in (pasteboard.pasteboardItems ?? []).enumerated() {
            block(NSDraggingItem(pasteboardWriter: item), index, &stop)
            if stop.boolValue { break }
        }
    }
}

extension ContentsWindow {
    /// What the list's table puts on the pasteboard for the row at `row` (the first is 0), as it does as
    /// a drag of the row begins; nil for a row it wouldn't drag.
    func writer(ofRow row: Int) throws -> (any NSPasteboardWriting)? {
        let outline = try require(outline, "no outline")
        return outline.dataSource?.outlineView?(outline, pasteboardWriterForItem: try require(outline.item(atRow: row)))
    }

    /// A drag of the rows at `rows` (the first is 0), as their writers begin one, at `fraction` of the way
    /// down the row at `row`: what the view AppKit hands it to hears (the outline, registered for what a row
    /// carries), and the drag.
    func drag(rows: [Int], over row: Int, at fraction: CGFloat) throws -> (target: NSView, drag: RowDrag) {
        let outline = try require(outline, "no outline")
        let pasteboard = NSPasteboard.withUniqueName()          // the caller releases it (`drag.pasteboard`)
        pasteboard.clearContents()
        pasteboard.writeObjects(try rows.map { try require(writer(ofRow: $0), "row \($0) doesn't drag") })
        let carried = try require(pasteboard.types?.first, "nothing carried")
        let target = try require(outline.registeredDraggedTypes.contains(carried) ? outline : nil, "the outline takes no rows")
        let bounds = outline.rect(ofRow: row)
        let y = outline.isFlipped ? bounds.minY + bounds.height * fraction : bounds.maxY - bounds.height * fraction
        return (target, RowDrag(pasteboard: pasteboard, source: outline, location: outline.convert(CGPoint(x: bounds.midX, y: y), to: nil), window: window))
    }
}

@MainActor private func ids(_ document: CanvasDocument) -> [ShapeID] { document.shapes.map(\.id) }

/// How far a drop's line reaches past the edge of the row it's at: half its ring, and a point to spare.
private let lineReach: CGFloat = 5

@MainActor let dragWindowTests = Suite("Table of contents: dragging rows, in a window", [
    test("a row's drag begins as the table asks what it carries; a frozen shape's row carries nothing, so the table doesn't drag it") {
        let editor = try contentsEditor([FreezingPlugin()], scheduler: TaskScheduler())
        let (_, b, c) = threeWidgets(editor)
        editor.freeze([b])
        let w = ContentsWindow(editor)
        w.window.spin { w.rows == 3 }
        expect(try w.writer(ofRow: 0) != nil)                   // front to back: C, B, A
        expectEqual(editor.contents.dragShapes, [c])
        expect(try w.writer(ofRow: 1) == nil, "B is frozen")
        expectEqual(editor.contents.dragShapes, [c], "the drag under way as it was")
    },
    test("dropped through the list: the row's own target takes the drag, points where on the row it is, and drops there; one step, Reorder") {
        let editor = try contentsEditor(scheduler: TaskScheduler())
        let (a, b, c) = threeWidgets(editor)
        let w = ContentsWindow(editor)
        w.window.spin { w.rows == 3 }
        let (target, drag) = try w.drag(rows: [2], over: 0, at: 0.2)           // A, over C's top
        defer { drag.pasteboard.releaseGlobally() }
        expectEqual(target.draggingEntered(drag), .move)
        expectEqual(target.draggingUpdated(drag), .move)
        expectEqual(editor.contents.dropZone(for: c), .above)
        expect(target.prepareForDragOperation(drag))
        expect(target.performDragOperation(drag))
        target.concludeDragOperation(drag)
        expectEqual(ids(editor.document), [b, c, a], "in front of C")
        expectEqual(editor.undoHistory.undoName, "Reorder")
        expectEqual(editor.contents.dropZone(for: c), nil)
        w.window.spin { w.rows == 3 }
    },
    test("a drag the list can't drop where it is shows nothing there, and its drop does nothing") {
        let editor = try contentsEditor(scheduler: TaskScheduler())
        let (a, b, c) = threeWidgets(editor)
        let w = ContentsWindow(editor)
        w.window.spin { w.rows == 3 }
        let step = editor.undoHistory.undoName
        let (target, drag) = try w.drag(rows: [2], over: 2, at: 0.2)           // A, over its own row
        defer { drag.pasteboard.releaseGlobally() }
        _ = target.draggingEntered(drag)
        expectEqual(target.draggingUpdated(drag), [])
        expectEqual(editor.contents.dropZone(for: a), nil)
        _ = target.performDragOperation(drag)
        expectEqual(ids(editor.document), [a, b, c])
        expectEqual(editor.undoHistory.undoName, step, "no step")
    },
    test("a drag's line shows across the row it points above, its ring on a corral's row it points on, and nothing else changes") {
        let editor = try corralEditor([RecordingMoves(log: MoveLog())], scheduler: TaskScheduler())
        let (a, b, _) = threeWidgets(editor)
        let f = editor.add(Corral(CGRect(x: 2000, y: 0, width: 400, height: 300)))
        let w = ContentsWindow(editor)
        w.window.spin { w.rows == 4 }
        w.window.settle()
        let plain = snapshot(w.hosting)
        let state = editor.contents
        let rowB = try w.rect(ofRow: 2), rowF = try w.rect(ofRow: 0)       // front to back: the corral, C, B, A
        expect(state.beginDrag(from: a))
        state.dragMoved(over: try require(state.row(b)), at: 0.2)
        w.window.spin { changedPixels(plain, snapshot(w.hosting), in: rowB) > 0 }
        let line = snapshot(w.hosting)
        let around = rowB.insetBy(dx: 0, dy: -lineReach)
        expectEqual(changedPixels(plain, line, in: w.hosting.bounds) - changedPixels(plain, line, in: around), 0, "only about B's top")
        state.dragMoved(over: try require(state.row(f)), at: 0.5)
        w.window.spin { changedPixels(plain, snapshot(w.hosting), in: rowB) == 0 }
        let ring = snapshot(w.hosting)
        expect(changedPixels(plain, ring, in: rowF) > 0, "the corral's row ringed")
        expectEqual(changedPixels(plain, ring, in: w.hosting.bounds) - changedPixels(plain, ring, in: rowF), 0, "and nothing else")
        state.dragLeft(try require(state.row(f)))
        w.window.spin { changedPixels(plain, snapshot(w.hosting), in: w.hosting.bounds) == 0 }
    },
])
