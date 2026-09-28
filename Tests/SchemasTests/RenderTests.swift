import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Foundation
import Geometry
import Schemas
import TestKit

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
/// Indigo, as the `{}` mark is: blue well above red and green.
func isAccent(_ pixel: [Int]) -> Bool { pixel[2] > pixel[0] + 60 && pixel[2] > pixel[1] + 60 }
/// Any hue at all: a channel well apart from another.
func isColorful(_ pixel: [Int]) -> Bool { pixel.prefix(3).max()! - pixel.prefix(3).min()! > 40 }
/// Muted text: darker than the card, lighter than ink.
func isMuted(_ pixel: [Int]) -> Bool { pixel.prefix(3).allSatisfy { $0 < 200 && $0 >= 120 } }
/// Validation's red outline: red, with little green or blue.
func isRed(_ pixel: [Int]) -> Bool { pixel[0] > 180 && pixel[1] < 110 && pixel[2] < 110 }

/// The canvas with `cards` on it, at `zoom`, twice over (as a Retina screen draws it).
@MainActor func render(_ cards: [SchemaCard], zoom: CGFloat = 1, size: CGSize = CGSize(width: 340, height: 280)) throws -> NSBitmapImageRep {
    let editor = try schemaEditor()
    for card in cards { editor.add(card) }
    editor.camera = Camera(zoom: zoom)
    let bitmap = renderBitmap(editor, size: size, scale: 2)
    bitmap.size = size   // two pixels a point, so `pixel` and `any` take points
    return bitmap
}

// A card at (40, 40), 240 wide: its content runs from x 52 to 268, the title's line from y 52 to 69,
// and row i from y 77 + 22 i, 18 tall.
private func rowBand(_ i: Int) -> CGRect { CGRect(x: 52, y: 77 + 22 * CGFloat(i), width: 216, height: 18) }
private let titleBand = CGRect(x: 52, y: 52, width: 216, height: 17)

@MainActor let renderTests = Suite("Schema card drawing", [
    test("a frame reads no card's schema again, however many different ones are in view; typing reads only the typed card's") {
        let editor = try schemaEditor()
        var ids: [ShapeID] = []
        for i in 0..<300 {
            let schema = "{\"title\": \"Card \(i)\", \"type\": \"object\", \"properties\": {\"field\(i)\": {\"type\": \"string\"}}}"
            ids.append(editor.add(card(schema, at: CGPoint(x: CGFloat(i % 20) * 260, y: CGFloat(i / 20) * 260))))
        }
        editor.camera = Camera(zoom: 0.2)
        let size = CGSize(width: 1100, height: 800)
        _ = renderBitmap(editor, size: size)
        let read = SchemasPlugin.schemasRead
        _ = renderBitmap(editor, size: size)
        expectEqual(SchemasPlugin.schemasRead, read, "a second frame of 300 different schemas reads none")
        let first = try require(editor.schemaCard(ids[0])).schema
        for i in 1...300 {                  // a keystroke at a time, each a new text
            editor.transact { $0.update(ids[0], as: SchemaCard.self) { $0.props.setSchema(first + String(repeating: " ", count: i)) } }
        }
        let typed = SchemasPlugin.schemasRead
        _ = renderBitmap(editor, size: size)
        expect(SchemasPlugin.schemasRead - typed <= 1, "only the typed card's, if that: \(SchemasPlugin.schemasRead - typed)")
    },
    test("a card: white, the {} mark in indigo and its name in ink, a gray chip per field, a gray star when required") {
        let bitmap = try render([card(fixture(6))])
        expect(isAbout(Palette.card)(pixel(bitmap, at: CGPoint(x: 150, y: 45))), "the card's body")
        expect(any(bitmap, in: CGRect(x: 52, y: 52, width: 16, height: 17), isAccent), "the {} mark")
        expect(any(bitmap, in: CGRect(x: 70, y: 52, width: 60, height: 17), isInk), "the name")
        for i in 0..<6 {
            expect(isAbout(Palette.chip)(pixel(bitmap, at: CGPoint(x: 54, y: rowBand(i).midY))), "row \(i)'s chip")
            expect(any(bitmap, in: rowBand(i), isInk), "row \(i)'s name")
        }
        expect(!any(bitmap, in: rowBand(6), isInk), "six rows, no seventh")
        expect(!any(bitmap, in: CGRect(x: 52, y: 77, width: 216, height: 128), isColorful), "no hue in the rows")
        // Below the card: canvas.
        expect(!isAbout(Palette.card, within: 3)(pixel(bitmap, at: CGPoint(x: 150, y: 40 + 177 + 8))))
        // The star, by difference: the same card with nothing required differs only in the required
        // field's row, and in no hue (the card's one hue is its {}).
        let required = try render([card(#"{"properties": {"a": {}, "b": {}}, "required": ["a"]}"#)])
        let optional = try render([card(#"{"properties": {"a": {}, "b": {}}}"#)])
        let starred = changedPixels(optional, required, in: rowBand(0))
        expect(starred > 0, "a star drawn")
        expectEqual(changedPixels(optional, required, in: CGRect(x: 20, y: 20, width: 300, height: 130)), starred, "only in a's row")
        expectEqual(changedPixels(optional, required, in: rowBand(1)), 0)
        expect(!any(required, in: rowBand(0), isColorful), "gray")
    },
    test("a required name cut short still ends in its star: …*") {
        let name = "primaryAccountManagerEmailAddress"
        let text = #"{"properties": {"\#(name)": {"type": "string"}}, "required": ["\#(name)"]}"#
        let row = try require(SchemaCardLayout(SchemaDocument(text), size: CGSize(width: 240, height: 67)).rows.first)
        let chip = row.chip
        expect(row.frame.maxX - chip.maxX < 50, "the chip runs up to `string`: the name is cut short")
        let required = try render([card(text)])
        let optional = try render([card(#"{"properties": {"\#(name)": {"type": "string"}}}"#)])
        // The chip's text ends 6 points in from its right; the star is the last thing in it.
        let end = CGRect(x: 40 + chip.maxX - 6 - 8, y: rowBand(0).minY, width: 8, height: 18)
        expect(changedPixels(optional, required, in: end) > 0, "the star, where the cut name ends")
        expect(!any(required, in: rowBand(0), isColorful), "gray")
    },
    test("a card with no fields says so in one muted line, where its first row would be; one that was never a schema too, outlined red") {
        let empty = try render([card(SchemaCard.starter)])
        let line = CGRect(x: 58, y: 77, width: 200, height: 18)
        expect(any(empty, in: line, isMuted), "No fields")
        expect(!any(empty, in: line, isInk), "muted, not ink")
        // No box around it (the old one's corners), no chip under it (where one's fill would show left of its text).
        for point in [CGPoint(x: 53, y: 78), CGPoint(x: 53, y: 94), CGPoint(x: 266, y: 78), CGPoint(x: 266, y: 94), CGPoint(x: 150, y: 78),
                      CGPoint(x: 55, y: 86)] {
            expect(isAbout(Palette.card, within: 2)(pixel(empty, at: point)), "the card's white at \(point)")
        }
        expect(!isAbout(Palette.card, within: 3)(pixel(empty, at: CGPoint(x: 150, y: 40 + 67 + 8))), "67 tall: canvas below")
        expect(!any(empty, in: CGRect(x: 20, y: 20, width: 300, height: 140), isRed), "valid: no outline")

        let broken = try render([card(fixture(10))])
        expect(any(broken, in: line, isMuted), "Invalid JSON")
        expect(!any(broken, in: line, isRed), "never red on the card")
        for point in [CGPoint(x: 53, y: 78), CGPoint(x: 266, y: 94), CGPoint(x: 55, y: 86)] {
            expect(isAbout(Palette.card, within: 2)(pixel(broken, at: point)), "no box: the card's white at \(point)")
        }
        expect(any(broken, in: CGRect(x: 30, y: 30, width: 20, height: 100), isRed), "Validation's outline")
        expect(any(broken, in: CGRect(x: 70, y: 52, width: 60, height: 17), isInk), "still named: Invoice")
    },
    test("far out, rows are bars with no text; below 20%, the title too") {
        // At 30%, the card is at (12, 12), 72 × 53: its rows from y 23.1.
        let bars = try render([card(fixture(6))], zoom: 0.3, size: CGSize(width: 120, height: 90))
        let rows = CGRect(x: 15.6, y: 23.2, width: 64.8, height: 36)
        expect(!any(bars, in: rows, isInk), "no text in the rows")
        expect(any(bars, in: rows, isAbout(Palette.bar, within: 20)), "bars")
        expect(any(bars, in: CGRect(x: 15.6, y: 15.6, width: 64.8, height: 5.1), { $0.prefix(3).allSatisfy { $0 < 160 } }), "the title, still text")
        let farther = try render([card(fixture(6))], zoom: 0.15, size: CGSize(width: 60, height: 45))
        // The title's bar is the secondary gray (115); text would be darker.
        expect(!any(farther, in: CGRect(x: 6, y: 6, width: 36, height: 27), { $0.prefix(3).allSatisfy { $0 < 100 } }), "no text at all")
        expect(any(farther, in: CGRect(x: 7.8, y: 7.8, width: 3, height: 2.6), isAccent), "the mark's bar")
        // The rules line (fixture 9's sixth row, from y 56.1) is a bar too, as `+N more` is.
        let rules = try render([card(fixture(9))], zoom: 0.3, size: CGSize(width: 120, height: 90))
        expect(any(rules, in: CGRect(x: 17, y: 56.1, width: 40, height: 5.4), isAbout(Palette.bar, within: 20)), "the rules' bar")
        // A card's line saying it has none isn't a field: no bar for it.
        let empty = try render([card(SchemaCard.starter)], zoom: 0.3, size: CGSize(width: 120, height: 90))
        expect(!any(empty, in: CGRect(x: 15.6, y: 23.2, width: 64.8, height: 5.4), { $0.prefix(3).allSatisfy { $0 < 230 } }), "a blank row")
    },
    test("a card draws what its schema says now: a write redraws it, a same-sized card of other text draws other text") {
        let editor = try schemaEditor()
        let id = editor.add(card(fixture(2)))
        let before = renderBitmap(editor, size: CGSize(width: 320, height: 240))
        editor.transact { $0.update(id, as: SchemaCard.self) { $0.props.setSchema(fixture(2).replacingOccurrences(of: "phone", with: "fax")) } }
        let after = renderBitmap(editor, size: CGSize(width: 320, height: 240))
        expectEqual(changedPixels(before, after, in: rowBand(0)), 0, "email is as it was")
        expect(changedPixels(before, after, in: rowBand(1)) > 20, "phone is fax")
    },
    test("every fixture draws at every zoom, at any size, without a problem (and to PNGs when SCHEMA_CARD_PNG_DIR is set)") {
        let directory = ProcessInfo.processInfo.environment["SCHEMA_CARD_PNG_DIR"].map { URL(fileURLWithPath: $0) }
        let all = fixtures.map { ($0.name, card($0.json)) }
        for (zoom, dark, columns, file) in [(1.0, false, 4, "real-all-100.png"), (0.5, false, 4, "real-all-50.png"),
                                            (1.0, true, 4, "real-all-100-dark.png"), (0.3, false, 5, "real-all-30-bars.png"),
                                            (0.15, true, 5, "real-all-15-bars-dark.png")] {
            let bitmap = try sheet(grid(all, columns: columns), zoom: zoom, dark: dark)
            if let directory { try write(bitmap, to: directory.appendingPathComponent(file)) }
        }
        for (pair, file) in [((1, 4), "real-closeup-1-4.png"), ((2, 3), "real-closeup-2-3.png"), ((5, 6), "real-closeup-5-6.png"),
                             ((7, 8), "real-closeup-7-8.png"), ((9, 10), "real-closeup-9-10.png")] {
            let bitmap = try sheet(grid([all[pair.0 - 1], all[pair.1 - 1]], columns: 2), zoom: 1, dark: false)
            if let directory { try write(bitmap, to: directory.appendingPathComponent(file)) }
        }
        func sized(_ n: Int, _ width: CGFloat, height: CGFloat? = nil) -> SchemaCard {
            var props = card(fixture(n), width: width)
            if let height { props.frame.size.height = height }
            return props
        }
        let sizes: [(String, SchemaCard, CGPoint)] = [
            ("order, 180 wide", sized(6, 180), CGPoint(x: 40, y: 62)), ("order, 240 (default)", sized(6, 240), CGPoint(x: 260, y: 62)),
            ("order, 360 wide", sized(6, 360), CGPoint(x: 540, y: 62)),
            ("customer, cut to 130 by hand", sized(5, 240, height: 130), CGPoint(x: 40, y: 330)),
            ("pet, 240 × 260 by hand", sized(3, 240, height: 260), CGPoint(x: 320, y: 330)),
            ("long names, 360 wide", sized(8, 360), CGPoint(x: 600, y: 330)),
        ]
        let bitmap = try sheet(sizes.map { caption, props, origin in
            var props = props
            props.frame.origin = origin
            return (caption, props)
        }, zoom: 1, dark: false)
        if let directory { try write(bitmap, to: directory.appendingPathComponent("real-sizes-100.png")) }
    },
])

/// Cards in rows of `columns`, 40 apart, each captioned: the prototype's sheets.
private func grid(_ cards: [(String, SchemaCard)], columns: Int) -> [(String, SchemaCard)] {
    let gap: CGFloat = 40, caption: CGFloat = 22, width: CGFloat = 240
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
            NSAttributedString(string: caption, attributes: attributes).draw(at: CGPoint(x: props.frame.minX, y: props.frame.minY - 22))
        }
        NSGraphicsContext.restoreGraphicsState()
    }
    return rep
}

@MainActor private func write(_ bitmap: NSBitmapImageRep, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try require(bitmap.representation(using: .png, properties: [:])).write(to: url)
}
