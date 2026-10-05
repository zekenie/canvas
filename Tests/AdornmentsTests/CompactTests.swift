import Adornments
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import TestKit

// The compact face (`AdornmentLabel.compact(_:)`): a label at the row's right end falls back on a
// narrower one whenever its full face would leave the row's left end's text not whole (cut short or
// left out): the fewest compact faces, nearest the edge first, that give the text as much width as all
// of them do, and all of them while none shows. So the faces change once as the shape widens (compact
// until the full faces and the whole text fit together, then full), however narrow it is. Pure layout
// first (`AdornmentLayout.frames`, fixture items), then through a board.

/// A text chip 80 wide at the row's right end that has an 18-wide disc as its compact face.
let wideChip = Item(.aboveTopRight, width: 80, isText: true, compact: .init(width: 18))

@MainActor let compactLayoutTests = Suite("Compact adornment faces", [
    test("with room for the title whole, the chip stays in full") {
        // 200 wide: the chip takes 80, the title 100 of the 116 left.
        expectEqual(AdornmentLayout.frames(of: [caption(100), wideChip], width: 200), [rect(0, -27, 100, 18), rect(120, -27, 80, 18)])
    },
    test("a title the full chip would cut short shows whole beside the compact one") {
        // 150 wide: 66 left of the full chip would cut the title (100) short; the compact chip leaves 128.
        expectEqual(AdornmentLayout.frames(of: [caption(100), wideChip], width: 150), [rect(0, -27, 100, 18), rect(132, -27, 18, 18)])
    },
    test("a title the full chip would leave out shows whole beside the compact one") {
        // 100 wide: the full chip leaves 16, under the 30 a title needs.
        expectEqual(AdornmentLayout.frames(of: [caption(60), wideChip], width: 100), [rect(0, -27, 60, 18), rect(82, -27, 18, 18)])
    },
    test("a title a compact chip still can't make whole is cut short beside it where the full chip left it out") {
        // 100 wide: the full chip leaves 16, under the 30 a title needs, so the title vanished; the compact
        // chip leaves 78 of the title's 100: placed, cut short, rather than none.
        expectEqual(AdornmentLayout.frames(of: [caption(100), wideChip], width: 100), [rect(0, -27, 78, 18), rect(82, -27, 18, 18)])
    },
    test("a title the full chip cuts short gets the compact chip's room, though that doesn't make it whole either") {
        // 130 wide: the full chip leaves 46 of the title's 120 (shown, cut); the compact chip leaves 108: still cut, but more.
        expectEqual(AdornmentLayout.frames(of: [caption(120), wideChip], width: 130), [rect(0, -27, 108, 18), rect(112, -27, 18, 18)])
    },
    test("a title that even the compact chip leaves under its room is left out, and the chip is compact all the same: it doesn't change as the shape narrows") {
        // 40 wide: the compact chip would leave 18, under the 30 a title needs: no title either way, the most room.
        expectEqual(AdornmentLayout.frames(of: [caption(100), wideChip], width: 40), [nil, rect(22, -27, 18, 18)])
        expectEqual(AdornmentLayout.frames(of: [caption(100), wideChip], width: 10), [nil, rect(-8, -27, 18, 18)])
    },
    test("the compact faces taken are as few as give the title all the room all of them do, nearest the edge first") {
        let near = Item(.aboveTopRight, width: 60, isText: true, compact: .init(width: 18))
        let far = Item(.aboveTopRight, width: 60, isText: true, compact: .init(width: 18))
        // 120 wide: both in full leave -8 (out); one compact leaves 34, both 76: placed, cut, and both are taken.
        expectEqual(AdornmentLayout.frames(of: [caption(100), near, far], width: 120),
                    [rect(0, -27, 76, 18), rect(102, -27, 18, 18), rect(80, -27, 18, 18)])
        // 100 wide: one compact leaves 14 (out), both leave 56.
        expectEqual(AdornmentLayout.frames(of: [caption(100), near, far], width: 100),
                    [rect(0, -27, 56, 18), rect(82, -27, 18, 18), rect(60, -27, 18, 18)])
        // 60 wide: both compact leave 16: out whatever is taken, so both are taken.
        expectEqual(AdornmentLayout.frames(of: [caption(100), near, far], width: 60),
                    [nil, rect(42, -27, 18, 18), rect(20, -27, 18, 18)])
    },
    test("with two titles at the left end, the compact faces are taken for the width both get") {
        let second = Item(.aboveTopLeft, width: 60, isText: true)
        // 120 wide, titles 40 and 60: with the full chip the first is cut at 36 and the second is out; with
        // the compact one the first is whole and the second placed, at the 54 that's left.
        expectEqual(AdornmentLayout.frames(of: [caption(40), second, wideChip], width: 120),
                    [rect(0, -27, 40, 18), rect(44, -27, 54, 18), rect(102, -27, 18, 18)])
        // 60 wide: with the compact chip the first is placed (38) and the second still out: the width they get.
        expectEqual(AdornmentLayout.frames(of: [caption(40), second, wideChip], width: 60),
                    [rect(0, -27, 38, 18), nil, rect(42, -27, 18, 18)])
    },
    test("as the shape widens the chip changes face once, from the narrowest: compact until the full chip and the whole title fit together, then full") {
        let lock = Item(.aboveTopRight, width: 18, isText: false)
        var faces: [Bool] = []                                                 // compact, at each width
        for width in stride(from: CGFloat(10), through: 400, by: 1) {
            let frames = AdornmentLayout.frames(of: [caption(100), lock, wideChip], width: width)
            let chip = try require(frames[2])
            faces.append(chip.width == 18)
            // Compact exactly while the full chip and the whole title don't both fit, whether or not any title shows.
            expectEqual(chip.width == 18, width < 100 + 4 + 80 + 4 + 18, "at \(width)")
            // The title shows from the least room a title needs beside the compact chip (30 + 4 + 18 + 4 + 18), not before.
            expectEqual(frames[0] != nil, width >= 30 + 4 + 18 + 4 + 18, "at \(width)")
        }
        expectEqual(faces.first, true, "compact from the narrowest")
        expectEqual(faces.last, false)
        let toFull = zip(faces, faces.dropFirst()).filter { $0 && !$1 }.count
        let toCompact = zip(faces, faces.dropFirst()).filter { !$0 && $1 }.count
        expectEqual(toFull, 1, "compact to full, once")
        expectEqual(toCompact, 0, "and never back")
    },
    test("a row with no text at its left end never needs the compact face") {
        expectEqual(AdornmentLayout.frames(of: [wideChip], width: 20), [rect(-60, -27, 80, 18)])
        let symbol = Item(.aboveTopLeft, width: 18, isText: false)
        expectEqual(AdornmentLayout.frames(of: [symbol, wideChip], width: 150)[1], rect(70, -27, 80, 18))
    },
    test("items give way nearest the edge first, one at a time, only until the title shows whole") {
        let near = Item(.aboveTopRight, width: 60, isText: true, compact: .init(width: 18))
        let far = Item(.aboveTopRight, width: 60, isText: true, compact: .init(width: 18))
        // 200 wide: both in full leave 72 (title 100 cut); the first compact leaves 114: whole.
        expectEqual(AdornmentLayout.frames(of: [caption(100), near, far], width: 200),
                    [rect(0, -27, 100, 18), rect(182, -27, 18, 18), rect(118, -27, 60, 18)])
        // 150 wide: one compact leaves 64; both leave 100... 150 - 18 - 4 - 18 - 4 = 106: whole.
        expectEqual(AdornmentLayout.frames(of: [caption(100), near, far], width: 150),
                    [rect(0, -27, 100, 18), rect(132, -27, 18, 18), rect(110, -27, 18, 18)])
    },
    test("an item without a compact face stays as it is, and the corner never takes one") {
        let plain = Item(.aboveTopRight, width: 60, isText: true)
        expectEqual(AdornmentLayout.frames(of: [caption(100), plain], width: 150), [rect(0, -27, 86, 18), rect(90, -27, 60, 18)])
        let corner = Item(.onTopRightCorner, width: 40, isText: true, compact: .init(width: 16))
        expectEqual(AdornmentLayout.frames(of: [caption(100), corner], width: 90), [rect(0, -27, 90, 18), rect(56, -8, 40, 16)])
    },
    test("whatever the items and the width: full where every title is whole already; else every title has the width all the compact faces give, all of them where none shows; and nothing overlaps") {
        var random = SeededGenerator(seed: 11)
        for _ in 0..<500 {
            let items: [Item] = (0..<Int.random(in: 1...5, using: &random)).map { _ in
                switch Int.random(in: 0..<3, using: &random) {
                case 0: caption(CGFloat.random(in: 20...150, using: &random))
                case 1: Item(.aboveTopRight, width: CGFloat.random(in: 18...90, using: &random), isText: true, compact: .init(width: 18))
                default: Item(.aboveTopRight, width: 18, isText: false)
                }
            }
            let width = CGFloat.random(in: 40...300, using: &random)
            let frames = AdornmentLayout.frames(of: items, width: width)
            let full = AdornmentLayout.frames(of: items.map { var item = $0; item.compact = nil; return item }, width: width)
            // Every compactable item in its compact face: the most room the text can get.
            let most = AdornmentLayout.frames(of: items.map { var item = $0; item.width = item.compact?.width ?? item.width; item.compact = nil; return item }, width: width)
            let texts = items.indices.filter { items[$0].placement == .aboveTopLeft && items[$0].isText }
            let isWholeInFull = texts.allSatisfy { (full[$0]?.width ?? 0) >= items[$0].width }
            if isWholeInFull {
                expect(frames == full, "faces stay full where every title is whole (or there is none)")
            } else {
                for i in texts { expectEqual(frames[i]?.width, most[i]?.width, "each title has the width every compact face gives it") }
                if texts.allSatisfy({ most[$0] == nil }) { expect(frames == most, "with no title shown even then, every compact face is taken") }
            }
            for i in texts where frames[i] == nil { expect(full[i] == nil, "a title left out is left out in full too") }
            let shown = frames.compactMap { $0 }
            for (a, b) in shown.enumerated().flatMap({ a in shown.dropFirst(a.offset + 1).map { (a.element, $0) } }) {
                expect(!a.insetBy(dx: -1, dy: 0).intersects(b) || a.minY != b.minY, "none overlaps another: \(a) \(b)")
            }
        }
    },
])

// Through a board: the face drawn is the compact one exactly where the layout takes it.

/// A caption and a text chip with a disc for its compact face, on every shape.
@MainActor func captionAndChip(caption text: String) -> [any CanvasPlugin] {
    [everyShape(Caption.self, id: "captions") { _ in AdornmentLabel(text) },
     everyShape(Flag.self, id: "chips") { _ in AdornmentLabel("Public · 3", systemImage: "globe").compact(AdornmentLabel(systemImage: "globe")) }]
}

@MainActor let compactBoardTests = Suite("Compact adornment faces on a board", [
    test("the chip is in full beside a title it leaves room for, and compact, a disc, as the shape narrows") {
        let title = "A fair title"
        // Wide: both in full, so the caption's own width and the chip's.
        let wide = try adornedHarness(captionAndChip(caption: title))
        let id = wide.add(Box(CGRect(x: 100, y: 100, width: 600, height: 120)))
        let frames = wide.editor.adornmentFrames(of: id)
        let (titleWidth, chipWidth) = (frames[0].rect.width, frames[1].rect.width)
        expect(chipWidth > 40, "the chip is text: \(chipWidth)")
        expectEqual(frames[1].label.text, "Public · 3")
        // Room for the title and the full chip: nothing changes.
        let fits = try adornedHarness(captionAndChip(caption: title))
        let fitting = fits.add(Box(CGRect(x: 100, y: 100, width: titleWidth + chipWidth + 4, height: 120)))
        expectEqual(fits.editor.adornmentFrames(of: fitting)[1].label.text, "Public · 3")
        expectEqual(fits.editor.adornmentFrames(of: fitting)[0].rect.width, titleWidth)
        // A point short: the title would be cut, so the chip goes compact and the title shows whole.
        let short = try adornedHarness(captionAndChip(caption: title))
        let narrow = short.add(Box(CGRect(x: 100, y: 100, width: titleWidth + chipWidth + 3, height: 120)))
        let compact = short.editor.adornmentFrames(of: narrow)
        expectEqual(compact[1].label.text, nil, "the disc")
        expectEqual(compact[1].label.systemImage, "globe")
        expectEqual(compact[1].rect.width, 18)
        expectEqual(compact[0].rect.width, titleWidth, "whole")
    },
    test("the compact face draws in its frame, a disc, and the full chip's pixels are gone") {
        let title = "A fair title"
        let probe = try adornedHarness(captionAndChip(caption: title))
        let id0 = probe.add(Box(CGRect(x: 100, y: 100, width: 600, height: 120)))
        let (titleWidth, chipWidth) = (probe.editor.adornmentFrames(of: id0)[0].rect.width, probe.editor.adornmentFrames(of: id0)[1].rect.width)
        let (plain, adorned, h) = try renders(captionAndChip(caption: title)) {
            $0.add(Box(CGRect(x: 100, y: 100, width: titleWidth + chipWidth + 3, height: 120)))
        }
        let frames = viewRects(h, h.editor.document.shapes[0].id)
        let disc = frames[1].insetBy(dx: -1, dy: -1).integral
        expect(changedPixels(plain, adorned, in: disc) > 100, "the disc draws")
        expectEqual(frames[1].width, 18)
        // Nothing of the chip's text is drawn where the full chip would have been.
        let gone = CGRect(x: frames[1].minX - 40, y: frames[1].minY, width: 30, height: 18)
        expectEqual(changedPixels(plain, adorned, in: gone) - changedPixels(plain, adorned, in: gone.intersection(frames[0].insetBy(dx: -1, dy: -1))), 0)
    },
    test("a title the full chip would push out entirely draws, cut short, beside the compact disc: at 100%, and at a small width as zooming out makes it") {
        let title = "A title that no chip and no room leaves whole"
        for zoom in [1, 0.5] as [CGFloat] {
            let probe = try adornedHarness(captionAndChip(caption: title))
            probe.editor.camera = Camera(origin: .zero, zoom: zoom)
            let id0 = probe.add(Box(CGRect(x: 100, y: 100, width: 800 / zoom, height: 120)))
            let (titleWidth, chipWidth) = (viewRects(probe, id0)[0].width, viewRects(probe, id0)[1].width)
            // The shape's width in view points: the full chip and 20 points of room, under the 30 a title needs.
            let width = chipWidth + AdornmentLayout.spacing + 20
            // Its room beside the full chip is 20, so before the compact face the title vanished.
            let (plain, adorned, h) = try renders(captionAndChip(caption: title), zoom: zoom) {
                $0.add(Box(CGRect(x: 100, y: 100, width: width / zoom, height: 120)))
            }
            let frames = viewRects(h, h.editor.document.shapes[0].id)
            expectEqual(frames.count, 2, "the title and the chip, at \(zoom)")
            guard frames.count == 2 else { continue }
            let labels = h.editor.adornmentFrames(of: h.editor.document.shapes[0].id).map(\.label)
            expectEqual(labels[1].text, nil, "the chip's disc at \(zoom)")
            expectEqual(frames[1].width, 18)
            expect(frames[0].width >= AdornmentLayout.minTextRoom, "the title has the room a title needs: \(frames[0].width) at \(zoom)")
            expect(frames[0].width < titleWidth, "cut short at \(zoom)")
            expectEqual(frames[1].minX - frames[0].maxX, AdornmentLayout.spacing, "4 points before the chip")
            expect(changedPixels(plain, adorned, in: frames[0].insetBy(dx: -1, dy: -1).integral) > 100, "the title draws at \(zoom)")
            expect(changedPixels(plain, adorned, in: frames[1].insetBy(dx: -1, dy: -1).integral) > 100, "the disc draws at \(zoom)")
        }
    },
    test("a compact face fades with its label: opacity applies to both") {
        let label = AdornmentLabel("Private", systemImage: "globe").compact(AdornmentLabel(systemImage: "globe")).opacity(0.5)
        expectEqual(label.opacity, 0.5)
        expectEqual(label.compactFace?.opacity, 0.5)
        expectEqual(AdornmentLabel("x").compactFace, nil)
        expectEqual(AdornmentLabel("x").compact(AdornmentLabel("   ")).compactFace, nil, "a face that shows nothing is no face")
    },
])
