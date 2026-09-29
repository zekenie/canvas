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
/// Magenta, as the `{}` mark is: red and blue well above green, blue nearly red's (not the indigo
/// of a subboard's border, whose blue is well above its red, nor validation's red).
func isAccent(_ pixel: [Int]) -> Bool { pixel[0] > pixel[1] + 50 && pixel[2] > pixel[1] + 40 && abs(pixel[0] - pixel[2]) < 60 }
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
    return render(editor, size: size)
}

/// `editor`'s canvas, twice over.
@MainActor func render(_ editor: CanvasEditor, size: CGSize) -> NSBitmapImageRep {
    let bitmap = renderBitmap(editor, size: size, scale: 2)
    bitmap.size = size   // two pixels a point, so `pixel` and `any` take points
    return bitmap
}

// A card at (40, 40), 240 wide: its content runs from x 52 to 268, the title's line from y 52 to 69,
// and row i from y 77 + 22 i, 18 tall.
private func rowBand(_ i: Int) -> CGRect { CGRect(x: 52, y: 77 + 22 * CGFloat(i), width: 216, height: 18) }
private let titleBand = CGRect(x: 52, y: 52, width: 216, height: 17)

// The same card's skeleton at 30%, at (12, 12), 72 wide: inside the padding from x 15.6, the {}'s
// mark from y 16.8, 2.7 tall, the name's bar after it from x 21.3; row i's chip from y 23.1 + 6.6 i,
// 5.4 tall, and the bar in it (or a line's, from x 17.4) 1.8 tall, its middle at y 25.8 + 6.6 i.
private let skeletonMark = CGRect(x: 15.6, y: 16.8, width: 4.2, height: 2.7)
private let skeletonTitle = CGRect(x: 21.3, y: 16.8, width: 40, height: 2.7)
private func skeletonBar(_ i: Int) -> CGFloat { 25.8 + 6.6 * CGFloat(i) }
private func skeletonRow(_ i: Int) -> CGRect { CGRect(x: 15.6, y: 23.1 + 6.6 * CGFloat(i), width: 64.8, height: 5.4) }
/// Where a chip shows and a line's bar doesn't: its inset, left of its bar.
private let chipInset: CGFloat = 16.3
/// Text darker than any skeleton's (the {}'s accent aside): the drawing's text, at any zoom.
private func isText(_ pixel: [Int]) -> Bool { pixel.prefix(3).allSatisfy { $0 < 160 } }

@MainActor let renderTests = Suite("Schema card drawing", [
    test("a frame reads no card's schema again, however many different ones are in view; typing reads only the typed card's") {
        let editor = try schemaEditor()
        var ids: [ShapeID] = []
        for i in 0..<300 {
            let schema = "{\"title\": \"Card \(i)\", \"type\": \"object\", \"properties\": {\"field\(i)\": {\"type\": \"string\"}}}"
            ids.append(editor.add(card(schema, at: CGPoint(x: CGFloat(i % 20) * 260, y: CGFloat(i / 20) * 260))))
        }
        editor.camera = Camera(zoom: 0.2)
        editor.skeletonZoom = 0                                  // in full: a skeleton reads none at all
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
    test("a file and its copy opened beside it, one card with another schema in each: neither window reads it again, frame after frame") {
        // Ids are unique within a file, not across files: a copy made in Finder has the same cards.
        let id = ShapeID()
        let original = try schemaEditor(), copy = try schemaEditor()
        original.transact { $0.insert(AnyShapeRecord(ShapeRecord(id: id, card(fixture(6))))) }
        copy.transact { $0.insert(AnyShapeRecord(ShapeRecord(id: id, card(fixture(2))))) }
        let size = CGSize(width: 340, height: 280)
        _ = renderBitmap(original, size: size)
        _ = renderBitmap(copy, size: size)
        let read = SchemasPlugin.schemasRead
        for _ in 0..<3 {
            _ = renderBitmap(original, size: size)
            _ = renderBitmap(copy, size: size)
        }
        expectEqual(SchemasPlugin.schemasRead, read, "each window's reading is kept beside the other's")
        expectEqual(SchemaCardLayout(try require(original.document[id]?.typed(as: SchemaCard.self))).title, "Order")
        expectEqual(SchemaCardLayout(try require(copy.document[id]?.typed(as: SchemaCard.self))).title, "Contact")
    },
    test("a card: white, the {} mark in magenta and its name in ink, a gray chip per field, a gray star when required") {
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
    test("below 35%, a card is its skeleton: white with a light gray edge and no shadow, the {} an accent mark, and bars where its name and rows' text are") {
        let size = CGSize(width: 120, height: 90), cardRect = CGRect(x: 12, y: 12, width: 72, height: 53.1)
        let editor = try schemaEditor()
        editor.add(card(fixture(6)))
        editor.camera = Camera(zoom: 0.3)
        let skeleton = render(editor, size: size)
        expect(!any(skeleton, in: cardRect, isText), "no text")
        expect(isAbout(Palette.card, within: 2)(pixel(skeleton, at: CGPoint(x: 75, y: 40))), "the card's white")
        // Its edge, where its shadow's showed: a device pixel of light gray inside the frame, then white.
        for (edge, inside) in [(CGPoint(x: 12.25, y: 40), CGPoint(x: 12.75, y: 40)), (CGPoint(x: 83.75, y: 40), CGPoint(x: 83.25, y: 40)),
                               (CGPoint(x: 50, y: 12.25), CGPoint(x: 50, y: 12.75))] {
            expect(isAbout(Palette.skeletonEdge, within: 3)(pixel(skeleton, at: edge)), "the edge at \(edge): \(pixel(skeleton, at: edge))")
            expect(isAbout(Palette.card, within: 2)(pixel(skeleton, at: inside)), "white inside it at \(inside)")
        }
        expect(any(skeleton, in: skeletonMark, isAccent), "the {}'s mark")
        expect(any(skeleton, in: skeletonTitle, isAbout(Palette.textBar, within: 6)), "the name's bar")
        for i in 0..<6 {
            expect(isAbout(Palette.chip, within: 3)(pixel(skeleton, at: CGPoint(x: chipInset, y: skeletonBar(i)))), "row \(i)'s chip")
            expect(any(skeleton, in: skeletonRow(i), isAbout(Palette.textBarOnChip, within: 6)), "row \(i)'s bar")
        }
        // No shadow: around the card, the canvas as it is without it.
        let bare = try render([], zoom: 0.3, size: size)
        let around = [CGRect(x: 6, y: 6, width: 6, height: 66), CGRect(x: 84, y: 6, width: 6, height: 66),
                      CGRect(x: 12, y: 6, width: 72, height: 6), CGRect(x: 12, y: 65.5, width: 72, height: 6)]
        expectEqual(around.map { changedPixels(bare, skeleton, in: $0) }, [0, 0, 0, 0], "no shadow")
        // Drawn in full (the host's switch), the same card at 30% has its text and its shadow.
        editor.skeletonZoom = 0
        let full = render(editor, size: size)
        expect(any(full, in: cardRect, isText), "text in full")
        expect(around.map { changedPixels(bare, full, in: $0) }.reduce(0, +) > 0, "a shadow in full")

        let farther = try render([card(fixture(6))], zoom: 0.15, size: CGSize(width: 60, height: 45))
        expect(!any(farther, in: CGRect(x: 6, y: 6, width: 36, height: 26.5), isText), "no text at 15%")
        expect(isAbout(Palette.skeletonEdge, within: 3)(pixel(farther, at: CGPoint(x: 6.25, y: 20))), "the edge at 15%, as thin on screen")
        expect(isAbout(Palette.card, within: 2)(pixel(farther, at: CGPoint(x: 6.75, y: 20))), "white inside it")
        expect(any(farther, in: CGRect(x: 7.8, y: 8.4, width: 2.1, height: 1.35), isAccent), "the mark at 15%")
        expect(any(farther, in: CGRect(x: 7.8, y: 11.55, width: 32.4, height: 13.2), isAbout(Palette.textBarOnChip, within: 20)), "bars at 15%")
        // At 35%, the card as ever.
        let near = try render([card(fixture(6))], zoom: 0.35, size: CGSize(width: 140, height: 100))
        expect(any(near, in: CGRect(x: 18.2, y: 26.95, width: 75.6, height: 6.3), isText), "the first row's text at 35%")
    },
    test("with its reading kept, a card's skeleton goes by it: a longer name's bar is longer; no fields, no rows' bars; `+N more` and the rules line are bars with no chip") {
        let size = CGSize(width: 120, height: 90)
        let names = try render([card(#"{"properties": {"a": {}, "abcdefghijkl": {}}}"#)], zoom: 0.3, size: size)
        let far = CGPoint(x: 30, y: skeletonBar(1))            // 72 units of bar from 17.4
        expect(isAbout(Palette.textBarOnChip, within: 6)(pixel(names, at: far)), "abcdefghijkl's bar reaches x 30")
        expect(isAbout(Palette.card, within: 2)(pixel(names, at: CGPoint(x: 30, y: skeletonBar(0)))), "a's doesn't: white there")
        // A bar is as long as its text's columns (`SkeletonText`), a wide character two: 名前名前名前 is
        // as long as abcdefghijkl, and a title of five Japanese characters and an emoji as one of
        // twelve letters.
        let lettered = try render([card(#"{"title": "abcdefghijkl", "properties": {"a": {}, "abcdefghijkl": {}}}"#)], zoom: 0.3, size: size)
        let wide = try render([card(#"{"title": "顧客データ🎉", "properties": {"a": {}, "名前名前名前": {}}}"#)], zoom: 0.3, size: size)
        expectEqual(changedPixels(lettered, wide, in: CGRect(origin: .zero, size: size)), 0, "twelve columns each")
        expect(changedPixels(lettered, try render([card(#"{"title": "abcdef", "properties": {"a": {}, "abcdef": {}}}"#)], zoom: 0.3, size: size),
                             in: CGRect(origin: .zero, size: size)) > 0, "six are shorter")

        let empty = try render([card(SchemaCard.starter)], zoom: 0.3, size: size)
        expect(!any(empty, in: skeletonRow(0), { !isAbout(Palette.card, within: 2)($0) }), "a blank row: \"No fields\" isn't a field")
        expect(any(empty, in: skeletonTitle, isAbout(Palette.textBar, within: 6)), "Untitled's bar")

        // Twenty fields: six rows, then `+14 more`, a line, in the seventh.
        let more = try render([card(fixture(5))], zoom: 0.3, size: size)
        for i in 0..<6 { expect(isAbout(Palette.chip, within: 3)(pixel(more, at: CGPoint(x: chipInset, y: skeletonBar(i)))), "row \(i)'s chip") }
        expect(isAbout(Palette.card, within: 2)(pixel(more, at: CGPoint(x: chipInset, y: skeletonBar(6)))), "no chip for +14 more")
        expect(isAbout(Palette.textBar, within: 6)(pixel(more, at: CGPoint(x: 25, y: skeletonBar(6)))), "its bar")
        // Five fields, then the rules line (`Rules if/then`) in the sixth row.
        let rules = try render([card(fixture(9))], zoom: 0.3, size: size)
        expect(isAbout(Palette.chip, within: 3)(pixel(rules, at: CGPoint(x: chipInset, y: skeletonBar(4)))), "the fifth field's chip")
        expect(isAbout(Palette.card, within: 2)(pixel(rules, at: CGPoint(x: chipInset, y: skeletonBar(5)))), "no chip for the rules")
        expect(isAbout(Palette.textBar, within: 6)(pixel(rules, at: CGPoint(x: 30, y: skeletonBar(5)))), "their bar")
    },
    test("a card's skeleton reads no schema: with no reading kept for its text, a chip and a bar for each row its height makes room for") {
        let size = CGSize(width: 120, height: 90)
        let editor = try schemaEditor()
        var props = card(#"{"properties": {"a": {}, "b": {}}}"#)
        props.frame.size.height = 177                           // two fields, and room for six rows: made taller by hand
        let id = editor.add(props)
        editor.camera = Camera(zoom: 0.3)
        _ = render(editor, size: size)                          // Validation has read it, and keeps what it found
        // Readings of as many other texts for its id as a card keeps (`versionsPerCard`, 4), as
        // typing makes them: none is kept for the text it has.
        for n in 0..<4 { _ = SchemaCardLayout(ShapeRecord(id: id, card(fixture(2 + n)))) }
        let read = SchemasPlugin.schemasRead
        let skeleton = render(editor, size: size)
        expectEqual(SchemasPlugin.schemasRead, read, "nothing read")
        for i in 0..<6 {
            expect(isAbout(Palette.chip, within: 3)(pixel(skeleton, at: CGPoint(x: chipInset, y: skeletonBar(i)))), "row \(i)'s chip")
            expect(any(skeleton, in: skeletonRow(i), isAbout(Palette.textBarOnChip, within: 6)), "row \(i)'s bar")
        }
        expect(!any(skeleton, in: CGRect(x: 12, y: 12, width: 72, height: 53.1), isText), "no text")
        expect(any(skeleton, in: skeletonMark, isAccent), "the {}'s mark")
        expect(any(skeleton, in: skeletonTitle, isAbout(Palette.textBar, within: 6)), "a name's bar")
        expectEqual(changedPixels(skeleton, render(editor, size: size), in: CGRect(origin: .zero, size: size)), 0, "the same every frame")
        expectEqual(SchemasPlugin.schemasRead, read, "nothing read by another frame")
        // Drawn in full, a frame reads it.
        editor.camera = Camera(zoom: 0.35)
        _ = render(editor, size: size)
        expectEqual(SchemasPlugin.schemasRead, read + 1, "read once in full")
    },
    test("zoomed out, the first frame after a card's schema changes goes by what it says: an edit, its undo and redo, the sync's write, a write to a board not shown") {
        let size = CGSize(width: 120, height: 90)
        let rules = #"{"properties": {"a": {}, "b": {}, "c": {}}, "allOf": [{}]}"#
        // Three fields, then the rules line in the fourth row: a bar with no chip, where a card with
        // no reading kept for its text would have a fourth field's chip (and nothing asks for
        // another frame).
        @MainActor func drawsRules(_ editor: CanvasEditor, _ comment: String) {
            let bitmap = render(editor, size: size)
            expect(isAbout(Palette.card, within: 2)(pixel(bitmap, at: CGPoint(x: chipInset, y: skeletonBar(3)))), "no chip for the rules: \(comment)")
            expect(isAbout(Palette.textBar, within: 6)(pixel(bitmap, at: CGPoint(x: 30, y: skeletonBar(3)))), "their bar: \(comment)")
        }
        let editor = try schemaEditor()
        let id = editor.add(card(rules))
        editor.camera = Camera(zoom: 0.3)
        drawsRules(editor, "placed")
        editor.transact("Rename") { $0.update(id, as: SchemaCard.self) { $0.props.setSchema(rules.replacingOccurrences(of: #""c""#, with: #""cc""#)) } }
        drawsRules(editor, "edited")
        editor.undo()
        drawsRules(editor, "undone")
        editor.redo()
        drawsRules(editor, "redone")

        let b = try SyncBench()
        let placed = b.place()                                  // at (0, 0), drawn where `card`'s are
        b.editor.camera = Camera(origin: CGPoint(x: -40, y: -40), zoom: 0.3)
        b.typePrompt(placed, "three letters, and a rule")
        b.sync(placed, answer: rules)
        expectEqual(b.card(placed)?.schema, rules)
        drawsRules(b.editor, "the sync's write")

        let pocket = ShapeID(), inside = ShapeID()
        let file = CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(ShapeRecord(id: pocket, Pocket(CGRect(x: 0, y: 0, width: 100, height: 100))))]),
                              children: [pocket: CanvasDocument(shapes: [AnyShapeRecord(ShapeRecord(id: inside, card(SchemaCard.starter)))])])
        let nested = try schemaEditor(file: file, more: [PocketsPlugin()])
        let written: Void? = nested.transact(on: BoardID(owner: pocket), "Write") { $0.update(inside, as: SchemaCard.self) { $0.props.setSchema(rules) } }
        expect(written != nil, "written on the pocket's board")
        expect(nested.showBoard(BoardID(owner: pocket)))
        nested.camera = Camera(zoom: 0.3)
        drawsRules(nested, "written on a board not shown, then shown")
    },
    test("a card of any size a file may hold draws, in full and as its skeleton, its reading kept or not") {
        let editor = try schemaEditor()
        var tall = card(fixture(6)), wide = card(fixture(6), at: CGPoint(x: 300, y: 40))
        tall.frame.size.height = 1e21                           // a file edited by hand keeps it
        wide.frame.size.width = 1e21
        let id = editor.add(tall)
        editor.add(wide)
        for zoom in [1, 0.3] as [CGFloat] {
            editor.camera = Camera(zoom: zoom)
            expect(changedPixels(try render([], zoom: zoom), render(editor, size: CGSize(width: 340, height: 280)),
                                 in: CGRect(x: 0, y: 0, width: 340, height: 280)) > 0, "drawn at \(zoom)")
        }
        _ = SchemaCardLayout(ShapeRecord(id: id, card(fixture(2))))    // no reading kept for its text
        expect(changedPixels(try render([], zoom: 0.3), render(editor, size: CGSize(width: 340, height: 280)),
                             in: CGRect(x: 0, y: 0, width: 340, height: 280)) > 0, "a row for each it has room for, as many as a card shows")
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
                                            (1.0, true, 4, "real-all-100-dark.png"), (0.3, false, 5, "real-all-30-skeleton.png"),
                                            (0.15, true, 5, "real-all-15-skeleton-dark.png")] {
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
