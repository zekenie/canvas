import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import Keyboard
import Selection
import TableOfContents
import TestKit

/// A box where `boxA` is, and a pocket where `boxB` is, whose board holds a box where `boxA` is.
@MainActor private func pocketFile() -> (file: CanvasFile, a: ShapeID, pocket: ShapeID, inner: ShapeID) {
    let a = ShapeRecord(Box(boxA)), pocket = ShapeRecord(Pocket(boxB)), inner = ShapeRecord(Box(boxA))
    let file = CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(a), AnyShapeRecord(pocket)]),
                          children: [pocket.id: CanvasDocument(shapes: [AnyShapeRecord(inner)])])
    return (file, a.id, pocket.id, inner.id)
}

/// An arrow from A's center with its end free at (400, 400), selected, its end's handle pressed.
@MainActor private func pressFreeEnd(in h: EditorHarness, from a: ShapeID) -> ShapeID {
    let arrow = h.add(Arrow(start: .bound(ArrowBinding(shapeID: a, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false, isExact: false)),
                            end: .free(CGPoint(x: 400, y: 400))))
    h.editor.selection = arrow
    h.move(to: CGPoint(x: 400, y: 400))
    h.press()
    return arrow
}

@MainActor let arrowBoardTests = Suite("Arrows across boards", [
    test("an arrow binds to a shape that owns a board, as to any closed shape") {
        let (file, a, pocket, _) = pocketFile()
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), PocketsPlugin(), ArrowsPlugin(), TableOfContentsPlugin()], file: file)
        let arrow = pressFreeEnd(in: h, from: a)
        h.drag(to: boxB.center, speed: fast)
        h.release()
        let props = try require(h.editor.document[arrow]?.typed(as: Arrow.self)?.props)
        expectEqual(props.start.binding?.shapeID, a)
        expectEqual(props.end.binding?.shapeID, pocket)
    },
    test("a file put in place mid-drag stops the aim: nothing hinted, and the precise timer doesn't run on") {
        let (file, a, pocket, _) = pocketFile()
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), PocketsPlugin(), ArrowsPlugin(), TableOfContentsPlugin()], file: file)
        _ = pressFreeEnd(in: h, from: a)
        h.drag(to: boxB.center, speed: fast)                         // onto the pocket, fast: imprecise, the timer runs
        expectEqual(h.editor.hintedShapeID, pocket)
        let pending = h.scheduler.pendingCount
        expect(pending > 0, "the precise timer")
        h.editor.replaceFile(with: file)
        expect(h.editor.session == nil)
        expectEqual(h.editor.hintedShapeID, nil)
        expectEqual(h.scheduler.pendingCount, pending - 1, "the timer is cancelled with the aim")
    },
])
