import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Foundation
import Geometry
import Schemas
import TestKit
import Titles

/// Whether any pixel of `bitmap` in `rect` (view points; every pixel, at any scale) passes `test`.
@MainActor func any(_ bitmap: NSBitmapImageRep, in rect: CGRect, _ test: ([Int]) -> Bool) -> Bool {
    let scale = CGFloat(bitmap.pixelsWide) / bitmap.size.width
    var value = [Int](repeating: 0, count: 4)
    for y in Int(rect.minY * scale)..<Int(rect.maxY * scale) {
        for x in Int(rect.minX * scale)..<Int(rect.maxX * scale) {
            bitmap.getPixel(&value, atX: x, y: y)
            if test(value) { return true }
        }
    }
    return false
}

func isAbout(_ color: [Int], within tolerance: Int = 14) -> ([Int]) -> Bool {
    { pixel in zip(pixel, color).allSatisfy { abs($0 - $1) <= tolerance } }
}

/// Text-dark: every channel under 120.
func isInk(_ pixel: [Int]) -> Bool { pixel.prefix(3).allSatisfy { $0 < 120 } }
/// Magenta, the kind's accent: red and blue well above green, blue nearly red's (not the indigo of a
/// subboard's border, whose blue is well above its red, nor validation's red).
func isAccent(_ pixel: [Int]) -> Bool { pixel[0] > pixel[1] + 50 && pixel[2] > pixel[1] + 40 && abs(pixel[0] - pixel[2]) < 60 }
/// Any hue at all: a channel well apart from another.
func isColorful(_ pixel: [Int]) -> Bool { pixel.prefix(3).max()! - pixel.prefix(3).min()! > 40 }
/// Validation's red outline: red, with little green or blue.
func isRed(_ pixel: [Int]) -> Bool { pixel[0] > 180 && pixel[1] < 110 && pixel[2] < 110 }

/// The canvas with `cards` on it, at `zoom`, twice over (as a Retina screen draws it).
@MainActor func render(_ cards: [SchemaCard], zoom: CGFloat = 1, size: CGSize = CGSize(width: 340, height: 280)) throws -> NSBitmapImageRep {
    let editor = try schemaEditor()
    for card in cards { editor.add(card) }
    editor.camera = Camera(zoom: zoom)
    return render(editor, size: size)
}

/// `editor`'s canvas, twice over.
@MainActor func render(_ editor: CanvasEditor, size: CGSize) -> NSBitmapImageRep {
    let bitmap = renderBitmap(editor, size: size, scale: 2)
    bitmap.size = size   // two pixels a point, so `pixel` and `any` take points
    return bitmap
}

// A card at (40, 40), 240 wide: its description from x 56 to 264, line i from y 56 + 19 i, 19 tall;
// its title's pill is above it, from x 40, y 13 to 31.
private func lineBand(_ i: Int) -> CGRect { CGRect(x: 56, y: 56 + 19 * CGFloat(i), width: 208, height: 19) }
private let pillBand = CGRect(x: 40, y: 13, width: 100, height: 18)

// The same card's skeleton at 30%, at (12, 12), 72 wide: its description's box from x 16.8, line
// i's bar from y 18.75 + 5.7 i, 2.55 tall. Its pill is above the bitmap.
private func skeletonBar(_ i: Int) -> CGFloat { 18.75 + 5.7 * CGFloat(i) + 1.275 }
private func skeletonLine(_ i: Int) -> CGRect { CGRect(x: 16.8, y: 16.8 + 5.7 * CGFloat(i), width: 62.4, height: 5.7) }
/// Text darker than any skeleton's: the drawing's text, at any zoom.
private func isText(_ pixel: [Int]) -> Bool { pixel.prefix(3).allSatisfy { $0 < 160 } }

/// A description of five lines at 240 wide: four of one paragraph, and one after a Return.
let petPrompt = "A pet in my household: its name, its species (a dog or a cat), and the year it was born.\nNothing else."

@MainActor let renderTests = Suite("Schema card drawing", [
    test("a card: white, its corners a note's, its description in dark text 16 points in, no hue; its name in its pill above it") {
        let bitmap = try render([card(fixture(3), prompt: "a pet in my household")])
        expect(isAbout(Palette.card)(pixel(bitmap, at: CGPoint(x: 150, y: 46))), "the card's body, above its text")
        expect(any(bitmap, in: lineBand(0), isInk), "its description's line")
        expect(!any(bitmap, in: CGRect(x: 40, y: 40, width: 240, height: 15), isInk), "nothing above it but the padding")
        expect(!any(bitmap, in: CGRect(x: 40, y: 40, width: 15, height: 52), isInk), "nor left of it")
        expect(any(bitmap, in: pillBand, isInk), "its name's pill")
        expect(!any(bitmap, in: CGRect(x: 40, y: 40, width: 240, height: 52), isColorful), "no hue on the card")
        // 52 tall: canvas below.
        expect(!isAbout(Palette.card, within: 3)(pixel(bitmap, at: CGPoint(x: 150, y: 40 + 52 + 8))))
    },
    test("a card with no description is blank; untitled, it has no pill") {
        let empty = try render([card(SchemaCard.starter)])
        expect(!any(empty, in: CGRect(x: 40, y: 40, width: 240, height: 52), isText), "nothing on it")
        expect(isAbout(Palette.card, within: 2)(pixel(empty, at: CGPoint(x: 150, y: 66))), "white")
        expect(!any(empty, in: pillBand, isInk), "untitled: no pill")
        expect(!any(empty, in: CGRect(x: 20, y: 20, width: 300, height: 90), isRed), "valid: no outline")
        // Its fields don't show: a titled schema of six fields and no description is blank too.
        let order = try render([card(fixture(6))])
        expect(!any(order, in: CGRect(x: 40, y: 40, width: 240, height: 52), isText), "no rows")
        expect(any(order, in: pillBand, isInk), "named, in its pill: Order")
        // A schema that isn't JSON is outlined by Validation, the card as blank as ever.
        let broken = try render([card(fixture(10))])
        expect(any(broken, in: CGRect(x: 30, y: 30, width: 20, height: 40), isRed), "Validation's outline")
        expect(!any(broken, in: CGRect(x: 44, y: 44, width: 232, height: 44), isText), "nothing said on the card")
    },
    test("a longer description draws every line, the card as tall as they are") {
        let props = card(petSchema, prompt: petPrompt)
        expectEqual(props.frame.height, cardHeight(lines: 5), "five lines: four of it wrapped, and one after its Return")
        let bitmap = try render([props], size: CGSize(width: 340, height: 200))
        for i in 0..<5 { expect(any(bitmap, in: lineBand(i), isInk), "line \(i)") }
        expect(!any(bitmap, in: CGRect(x: 40, y: 40 + props.frame.height - 15, width: 240, height: 15), isInk), "the padding below")
    },
    test("below 35%, a card is its skeleton: white with a light gray edge and no shadow, and a bar where each of its description's lines is") {
        let size = CGSize(width: 120, height: 90), cardRect = CGRect(x: 12, y: 12, width: 72, height: cardHeight(lines: 5) * 0.3)
        let editor = try schemaEditor()
        editor.add(card(petSchema, prompt: petPrompt))
        editor.camera = Camera(zoom: 0.3)
        let skeleton = render(editor, size: size)
        expect(!any(skeleton, in: cardRect, isText), "no text")
        // Its edge, where its shadow's showed: a device pixel of light gray inside the frame, then white.
        for (edge, inside) in [(CGPoint(x: 12.25, y: 30), CGPoint(x: 12.75, y: 30)), (CGPoint(x: 83.75, y: 30), CGPoint(x: 83.25, y: 30)),
                               (CGPoint(x: 50, y: 12.25), CGPoint(x: 50, y: 12.75))] {
            expect(isAbout(Palette.skeletonEdge, within: 3)(pixel(skeleton, at: edge)), "the edge at \(edge): \(pixel(skeleton, at: edge))")
            expect(isAbout(Palette.card, within: 2)(pixel(skeleton, at: inside)), "white inside it at \(inside)")
        }
        expect(!any(skeleton, in: cardRect, isAccent), "no mark: its name is its pill's")
        for i in 0..<5 {
            expect(isAbout(Palette.textBar, within: 6)(pixel(skeleton, at: CGPoint(x: 18, y: skeletonBar(i)))), "line \(i)'s bar")
        }
        expect(isAbout(Palette.card, within: 2)(pixel(skeleton, at: CGPoint(x: 18, y: skeletonBar(5)))), "five lines, no sixth")
        expect(isAbout(Palette.card, within: 2)(pixel(skeleton, at: CGPoint(x: 70, y: skeletonBar(4)))), "the last line short: Nothing else.")
        // No shadow: around the card, the canvas as it is without it.
        let bare = try render([], zoom: 0.3, size: size)
        let around = [CGRect(x: 6, y: 6, width: 6, height: 40), CGRect(x: 84, y: 6, width: 6, height: 40), CGRect(x: 12, y: 6, width: 72, height: 6)]
        expectEqual(around.map { changedPixels(bare, skeleton, in: $0) }, [0, 0, 0], "no shadow")
        // Drawn in full (the host's switch), the same card at 30% has its text and its shadow.
        editor.skeletonZoom = 0
        let full = render(editor, size: size)
        expect(any(full, in: cardRect, isText), "text in full")
        expect(around.map { changedPixels(bare, full, in: $0) }.reduce(0, +) > 0, "a shadow in full")
        // At 35%, the card as ever.
        let near = try render([card(petSchema, prompt: petPrompt)], zoom: 0.35, size: CGSize(width: 140, height: 100))
        expect(any(near, in: CGRect(x: 19.6, y: 19.6, width: 72.8, height: 6.65), isText), "the first line's text at 35%")
    },
    test("zoomed out, a bar is as long as its line's columns (a wide character two); an empty card has none; what it says now is what's drawn") {
        let size = CGSize(width: 120, height: 90)
        let letters = try render([card(SchemaCard.starter, prompt: "abcdefghijkl")], zoom: 0.3, size: size)
        let wide = try render([card(SchemaCard.starter, prompt: "名前名前名前")], zoom: 0.3, size: size)
        expectEqual(changedPixels(letters, wide, in: CGRect(origin: .zero, size: size)), 0, "twelve columns each")
        let six = try render([card(SchemaCard.starter, prompt: "abcdef")], zoom: 0.3, size: size)
        expect(changedPixels(letters, six, in: CGRect(origin: .zero, size: size)) > 0, "six are shorter")
        let empty = try render([card(SchemaCard.starter)], zoom: 0.3, size: size)
        expect(!any(empty, in: skeletonLine(0), { !isAbout(Palette.card, within: 2)($0) }), "no description, no bar")
        // Written, the next frame goes by what it says: nothing is kept that could be stale.
        let editor = try schemaEditor()
        let id = editor.add(card(SchemaCard.starter, prompt: "abcdef"))
        editor.camera = Camera(zoom: 0.3)
        expectEqual(changedPixels(render(editor, size: size), six, in: CGRect(origin: .zero, size: size)), 0)
        editor.transact { $0.update(id, as: SchemaCard.self) { $0.props.setPrompt("abcdefghijkl") } }
        expectEqual(changedPixels(render(editor, size: size), letters, in: CGRect(origin: .zero, size: size)), 0, "the edit")
        editor.undo()
        expectEqual(changedPixels(render(editor, size: size), six, in: CGRect(origin: .zero, size: size)), 0, "its undo")
    },
    test("a card of any size a file may hold draws, in full and as its skeleton") {
        let editor = try schemaEditor()
        var tall = card(fixture(6), prompt: petPrompt), wide = card(fixture(6), prompt: petPrompt, at: CGPoint(x: 300, y: 40))
        tall.frame.size.height = 1e21                           // a file edited by hand keeps it
        wide.frame.size.width = 1e21
        editor.add(tall)
        editor.add(wide)
        for zoom in [1, 0.3] as [CGFloat] {
            editor.camera = Camera(zoom: zoom)
            expect(changedPixels(try render([], zoom: zoom), render(editor, size: CGSize(width: 340, height: 280)),
                                 in: CGRect(x: 0, y: 0, width: 340, height: 280)) > 0, "drawn at \(zoom)")
        }
    },
    test("a card draws what its description says now: a write redraws it") {
        let editor = try schemaEditor()
        let id = editor.add(card(fixture(2), prompt: "email and phone"))
        let before = renderBitmap(editor, size: CGSize(width: 320, height: 240))
        editor.transact { $0.update(id, as: SchemaCard.self) { $0.props.setPrompt("email and fax") } }
        let after = renderBitmap(editor, size: CGSize(width: 320, height: 240))
        expect(changedPixels(before, after, in: lineBand(0)) > 20, "phone is fax")
    },
    test("drawing a card reads no schema: a frame of 300 different ones reads none after the first, in full or zoomed out, and a write reads only the card written") {
        let editor = try schemaEditor()
        var ids: [ShapeID] = []
        for i in 0..<300 {
            let schema = "{\"title\": \"Card \(i)\", \"type\": \"object\", \"properties\": {\"field\(i)\": {\"type\": \"string\"}}}"
            ids.append(editor.add(card(schema, prompt: "card \(i)", at: CGPoint(x: CGFloat(i % 20) * 260, y: CGFloat(i / 20) * 260))))
        }
        let size = CGSize(width: 1100, height: 800)
        for skeletons in [false, true] {
            editor.camera = Camera(zoom: 0.2)
            editor.skeletonZoom = skeletons ? 0.35 : 0
            _ = renderBitmap(editor, size: size)
            let read = SchemasPlugin.schemasRead
            _ = renderBitmap(editor, size: size)
            expectEqual(SchemasPlugin.schemasRead, read, "a second frame reads none, skeletons \(skeletons)")
        }
        editor.skeletonZoom = 0
        let first = try require(editor.schemaCard(ids[0])).schema
        editor.transact { $0.update(ids[0], as: SchemaCard.self) { $0.props.schema = first + " " } }
        let typed = SchemasPlugin.schemasRead
        _ = renderBitmap(editor, size: size)
        expect(SchemasPlugin.schemasRead - typed <= 1, "only the written card's, for its name: \(SchemasPlugin.schemasRead - typed)")
    },
    test("every card draws at every zoom, in either appearance, without a problem (and to PNGs when SCHEMA_CARD_PNG_DIR is set)") {
        let directory = ProcessInfo.processInfo.environment["SCHEMA_CARD_PNG_DIR"].map { URL(fileURLWithPath: $0) }
        let prompts = ["", "email, phone and a description", petPrompt, "a book: title, author, pages", "a customer and how to reach them",
                       "an order: its items, where it ships, and its status", "an organization and its headquarters", "", "a payment", ""]
        let all = fixtures.enumerated().map { i, fixture in (fixture.name, card(fixture.json, prompt: prompts[i])) }
        for (zoom, dark, columns, file) in [(1.0, false, 4, "real-all-100.png"), (0.5, false, 4, "real-all-50.png"),
                                            (1.0, true, 4, "real-all-100-dark.png"), (0.3, false, 5, "real-all-30-skeleton.png"),
                                            (0.15, true, 5, "real-all-15-skeleton-dark.png")] {
            let bitmap = try sheet(grid(all, columns: columns), zoom: zoom, dark: dark)
            if let directory { try write(bitmap, to: directory.appendingPathComponent(file)) }
        }
    },
])

/// Cards in rows of `columns`, 40 apart, each captioned above its title's pill: the prototype's sheets.
@MainActor private func grid(_ cards: [(String, SchemaCard)], columns: Int) -> [(String, SchemaCard)] {
    let gap: CGFloat = 40, caption: CGFloat = captionAbove, width: CGFloat = 240
    var y = gap, out: [(String, SchemaCard)] = []
    for start in stride(from: 0, to: cards.count, by: columns) {
        let row = cards[start..<min(start + columns, cards.count)]
        for (i, (name, props)) in row.enumerated() {
            var props = props
            props.frame.origin = CGPoint(x: gap + CGFloat(i) * (width + gap), y: y + caption)
            out.append((name, props))
        }
        y += (row.map(\.1.frame.height).max() ?? 0) + caption + gap
    }
    return out
}

/// How far above a card its caption starts: above its title's pill.
private let captionAbove: CGFloat = 44

/// The canvas with these cards, captioned, at `zoom`, 2 pixels a point, in either appearance.
@MainActor private func sheet(_ cards: [(String, SchemaCard)], zoom: CGFloat, dark: Bool) throws -> NSBitmapImageRep {
    let editor = try schemaEditor()
    for (_, props) in cards { editor.add(props) }
    editor.camera = Camera(zoom: zoom)
    let world = cards.reduce(CGRect.null) { $0.union($1.1.frame) }
    let size = CGSize(width: ((world.maxX + 40) * zoom).rounded(.up), height: ((world.maxY + 40) * zoom).rounded(.up))
    let scale: CGFloat = 2
    let rep = try require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    let cg = try require(NSGraphicsContext(bitmapImageRep: rep)).cgContext
    cg.translateBy(x: 0, y: size.height * scale)
    cg.scaleBy(x: scale, y: -scale)
    try require(NSAppearance(named: dark ? .darkAqua : .aqua)).performAsCurrentDrawingAppearance {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        let bounds = CGRect(origin: .zero, size: size)
        editor.draw(in: cg, bounds: bounds, dirtyRect: bounds)
        cg.scaleBy(x: zoom, y: zoom)
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .medium),
                                                         .foregroundColor: NSColor(white: dark ? 0.6 : 0.5, alpha: 1)]
        for (caption, props) in cards {
            NSAttributedString(string: caption, attributes: attributes).draw(at: CGPoint(x: props.frame.minX, y: props.frame.minY - captionAbove))
        }
        NSGraphicsContext.restoreGraphicsState()
    }
    return rep
}

@MainActor private func write(_ bitmap: NSBitmapImageRep, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try require(bitmap.representation(using: .png, properties: [:])).write(to: url)
}
