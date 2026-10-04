import AppKit
import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import TestKit
import Titles

// Zoomed out, where shapes are skeletons and show no adornments, a titled shape says its title on
// itself: a cover, plain text in an ink that reads on the shape's surface, sized by the shape.
// At 30% the test plaque is where `plaqueFrame` is in view, 200 by 120 points with its top-left
// corner at (60, 100), so a cover's text is read in view points through the camera.

/// A rect given in view points at `zoom`, as the world rect that's there.
func world(_ frame: CGRect, atZoom zoom: CGFloat) -> CGRect {
    CGRect(x: frame.minX / zoom, y: frame.minY / zoom, width: frame.width / zoom, height: frame.height / zoom)
}

/// The whole canvas, in view points.
let canvasView = CGRect(x: 0, y: 0, width: 400, height: 300)

/// How many pixels of a rect have a red channel under 90 (`dark`) or over 200: a dark ink's
/// glyphs, or a light one's, over a mid gray.
@MainActor func inkPixels(_ rep: NSBitmapImageRep, in rect: CGRect, dark: Bool) -> Int {
    var count = 0
    for y in stride(from: rect.minY, to: rect.maxY, by: 1) {
        for x in stride(from: rect.minX, to: rect.maxX, by: 1) {
            let red = pixel(rep, at: CGPoint(x: x, y: y))[0]
            if dark ? red < 90 : red > 200 { count += 1 }
        }
    }
    return count
}

/// How wide `word` is set at `size` points, as a cover sets it.
@MainActor func wordWidth(_ word: String, at size: CGFloat) -> CGFloat {
    NSAttributedString(string: word, attributes: [.font: NSFont.systemFont(ofSize: size, weight: .semibold)]).size().width
}

@MainActor let coverTests = Suite("Title covers", [
    test("zoomed out, a titled shape has its title on it, centered, in a dark ink on a light surface, and no pill above it") {
        let editor = try titleEditor()
        editor.camera = Camera(origin: .zero, zoom: 0.3)
        let id = editor.add(Plaque(world(plaqueFrame, atZoom: 0.3)))
        let untitled = render(editor)
        expectEqual(editor.titleCover(of: id), nil, "untitled: none")
        editor.rename(id, "Front desk")
        let titled = render(editor)
        let cover = try require(editor.titleCover(of: id))
        expectEqual(cover.text, "Front desk")
        let text = editor.camera.toView(cover.rect)
        expect(plaqueFrame.contains(text), "inside the shape: \(text)")
        expectClose(text.midX, plaqueFrame.midX, within: 1.5)
        expectClose(text.midY, plaqueFrame.midY, within: 1.5)
        let drawn = changedPixels(untitled, titled, in: text.insetBy(dx: -3, dy: -3).integral)
        expect(drawn > 150, "the text: \(drawn)")
        expectEqual(changedPixels(untitled, titled, in: canvasView) - drawn, 0, "and nowhere else: no pill above the shape, no plate")
        expect(inkPixels(titled, in: text, dark: true) > 40, "in a dark ink")
        expectEqual(inkPixels(titled, in: text, dark: false), 0, "and no light one")
    },
    test("in full, at 35% and above, a shape has no cover: its pill is above it, and nothing is on it") {
        let editor = try titleEditor()
        editor.camera = Camera(origin: .zero, zoom: 0.35)
        let id = editor.add(Plaque(world(plaqueFrame, atZoom: 0.35)))
        let untitled = render(editor)
        editor.rename(id, "Front desk")
        expectEqual(editor.titleCover(of: id), nil)
        let titled = render(editor)
        expect(changedPixels(untitled, titled, in: CGRect(x: 60, y: 75, width: 36, height: 12)) > 300, "the pill")
        expectEqual(changedPixels(untitled, titled, in: plaqueFrame), 0, "nothing on the shape")
    },
    test("the ink is chosen by the surface the kind says it's drawn on: light on a dark one, and dark without one said, on the default skeleton's gray") {
        let night = Contributor(id: "disc-titles") { $0.title(Disc.self, coverSurface: NSColor(white: 0.1, alpha: 1)) { _ in "Disc" } }
        let editor = try titleEditor([night])
        editor.camera = Camera(origin: .zero, zoom: 0.3)
        let disc = editor.add(Disc(world(plaqueFrame, atZoom: 0.3)))
        let plaque = editor.add(Plaque(world(plaqueFrame.offsetBy(dx: 0, dy: 140), atZoom: 0.3)), named: "Disc")
        let rendered = render(editor)
        let onDark = editor.camera.toView(try require(editor.titleCover(of: disc)).rect)
        let onDefault = editor.camera.toView(try require(editor.titleCover(of: plaque)).rect)
        expect(inkPixels(rendered, in: onDark, dark: false) > 40, "a light ink on a dark surface")
        expect(inkPixels(rendered, in: onDefault, dark: true) > 40, "a dark ink without a surface said")
        expectEqual(inkPixels(rendered, in: onDefault, dark: false), 0, "and not a light one")
    },
    test("no cover on an untitled or blank-titled shape, a shape too small on screen to say anything on, or a kind that shows no pill; a card-sized one has it") {
        let editor = try titleEditor([Contributor(id: "disc-titles") { $0.title(Disc.self, pill: false) { _ in "Disc" } }])
        editor.camera = Camera(origin: .zero, zoom: 0.3)
        func plaque(_ frame: CGRect, named name: String? = nil) -> ShapeID { editor.add(Plaque(world(frame, atZoom: 0.3)), named: name) }
        let none = plaque(CGRect(x: 20, y: 20, width: 100, height: 60))
        let blank = plaque(CGRect(x: 140, y: 20, width: 100, height: 60), named: "  ")
        let narrow = plaque(CGRect(x: 20, y: 120, width: 36, height: 60), named: "Narrow")
        let short = plaque(CGRect(x: 80, y: 120, width: 100, height: 12), named: "Short")
        let disc = editor.add(Disc(world(CGRect(x: 260, y: 20, width: 100, height: 60), atZoom: 0.3)))
        for (name, id) in [("untitled", none), ("blank", blank), ("narrow", narrow), ("short", short), ("a kind with no pill", disc)] {
            expectEqual(editor.titleCover(of: id), nil, name)
        }
        // A card's size, wide and a line tall, still says its title, inside it.
        let card = plaque(CGRect(x: 20, y: 220, width: 72, height: 15.6), named: "Pet")
        let cardText = editor.camera.toView(try require(editor.titleCover(of: card), "72 by 15.6 points").rect)
        expect(CGRect(x: 20, y: 220, width: 72, height: 15.6).contains(cardText), "\(cardText)")
        // Just big enough, 56 by 30, a short title is said.
        let small = plaque(CGRect(x: 200, y: 120, width: 56, height: 30), named: "Hi")
        let smallText = editor.camera.toView(try require(editor.titleCover(of: small), "56 by 30 points").rect)
        expect(CGRect(x: 200, y: 120, width: 56, height: 30).contains(smallText), "\(smallText)")
    },
    test("the size follows the shape's, not the title's: equal shapes, equal sizes, whatever they say; a bigger shape bigger; 28 points at most") {
        let editor = try titleEditor()
        editor.camera = Camera(origin: .zero, zoom: 0.3)
        func plaque(_ frame: CGRect, _ title: String) -> ShapeID { editor.add(Plaque(world(frame, atZoom: 0.3)), named: title) }
        let a = plaque(CGRect(x: 20, y: 20, width: 120, height: 80), "cli")
        let b = plaque(CGRect(x: 160, y: 20, width: 120, height: 80), "Lock")
        let c = plaque(CGRect(x: 20, y: 120, width: 120, height: 80), "Front desk")
        let big = plaque(CGRect(x: 160, y: 120, width: 240, height: 160), "cli")
        let huge = plaque(CGRect(x: 20, y: 220, width: 600, height: 400), "cli")
        let sizes = try [a, b, c, big, huge].map { try require(editor.titleCover(of: $0)).fontSize }
        expectEqual(sizes[0], sizes[1], "short titles, the same size")
        expectEqual(sizes[0], sizes[2], "and a longer one that fits")
        expect(sizes[3] > sizes[0], "a bigger shape: \(sizes)")
        expectEqual(sizes[4], 28, "the most")
        expectEqual(sizes[0], (0.22 * 80 * 2).rounded(.down) / 2, "0.22 of the shorter side, to half points")
    },
    test("a long title is smaller, to fit the shape's room, never under 9 points") {
        let editor = try titleEditor()
        editor.camera = Camera(origin: .zero, zoom: 0.3)
        let title = "A name much longer than the plaque is wide, which wraps"
        let short = editor.add(Plaque(world(plaqueFrame, atZoom: 0.3)), named: "Hi")
        let long = editor.add(Plaque(world(plaqueFrame.offsetBy(dx: 0, dy: 140), atZoom: 0.3)), named: title)
        let small = editor.add(Plaque(world(CGRect(x: 280, y: 100, width: 100, height: 60), atZoom: 0.3)), named: title)
        let sizes = try [short, long, small].map { try require(editor.titleCover(of: $0)).fontSize }
        expect(sizes[1] >= 9 && sizes[1] < sizes[0], "a long title in the same shape: \(sizes[1]) against \(sizes[0])")
        expect(sizes[2] >= 9 && sizes[2] < sizes[1], "the same title in a smaller shape: \(sizes[2])")
        for id in [short, long, small] {
            let shape = try require(editor.shapeContext.geometry(of: id)).bounds
            expect(shape.contains(try require(editor.titleCover(of: id)).rect), "inside its shape")
        }
    },
    test("a word is never broken: the size is made smaller until the widest word fits a line; where it can't at 9 points, one line, truncated") {
        let editor = try titleEditor()
        editor.camera = Camera(origin: .zero, zoom: 0.3)
        // Words of a plugin list, on notes of 80 and 60 points, where the title at the shape's size
        // would need a word wider than the line.
        for (shapeWidth, words) in [(80, ["adornments", "mentions", "slash commands", "validation", "topology"]), (60, ["mentions", "boards", "arrows"])] {
            for (i, title) in words.enumerated() {
                let frame = CGRect(x: 20 + CGFloat(i % 4) * 90, y: 20 + CGFloat(i / 4) * 90, width: CGFloat(shapeWidth), height: 60)
                let id = editor.add(Plaque(world(frame, atZoom: 0.3)), named: title)
                let cover = try require(editor.titleCover(of: id))
                let text = editor.camera.toView(cover.rect)
                for word in title.split(separator: " ") {
                    expect(wordWidth(String(word), at: cover.fontSize) <= text.width + 0.5, "“\(word)” fits its line: \(cover.fontSize) pt in \(text.width)")
                }
            }
        }
        // Too narrow for the word at 9 points: one line, the title cut with an ellipsis, not broken over lines.
        let narrow = editor.add(Plaque(world(CGRect(x: 20, y: 200, width: 48, height: 40), atZoom: 0.3)), named: "adornments")
        let cover = try require(editor.titleCover(of: narrow))
        expectEqual(cover.fontSize, 9)
        expect(editor.camera.toView(cover.rect).height <= 9 * 1.5, "one line: \(editor.camera.toView(cover.rect))")
    },
    test("a title is cut to 120 characters, ending in an ellipsis; one of 120 is whole") {
        let editor = try titleEditor()
        editor.camera = Camera(origin: .zero, zoom: 0.3)
        let id = editor.add(Plaque(world(plaqueFrame, atZoom: 0.3)))
        let whole = String(repeating: "ab", count: 60)
        editor.rename(id, whole)
        expectEqual(editor.titleCover(of: id)?.text, whole, "120 characters")
        editor.rename(id, whole + "c")
        expectEqual(editor.titleCover(of: id)?.text, whole + "…", "121")
        editor.rename(id, String(repeating: "word ", count: 2_000))
        let cut = try require(editor.titleCover(of: id)).text
        expectEqual(cut.count, 121, "thousands of characters: a hundred and twenty and an ellipsis")
        expect(cut.hasSuffix("…"), cut)
    },
    test("a title too long for its shape is cut where the shape's room ends, at the smallest size, and nothing is drawn outside the shape") {
        let editor = try titleEditor()
        editor.camera = Camera(origin: .zero, zoom: 0.3)
        let frame = CGRect(x: 100, y: 100, width: 80, height: 40)
        let id = editor.add(Plaque(world(frame, atZoom: 0.3)))
        let untitled = render(editor)
        editor.rename(id, "A name much longer than the plaque is wide, and wider still")
        let titled = render(editor)
        let cover = try require(editor.titleCover(of: id))
        expectEqual(cover.fontSize, 9, "the smallest")
        expect(frame.insetBy(dx: 3.5, dy: 3.5).contains(editor.camera.toView(cover.rect)), "inside the shape, with room around it")
        let inside = changedPixels(untitled, titled, in: frame)
        expect(inside > 150, "drawn: \(inside)")
        expectEqual(changedPixels(untitled, titled, in: canvasView) - inside, 0, "nothing outside the shape")
    },
    test("a container's cover is at its top left, where its pill goes; other shapes' are centered") {
        let corrals = Contributor(id: "corral-titles") { $0.title(Corral.self) }
        let editor = try titleEditor([CorralsPlugin(), corrals])
        editor.camera = Camera(origin: .zero, zoom: 0.3)
        let corral = editor.add(Corral(world(plaqueFrame, atZoom: 0.3)))
        editor.rename(corral, "Lobby")
        let text = editor.camera.toView(try require(editor.titleCover(of: corral)).rect)
        expectClose(text.minX, plaqueFrame.minX + 4, within: 0.5)
        expectClose(text.minY, plaqueFrame.minY + 4, within: 0.5)
        let plaque = editor.add(Plaque(world(plaqueFrame.offsetBy(dx: 0, dy: 140), atZoom: 0.3)), named: "Lobby")
        let centered = editor.camera.toView(try require(editor.titleCover(of: plaque)).rect)
        expectClose(centered.midY, plaqueFrame.midY + 140, within: 1.5)
    },
    test("the cover goes where its shape is drawn (a shake), in view points") {
        let editor = try titleEditor()
        editor.camera = Camera(origin: .zero, zoom: 0.3)
        let id = editor.add(Plaque(world(plaqueFrame, atZoom: 0.3)), named: "Lobby")
        let still = render(editor)
        let text = editor.camera.toView(try require(editor.titleCover(of: id)).rect)
        editor.setDrawingOffset(CGPoint(x: 12, y: 0), for: id)
        let moved = render(editor)
        for y in stride(from: text.minY, to: text.maxY, by: 2) {
            for x in stride(from: text.minX, to: text.maxX, by: 2) {
                expectEqual(pixel(moved, at: CGPoint(x: x + 12, y: y)), pixel(still, at: CGPoint(x: x, y: y)), "(\(x), \(y))")
            }
        }
    },
])
