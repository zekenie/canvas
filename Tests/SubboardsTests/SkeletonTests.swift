import AppKit
import Boards
@_spi(Host) import Canvas
import CanvasTesting
import Subboards
import TestKit
import Titles

// A card zoomed out (`CustomSkeleton`): its fills alone (the plates, an indigo border, the header
// band, a white body), a bar where its title is, and its board's preview once built; no shadow,
// symbol, title or count. The camera is Geometry's, which these tests don't import, so the level
// moves instead: `skeletonZoom` just over 100% draws skeletons at 100%, where world units are view
// points, as `cardTests` draw the card.

private let canvas = CGSize(width: 320, height: 240)

/// The canvas with one subboard at `frame`, titled `title`, whose board holds `inside` boxes, drawn
/// as skeletons. Two make a board 1,600 × 400, which fitting alone would draw at 0.135 in the
/// card's preview (216 × 96), and which the card draws at a tenth, its most (160 × 40).
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

/// How far right the title's bar reaches in the header: the last point inside the border, along
/// the middle of the bar's row, darker than the band.
@MainActor private func barEnd(_ bitmap: NSBitmapImageRep) -> CGFloat? {
    let band = pixel(bitmap, at: CGPoint(x: 276, y: 57))
    return (44..<276).last { pixel(bitmap, at: CGPoint(x: $0, y: 57))[0] < band[0] - 8 }.map { CGFloat($0 + 1) }
}

/// How far right the render's title reaches in the header: the last column of the title's band
/// with a pixel of its text in it.
@MainActor private func titleEnd(_ bitmap: NSBitmapImageRep) -> CGFloat? {
    let band = pixel(bitmap, at: CGPoint(x: 276, y: 57))
    return (Int(Band.title.minX)..<Int(Band.title.maxX)).last { x in
        (Int(Band.title.minY)..<Int(Band.title.maxY)).contains { pixel(bitmap, at: CGPoint(x: x, y: $0))[0] < band[0] - 60 }
    }.map { CGFloat($0 + 1) }
}

@MainActor let cardSkeletonTests = Suite("The card zoomed out", [
    test("the plates, an indigo border, the header band tinted indigo, a white body and a bar for its title; no symbol, count or shadow") {
        let h = try skeletonCard(title: "Kitchen")
        let drawn = renderBitmap(h.editor, size: canvas)
        h.editor.skeletonZoom = 0
        let full = renderBitmap(h.editor, size: canvas)
        let blank = renderBitmap(try EditorHarness(plugins: subboardPlugins()).editor, size: canvas)
        expectColor(pixel(drawn, at: CGPoint(x: 265, y: 46)), [230, 230, 250], "the header band")
        expectColor(pixel(drawn, at: CGPoint(x: 250, y: 100)), [255, 255, 255], "the body", within: 0)
        let border = pixel(drawn, at: CGPoint(x: 40, y: 120))
        expect(border[2] > border[0] + 60, "the border, in indigo: \(border)")
        let bar = pixel(drawn, at: CGPoint(x: 90, y: 57))
        expect(bar[0] < 200 && bar[2] > bar[0], "the title's bar, on the band: \(bar)")
        for y: CGFloat in [194, 198] {
            let plate = pixel(drawn, at: CGPoint(x: 160, y: y))
            expect(plate[2] > plate[0] + 8 && plate[0] > 200, "a plate at \(y), lavender: \(plate)")
        }
        let right = CGRect(x: 280, y: 50, width: 4, height: 140)
        expectEqual(changedPixels(drawn, blank, in: right), 0, "no shadow")
        expect(changedPixels(full, blank, in: right) > 0, "where the render's is")
        expectEqual(darkest(drawn, in: Band.symbol), 250, "no symbol: the band where it is")
        expect(darkest(full, in: Band.symbol) < 230, "where the render's is")
        expectEqual(darkest(drawn, in: Band.caption), 255, "no count: the body, white")
        expect(darkest(full, in: Band.caption) < 170, "where the render's is")
    },
    test("the title's bar is as long as its characters, no longer than the header leaves it; the placeholder's is dimmed") {
        let kitchen = try skeleton(title: "Kitchen"), untitled = try skeleton(title: nil)
        let long = try skeleton(title: String(repeating: "Long title ", count: 8))
        let kitchenEnd = try require(barEnd(kitchen)), untitledEnd = try require(barEnd(untitled)), longEnd = try require(barEnd(long))
        // After the padding and the symbol's place, 34 in, 7.8 a character.
        expect(abs(kitchenEnd - (74 + 7 * 7.8)) < 2, "Kitchen: \(kitchenEnd)")
        expect(abs(untitledEnd - (74 + 17 * 7.8)) < 2, "Untitled Subboard: \(untitledEnd)")
        expect(abs(longEnd - 270) < 2, "cut where the title's room ends: \(longEnd)")
        let titled = pixel(kitchen, at: CGPoint(x: 90, y: 57)), placeholder = pixel(untitled, at: CGPoint(x: 90, y: 57))
        expect(placeholder[0] > titled[0] + 10, "dimmed: \(placeholder), \(titled)")
        expectEqual(changedPixels(untitled, try skeleton(title: "   "), in: Band.title), 0, "a blank title is none")
    },
    test("the title's bar is as long as its columns, about as long as the title in full, in Japanese or Chinese too: a character a full em, two columns") {
        // Within a few points of its text, and nearer than a column a character would be: Latin
        // to a point, Japanese and Chinese to 10%; Hangul, set at 0.85 em, and emoji, at 1.3,
        // to a quarter.
        for (title, within) in [("Kitchen", 3), ("Groceries and more", 3), ("東京の会議メモ", 12), ("会议记录和计划", 12),
                                ("한국어 회의록", 25), ("🎉🎂🎈 Party", 15)] as [(String, CGFloat)] {
            let h = try skeletonCard(title: title)
            let bar = try require(barEnd(renderBitmap(h.editor, size: canvas)), title)
            h.editor.skeletonZoom = 0
            let full = try require(titleEnd(renderBitmap(h.editor, size: canvas)), title)
            expect(abs(bar - full) < within, "\(title): its bar ends at \(bar), its title at \(full)")
            let characters = 74 + CGFloat(title.unicodeScalars.count) * 7.8
            expect(title.utf8.count == title.count || abs(bar - full) < abs(characters - full), "\(title): a column a character ends at \(characters)")
        }
        let tokyo = try require(barEnd(try skeleton(title: "東京の会議メモ")))
        expect(abs(tokyo - (74 + 14 * 7.8)) < 2, "seven characters, fourteen columns: \(tokyo)")
    },
    test("its board's preview shows as the card's does once it's built, at no more than a tenth of its board, and nothing while it builds") {
        let h = try skeletonCard(title: nil, inside: 2)
        h.editor.boardPreviews.frameBudget = .seconds(60)
        let asking = renderBitmap(h.editor, size: canvas)
        h.wait(0)
        let built = renderBitmap(h.editor, size: canvas)
        h.editor.skeletonZoom = 0
        let full = renderBitmap(h.editor, size: canvas)
        let preview = CGRect(x: 52, y: 84, width: 216, height: 96)
        expectEqual(darkest(asking, in: preview), 255, "white while it's built")
        expect(changedPixels(asking, built, in: preview) > 500, "then the preview")
        expectEqual(darkest(built, in: CGRect(x: 52, y: 84, width: 26, height: 96)), 255, "at a tenth: 160 across, from x 80")
        expectEqual(changedPixels(built, full, in: preview), 0, "as the card draws it")
        expectEqual(h.scheduler.pendingCount, 0, "no frame asked for once it's drawn")
    },
    test("a card with no room for a preview asks for none") {
        let h = try skeletonCard(title: nil, inside: 2, frame: CGRect(x: 40, y: 40, width: 240, height: 40))
        _ = renderBitmap(h.editor, size: canvas)
        expect(!h.editor.boardPreviews.isPending)
    },
    test("a card sized small is drawn inside its frame") {
        let blank = renderBitmap(try EditorHarness(plugins: subboardPlugins()).editor, size: canvas)
        for size in [CGSize(width: 30, height: 12), CGSize(width: 8, height: 4), CGSize(width: 240, height: 20)] {
            let frame = CGRect(origin: CGPoint(x: 40, y: 40), size: size)
            let bitmap = try skeleton(title: "Kitchen", frame: frame)
            expectEqual(changedPixels(blank, bitmap, in: CGRect(origin: .zero, size: canvas)), changedPixels(blank, bitmap, in: frame), "\(size)")
            expect(changedPixels(blank, bitmap, in: frame) > 0, "\(size) draws")
        }
    },
])
