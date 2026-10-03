import AppKit
import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import TestKit
import Titles

// Zoomed out, where shapes are skeletons and show no adornments, a titled shape says its title on
// itself: a cover, the title in white on the pill's dark plate, as large as the shape allows. At 30%
// the test plaque is where `plaqueFrame` is in view, 200 by 120 points with its top-left corner at
// (60, 100), so a cover's plate is read in view points through the camera.

/// A rect given in view points at `zoom`, as the world rect that's there.
func world(_ frame: CGRect, atZoom zoom: CGFloat) -> CGRect {
    CGRect(x: frame.minX / zoom, y: frame.minY / zoom, width: frame.width / zoom, height: frame.height / zoom)
}

/// The whole canvas, in view points.
let canvasView = CGRect(x: 0, y: 0, width: 400, height: 300)

/// How many pixels of a rect are light: a title's white, on a dark plate.
@MainActor func lightPixels(_ rep: NSBitmapImageRep, in rect: CGRect) -> Int {
    var count = 0
    for y in stride(from: rect.minY, to: rect.maxY, by: 1) {
        for x in stride(from: rect.minX, to: rect.maxX, by: 1) where pixel(rep, at: CGPoint(x: x, y: y))[0] > 200 { count += 1 }
    }
    return count
}

@MainActor let coverTests = Suite("Title covers", [
    test("zoomed out, a titled shape has its title on it, centered on a dark plate, and no pill above it") {
        let editor = try titleEditor()
        editor.camera = Camera(origin: .zero, zoom: 0.3)
        let id = editor.add(Plaque(world(plaqueFrame, atZoom: 0.3)))
        let untitled = render(editor)
        expectEqual(editor.titleCover(of: id), nil, "untitled: none")
        editor.rename(id, "Front desk")
        let titled = render(editor)
        let cover = try require(editor.titleCover(of: id))
        expectEqual(cover.text, "Front desk")
        let plate = editor.camera.toView(cover.rect)
        expect(plaqueFrame.contains(plate), "inside the shape: \(plate)")
        expectClose(plate.midX, plaqueFrame.midX, within: 1)
        expectClose(plate.midY, plaqueFrame.midY, within: 1)
        let drawn = changedPixels(untitled, titled, in: plate.insetBy(dx: -1, dy: -1).integral)
        expect(drawn > 800, "the plate: \(drawn)")
        expectEqual(changedPixels(untitled, titled, in: canvasView) - drawn, 0, "and nowhere else: no pill above the shape")
        let fill = pixel(titled, at: CGPoint(x: plate.minX + 2.5, y: plate.midY))
        expect((55...100).contains(fill[0]), "the pill's dark gray: \(fill)")
        expect(lightPixels(titled, in: plate) > 30, "its text, in white")
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
    test("no cover on an untitled or blank-titled shape, a shape too small on screen to say anything on, or a kind that shows no pill; a card-sized one has it") {
        let editor = try titleEditor([Contributor(id: "disc-titles") { $0.title(Disc.self, pill: false) { _ in "Disc" } }])
        editor.camera = Camera(origin: .zero, zoom: 0.3)
        func plaque(_ frame: CGRect, named name: String? = nil) -> ShapeID { editor.add(Plaque(world(frame, atZoom: 0.3)), named: name) }
        let none = plaque(CGRect(x: 20, y: 20, width: 100, height: 60))
        let blank = plaque(CGRect(x: 140, y: 20, width: 100, height: 60), named: "  ")
        let narrow = plaque(CGRect(x: 20, y: 120, width: 40, height: 60), named: "Narrow")
        let short = plaque(CGRect(x: 80, y: 120, width: 100, height: 12), named: "Short")
        let disc = editor.add(Disc(world(CGRect(x: 260, y: 20, width: 100, height: 60), atZoom: 0.3)))
        for (name, id) in [("untitled", none), ("blank", blank), ("narrow", narrow), ("short", short), ("a kind with no pill", disc)] {
            expectEqual(editor.titleCover(of: id), nil, name)
        }
        // A card's size, wide and a line tall, still says its title, the plate as tall as the shape.
        let card = plaque(CGRect(x: 20, y: 220, width: 72, height: 15.6), named: "Pet")
        let cardPlate = editor.camera.toView(try require(editor.titleCover(of: card), "72 by 15.6 points").rect)
        expect(CGRect(x: 20, y: 220, width: 72, height: 15.6).contains(cardPlate), "\(cardPlate)")
        // Just big enough, 56 by 30, a short title is said.
        let small = plaque(CGRect(x: 200, y: 120, width: 56, height: 30), named: "Hi")
        let plate = editor.camera.toView(try require(editor.titleCover(of: small), "56 by 30 points").rect)
        expect(CGRect(x: 200, y: 120, width: 56, height: 30).contains(plate), "\(plate)")
    },
    test("the text is as large as the shape allows, 30 points down to 9: a long title smaller than a short one, and a smaller shape smaller") {
        let editor = try titleEditor()
        editor.camera = Camera(origin: .zero, zoom: 0.3)
        let title = "A name much longer than the plaque is wide, which wraps"
        let short = editor.add(Plaque(world(plaqueFrame, atZoom: 0.3)), named: "Hi")
        let long = editor.add(Plaque(world(plaqueFrame.offsetBy(dx: 0, dy: 140), atZoom: 0.3)), named: title)
        let small = editor.add(Plaque(world(CGRect(x: 280, y: 100, width: 100, height: 60), atZoom: 0.3)), named: "Hi")
        let sizes = try [short, long, small].map { try require(editor.titleCover(of: $0)).fontSize }
        expectEqual(sizes[0], 30, "a short title, large: the most")
        expect(sizes[1] >= 9 && sizes[1] < sizes[0], "a long title in the same shape: \(sizes[1])")
        expect(sizes[2] >= 9 && sizes[2] < sizes[0], "the same title in a smaller shape: \(sizes[2])")
        for id in [short, long, small] {
            let shape = try require(editor.shapeContext.geometry(of: id)).bounds
            expect(shape.contains(try require(editor.titleCover(of: id)).rect), "inside its shape")
        }
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
        expect(frame.insetBy(dx: 2.5, dy: 2.5).contains(editor.camera.toView(cover.rect)), "inside the shape, with room around it")
        let inside = changedPixels(untitled, titled, in: frame)
        expect(inside > 300, "drawn: \(inside)")
        expectEqual(changedPixels(untitled, titled, in: canvasView) - inside, 0, "nothing outside the shape")
    },
    test("a container's cover is at its top left, where its pill goes, which it's no longer held to; other shapes' are centered") {
        let corrals = Contributor(id: "corral-titles") { $0.title(Corral.self) }
        let editor = try titleEditor([CorralsPlugin(), corrals])
        editor.camera = Camera(origin: .zero, zoom: 0.3)
        let corral = editor.add(Corral(world(plaqueFrame, atZoom: 0.3)))
        editor.rename(corral, "Lobby")
        let plate = editor.camera.toView(try require(editor.titleCover(of: corral)).rect)
        expectClose(plate.minX, plaqueFrame.minX + 3, within: 0.5)
        expectClose(plate.minY, plaqueFrame.minY + 3, within: 0.5)
        let plaque = editor.add(Plaque(world(plaqueFrame.offsetBy(dx: 0, dy: 140), atZoom: 0.3)), named: "Lobby")
        let centered = editor.camera.toView(try require(editor.titleCover(of: plaque)).rect)
        expectClose(centered.midY, plaqueFrame.midY + 140, within: 1)
    },
    test("the cover goes where its shape is drawn (a shake), in view points") {
        let editor = try titleEditor()
        editor.camera = Camera(origin: .zero, zoom: 0.3)
        let id = editor.add(Plaque(world(plaqueFrame, atZoom: 0.3)), named: "Lobby")
        let still = render(editor)
        let plate = editor.camera.toView(try require(editor.titleCover(of: id)).rect)
        editor.setDrawingOffset(CGPoint(x: 12, y: 0), for: id)
        let moved = render(editor)
        for y in stride(from: plate.minY + 2, to: plate.maxY - 2, by: 3) {
            for x in stride(from: plate.minX + 2, to: plate.maxX - 2, by: 3) {
                expectEqual(pixel(moved, at: CGPoint(x: x + 12, y: y)), pixel(still, at: CGPoint(x: x, y: y)), "(\(x), \(y))")
            }
        }
    },
])
