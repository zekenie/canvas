import Adornments
import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Geometry
import TestKit

// What's drawn: each adornment in its frame and nowhere else, at its size on screen, for shapes in
// view and those just outside it that reach in, stacked by their shapes, where their shapes are
// drawn, and a clickable one hovered and pressed. A box's shadow reaches 6 points out, and edges
// are antialiased, so what's drawn is checked in its frame grown by a point.

/// The same board drawn twice, as `board` puts it down: without the adornments `plugins` place,
/// and with them. The harness with them, to ask where they are.
@MainActor func renders(_ plugins: [any CanvasPlugin], zoom: CGFloat = 1, _ board: (EditorHarness) -> Void) throws
    -> (plain: NSBitmapImageRep, adorned: NSBitmapImageRep, h: EditorHarness) {
    let plain = try adornedHarness(), adorned = try adornedHarness(plugins)
    for h in [plain, adorned] {
        h.editor.camera = Camera(origin: .zero, zoom: zoom)
        board(h)
    }
    return (render(plain), render(adorned), adorned)
}

/// A shape's adornments' frames in view points, through the camera.
@MainActor func viewRects(_ h: EditorHarness, _ id: ShapeID) -> [CGRect] {
    h.editor.rects(id).map { h.editor.camera.toView($0) }
}

/// Whether a grid dot (every 24 points, 2 across, at 100%) may be at or next to a point.
func nearGridDot(_ point: CGPoint) -> Bool {
    [point.x, point.y].contains { [23, 0, 1].contains(Int($0.rounded(.down)) % 24) }
}

let longText = "A caption much longer than the box is wide"

@MainActor let drawingTests = Suite("Drawing adornments", [
    test("each adornment draws in its frame, and nowhere else") {
        let cases: [(String, any CanvasPlugin)] = [
            ("a caption", everyShape(Caption.self) { _ in AdornmentLabel("Lobby") }),
            ("a long caption", everyShape(Caption.self) { _ in AdornmentLabel(longText) }),
            ("a flag", everyShape(Flag.self) { _ in flagLabel }),
            ("a pin", everyShape(Pin.self) { _ in pinLabel }),
            ("a count", everyShape(Count.self) { _ in AdornmentLabel("☑ 2/5") }),
            ("a count done", everyShape(Count.self) { _ in AdornmentLabel("☑ 5/5", tone: .success) }),
        ]
        for (name, plugin) in cases {
            let (plain, adorned, h) = try renders([plugin]) { $0.add(Box(boxFrame)) }
            let frame = try require(viewRects(h, h.editor.document.shapes[0].id).first).insetBy(dx: -1, dy: -1).integral
            let inside = changedPixels(plain, adorned, in: frame)
            expect(inside > 100, "\(name) draws: \(inside)")
            expectEqual(changedPixels(plain, adorned, in: wholeView) - inside, 0, "\(name) draws nowhere else")
        }
    },
    test("text after a symbol: the symbol in its place before the text, the text as without it moved 14 points, the capsule 14 longer; cut short, the symbol stays") {
        let (_, marked, h) = try renders([everyShape(Caption.self) { _ in AdornmentLabel("Lobby", systemImage: "curlybraces") }]) { $0.add(Box(boxFrame)) }
        let (_, alone, g) = try renders([everyShape(Caption.self) { _ in AdornmentLabel("Lobby") }]) { $0.add(Box(boxFrame)) }
        let withSymbol = try require(viewRects(h, h.editor.document.shapes[0].id).first)
        let without = try require(viewRects(g, g.editor.document.shapes[0].id).first)
        expectEqual(withSymbol.width - without.width, 14, "its place, 11, and the gap after it, 3")
        @MainActor func isLight(_ color: [Int]) -> Bool { color.prefix(3).allSatisfy { $0 > 150 } }
        @MainActor func lights(_ bitmap: NSBitmapImageRep, in rect: CGRect) -> Int {
            stride(from: rect.minY, to: rect.maxY, by: 1).reduce(0) { count, y in
                count + stride(from: rect.minX, to: rect.maxX, by: 1).filter { isLight(pixel(bitmap, at: CGPoint(x: $0, y: y))) }.count
            }
        }
        expect(lights(marked, in: CGRect(x: withSymbol.minX + 7, y: withSymbol.minY + 2, width: 11, height: 14)) > 4, "the symbol, light on the capsule")
        // The text, pixel for pixel, but where a grid dot shows through the capsule at either place.
        var moved = 0
        for y in stride(from: without.minY + 2, to: without.maxY - 2, by: 1) {
            for x in stride(from: without.minX + 7, to: without.maxX - 7, by: 1) {
                let here = CGPoint(x: x, y: y), there = CGPoint(x: x + 14, y: y)
                if !nearGridDot(here), !nearGridDot(there), pixel(alone, at: here) != pixel(marked, at: there) { moved += 1 }
            }
        }
        expectEqual(moved, 0, "the text as without the symbol, 14 points on")
        let (_, long, k) = try renders([everyShape(Caption.self) { _ in AdornmentLabel(longText, systemImage: "curlybraces") }]) { $0.add(Box(boxFrame)) }
        let cut = try require(viewRects(k, k.editor.document.shapes[0].id).first)
        expectEqual(cut.width, boxFrame.width, "cut to the row")
        expect(lights(long, in: CGRect(x: cut.minX + 7, y: cut.minY + 2, width: 11, height: 14)) > 4, "the symbol, whole, where the text gives way")
    },
    test("a label's tone: neutral is the dark gray of a title's pill, success is green") {
        for (tone, isGreen) in [(AdornmentLabel.Tone.neutral, false), (.success, true)] {
            let (_, adorned, h) = try renders([everyShape(Count.self) { _ in AdornmentLabel("☑ 2/5", tone: tone) }]) { $0.add(Box(boxFrame)) }
            let frame = try require(viewRects(h, h.editor.document.shapes[0].id).first)
            let color = pixel(adorned, at: CGPoint(x: frame.minX + 3, y: frame.midY))      // in the capsule, before its text
            expectEqual(color[1] - color[0] > 80, isGreen, "\(tone): \(color)")
            expect(color[0] < 100, "dark enough for white text: \(color)")
        }
    },
    test("an adornment keeps its size on screen zoomed in, and, with skeletons off, shrinks with the shapes below 25%") {
        for (zoom, size) in [(CGFloat(2), CGFloat(18)), (0.125, 9)] {
            let world = CGRect(x: boxFrame.minX / zoom, y: boxFrame.minY / zoom, width: boxFrame.width / zoom, height: boxFrame.height / zoom)
            let plain = try adornedHarness(), h = try adornedHarness([everyShape(Flag.self) { _ in flagLabel }])
            for board in [plain, h] {
                board.editor.skeletonZoom = 0                       // every shape in full at every zoom
                board.editor.camera = Camera(origin: .zero, zoom: zoom)
                board.add(Box(world))
            }
            let (before, after) = (render(plain), render(h))
            let frame = try require(viewRects(h, h.editor.document.shapes[0].id).first)
            expectClose(frame.width, size)
            expectClose(frame.maxX, boxFrame.maxX)
            let grown = frame.insetBy(dx: -1, dy: -1).integral
            expect(changedPixels(before, after, in: grown) > Int(size * size / 2), "at \(zoom)")
            expectEqual(changedPixels(before, after, in: wholeView), changedPixels(before, after, in: grown), "at \(zoom), nowhere else")
        }
    },
    test("a shape just outside the view shows what of its adornments reaches in") {
        let (plain, below, _) = try renders([everyShape(Caption.self) { _ in AdornmentLabel("Lobby") }]) {
            $0.add(Box(CGRect(x: 100, y: 310, width: 200, height: 100)))          // its caption 283 to 301 down
        }
        expect(changedPixels(plain, below, in: CGRect(x: 100, y: 285, width: 30, height: 15)) > 200, "a caption at the view's foot")
        let (plainLeft, left, _) = try renders([everyShape(Count.self) { _ in AdornmentLabel("☑ 2/5") }]) {
            $0.add(Box(CGRect(x: -200, y: 100, width: 197, height: 100)))         // its count reaching to 3
        }
        expect(changedPixels(plainLeft, left, in: CGRect(x: 0, y: 94, width: 3, height: 12)) > 10, "a count's overhang at its left side")
        let h = try adornedHarness(), sign = h.add(Sign(CGRect(x: 410, y: 100, width: 0, height: 100)))    // a flag from 392 to 410
        let unflagged = render(h)
        h.editor.transact { $0.update(sign, as: Sign.self) { $0.props.isFlagged = true } }
        expect(changedPixels(unflagged, render(h), in: CGRect(x: 393, y: 76, width: 7, height: 12)) > 40, "a flag at its right side")
    },
    test("a shape just outside the view that a shake draws toward it shows what of its adornments reaches in") {
        let (plain, shaken, _) = try renders([everyShape(Count.self) { _ in AdornmentLabel("☑ 2/5") }]) { h in
            let box = h.add(Box(CGRect(x: -200, y: 100, width: 192, height: 100)))   // its count reaching to −2, out of view
            h.editor.setDrawingOffset(CGPoint(x: 5, y: 0), for: box)                  // drawn reaching to 3
        }
        expect(changedPixels(plain, shaken, in: CGRect(x: 0, y: 94, width: 3, height: 12)) > 10, "a count's overhang at its left side")
    },
    test("two adornments in one run are drawn apart: none of their pixels meet") {
        let (plain, adorned, h) = try renders([everyShape(Flag.self) { _ in flagLabel }, everyShape(Pin.self, id: "pins") { _ in pinLabel }]) {
            $0.add(Box(boxFrame))
        }
        let rects = viewRects(h, h.editor.document.shapes[0].id).map { $0.insetBy(dx: -1, dy: -1).integral }
        expectEqual(rects.count, 2)
        expect(!rects[0].intersects(rects[1]), "\(rects)")
        let each = rects.map { changedPixels(plain, adorned, in: $0) }
        expect(each.allSatisfy { $0 > 100 }, "\(each)")
        expectEqual(changedPixels(plain, adorned, in: wholeView), each.reduce(0, +))
    },
    test("a front shape's adornments are drawn over a back shape's where they meet") {
        let h = try adornedHarness([everyShape(Caption.self) { $0.box?.minX == 100 ? AdornmentLabel(longText, tone: .success) : AdornmentLabel(longText) }])
        let back = h.add(Box(CGRect(x: 100, y: 100, width: 200, height: 100)))   // green, 100 to 300
        h.add(Box(CGRect(x: 160, y: 100, width: 200, height: 100)))              // gray, from 160, in front
        let point = CGPoint(x: 180, y: 74)                                       // on both, above their text
        let gray = pixel(render(h), at: point)
        expect(gray[1] - gray[0] < 20, "the front's gray: \(gray)")
        h.editor.transact { $0.bringToFront(back) }
        let green = pixel(render(h), at: point)
        expect(green[1] - green[0] > 80, "brought to the front, the other's green: \(green)")
    },
    test("adornments are drawn where their shape is drawn, so they shake with it") {
        let h = try adornedHarness([everyShape(Caption.self) { _ in AdornmentLabel("Lobby") }, everyShape(Flag.self, id: "flags") { _ in flagLabel },
                                    everyShape(Count.self, id: "counts") { _ in AdornmentLabel("☑ 2/5") }])
        let box = h.add(Box(boxFrame))
        let still = render(h)
        h.editor.setDrawingOffset(CGPoint(x: 5, y: 0), for: box)                 // where a shake has it, at its widest
        let shaken = render(h)
        for frame in viewRects(h, box) {
            for y in stride(from: frame.minY + 2, to: frame.maxY - 2, by: 2) {
                for x in stride(from: frame.minX + 2, to: frame.maxX - 2, by: 2) {
                    let point = CGPoint(x: x, y: y), moved = CGPoint(x: x + 5, y: y)
                    guard !nearGridDot(point), !nearGridDot(moved) else { continue }
                    expectEqual(pixel(shaken, at: moved), pixel(still, at: point), "(\(x), \(y))")
                }
            }
        }
    },
    test("a clickable adornment draws lighter hovered and darker pressed") {
        let h = try adornedHarness([everyShape(Pin.self) { _ in pinLabel }])
        h.add(Box(boxFrame))
        let point = CGPoint(x: flagCenter.x, y: flagCenter.y - 7)                // on the disc, above the pin
        let normal = pixel(render(h), at: point)[0]
        h.move(to: flagCenter)
        let hovered = pixel(render(h), at: point)[0]
        h.press(at: flagCenter)
        let pressed = pixel(render(h), at: point)[0]
        expect(pressed < normal && normal < hovered, "\(pressed) < \(normal) < \(hovered)")
    },
    test("a label drawn half opaque is lighter") {
        let point = CGPoint(x: flagCenter.x, y: flagCenter.y - 7)
        let (_, opaque, _) = try renders([everyShape(Flag.self) { _ in flagLabel }]) { $0.add(Box(boxFrame)) }
        let (plain, half, _) = try renders([everyShape(Flag.self) { _ in flagLabel.opacity(0.5) }]) { $0.add(Box(boxFrame)) }
        let (full, halfway, none) = (pixel(opaque, at: point)[0], pixel(half, at: point)[0], pixel(plain, at: point)[0])
        expect(full < halfway && halfway < none, "\(full) < \(halfway) < \(none)")
    },
    test("a placeholder's text is drawn dimmed, on the same capsule, laid out as the same text, in the row and on the corner") {
        let cases: [(String, any CanvasPlugin, any CanvasPlugin)] = [
            ("Lobby", everyShape(Caption.self) { _ in AdornmentLabel("Lobby") }, everyShape(Caption.self) { _ in AdornmentLabel(placeholder: "Lobby") }),
            ("☑ 2/5", everyShape(Count.self) { _ in AdornmentLabel("☑ 2/5") }, everyShape(Count.self) { _ in AdornmentLabel(placeholder: "☑ 2/5") }),
        ]
        for (text, plain, dimmed) in cases {
            let (_, titled, h) = try renders([plain]) { $0.add(Box(boxFrame)) }
            let (_, placeholder, g) = try renders([dimmed]) { $0.add(Box(boxFrame)) }
            let frame = try require(viewRects(h, h.editor.document.shapes[0].id).first)
            expectEqual(viewRects(g, g.editor.document.shapes[0].id), [frame], "\(text): laid out alike")
            let fill = CGPoint(x: frame.minX + 3, y: frame.midY)                          // in the capsule, before its text
            expectEqual(pixel(placeholder, at: fill), pixel(titled, at: fill), "\(text): the same capsule")
            @MainActor func brightest(_ bitmap: NSBitmapImageRep) -> Int {
                stride(from: frame.minY + 2, to: frame.maxY - 2, by: 1).flatMap { y in
                    stride(from: frame.minX + 4, to: frame.maxX - 4, by: 1).map { pixel(bitmap, at: CGPoint(x: $0, y: y))[0] }
                }.max() ?? 0
            }
            let (dim, bright, capsule) = (brightest(placeholder), brightest(titled), pixel(titled, at: fill)[0])
            expect(capsule + 40 < dim && dim + 40 < bright, "\(text): \(capsule) < \(dim) < \(bright)")
        }
    },
])
