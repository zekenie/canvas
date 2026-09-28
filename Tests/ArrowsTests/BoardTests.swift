import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import Keyboard
import Selection
import TableOfContents
import TestKit

/// The arrow tool as the default one, so showing a board doesn't change it: what's reset is reset
/// for the board, not the tool.
private struct ArrowsByDefault: CanvasPlugin {
    var id: PluginID { "arrows-by-default" }
    func register(into registrar: inout PluginRegistrar) { registrar.defaultTool(.arrow) }
}

/// A box where `boxA` is, and a pocket where `boxB` is, whose board holds a box where `boxA` is.
@MainActor private func pocketFile() -> (file: CanvasFile, a: ShapeID, pocket: ShapeID, inner: ShapeID) {
    let a = ShapeRecord(Box(boxA)), pocket = ShapeRecord(Pocket(boxB)), inner = ShapeRecord(Box(boxA))
    let file = CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(a), AnyShapeRecord(pocket)]),
                          children: [pocket.id: CanvasDocument(shapes: [AnyShapeRecord(inner)])])
    return (file, a.id, pocket.id, inner.id)
}

@MainActor let arrowBoardTests = Suite("Arrows across boards", [
    test("an arrow binds to a shape that owns a board, as to any closed shape") {
        let (file, a, pocket, _) = pocketFile()
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), PocketsPlugin(), ArrowsPlugin(), TableOfContentsPlugin()], file: file)
        h.key("a")
        h.move(to: boxA.center)
        h.press()
        h.drag(to: boxB.center, speed: fast)
        h.release()
        let arrow = try require(h.editor.document.shapes.lazy.compactMap { $0.typed(as: Arrow.self)?.props }.first)
        expectEqual(arrow.start.binding?.shapeID, a)
        expectEqual(arrow.end.binding?.shapeID, pocket)
    },
    test("showing another board stops the aim: nothing hinted, and the precise timer doesn't run on") {
        let (file, _, pocket, inner) = pocketFile()
        let h = try EditorHarness(plugins: [KeyboardPlugin(), FixturesPlugin(), PocketsPlugin(), ArrowsPlugin(), TableOfContentsPlugin(), ArrowsByDefault()], file: file)
        expectEqual(h.editor.currentToolID, .arrow)
        h.move(to: boxA.center)
        h.wait(300)                                     // halfway to aiming precisely
        expect(h.editor.hintedShapeID != nil)
        expectEqual(h.scheduler.pendingCount, 1, "the precise timer")
        h.enter(pocket)
        expectEqual(h.editor.currentToolID, .arrow, "still the default tool")
        expectEqual(h.editor.hintedShapeID, nil)
        expectEqual(h.scheduler.pendingCount, 0, "the timer is cancelled with the aim")
        h.move(to: boxA.center + CGPoint(x: 1, y: 0))
        expectEqual(h.editor.hintedShapeID, inner, "aiming starts again on the board shown")
    },
    test("a file put in place stops the aim too, though the tool stays") {
        let (file, a, _, _) = pocketFile()
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), PocketsPlugin(), ArrowsPlugin(), TableOfContentsPlugin()], file: file)
        h.key("a")
        h.move(to: boxA.center)
        expectEqual(h.editor.hintedShapeID, a)
        h.editor.replaceFile(with: file)
        expectEqual(h.editor.currentToolID, .arrow)
        expectEqual(h.editor.hintedShapeID, nil)
        h.wait(1000)
        h.press()
        h.drag(to: CGPoint(x: 400, y: 400), speed: fast)
        h.release()
        let arrow = try require(h.editor.document.shapes.lazy.compactMap { $0.typed(as: Arrow.self)?.props }.first)
        expectEqual(arrow.start.binding?.isPrecise, false, "no longer aiming: the hover before the file was put in place doesn't count")
    },
])
