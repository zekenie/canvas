import AppKit
import Boards
@_spi(Host) import Canvas
import CanvasTesting
import Subboards
import TestKit

// The card at `cardFrame` (40, 40, 240 × 160), and the preview fitted into it 12 points in,
// (52, 52, 216 × 136).
private let previewRect = CGRect(x: 52, y: 52, width: 216, height: 136)
/// The middle of the caption, where "2 shapes" is written, clear of a preview's boxes.
private let captionMiddle = CGRect(x: 140, y: 112, width: 40, height: 16)
private let canvasSize = CGSize(width: 320, height: 240)

/// Draws the editor twice: the frame that asks for the previews it shows, and the next, which has
/// built them (as long as it takes) and draws them. Returns both.
@MainActor private func twoFrames(_ h: EditorHarness) -> (asking: NSBitmapImageRep, built: NSBitmapImageRep) {
    h.editor.boardPreviews.frameBudget = .seconds(60)
    let asking = renderBitmap(h.editor, size: canvasSize)
    h.wait(0)
    return (asking, renderBitmap(h.editor, size: canvasSize))
}

@MainActor let previewCardTests = Suite("The card's preview", [
    test("once built, the card shows the board's shapes as silhouettes where they are, fitted; until then, the count") {
        let sub = ShapeRecord(Subboard(frame: cardFrame))
        // A board four times as wide as tall, big enough to be fitted under a tenth of its size:
        // fitted to the rect's width, 54 tall, in its middle (93 to 147), a box at each end.
        let file = CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(sub)]),
                              children: [sub.id: CanvasDocument(shapes: [record(ShapeID(), Box(CGRect(x: 0, y: 0, width: 1000, height: 1000))),
                                                                         record(ShapeID(), Box(CGRect(x: 3000, y: 0, width: 1000, height: 1000)))])])
        let h = try EditorHarness(plugins: subboardPlugins(), file: file)
        let (asking, built) = twoFrames(h)
        expect(darkest(asking, in: captionMiddle) < 170, "the count, while the preview's built")
        expectEqual(darkest(built, in: captionMiddle), 255, "then no caption, and nothing between the boxes")
        for (x, what) in [(78, "the first box"), (240, "the second")] {
            let silhouette = pixel(built, at: CGPoint(x: CGFloat(x), y: 120))
            expect(silhouette[0] < 225 && abs(silhouette[0] - silhouette[2]) < 20, "\(what), in a muted gray: \(silhouette)")
        }
        for y: CGFloat in [70, 170] {
            expectColor(pixel(built, at: CGPoint(x: 78, y: y)), cardFill, "above and below the fitted board, the card at \(y)", within: 2)
        }
        expectEqual(h.scheduler.pendingCount, 0, "no frame asked for once it's drawn")
    },
    test("a board of little is drawn at a tenth of its size, small in the card's middle, not as big as a board of hundreds") {
        let sub = ShapeRecord(Subboard(frame: cardFrame))
        // One 200-point box: 20 points across at a tenth, around the rect's middle, (160, 120).
        let file = CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(sub)]),
                              children: [sub.id: CanvasDocument(shapes: [record(ShapeID(), Box(CGRect(x: 500, y: 500, width: 200, height: 200)))])])
        let h = try EditorHarness(plugins: subboardPlugins(), file: file)
        let built = twoFrames(h).built
        for point in [CGPoint(x: 160, y: 120), CGPoint(x: 152, y: 112), CGPoint(x: 168, y: 128)] {
            let silhouette = pixel(built, at: point)
            expect(silhouette[0] < 225 && abs(silhouette[0] - silhouette[2]) < 20, "the box at \(point): \(silhouette)")
        }
        for point in [CGPoint(x: 140, y: 120), CGPoint(x: 180, y: 120), CGPoint(x: 160, y: 100), CGPoint(x: 160, y: 140)] {
            expectColor(pixel(built, at: point), cardFill, "the card around it, at \(point)", within: 2)
        }
    },
    test("after the board is edited, and after an undo, the card never shows the preview it had: the count, then the board as it is") {
        let nest = Nest()
        let h = try nestHarness(nest)
        let original = twoFrames(h).built
        expect(changedPixels(original, renderBitmap(try CanvasEditor(registry: Registry(plugins: subboardPlugins()), scheduler: ManualScheduler()),
                                                    size: canvasSize), in: previewRect) > 500, "the board's preview")
        expect(h.enter(nest.s))
        let first = try require(h.editor.document.shapes.first { $0.kind == Box.kind }?.id)
        h.editor.transact("Move") { $0.update(first, as: Box.self) { $0.frame.origin.x = 600 } }
        h.editor.goToEnclosingBoard()
        let edited = twoFrames(h)
        expect(darkest(edited.asking, in: captionMiddle) < 170, "coming back, the count, not the old preview")
        expect(changedPixels(original, edited.built, in: previewRect) > 200, "then the board as it is now")
        h.editor.undo()
        expectEqual(h.editor.board, nest.sBoard, "undo showed the board it was made on")
        h.editor.goToEnclosingBoard()
        let undone = twoFrames(h)
        expect(darkest(undone.asking, in: captionMiddle) < 170, "after the undo, the count, not the edited board's preview")
        expectEqual(changedPixels(original, undone.built, in: previewRect), 0, "then the board as it was")
    },
    test("a card with no room for a preview asks for none, whatever its board holds") {
        let nest = Nest()
        let sub = record(nest.s, Subboard(frame: CGRect(x: 40, y: 40, width: 240, height: 30)))
        let file = CanvasFile(root: CanvasDocument(shapes: [sub]), children: nest.file().children)
        let h = try EditorHarness(plugins: subboardPlugins(), file: file)
        _ = renderBitmap(h.editor, size: canvasSize)
        expect(!h.editor.boardPreviews.isPending, "6 points tall inside its inset: too short to show one")
        expectEqual(h.scheduler.pendingCount, 0, "and no frame asked for")
    },
    test("an empty board says so, and asks for no preview") {
        let h = try EditorHarness(plugins: subboardPlugins(), file: Nest().file().removingBoards())
        let (asking, built) = twoFrames(h)
        expect(!h.editor.boardPreviews.isPending, "none asked for")
        expect(darkest(built, in: Band.caption) < 170, "\"Empty\"")
        expectEqual(changedPixels(asking, built, in: previewRect), 0)
    },
])

extension CanvasFile {
    /// The root alone.
    fileprivate func removingBoards() -> CanvasFile { CanvasFile(root: root) }
}
