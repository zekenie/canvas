import Adornments
import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Geometry
import Selection
import TestKit

// Zoomed out, where the canvas draws shapes as skeletons (under 35%), every adornment on one is
// drawn blank: a capsule with no text, a disc with no symbol, in a pale gray, as long as its text's
// columns (`SkeletonText`). It's pointed at where it's drawn, and nothing is measured or kept
// measured. The shape being edited is drawn in full, and so are its adornments. The test box is
// drawn where it is at 100% (`blankHarness`): its top-left corner at (100, 100) in view, 200 wide,
// so its pin's disc is centered at (291, 82) and its caption starts at (100, 73).

/// Text at the row's right end that a click does something with.
enum Stamp {}
extension Stamp: Adornment {
    static var placement: AdornmentPlacement { .aboveTopRight }
}
extension Stamp: ClickableAdornment {
    static func click(on shape: ShapeID, in editor: CanvasEditor) { clicked.append(shape) }
}

/// Where a box is at `zoom` to be where `boxFrame` is at 100%, in view.
func world(_ frame: CGRect, atZoom zoom: CGFloat) -> CGRect {
    CGRect(x: frame.minX / zoom, y: frame.minY / zoom, width: frame.width / zoom, height: frame.height / zoom)
}

/// The same board drawn at `zoom` without the adornments `plugins` place, and with them, the test
/// box where it is at 100% in view.
@MainActor func blankRenders(_ plugins: [any CanvasPlugin], zoom: CGFloat = 0.3) throws
    -> (plain: NSBitmapImageRep, adorned: NSBitmapImageRep, h: EditorHarness, box: ShapeID) {
    let (plain, adorned, h) = try renders(plugins, zoom: zoom) { $0.add(Box(world(boxFrame, atZoom: zoom))) }
    return (plain, adorned, h, h.editor.document.shapes[0].id)
}

/// The colors in a rect of view points, each once.
@MainActor func colors(_ rep: NSBitmapImageRep, in rect: CGRect) -> Set<[Int]> {
    Set(stride(from: rect.minY, to: rect.maxY, by: 1).flatMap { y in
        stride(from: rect.minX, to: rect.maxX, by: 1).map { x in pixel(rep, at: CGPoint(x: x, y: y)) }
    })
}

/// Well inside an adornment's frame (view points), where only its face is: a capsule's straight
/// middle, or a disc's middle.
func inside(_ frame: CGRect) -> CGRect {
    frame.width > frame.height + 1 ? frame.insetBy(dx: frame.height / 2, dy: 3) : frame.insetBy(dx: 5, dy: 5)
}

/// Whether a color is the blank gray, on the light canvas: about 214, 217, 219, bluer than red.
func isBlankGray(_ color: [Int]) -> Bool { (205...225).contains(color[0]) && color[2] > color[0] && color[1] - color[0] < 10 }

/// The blank gray, on the light canvas.
let blankGray = CGColor(srgbRed: 0.84, green: 0.85, blue: 0.86, alpha: 1)

/// A shape's caption's frame, in view points.
@MainActor func captionRect(_ h: EditorHarness, _ id: ShapeID) throws -> CGRect {
    h.editor.camera.toView(try require(h.editor.adornmentFrames(of: id).first { $0.adornment == .of(Caption.self) }).rect)
}

@MainActor let skeletonTests = Suite("Adornments zoomed out", [
    test("below 35%, each adornment is drawn blank in its frame, and nowhere else: a capsule with no text, a disc with no symbol") {
        let cases: [(String, any CanvasPlugin)] = [
            ("a caption", everyShape(Caption.self) { _ in AdornmentLabel("Lobby") }),
            ("a long caption", everyShape(Caption.self) { _ in AdornmentLabel(longText) }),
            ("a flag", everyShape(Flag.self) { _ in flagLabel }),
            ("a pin", everyShape(Pin.self) { _ in pinLabel }),
            ("a count", everyShape(Count.self) { _ in AdornmentLabel("☑ 2/5") }),
        ]
        for (name, plugin) in cases {
            let (plain, adorned, h, box) = try blankRenders([plugin])
            let frame = try require(viewRects(h, box).first)
            let grown = frame.insetBy(dx: -1, dy: -1).integral
            let drawn = changedPixels(plain, adorned, in: grown)
            expect(drawn > 100, "\(name) draws: \(drawn)")
            expectEqual(changedPixels(plain, adorned, in: wholeView) - drawn, 0, "\(name) draws nowhere else")
            let seen = colors(adorned, in: inside(frame))
            expectEqual(seen.count, 1, "\(name) is one color inside, no text or symbol: \(seen)")
            expect(seen.allSatisfy(isBlankGray), "\(name) is the blank gray: \(seen)")
        }
    },
    test("a blank capsule and disc are round, as drawn with curves, to within antialiasing, at 1× and 2×, at 30% and 10%") {
        for (zoom, scale) in [(0.3, 1), (0.3, 2), (0.1, 1), (0.1, 2)] as [(CGFloat, CGFloat)] {
            let plugins = [everyShape(Caption.self) { _ in AdornmentLabel("Lobby") }, everyShape(Pin.self, id: "pins") { _ in pinLabel }]
            let plain = try adornedHarness(), adorned = try adornedHarness(plugins)
            for h in [plain, adorned] {
                h.editor.camera = Camera(origin: .zero, zoom: zoom)
                h.add(Box(world(boxFrame, atZoom: zoom)))
            }
            let blank = renderBitmap(adorned.editor, size: wholeView.size, scale: scale)
            // The same capsule and disc, filled with curves over the board without them.
            let curved = renderBitmap(plain.editor, size: wholeView.size, scale: scale)
            let cg = try require(NSGraphicsContext(bitmapImageRep: curved)).cgContext
            cg.translateBy(x: 0, y: wholeView.height * scale)
            cg.scaleBy(x: scale, y: -scale)
            let frames = viewRects(adorned, adorned.editor.document.shapes[0].id)
            expectEqual(frames.count, 2, "at \(zoom)")
            cg.setFillColor(blankGray)
            for frame in frames {
                let radius = min(frame.width, frame.height) / 2
                cg.addPath(CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil))
            }
            cg.fillPath()
            for frame in frames {
                let difference = largestDifference(blank, curved, in: frame.insetBy(dx: -1, dy: -1).integral, scale: scale)
                expect(difference <= 32, "at \(zoom), \(scale)×, \(frame): \(difference)")
                expect(isBlankGray(pixel(blank, at: CGPoint(x: frame.midX, y: frame.midY), scale: scale)), "drawn at \(zoom), \(scale)×")
            }
        }
    },
    test("the level is 35%: there a caption has its text, just under it none, and back at 35% its text again") {
        let h = try adornedHarness([everyShape(Caption.self) { _ in AdornmentLabel("Lobby") }])
        let box = h.add(Box(world(boxFrame, atZoom: 0.35)))
        var counts: [Int] = []
        for zoom in [0.35, 0.349, 0.35] as [CGFloat] {
            h.editor.camera = Camera(origin: .zero, zoom: zoom)
            let frame = try require(viewRects(h, box).first)
            counts.append(colors(render(h), in: inside(frame)).count)
        }
        expect(counts[0] > 3 && counts[2] == counts[0], "text in full: \(counts)")
        expectEqual(counts[1], 1, "blank just under 35%")
    },
    test("drawn blank, text after a symbol is longer by the symbol's place, as in full, and shows neither") {
        let h = try adornedHarness([everyShape(Caption.self) {
            $0.box?.minY == boxFrame.minY / 0.3 ? AdornmentLabel("Lobby", systemImage: "curlybraces") : AdornmentLabel("Lobby")
        }])
        let marked = h.add(Box(world(boxFrame, atZoom: 0.3)))
        let alone = h.add(Box(world(boxFrame.offsetBy(dx: 0, dy: 150), atZoom: 0.3)))
        h.editor.camera = Camera(origin: .zero, zoom: 0.3)
        let blank = try [marked, alone].map { try require(viewRects(h, $0).first).width }
        expectClose(blank[0] - blank[1], 14)                      // blank, the symbol's place and its gap
        let rendered = render(h)
        expectEqual(colors(rendered, in: inside(try captionRect(h, marked))).filter { !isBlankGray($0) }, [], "one flat gray: no symbol, no text")
        h.editor.skeletonZoom = 0.2                                 // in full at 30%
        let full = try [marked, alone].map { try require(viewRects(h, $0).first).width }
        expectClose(full[0] - full[1], 14)                        // in full, the same
    },
    test("drawn blank, a label is as long as its text's columns, not its letters") {
        let h = try adornedHarness([everyShape(Caption.self) { $0.box?.minY == boxFrame.minY / 0.3 ? AdornmentLabel("iiiiiiii") : AdornmentLabel("WWWWWWWW") }])
        let narrow = h.add(Box(world(boxFrame, atZoom: 0.3)))
        let wide = h.add(Box(world(boxFrame.offsetBy(dx: 0, dy: 150), atZoom: 0.3)))
        h.editor.camera = Camera(origin: .zero, zoom: 0.3)
        let blank = try [narrow, wide].map { try require(viewRects(h, $0).first).width }
        expectEqual(blank[0], blank[1], "the same length, blank")
        h.editor.skeletonZoom = 0.2                                 // in full at 30%
        let full = try [narrow, wide].map { try require(viewRects(h, $0).first).width }
        expect(full[1] > full[0] + 40, "measured, W's are wider: \(full)")
        expect(blank[0] > full[0] && blank[0] < full[1], "between the two: \(blank[0]), \(full)")
    },
    test("drawn blank, a title in Japanese, Korean or emoji is about as long as in full, each character two columns, so it keeps its length at 35%") {
        // Within 15% of in full (emoji, wider than two columns, 30%), where a character a column
        // was 42% short in Japanese, 28% in Korean and 54% in emoji. Measured: "Groceries" 64 blank
        // and 67 in full, "東京の会議メモ" 91 and 90, "회의록 정리" 74 and 65, "🎉🎉🎉🎉" 58 and 78.
        let titles = ["Groceries", "東京の会議メモ", "회의록 정리", "🎉🎉🎉🎉", "👨‍👩‍👧 family", "Cafe\u{301} menu"]
        let within: [CGFloat] = [0.15, 0.15, 0.15, 0.3, 0.15, 0.15]
        let h = try adornedHarness([everyShape(Caption.self) { shape in
            (shape.box?.minY).map { AdornmentLabel(titles[Int((($0 * 0.3 - 100) / 40).rounded())]) }
        }])
        // Each box as wide as the view, so no caption gives way.
        let boxes = titles.indices.map { i in h.add(Box(world(CGRect(x: 20, y: 100 + CGFloat(i) * 40, width: 360, height: 20), atZoom: 0.3))) }
        h.editor.camera = Camera(origin: .zero, zoom: 0.3)
        let blank = try boxes.map { try captionRect(h, $0).width }
        h.editor.skeletonZoom = 0.2                                 // in full at 30%
        let full = try boxes.map { try captionRect(h, $0).width }
        for (i, title) in titles.enumerated() {
            expect(abs(blank[i] - full[i]) <= full[i] * within[i], "\(title): \(blank[i]) blank, \(full[i]) in full")
        }
        // Wide characters count twice: as a Latin text twice as long.
        let japanese = AdornmentLabel("東京の会議メモ"), latin = AdornmentLabel("abcdefghijklmn")
        let wide = try adornedHarness([everyShape(Caption.self) { $0.box?.minY == 100 / 0.3 ? japanese : latin }])
        let pair = [wide.add(Box(world(boxFrame, atZoom: 0.3))), wide.add(Box(world(boxFrame.offsetBy(dx: 0, dy: 150), atZoom: 0.3)))]
        wide.editor.camera = Camera(origin: .zero, zoom: 0.3)
        expectEqual(try captionRect(wide, pair[0]).width, try captionRect(wide, pair[1]).width, "7 wide characters, 14 narrow ones")
    },
    test("drawn blank, adornments are pointed at where they're drawn: a click on a pin clicks it, a hover on a caption hovers its shape") {
        clicked = []
        let h = try adornedHarness([everyShape(Pin.self) { _ in pinLabel }, everyShape(Caption.self, id: "captions") { _ in AdornmentLabel("WWWWWWWW") }])
        let box = h.add(Box(world(boxFrame, atZoom: 0.3)))
        h.editor.camera = Camera(origin: .zero, zoom: 0.3)
        h.click(at: flagCenter)
        expectEqual(clicked, [box], "the pin, blank")
        h.editor.selection = nil
        let caption = try require(h.editor.adornmentFrames(of: box).first { $0.adornment == .of(Caption.self) }).rect
        let blank = h.editor.camera.toView(caption)
        h.move(to: CGPoint(x: blank.minX + 10, y: blank.midY))
        expectEqual(h.editor.hovered, box, "the caption, blank")
        // Past the blank caption's end, but on the caption measured in full, which is wider.
        let past = CGPoint(x: blank.maxX + 12, y: blank.midY)
        h.move(to: past)
        expectEqual(h.editor.hovered, nil, "past the caption as drawn")
        h.editor.skeletonZoom = 0.2
        let full = h.editor.camera.toView(try require(h.editor.adornmentFrames(of: box).first { $0.adornment == .of(Caption.self) }).rect)
        expect(full.maxX > past.x + 4, "in full it reaches past: \(full), \(past)")
        h.move(to: past)
        expectEqual(h.editor.hovered, box, "on the caption in full")
    },
    test("zoomed out, labels are made once, as ever, but no text is set or measured, nor kept; zoomed in, those in view are measured again") {
        let calls = Calls()
        let h = try adornedHarness([countedCaptions(calls)])
        h.editor.transact { transaction in
            for row in 0..<25 {
                for column in 0..<40 {
                    transaction.insert(ShapeRecord(Box(CGRect(x: column * 100, y: row * 100, width: 80, height: 60))))
                }
            }
        }
        h.editor.camera = Camera(origin: .zero, zoom: 0.1)          // the whole board in view
        _ = render(h)
        h.move(to: CGPoint(x: 150, y: 150))
        _ = render(h)
        expectEqual(calls.counts.count, 1000, "every shape's label made")
        expectEqual(h.editor.adornmentsKept, 1000)
        expectEqual(h.editor.adornmentFacesMade, 0, "none measured")
        expectEqual(h.editor.adornmentFacesKept, 0)
        h.editor.camera = Camera(origin: .zero, zoom: 1)
        _ = render(h)
        let measured = h.editor.adornmentFacesMade
        expect(measured > 0 && measured < 40, "those in view measured: \(measured)")
        expectEqual(h.editor.adornmentFacesKept, measured)
        h.editor.camera = Camera(origin: .zero, zoom: 0.1)
        expectEqual(h.editor.adornmentFacesKept, 0, "zoomed out, the measured faces go")
        _ = render(h)
        expectEqual(h.editor.adornmentFacesMade, measured, "and none is measured")
        expect(calls.counts.values.allSatisfy { $0 == 1 }, "no label made twice: \(Set(calls.counts.values))")
    },
    test("drawn blank, a front shape's label is over a back shape's where they meet, whichever is in front") {
        let h = try adornedHarness([everyShape(Caption.self) { $0.box?.minX == 100 / 0.3 ? AdornmentLabel(longText, tone: .success) : AdornmentLabel(longText) }])
        let back = h.add(Box(world(CGRect(x: 100, y: 100, width: 200, height: 100), atZoom: 0.3)))  // green, 100 to 300
        h.add(Box(world(CGRect(x: 160, y: 100, width: 200, height: 100), atZoom: 0.3)))             // gray, from 160, in front
        h.editor.camera = Camera(origin: .zero, zoom: 0.3)
        let point = CGPoint(x: 180, y: 82)                                                       // on both
        let gray = pixel(render(h), at: point)
        expect(isBlankGray(gray), "the front's gray: \(gray)")
        h.editor.transact { $0.bringToFront(back) }
        let green = pixel(render(h), at: point)
        expect(green[1] - green[0] > 30, "brought to the front, the other's muted green: \(green)")
    },
    test("drawn blank, a pin is lighter hovered and darker pressed, and a label half opaque is lighter") {
        let h = try adornedHarness([everyShape(Pin.self) { _ in pinLabel }])
        h.add(Box(world(boxFrame, atZoom: 0.3)))
        h.editor.camera = Camera(origin: .zero, zoom: 0.3)
        let normal = pixel(render(h), at: flagCenter)[0]
        h.move(to: flagCenter)
        let hovered = pixel(render(h), at: flagCenter)[0]
        h.press(at: flagCenter)
        let pressed = pixel(render(h), at: flagCenter)[0]
        expect(pressed < normal && normal < hovered, "\(pressed) < \(normal) < \(hovered)")
        let (plain, half, _, _) = try blankRenders([everyShape(Flag.self) { _ in flagLabel.opacity(0.5) }])
        let (halfway, none) = (pixel(half, at: flagCenter)[0], pixel(plain, at: flagCenter)[0])
        expect(normal < halfway && halfway < none, "\(normal) < \(halfway) < \(none)")
    },
    test("as the level changes under a still pointer, the select tool looks there again: a button come or gone, a caption cut shorter") {
        // Selection looks again as it hears the level change (its `drawsSkeletonsDidChange`), for
        // every plugin's buttons and every shape; Adornments adds no look of its own, so without
        // Selection's none of this would follow.
        clicked = []
        let h = try adornedHarness([everyShape(Stamp.self) { _ in AdornmentLabel("WWWWWWWW") },
                                    everyShape(Caption.self, id: "captions") { _ in AdornmentLabel("WWWWWWWW") }])
        let box = h.add(Box(world(boxFrame, atZoom: 0.3)))
        h.editor.camera = Camera(origin: .zero, zoom: 0.3)
        let blank = try stampRect(h, box), blankCaption = try captionRect(h, box)
        h.editor.skeletonZoom = 0.2                                 // in full
        let full = try stampRect(h, box), fullCaption = try captionRect(h, box)
        expect(full.minX < blank.minX - 12, "the stamp is wider in full: \(full), \(blank)")
        expect(fullCaption.maxX > blankCaption.maxX + 12 && fullCaption.maxX < full.minX - 3,
               "the caption is wider in full, short of the stamp: \(fullCaption), \(blankCaption)")
        let stamp = AnyHashable(AdornmentButton(Stamp.self, on: box))
        let point = CGPoint(x: blank.minX - 8, y: blank.midY)       // on it in full, past it blank
        h.move(to: point)
        expectEqual(h.editor.hoveredButton, stamp)
        expectEqual(h.editor.cursor, .pointingHand)
        h.editor.skeletonZoom = 0.35                                // blank
        expectEqual(h.editor.hoveredButton, nil, "let go of, blank")
        expectEqual(h.editor.cursor, .standard)
        h.editor.skeletonZoom = 0.2
        expectEqual(h.editor.hoveredButton, stamp, "found again, in full")
        h.click(at: point)
        expectEqual(clicked, [box])
        // On the caption in full, past its end blank.
        let caption = CGPoint(x: (blankCaption.maxX + fullCaption.maxX) / 2, y: blankCaption.midY)
        h.move(to: caption)
        expectEqual(h.editor.hovered, box)
        h.editor.skeletonZoom = 0.35
        expectEqual(h.editor.hovered, nil, "the caption cut shorter, blank: the pointer's past it")
        h.editor.skeletonZoom = 0.2
        expectEqual(h.editor.hovered, box, "in full again, on it")
    },
    test("zoomed out, the shape being edited is drawn in full, and its adornments are too, drawn and pointed at, while another's are blank") {
        let plugins = [everyShape(Stamp.self) { _ in AdornmentLabel("WWWWWWWW") }, everyShape(Caption.self, id: "captions") { _ in AdornmentLabel("WWWWWWWW") }]
        let h = try adornedHarness(plugins)
        // Two cards, which are edited in place: the other 150 points below.
        let edited = h.add(Card(world(boxFrame, atZoom: 0.3)))
        let other = h.add(Card(world(boxFrame.offsetBy(dx: 0, dy: 150), atZoom: 0.3)))
        h.editor.camera = Camera(origin: .zero, zoom: 0.3)
        let blank = try captionRect(h, edited), blankStamp = try stampRect(h, edited)
        h.editor.skeletonZoom = 0.2                                 // in full at 30%
        let full = try captionRect(h, edited), fullStamp = try stampRect(h, edited)
        h.editor.skeletonZoom = 0.35
        let idle = render(h)
        expect(h.editor.beginEditing(edited))
        expect(h.editor.drawsSkeletons && !h.editor.drawsSkeleton(of: edited))
        expectEqual(try captionRect(h, edited), full, "laid out in full")
        expectEqual(try stampRect(h, edited), fullStamp)
        expectEqual(try captionRect(h, other), blank.offsetBy(dx: 0, dy: 150), "the other's blank")
        let editing = render(h)
        h.editor.skeletonZoom = 0.2
        let inFull = render(h)
        h.editor.skeletonZoom = 0.35
        for (name, rect) in [("caption", full), ("stamp", fullStamp)] {
            expect(changedPixels(idle, editing, in: rect) > 100, "the \(name) drawn otherwise than blank")
            expectEqual(changedPixels(inFull, editing, in: rect.insetBy(dx: -2, dy: -2)), 0, "the \(name) as it's drawn in full")
        }
        expectEqual(colors(editing, in: inside(blank.offsetBy(dx: 0, dy: 150))).count, 1, "the other's caption, blank")
        expectEqual(changedPixels(idle, editing, in: CGRect(x: 0, y: 222, width: 400, height: 78)), 0, "the other, as it was")
        // Pointed at where they're drawn: on the edited card's in full, past where they'd end blank.
        let pastCaption = CGPoint(x: (blank.maxX + full.maxX) / 2, y: full.midY)
        let pastStamp = CGPoint(x: blankStamp.minX - 8, y: fullStamp.midY)
        h.move(to: pastCaption)
        expectEqual(h.editor.hovered, edited, "on its caption, in full")
        h.move(to: pastStamp)
        expectEqual(h.editor.hoveredButton, AnyHashable(AdornmentButton(Stamp.self, on: edited)), "on its stamp, in full")
        h.move(to: CGPoint(x: pastCaption.x, y: pastCaption.y + 150))
        expectEqual(h.editor.hovered, nil, "past the other's, blank")
        h.move(to: CGPoint(x: pastStamp.x, y: pastStamp.y + 150))
        expectEqual(h.editor.hoveredButton, nil)
        h.editor.endEditing()
        expectEqual(try captionRect(h, edited), blank, "blank again once it's no longer edited")
        expectEqual(changedPixels(idle, render(h), in: wholeView), 0)
    },
])

/// A shape's stamp's frame, in view points.
@MainActor func stampRect(_ h: EditorHarness, _ id: ShapeID) throws -> CGRect {
    h.editor.camera.toView(try require(h.editor.adornmentFrames(of: id).first { $0.adornment == .of(Stamp.self) }).rect)
}
