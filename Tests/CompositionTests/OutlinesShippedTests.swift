import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Frames
import LanguageModels
import Mentions
import References
import Selection
import ShippedTesting
import StickyNotes
import Subboards
import TestKit
import Types

// Outlines as shipped: the selection's, a hover's and the hint stand off every closed shape's edge by
// the same 4 view points, whatever its kind, its rounded corners growing with it; an arrow's is its
// own line. These editors are the app's (no harness, which draws on the edge), so what's held here is
// what the app draws.

@MainActor private func expectBox(_ box: CGRect, _ expected: CGRect, _ message: String) {
    for (actual, wanted) in [(box.minX, expected.minX), (box.minY, expected.minY), (box.width, expected.width), (box.height, expected.height)] {
        expect(abs(actual - wanted) < 0.01, "\(message): \(box), not \(expected)")
    }
}

@MainActor let outlinesShippedTests = Suite("Outlines, as shipped", [
    test("every shipped box kind's outline stands 4 points off its edge, its corners concentric with its own, grown directly; an arrow's is its own line") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), pasteboard: pasteboard, model: ScriptedLanguageModel())
        expectEqual(editor.outlineGap, 4, "what ships")
        // Each kind, with the radius its corners are rounded by (NoteStyle's, FrameStyle's,
        // SubboardStyle's and a pill's, half its height).
        let kinds: [(name: String, id: ShapeID, radius: CGFloat)] = [
            ("note", editor.add(StickyNote(frame: CGRect(x: 100, y: 100, width: 200, height: 200), text: "Milk")), 4),
            ("frame", editor.add(Frame(frame: CGRect(x: 400, y: 100, width: 300, height: 200))), 12),
            ("subboard", editor.add(Subboard(frame: CGRect(x: 400, y: 400, width: 240, height: 160))), 10),
            ("reference", editor.add(Reference(frame: CGRect(x: 700, y: 400, width: 160, height: 32))), 16),
        ]
        let arrow = editor.add(Arrow(start: .free(CGPoint(x: 800, y: 100)), end: .free(CGPoint(x: 1000, y: 300)), bend: 0))
        // The canvas draws every one of them outlined, as ⌘A has them.
        editor.selectedShapeIDs = kinds.map(\.id) + [arrow]
        _ = renderBitmap(editor, size: CGSize(width: 1200, height: 700))
        let unit = CGFloat(0.5).squareRoot()
        for (name, id, radius) in kinds {
            let record = try require(editor.document[id])
            let frame = try require(record.box)
            let ring = try require(editor.outlinePath(of: record))
            expectBox(ring.boundingBoxOfPath, frame.insetBy(dx: -4, dy: -4), "the \(name), 4 out")
            // On the diagonal from the corner arc's center toward the corner, the ring is radius + 4 from
            // it: 3.5 along is inside, 4.5 is outside.
            let center = CGPoint(x: frame.minX + radius, y: frame.minY + radius)
            func along(_ distance: CGFloat) -> CGPoint { CGPoint(x: center.x - distance * unit, y: center.y - distance * unit) }
            expect(ring.contains(along(radius + 3.5)) && !ring.contains(along(radius + 4.5)), "the \(name)'s corner is the shape's, 4 further round")
        }
        let line = try require(editor.document[arrow])
        let own = try require(editor.registry.indicatorPath(of: line, in: editor.shapeContext))
        expectBox(try require(editor.outlinePath(of: line)).boundingBoxOfPath, own.boundingBoxOfPath, "the arrow's, on its own path")
        #if DEBUG
        expectEqual(editor.outlinesGrownByArithmetic, 0, "each kind's outline is a rounded rect, which the core grows directly")
        #endif
    },
])
