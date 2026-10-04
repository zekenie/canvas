import AppKit
import Boards
@_spi(Host) import Canvas
import CanvasTesting
import Subboards
import TestKit
import Titles

// A card zoomed out (`CustomSkeleton`): its fills alone (an indigo border, the card inside it) and
// its board's preview once built; no shadow, symbol or count. Its title is Titles' cover, on it. The
// camera is Geometry's, which these tests don't import, so the level moves instead: `skeletonZoom` just over 100% draws skeletons at 100%, where world units are view
// points, as `cardTests` draw the card.

private let canvas = CGSize(width: 320, height: 240)

/// The canvas with one subboard at `frame`, titled `title`, whose board holds `inside` boxes, drawn
/// as skeletons. Two make a board 1,600 × 400, which fitting alone would draw at 0.135 in the
/// card's preview (216 × 136), and which the card draws at a tenth, its most (160 × 40).
@MainActor private func skeletonCard(title: String?, inside: Int = 0, frame: CGRect = cardFrame) throws -> EditorHarness {
    let nest = Nest()
    var sub = ShapeRecord(id: nest.s, Subboard(frame: frame))
    sub[TitleProperty.self] = title
    let boxes = (0..<inside).map { i in record(ShapeID(), Box(CGRect(x: CGFloat(i) * 1200, y: 0, width: 400, height: 400))) }
    let file = CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(sub)]), children: inside == 0 ? [:] : [nest.s: CanvasDocument(shapes: boxes)])
    let h = try EditorHarness(plugins: subboardPlugins(), file: file)
    h.editor.skeletonZoom = 1.01
    return h
}

@MainActor private func skeleton(title: String?, frame: CGRect = cardFrame) throws -> NSBitmapImageRep {
    renderBitmap(try skeletonCard(title: title, frame: frame).editor, size: canvas)
}

@MainActor let cardSkeletonTests = Suite("The card zoomed out", [
    test("an indigo border and the card inside it, square; no symbol, count or shadow") {
        let h = try skeletonCard(title: nil)
        let drawn = renderBitmap(h.editor, size: canvas)
        h.editor.skeletonZoom = 0
        let full = renderBitmap(h.editor, size: canvas)
        let blank = renderBitmap(try EditorHarness(plugins: subboardPlugins()).editor, size: canvas)
        expectColor(pixel(drawn, at: CGPoint(x: 250, y: 100)), cardFill, "the card", within: 0)
        for point in [CGPoint(x: 40, y: 120), CGPoint(x: 40, y: 40), CGPoint(x: 279, y: 199)] {
            let border = pixel(drawn, at: point)
            expect(border[2] > border[0] + 60, "the border at \(point), in indigo, to the corner: \(border)")
        }
        let right = CGRect(x: 280, y: 50, width: 4, height: 140)
        expectEqual(changedPixels(drawn, blank, in: right), 0, "no shadow")
        expect(changedPixels(full, blank, in: right) > 0, "where the render's is")
        expect(!hasIndigo(drawn, in: Band.symbol), "no symbol")
        expect(hasIndigo(full, in: Band.symbol), "where the render's is")
        expectEqual(darkest(drawn, in: Band.caption), 255, "no count")
        expect(darkest(full, in: Band.caption) < 170, "where the render's is")
    },
    test("in the dark, a dark card in a lighter indigo") {
        let drawn = renderDark(try skeletonCard(title: nil).editor, size: canvas)
        let card = pixel(drawn, at: CGPoint(x: 250, y: 100))
        expect(card.prefix(3).allSatisfy { $0 < 60 } && card[2] > card[0], "the card, dark and a little indigo: \(card)")
        let border = pixel(drawn, at: CGPoint(x: 40, y: 120))
        expect(border[2] > border[0] + 60 && border[2] > 200, "the border, in indigo: \(border)")
    },
    test("its title is on it, Titles' cover, and there's no pill above it") {
        let kitchen = try skeleton(title: "Kitchen"), untitled = try skeleton(title: nil)
        expectEqual(changedPixels(untitled, kitchen, in: Band.pill), 0, "no pill")
        expect(changedPixels(untitled, kitchen, in: cardFrame) > 300, "the title on the card")
        expectEqual(changedPixels(untitled, kitchen, in: CGRect(origin: .zero, size: canvas)), changedPixels(untitled, kitchen, in: cardFrame),
                    "and nowhere else")
    },
    test("its board's preview shows as the card's does once it's built, at no more than a tenth of its board, and nothing while it builds") {
        let h = try skeletonCard(title: nil, inside: 2)
        h.editor.boardPreviews.frameBudget = .seconds(60)
        let asking = renderBitmap(h.editor, size: canvas)
        h.wait(0)
        let built = renderBitmap(h.editor, size: canvas)
        h.editor.skeletonZoom = 0
        let full = renderBitmap(h.editor, size: canvas)
        let preview = CGRect(x: 52, y: 52, width: 216, height: 136)
        expectEqual(darkest(asking, in: preview), 255, "the card alone while it's built")
        expect(changedPixels(asking, built, in: preview) > 500, "then the preview")
        expectEqual(darkest(built, in: CGRect(x: 52, y: 52, width: 26, height: 136)), 255, "at a tenth: 160 across, from x 80")
        expectEqual(changedPixels(built, full, in: preview), 0, "as the card draws it")
        expectEqual(h.scheduler.pendingCount, 0, "no frame asked for once it's drawn")
    },
    test("a card with no room for a preview asks for none") {
        let h = try skeletonCard(title: nil, inside: 2, frame: CGRect(x: 40, y: 40, width: 240, height: 30))
        _ = renderBitmap(h.editor, size: canvas)
        expect(!h.editor.boardPreviews.isPending)
    },
    test("a card sized small is drawn inside its frame") {
        let blank = renderBitmap(try EditorHarness(plugins: subboardPlugins()).editor, size: canvas)
        for size in [CGSize(width: 30, height: 12), CGSize(width: 8, height: 4), CGSize(width: 240, height: 20)] {
            let frame = CGRect(origin: CGPoint(x: 40, y: 40), size: size)
            let bitmap = try skeleton(title: nil, frame: frame)
            expectEqual(changedPixels(blank, bitmap, in: CGRect(origin: .zero, size: canvas)), changedPixels(blank, bitmap, in: frame), "\(size)")
            expect(changedPixels(blank, bitmap, in: frame) > 0, "\(size) draws")
        }
    },
])
