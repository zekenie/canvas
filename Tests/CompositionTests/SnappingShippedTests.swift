import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import Composition
import CoreGraphics
import LanguageModels
import Mentions
import Selection
import Snapping
import StickyNotes
import TestKit

// Snapping as shipped: dragged with the select tool, notes snap to the shapes in view, arrows
// neither snap nor are snapped to, and a shape placed by a tool snaps as it follows the pointer. In a
// 1200 × 800 view at 100%, where view points are world units.

@MainActor private func note(_ frame: CGRect) -> AnyShapeRecord {
    AnyShapeRecord(ShapeRecord(StickyNote(frame: frame, text: MentionText(plain: "Hi"))))
}

/// The shipped plugins on a board of `shapes`, in a view.
@MainActor private func shipped(_ shapes: [AnyShapeRecord], _ pasteboard: NSPasteboard) -> EditorHarness {
    let h = EditorHarness { ShippedPlugins.makeEditor(document: CanvasDocument(shapes: shapes), scheduler: $0, pasteboard: pasteboard, model: ScriptedLanguageModel()) }
    h.editor.viewportDidResize(to: CGSize(width: 1200, height: 800))
    return h
}

@MainActor let snappingShippedTests = Suite("Snapping, as shipped", [
    test("a note dragged with the select tool snaps onto another's edge, with a guide, and ⌘ lets it go where the pointer is") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let a = note(CGRect(x: 400, y: 0, width: 200, height: 200)), b = note(CGRect(x: 0, y: 300, width: 200, height: 200))
        let h = shipped([a, b], pasteboard)
        h.press(at: CGPoint(x: 100, y: 400))
        // Its right edge 3 short of the other's left edge.
        h.drag(to: CGPoint(x: 297, y: 413))
        expectEqual(h.editor.document[b.id]?.box?.origin, CGPoint(x: 200, y: 313))
        expectEqual(h.editor.snapGuides, [.alignment(.x, at: 400, points: [CGPoint(x: 400, y: 0), CGPoint(x: 400, y: 200),
                                                                            CGPoint(x: 400, y: 313), CGPoint(x: 400, y: 513)])])
        h.hold(.command)
        expectEqual(h.editor.document[b.id]?.box?.origin, CGPoint(x: 197, y: 313))
        expectEqual(h.editor.snapGuides, [])
        h.hold([])
        h.wait(150)
        expectEqual(h.editor.document[b.id]?.box?.origin, CGPoint(x: 200, y: 313))
        h.release()
        expectEqual(h.editor.document[b.id]?.box?.origin, CGPoint(x: 200, y: 313))
        expectEqual(h.editor.snapGuides, [])
        expectEqual(h.editor.selectedShapeIDs, [b.id])
    },
    test("in a canvas view, as the app hosts it, a note dragged near another snaps, with its guide") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let a = note(CGRect(x: 400, y: 0, width: 200, height: 200)), b = note(CGRect(x: 0, y: 300, width: 200, height: 200))
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(shapes: [a, b]), scheduler: ManualScheduler(), pasteboard: pasteboard,
                                               model: ScriptedLanguageModel())
        let (window, canvas) = windowed(editor)
        expectEqual(editor.viewportSize, CGSize(width: 800, height: 600), "the view says what's in view")
        canvas.mouseDown(with: window.mouse(.leftMouseDown, at: CGPoint(x: 100, y: 400), time: 1))
        canvas.mouseDragged(with: window.mouse(.leftMouseDragged, at: CGPoint(x: 200, y: 410), time: 1.016))
        expectEqual(editor.document[b.id]?.box?.origin, CGPoint(x: 100, y: 310))
        // Its right edge 3 short of the other's left edge.
        canvas.mouseDragged(with: window.mouse(.leftMouseDragged, at: CGPoint(x: 297, y: 413), time: 1.032))
        expectEqual(editor.document[b.id]?.box?.origin, CGPoint(x: 200, y: 313))
        expect(!editor.snapGuides.isEmpty)
        canvas.mouseUp(with: window.mouse(.leftMouseUp, at: CGPoint(x: 297, y: 413), time: 1.048))
        expectEqual(editor.document[b.id]?.box?.origin, CGPoint(x: 200, y: 313))
        expectEqual(editor.snapGuides, [])
    },
    test("arrows are neither snapped to nor snap") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let a = note(CGRect(x: 400, y: 0, width: 200, height: 200)), b = note(CGRect(x: 0, y: 300, width: 200, height: 200))
        let arrow = AnyShapeRecord(ShapeRecord(Arrow(start: .free(CGPoint(x: 700, y: 250)), end: .free(CGPoint(x: 900, y: 250)))))
        let h = shipped([a, b, arrow], pasteboard)
        // The note's top 3 below the arrow.
        h.press(at: CGPoint(x: 100, y: 400))
        h.drag(to: CGPoint(x: 100, y: 353))
        expectEqual(h.editor.document[b.id]?.box?.origin, CGPoint(x: 0, y: 253))
        expectEqual(h.editor.snapGuides, [])
        h.release()
        // The arrow's left end 3 past the note's left edge.
        h.press(at: CGPoint(x: 750, y: 250))
        h.drag(to: CGPoint(x: 453, y: 250))
        let moved = try require(h.editor.document[arrow.id]?.typed(as: Arrow.self)?.props)
        expectEqual(moved.start, .free(CGPoint(x: 403, y: 250)))
        expectEqual(moved.end, .free(CGPoint(x: 603, y: 250)))
        expectEqual(h.editor.snapGuides, [])
        h.release()
    },
    test("a shape placed with its tool snaps as it follows the pointer") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let a = note(CGRect(x: 400, y: 0, width: 200, height: 200))
        let h = shipped([a], pasteboard)
        h.key("r")
        h.press(at: CGPoint(x: 100, y: 650))
        let placed = try require(h.editor.selection)
        let frame = try require(h.editor.document[placed]?.box)
        // Its right edge 3 short of the note's left edge.
        h.drag(to: CGPoint(x: 100 + 397 - frame.maxX, y: 650))
        expectEqual(h.editor.document[placed]?.box?.maxX, 400)
        h.release()
        expectEqual(h.editor.document[placed]?.box?.maxX, 400)
    },
])
