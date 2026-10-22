import Adornments
import AppKit
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CanvasUI
import Foundation
import Geometry
import LanguageModels
import Mentions
import StickyNotes
import TestKit
import Titles
import Types

// A type's note draws its rows under its words, and a note that is one the names of its fields: each row's
// name at the left and its kind at the right, a needed field's dot, an inherited row fainter and ticked in
// the color of the type that gave it, another type as its chip, the fold, and what the spot says while
// there are none. Through bitmaps: nothing here reads the screen.

private let white = [255, 255, 255, 255]

/// What a test says when its setup is not what it expects.
private struct Failure: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

/// Type notes of the shared fixtures (`FieldFixtures`), Employee a Person, and a note that is each of
/// `instances`' types, at `origin`; the types in a row from (40, 40), each 200 stored and 320 laid out.
@MainActor
private final class Bench {
    let editor: CanvasEditor
    var book: RowBook { editor.rowBook! }

    init(_ types: [FieldFixtures.TypeText] = [FieldFixtures.person], zoom: CGFloat = 1, buildingOn parents: [(FieldFixtures.TypeText, FieldFixtures.TypeText)] = []) throws {
        editor = CanvasEditor(registry: try Registry(plugins: notePlugins + [LanguageModelsPlugin(model: ScriptedLanguageModel())]), scheduler: ManualScheduler())
        editor.camera.setZoom(zoom, around: .zero)
        for (place, type) in types.enumerated() { add(type, at: CGPoint(x: 40 + 400 * Double(place), y: 40)) }
        for (parent, child) in parents { editor.addTypeLink(parent.id, to: child.id) }
    }

    @discardableResult
    func add(_ type: FieldFixtures.TypeText, at origin: CGPoint) -> ShapeID {
        var note = ShapeRecord(id: type.id, StickyNote(frame: CGRect(origin: origin, size: CGSize(width: 200, height: 200)), text: MentionText(plain: type.words)))
        note[TypeSchemaProperty.self] = SchemaText(type.schema)
        if !type.title.isEmpty { note[TitleProperty.self] = type.title }
        let record = AnyShapeRecord(note)
        editor.transact { $0.insert(record) }
        return record.id
    }

    /// A note of text with `fields` text fields.
    @discardableResult
    func addWide(_ count: Int, words: String = "Wide", at origin: CGPoint = CGPoint(x: 40, y: 40)) -> ShapeID {
        add((ShapeID(), "Wide", words, FieldFixtures.wide(count).schema), at: origin)
    }

    @discardableResult
    func addInstance(of types: [ShapeID], words: String = "Ann", at origin: CGPoint = CGPoint(x: 40, y: 500)) -> ShapeID {
        var note = ShapeRecord(StickyNote(frame: CGRect(origin: origin, size: CGSize(width: 200, height: 200)), text: MentionText(plain: words)))
        note[IsAProperty.self] = types.map(TypeLink.init)
        let record = AnyShapeRecord(note)
        editor.transact { $0.insert(record) }
        return record.id
    }

    /// A note's values.
    func set(_ id: ShapeID, _ values: JSONObject) {
        editor.transact { $0.update(id) { $0[FieldValuesProperty.self] = FieldValues(values) } }
    }

    func draw(dark: Bool = false, size: CGSize = CGSize(width: 900, height: 800)) -> NSBitmapImageRep {
        if !dark { return renderBitmap(editor, size: size) }
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let cg = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
        cg.translateBy(x: 0, y: size.height)
        cg.scaleBy(x: 1, y: -1)
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
            editor.draw(in: cg, bounds: CGRect(origin: .zero, size: size), dirtyRect: CGRect(origin: .zero, size: size))
            NSGraphicsContext.restoreGraphicsState()
        }
        return rep
    }
}

/// How many pixels in `rect` differ from `paper`.
@MainActor private func ink(_ rep: NSBitmapImageRep, in rect: CGRect, paper: [Int] = white, by tolerance: Int = 24) -> Int {
    var count = 0
    for y in stride(from: rect.minY.rounded(.down), to: rect.maxY.rounded(.up), by: 1) {
        for x in stride(from: rect.minX.rounded(.down), to: rect.maxX.rounded(.up), by: 1)
        where zip(pixel(rep, at: CGPoint(x: x, y: y)), paper).prefix(3).contains(where: { abs($0 - $1) > tolerance }) {
            count += 1
        }
    }
    return count
}

/// The darkest red channel in `rect`: how dark its ink gets.
@MainActor private func darkest(_ rep: NSBitmapImageRep, in rect: CGRect) -> Int {
    var low = 255
    for y in stride(from: rect.minY.rounded(.down), to: rect.maxY.rounded(.up), by: 1) {
        for x in stride(from: rect.minX.rounded(.down), to: rect.maxX.rounded(.up), by: 1) { low = min(low, pixel(rep, at: CGPoint(x: x, y: y))[0]) }
    }
    return low
}

/// Whether any pixel in `rect` is about `color`.
@MainActor private func has(_ rep: NSBitmapImageRep, _ color: [Int], in rect: CGRect, within tolerance: Int = 40) -> Bool {
    for y in stride(from: rect.minY.rounded(.down), to: rect.maxY.rounded(.up), by: 1) {
        for x in stride(from: rect.minX.rounded(.down), to: rect.maxX.rounded(.up), by: 1)
        where zip(pixel(rep, at: CGPoint(x: x, y: y)), color).prefix(3).allSatisfy({ abs($0 - $1) <= tolerance }) { return true }
    }
    return false
}

private let amber = [245, 158, 10]

/// A type's color as a note's paper shows it (the light appearance), 0 to 255: its tick, and its chip's capsule
/// (the color at 14% over white) and title.
@MainActor private func typeColor(_ id: ShapeID, in editor: CanvasEditor) -> (solid: [Int], wash: [Int], ink: [Int]) {
    func components(_ color: NSColor?) -> [Int] {
        var found: [Int] = []
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            if let c = color.flatMap({ NSColor(cgColor: $0.cgColor) })?.usingColorSpace(.sRGB) {
                found = [c.redComponent, c.greenComponent, c.blueComponent].map { Int(($0 * 255).rounded()) }
            }
        }
        return found
    }
    let look = editor.types?.look(of: id)
    let solid = components(look?.tick)
    return (solid, solid.map { Int((Double($0) * 0.14 + 255 * 0.86).rounded()) }, components(look?.light.ink))
}

/// The right part of a row, where its kind is.
private func kindRect(_ row: ShownRow) -> CGRect { CGRect(x: row.valueRect.maxX - 90, y: row.rect.minY, width: 90, height: row.rect.height) }

/// A canvas view over `editor` in an unshown window, as the app puts one: enough for an editing view, first
/// responders and the views a press lands in.
@MainActor private func windowedCanvas(_ editor: CanvasEditor) -> (NSWindow, CanvasView) {
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
    let canvas = CanvasView(editor: editor)
    window.contentView = canvas
    editor.viewportDidResize(to: CGSize(width: 800, height: 600))
    return (window, canvas)
}

/// The view a press at a world point lands in (the camera is at its origin, zoom 1): the deepest under it.
@MainActor private func viewUnder(_ canvas: CanvasView, at point: CGPoint) throws -> NSView {
    try require(canvas.hitTest(canvas.convert(point, to: canvas.superview)), "a view under \(point)")
}

/// A press delivered to the rows' view under a point, as the window would. (A text view's own mouse down
/// tracks the pointer until the button is up, so a press on the words is only found, not sent.)
@MainActor private func press(_ window: NSWindow, _ canvas: CanvasView, at point: CGPoint, time: TimeInterval = 1) throws -> NSView {
    let hit = try viewUnder(canvas, at: point)
    guard hit is RowsView else { return hit }
    hit.mouseDown(with: window.mouse(.leftMouseDown, at: point, time: time))
    return hit
}

private let petFields = #"{"type": "object", "properties": {"name": {"type": "string"}, "species": {"type": "string"}, "venue": {"type": "object", "properties": {"city": {"type": "string"}}}}}"#

@MainActor let noteRowsTests = Suite("Note rows", [
    test("a type's note draws ink in the name and the kind of each of its rows, and none below them") {
        let b = try Bench()
        let id = b.addWide(3)
        let rows = b.book.rows(of: id)
        expectEqual(rows.map(\.name), ["f1", "f2", "f3"])
        let drawn = b.draw()
        for row in rows {
            expect(ink(drawn, in: row.nameRect) > 10, "ink in the name of \(row.name)")
            expect(ink(drawn, in: kindRect(row)) > 10, "ink in the kind of \(row.name)")
        }
        let last = try require(rows.last)
        let below = CGRect(x: last.rect.minX, y: last.rect.maxY + 2, width: last.rect.width, height: 40)
        expectEqual(ink(drawn, in: below), 0, "nothing under the last row")
        let rule = try require(b.editor.rowBook?.rowsRect(of: id))
        expect(ink(drawn, in: CGRect(x: rule.minX, y: rule.minY, width: rule.width, height: 1)) > 100, "a hairline under the words")
    },
    test("each state of the spot has its look: three gray bars and no text ink; `No fields`; a reason with the accent blue at its end") {
        let model = ScriptedLanguageModel()
        let editor = CanvasEditor(registry: try Registry(plugins: notePlugins + [LanguageModelsPlugin(model: model)]), scheduler: ManualScheduler())
        var note = ShapeRecord(StickyNote(frame: CGRect(x: 40, y: 40, width: 200, height: 200), text: MentionText(plain: "a pet")))
        note[TypeSchemaProperty.self] = SchemaText(TypeSchemaProperty.starter)
        let record = AnyShapeRecord(note)
        editor.transact { $0.insert(record) }
        let size = CGSize(width: 500, height: 300)
        let book = try require(editor.rowBook), sync = try require(editor.typeSync)
        // Reading: the call is held out.
        model.holdsAnswers = true
        model.queue(#"{"type": "object"}"#)
        editor.transact { $0.update(record.id, as: StickyNote.self) { $0.props.text = MentionText(plain: "a pet, edited") } }
        sync.commit(record.id)
        expectEqual(book.spot(of: record.id), .reading)
        let reading = renderBitmap(editor, size: size)
        let block = try require(book.rowsRect(of: record.id))
        let firstRow = CGRect(x: block.minX, y: block.minY + TypesStyle.rowsLead, width: block.width, height: TypesStyle.rowHeight)
        expect(ink(reading, in: firstRow) > 100, "a bar")
        expect(darkest(reading, in: CGRect(x: block.minX, y: block.minY + TypesStyle.rowsLead, width: block.width, height: 3 * TypesStyle.rowHeight)) > 200, "gray bars, no text")
        spinRunLoop(until: { model.waiting == 1 })
        model.release()
        spinRunLoop(until: { sync.status(of: record.id) == .idle })
        // No fields.
        expectEqual(book.spot(of: record.id), .noFields)
        let none = renderBitmap(editor, size: size)
        expect(ink(none, in: firstRow) > 20 && darkest(none, in: firstRow) < 200, "`No fields`, in text")
        // A reason, and Retry in the accent blue at its end.
        model.holdsAnswers = false
        model.queue(.overloaded)
        editor.transact { $0.update(record.id, as: StickyNote.self) { $0.props.text = MentionText(plain: "a pet, edited again") } }
        sync.commit(record.id)
        spinRunLoop(until: { sync.status(of: record.id) != .updating(.schema) })
        guard case .failed(let reason, .retry?)? = book.spot(of: record.id) else { throw Failure("a reason with Retry: \(String(describing: book.spot(of: record.id)))") }
        expect(!reason.isEmpty)
        let failed = renderBitmap(editor, size: size)
        expect(has(failed, [0, 97, 217], in: firstRow, within: 60), "Retry in the accent blue")
        expect(!has(none, [0, 97, 217], in: firstRow, within: 60), "and no blue without it")
    },
    test("a needed field has amber pixels after its name; a field that is not has none") {
        let b = try Bench([FieldFixtures.person])
        let rows = b.book.rows(of: FieldFixtures.personID)
        expectEqual(rows.map(\.name), ["name", "email"])
        expectEqual(rows.map(\.isNeeded), [true, false])
        let drawn = b.draw()
        expect(has(drawn, amber, in: rows[0].nameRect, within: 30), "the dot after `name`")
        expect(!has(drawn, amber, in: rows[1].nameRect, within: 30), "none after `email`")
        expect(!has(drawn, amber, in: rows[0].valueRect, within: 30), "and none in the kind")
    },
    test("inherited rows are fainter than own rows, and each has its type's color in the left padding; own rows have none") {
        let b = try Bench([FieldFixtures.person, FieldFixtures.employee], buildingOn: [(FieldFixtures.person, FieldFixtures.employee)])
        let rows = b.book.rows(of: FieldFixtures.employeeID)
        expectEqual(rows.map(\.name), ["name", "email", "role", "start date"])
        expectEqual(rows.map(\.isFaint), [true, true, false, false])
        expectEqual(rows.map(\.tick), [FieldFixtures.personID, FieldFixtures.personID, nil, nil])
        let drawn = b.draw()
        let faint = darkest(drawn, in: rows[0].nameRect), full = darkest(drawn, in: rows[2].nameRect)
        expect(faint > full + 40, "an inherited name is fainter: \(faint) against \(full)")
        let faintKind = darkest(drawn, in: rows[0].valueRect), fullKind = darkest(drawn, in: rows[2].valueRect)
        expect(faintKind > fullKind + 15, "an inherited row's kind is fainter too: \(faintKind) against \(fullKind)")
        let tick = { (row: ShownRow) in CGRect(x: row.rect.minX - TypesStyle.tickInset, y: row.rect.minY + 6, width: TypesStyle.tickWidth, height: row.rect.height - 12) }
        let personColor = typeColor(FieldFixtures.personID, in: b.editor).solid
        for row in rows.prefix(2) { expect(has(drawn, personColor, in: tick(row), within: 24), "\(row.name)'s tick is Person's color, in the padding") }
        for row in rows.suffix(2) { expectEqual(ink(drawn, in: tick(row).insetBy(dx: -3, dy: 0)), 0, "\(row.name) has no tick") }
    },
    test("an inherited row's tick is drawn outside the block, in the paper's left padding, and is not clipped away") {
        let b = try Bench([FieldFixtures.person, FieldFixtures.employee], buildingOn: [(FieldFixtures.person, FieldFixtures.employee)])
        let block = try require(b.book.rowsRect(of: FieldFixtures.employeeID))
        let row = try require(b.book.rows(of: FieldFixtures.employeeID).first)
        let x = block.minX - TypesStyle.tickInset
        expect(x > 440, "inside the paper: \(x) (the note starts at 440)")
        expect(has(b.draw(), typeColor(FieldFixtures.personID, in: b.editor).solid, in: CGRect(x: x, y: row.rect.midY - 2, width: TypesStyle.tickWidth, height: 4), within: 24))
    },
    test("a chip is drawn in a row of another type's fields, in that type's color; dashed once the type is deleted") {
        let b = try Bench([FieldFixtures.address, FieldFixtures.order])
        let rows = b.book.rows(of: FieldFixtures.orderID)
        let row = try require(rows.first { $0.name == "shipping address" })
        guard case .kind(_, let chip, _) = row.content else { throw Failure("a kind") }
        expectEqual(chip, FieldFixtures.addressID)
        let address = typeColor(FieldFixtures.addressID, in: b.editor)
        let chipArea = CGRect(x: row.valueRect.maxX - 140, y: row.rect.minY, width: 140, height: row.rect.height)
        let drawn = b.draw()
        // A light chip: its capsule is the color at 14%, its text the color's ink.
        expect(has(drawn, address.wash, in: chipArea, within: 10) || has(drawn, address.ink, in: chipArea, within: 60), "the chip in Address's color")
        let filled = ink(drawn, in: chipArea)
        b.editor.removeType(FieldFixtures.addressID)
        let gone = b.draw()
        expect(ink(gone, in: chipArea) > 20, "a dashed chip with the last name")
        expect(ink(gone, in: chipArea) < filled, "far less ink than the filled one")
    },
    test("the fold rows read as the rule says, and draw") {
        let b = try Bench()
        let id = b.addWide(20)
        let rows = b.book.rows(of: id)
        expectEqual(rows.map(\.name), (1...8).map { "f\($0)" } + ["+12 more"])
        guard case .fold(let words) = rows[8].content else { throw Failure("a fold") }
        expectEqual(words, "")
        let drawn = b.draw()
        expect(ink(drawn, in: rows[8].rect) > 20, "`+12 more ›` is drawn")
        let nine = try Bench()
        let wide9 = nine.addWide(9)
        expectEqual(nine.book.rows(of: wide9).count, 9)
        let person = try Bench([FieldFixtures.person, FieldFixtures.employee], buildingOn: [(FieldFixtures.person, FieldFixtures.employee)])
        let employee = person.addWide(8, at: CGPoint(x: 900, y: 40))
        person.editor.addTypeLink(FieldFixtures.personID, to: employee)
        let inherited = person.book.rows(of: employee)
        expectEqual(inherited.map(\.name), ["from Person"] + (1...8).map { "f\($0)" }, "ten fields, two of them Person's: they fold")
        guard case .fold(let value) = inherited[0].content else { throw Failure("a fold") }
        expectEqual(value, "2 fields")
        expectEqual(inherited[0].tick, FieldFixtures.personID)
    },
    test("a long name is cut and the kind is whole; the name column is at most 45% of the rows' width") {
        let b = try Bench()
        let long = "averyveryveryverylongfieldnamethatneverseemstoend"
        let id = b.add((ShapeID(), "Long", "Words", #"{"type": "object", "properties": {"\#(long)": {"type": "string"}, "b": {"type": "string"}}}"#), at: CGPoint(x: 40, y: 40))
        let rows = b.book.rows(of: id)
        let block = try require(b.book.rowsRect(of: id))
        expectEqual(rows[0].nameRect.width, TypesStyle.nameShare * block.width)
        expectEqual(rows[1].nameRect.width, rows[0].nameRect.width, "one column")
        let drawn = b.draw()
        let gap = CGRect(x: rows[0].nameRect.maxX, y: rows[0].rect.minY, width: TypesStyle.nameGap - 1, height: rows[0].rect.height)
        expectEqual(ink(drawn, in: gap), 0, "the name is cut before the kind's column")
        expect(ink(drawn, in: kindRect(rows[0])) > 10, "the kind is whole")
    },
    test("the name column is the same width on a type's note and on a note that is one, so a name is cut at the same place") {
        let b = try Bench([FieldFixtures.person])
        let long = "averyveryveryverylongfieldnamethatneverseemstoend"
        let id = b.add((ShapeID(), "Long", "Words", #"{"type": "object", "properties": {"\#(long)": {"type": "string"}, "b": {"type": "string"}}}"#), at: CGPoint(x: 440, y: 40))
        let instance = b.addInstance(of: [id])
        let type = b.book.rows(of: id), mine = b.book.rows(of: instance)
        expectEqual(mine.map(\.name), type.map(\.name))
        expect(zip(mine, type).allSatisfy { abs($0.nameRect.width - $1.nameRect.width) < 0.001 }, "the same column: \(mine.map(\.nameRect.width)) and \(type.map(\.nameRect.width))")
        expect(zip(mine, type).allSatisfy { abs($0.valueRect.width - $1.valueRect.width) < 0.001 })
        let plain = try Bench([FieldFixtures.person])
        let person = plain.addInstance(of: [FieldFixtures.personID])
        let names = plain.book.rows(of: person)
        let draws = plain.draw(size: CGSize(width: 500, height: 900))
        let yellow = [255, 222, 115, 255]
        for row in names { expect(ink(draws, in: row.nameRect, paper: yellow) > 10, "the name of \(row.name) is drawn on a note that is one") }
        for row in names { expect(ink(draws, in: row.valueRect, paper: yellow) > 5, "and `add \(row.name)`, empty, at the right") }
    },
    test("the rows draw under the editor while the words are edited, and the words' lines still fall on the render's") {
        for (scale, zoom) in [(1, 1), (2, 1), (1, 2), (2, 0.6)] as [(CGFloat, CGFloat)] {
            let b = try Bench([FieldFixtures.person])
            b.editor.camera.setZoom(zoom, around: .zero)
            let id = FieldFixtures.personID
            let paper = try require(b.editor.shapeContext.frame(of: id))
            let size = CGSize(width: (paper.maxX + 20) * zoom, height: (paper.maxY + 20) * zoom)
            let inView = b.editor.camera.toView(paper)
            let drawn = renderBitmap(b.editor, size: size, scale: scale)
            expect(b.editor.beginEditing(id))
            let editing = try require(b.editor.makeEditingView())
            let edited = renderBitmap(b.editor, size: size, scale: scale, editing: editing)
            let rows = b.book.rows(of: id)
            let first = b.editor.camera.toView(rows[0].nameRect)
            expect(ink(edited, in: CGRect(x: first.minX * scale, y: first.minY * scale, width: first.width * scale, height: first.height * scale)) > 10, "the rows draw under the editor at \(scale)×, zoom \(zoom)")
            let words = b.editor.camera.toView(try require(b.editor.registry.mentionTextPlacements(of: try require(b.editor.document[id]), in: b.editor.shapeContext).first?.box))
            let difference = largestDifference(drawn, edited, in: words, scale: scale)
            expect(difference <= antiAliasing, "at \(scale)×, zoom \(zoom): a pixel of the words differs by \(difference)")
            _ = inView
            b.editor.endEditing()
        }
    },
    test("a press on Retry in the editing view reads again and leaves the caret where it was") {
        let model = ScriptedLanguageModel()
        let editor = CanvasEditor(registry: try Registry(plugins: notePlugins + [LanguageModelsPlugin(model: model)]), scheduler: ManualScheduler())
        var note = ShapeRecord(StickyNote(frame: CGRect(x: 40, y: 40, width: 200, height: 200), text: MentionText(plain: "a pet in my household")))
        note[TypeSchemaProperty.self] = SchemaText(TypeSchemaProperty.starter)
        let id = note.id
        editor.transact { $0.insert(AnyShapeRecord(note)) }
        let book = try require(editor.rowBook), sync = try require(editor.typeSync)
        model.queue(.overloaded)
        sync.commit(id)
        spinRunLoop(until: { sync.status(of: id) != .updating(.schema) })
        guard case .failed(_, .retry?)? = book.spot(of: id) else { throw Failure("a reason with Retry") }
        let (window, canvas) = windowedCanvas(editor)
        expect(editor.beginEditing(id))
        let text = try require(window.firstResponder as? NSTextView)
        text.setSelectedRange(NSRange(location: 3, length: 0))
        let retry = try require(book.actionRect(of: id))
        model.queue(petFields)
        let hit = try press(window, canvas, at: CGPoint(x: retry.midX, y: retry.midY))
        expect(hit is RowsView, "the rows' view takes the press, not the text under it: \(type(of: hit))")
        spinRunLoop(until: { sync.status(of: id) == .idle })
        expectEqual(model.requests.count, 2, "read again")
        expectEqual(book.spot(of: id), .rows)
        expectEqual(editor.editingShapeID, id, "still editing")
        expectEqual(text.selectedRange(), NSRange(location: 3, length: 0), "the caret where it was")
        expect(window.firstResponder === text)
    },
    test("while the words are edited a press on a plain row moves no caret, one on a row with `›` asks for its card, and one on the words is the text's") {
        let b = try Bench()
        let id = b.add((ShapeID(), "Pet", "A pet in my household.", petFields), at: CGPoint(x: 40, y: 40))
        let (window, canvas) = windowedCanvas(b.editor)
        expect(b.editor.beginEditing(id))
        let text = try require(window.firstResponder as? NSTextView)
        text.setSelectedRange(NSRange(location: 3, length: 0))
        let rows = b.book.rows(of: id)
        let name = try require(rows.first { $0.name == "name" }), venue = try require(rows.first { $0.name == "venue" })
        expect(try press(window, canvas, at: CGPoint(x: name.rect.midX, y: name.rect.midY)) is RowsView)
        expectEqual(text.selectedRange(), NSRange(location: 3, length: 0), "a plain row: no caret moved")
        expect(b.book.opened.isEmpty)
        let lead = try require(b.book.rowsRect(of: id))
        expect(try press(window, canvas, at: CGPoint(x: lead.midX, y: lead.minY + 3)) is RowsView)
        expectEqual(text.selectedRange(), NSRange(location: 3, length: 0), "the lead under the hairline: none either")
        expect(try press(window, canvas, at: CGPoint(x: venue.rect.midX, y: venue.rect.midY)) is RowsView)
        expectEqual(b.book.opened.map(\.target), [.field(FieldPath(field: "venue"))], "the card is asked for")
        expectEqual(b.book.opened.first?.isReadOnly, true)
        expectEqual(text.selectedRange(), NSRange(location: 3, length: 0))
        let words = try require(b.editor.registry.mentionTextPlacements(of: try require(b.editor.document[id]), in: b.editor.shapeContext).first?.box)
        let hit = try viewUnder(canvas, at: CGPoint(x: words.minX + 6, y: words.minY + 6))
        expect(hit === text, "the words are the text view's: \(type(of: hit))")
        // The view follows the rows: another field makes the note taller and the view with it.
        let before = try require(canvas.descendants(RowsView.self).first).frame
        b.editor.transact { $0.update(id) { $0[TypeSchemaProperty.self] = SchemaText(petFields.replacingOccurrences(of: #""species""#, with: #""kind": {"type": "string"}, "species""#)) } }
        let after = try require(canvas.descendants(RowsView.self).first).frame
        expectEqual(after.height, before.height + TypesStyle.rowHeight, "one more row, one more row of view")
        expect(b.editor.rowBook?.rowsRect(of: id)?.height == after.height)
    },
    test("zoomed out at 30%: a bar for each row's name, as wide as the name; a fold is three dots; the words' bars stay above the rows; `No fields` and the reading state are bars") {
        let b = try Bench([], zoom: 0.3)
        // Untitled: zoomed out a titled note wears its title large over the paper, on top of the rows' bars.
        let words = "A thing with a long enough description that it wraps on to a second line, and then a third one besides."
        let id = b.add((ShapeID(), "", words, #"{"type": "object", "properties": {"a": {"type": "string"}, "averyveryverylongfieldname": {"type": "string"}, "b": {"type": "string"}}}"#), at: CGPoint(x: 40, y: 40))
        let rows = b.book.rows(of: id)
        expectEqual(rows.map(\.name), ["a", "averyveryverylongfieldname", "b"])
        let drawn = b.draw(size: CGSize(width: 300, height: 120))
        let zoom = b.editor.camera.zoom
        let view = { (rect: CGRect) in b.editor.camera.toView(rect) }
        /// How far across a row's name column ink goes, in world units: the bar's width.
        @MainActor func extent(_ row: ShownRow) -> CGFloat {
            let rect = view(row.rect)
            var widest: CGFloat = 0
            for x in stride(from: rect.minX, to: rect.minX + view(row.nameRect).width + 4, by: 1)
            where ink(drawn, in: CGRect(x: x, y: rect.minY, width: 1, height: rect.height), by: 6) > 0 { widest = x + 1 - rect.minX }
            return widest / zoom
        }
        let widths = rows.map(extent)
        expect(widths.allSatisfy { $0 > 0 }, "a bar in each row: \(widths)")
        expect(widths[1] > widths[0] * 3, "as wide as the name: \(widths)")
        for row in rows { expectEqual(ink(drawn, in: view(row.valueRect).insetBy(dx: 1, dy: 0), by: 6), 0, "nothing at the right of \(row.name)") }
        let block = try require(b.book.rowsRect(of: id))
        let last = try require(rows.last)
        let paper = try require(b.editor.shapeContext.frame(of: id))
        expectEqual(ink(drawn, in: view(CGRect(x: block.minX, y: block.minY, width: block.width, height: TypesStyle.rowsLead - 1)), by: 6), 0, "no hairline zoomed out")
        expectEqual(ink(drawn, in: view(CGRect(x: block.minX, y: last.rect.maxY + 2, width: block.width, height: paper.maxY - last.rect.maxY - 4)), by: 6), 0,
                    "nothing under the last row")
        expect(ink(drawn, in: view(CGRect(x: paper.minX, y: paper.minY, width: paper.width, height: block.minY - paper.minY)), by: 6) > 0, "the words' bars, above the rows")
        // A fold is three dots from the left edge.
        let wide = b.addWide(20, at: CGPoint(x: 440, y: 40))
        let more = try require(b.book.rows(of: wide).last)
        let after = b.draw()
        for dot in 0..<3 {
            let x = more.rect.minX + CGFloat(dot) * (TypesStyle.skeletonFoldDot + TypesStyle.skeletonFoldDotGap)
            expect(ink(after, in: view(CGRect(x: x, y: more.rect.midY - 2, width: TypesStyle.skeletonFoldDot, height: 4)), by: 6) > 0, "dot \(dot) of `+12 more`")
        }
        // The reading state is its three bars; a reason, one.
        let model = ScriptedLanguageModel()
        let editor = CanvasEditor(registry: try Registry(plugins: notePlugins + [LanguageModelsPlugin(model: model)]), scheduler: ManualScheduler())
        editor.camera.setZoom(0.3, around: .zero)
        var note = ShapeRecord(StickyNote(frame: CGRect(x: 40, y: 40, width: 200, height: 200), text: MentionText(plain: "a pet")))
        note[TypeSchemaProperty.self] = SchemaText(TypeSchemaProperty.starter)
        let record = AnyShapeRecord(note)
        editor.transact { $0.insert(record) }
        let book = try require(editor.rowBook), sync = try require(editor.typeSync)
        model.holdsAnswers = true
        model.queue(.overloaded)
        sync.commit(record.id)
        expectEqual(book.spot(of: record.id), .reading)
        let blockNow = try require(book.rowsRect(of: record.id))
        let reading = renderBitmap(editor, size: CGSize(width: 300, height: 200))
        let rowView = { (row: Int) in editor.camera.toView(CGRect(x: blockNow.minX, y: blockNow.minY + TypesStyle.rowsLead + CGFloat(row) * TypesStyle.rowHeight, width: blockNow.width, height: TypesStyle.rowHeight)) }
        for row in 0..<3 { expect(ink(reading, in: rowView(row), by: 6) > 0, "reading bar \(row)") }
        spinRunLoop(until: { model.waiting == 1 })
        model.release()
        spinRunLoop(until: { sync.status(of: record.id) != .updating(.schema) })
        guard case .failed? = book.spot(of: record.id) else { throw Failure("a reason") }
        let failed = renderBitmap(editor, size: CGSize(width: 300, height: 200))
        expect(ink(failed, in: rowView(0), by: 6) > 0, "one bar for the reason")
        expectEqual(ink(failed, in: rowView(1), by: 6), 0, "and no second")
    },
    test("zoomed out to 10%, below the zoom a row is under three pixels tall, no bar is drawn for any row") {
        let b = try Bench([], zoom: 0.1)
        let id = b.addWide(5)
        let rows = b.book.rows(of: id)
        let drawn = b.draw(size: CGSize(width: 200, height: 100))
        for row in rows { expectEqual(ink(drawn, in: b.editor.camera.toView(row.rect), by: 6), 0, "no bar in \(row.name)") }
        b.editor.camera.setZoom(TypesStyle.skeletonRowsZoom, around: .zero)
        let drawnAt = b.draw(size: CGSize(width: 400, height: 200))
        expect(ink(drawnAt, in: b.editor.camera.toView(try require(rows.first).rect), by: 6) > 0, "at the zoom itself the bars are drawn")
    },
    test("light and dark give the same rows, chips and a gone type's dashed chip: the paper's ink is fixed") {
        let b = try Bench([FieldFixtures.address, FieldFixtures.order])
        b.editor.removeType(FieldFixtures.addressID)
        let rows = b.book.rows(of: FieldFixtures.orderID)
        let light = b.draw(), dark = b.draw(dark: true)
        for row in rows {
            let rect = row.rect.insetBy(dx: 0, dy: 2)
            expect(abs(darkest(light, in: rect) - darkest(dark, in: rect)) <= 3, "\(row.name): the same darkest ink, \(darkest(light, in: rect)) and \(darkest(dark, in: rect))")
            expectEqual(ink(light, in: rect, paper: white, by: 30) > 0, ink(dark, in: rect, paper: [235, 235, 235, 255], by: 30) > 0)
        }
        let chipRow = try require(rows.first { $0.name == "shipping address" })
        let chip = CGRect(x: chipRow.valueRect.maxX - 120, y: chipRow.rect.minY, width: 120, height: chipRow.rect.height)
        let a = ink(light, in: chip, paper: white, by: 30), c = ink(dark, in: chip, paper: [235, 235, 235, 255], by: 30)
        expect(abs(a - c) * 20 <= max(a, c), "the chip, dashes and all: \(a) and \(c) inked pixels")
    },
    test("each kind of value has its look: a value in the ink, `add x` faint, a box that is blue when ticked, a summary with its `›`") {
        let b = try Bench([FieldFixtures.everyKind.a, FieldFixtures.address])
        let id = b.addInstance(of: [FieldFixtures.kindsAID])
        b.set(id, ["name": "Ann", "done": true, "status": "paid", "tags": ["gift", "mugs"]])
        let rows = b.book.rows(of: id)
        let drawn = b.draw()
        let yellow = [255, 222, 115, 255]
        let row = { (name: String) throws -> ShownRow in try require(rows.first { $0.name == name }, name) }
        let value = { (name: String) throws -> CGRect in try row(name).valueRect }
        for name in ["name", "status", "tags"] { expect(ink(drawn, in: try value(name), paper: yellow) > 20, "\(name) is drawn") }
        let filled = darkest(drawn, in: try value("name")), faint = darkest(drawn, in: try value("price"))
        expect(ink(drawn, in: try value("price"), paper: yellow) > 5, "`add price`")
        expect(faint > filled + 40, "the empty row is fainter than a value: \(faint) against \(filled)")
        let box = { (name: String) throws -> CGRect in let r = try value(name); return CGRect(x: r.minX, y: try row(name).rect.midY - 7, width: 14, height: 14) }
        expect(has(drawn, [0, 97, 217], in: try box("done"), within: 40), "a ticked box is blue")
        b.set(id, ["done": false])
        let unticked = b.draw()
        expect(!has(unticked, [0, 97, 217], in: try box("done"), within: 40), "an unticked one is not")
        expect(ink(unticked, in: try box("done"), paper: yellow) > 20, "but it is there, outlined")
        // A summary's `›` follows the text: more ink in the row than the text alone has.
        let tags = try row("tags")
        expect(ink(drawn, in: CGRect(x: tags.valueRect.minX, y: tags.rect.minY, width: 100, height: tags.rect.height), paper: yellow) > 20)
    },
    test("a wrong value is red with a wavy line under it, and so is a row above it; a needed one is amber; a fold carries the worst of what it folds") {
        let b = try Bench([FieldFixtures.person, FieldFixtures.order])
        let yellow = [255, 222, 115, 255]
        let red = [189, 26, 26], amberText = [140, 82, 0]
        let person = b.addInstance(of: [FieldFixtures.personID])
        b.set(person, ["name": "Bob"])
        func problem(_ path: FieldPath, _ kind: FieldClass) -> FieldProblem {
            FieldProblem(path: path, kind: kind, keyword: kind == .wrong ? "format" : "required", place: [], message: "")
        }
        let email = try require(b.book.rows(of: person).first { $0.name == "email" })
        let name = try require(b.book.rows(of: person).first { $0.name == "name" })
        let underline = CGRect(x: email.valueRect.minX, y: email.rect.midY + 6.5, width: 30, height: 4.5)
        let before = b.draw()
        expect(!has(before, red, in: email.valueRect, within: 40) && ink(before, in: underline, paper: yellow) == 0, "unmarked")
        // The real check (Track G's): a value that is not an email is wrong, with nothing handed in.
        b.set(person, ["name": "Bob", "email": "Bob"])
        expectEqual(b.editor.fieldChecks?.check(of: try require(b.editor.document[person])).mark(at: FieldPath(field: "email")), .wrong)
        let wrong = b.draw()
        expect(has(wrong, red, in: email.valueRect, within: 40), "the value is red")
        expect(ink(wrong, in: underline, paper: yellow) > 0, "with a wavy line under the baseline")
        expect(!has(wrong, red, in: name.valueRect, within: 40), "the row above it that is fine is not")
        // The row being typed in is not drawn, marked or not: its own text view draws it.
        b.editor.fieldChecks?.typing = (person, FieldPath(field: "email"))
        let typing = b.draw()
        expectEqual(ink(typing, in: email.valueRect, paper: yellow), 0, "the typed row's value is the field's to draw")
        b.editor.fieldChecks?.typing = nil
        // Needed: amber, not red; inside a row that has a value its summary is amber.
        let order = b.addInstance(of: [FieldFixtures.orderID], at: CGPoint(x: 440, y: 500))
        b.set(order, ["lineItems": [["product": "Mug"]], "status": "paid"])
        let rows = b.book.rows(of: order)
        let customer = try require(rows.first { $0.name == "customer" }), items = try require(rows.first { $0.name == "line items" })
        let needed = b.draw()
        expect(has(needed, amberText, in: customer.valueRect, within: 40), "`add customer` is amber")
        expect(has(needed, amberText, in: items.valueRect, within: 40), "`1 item` is amber for a missing quantity inside it")
        expect(!has(needed, red, in: customer.valueRect, within: 40) && !has(needed, red, in: items.valueRect, within: 40), "and nothing is red")
        b.set(order, ["lineItems": [["product": "Mug", "quantity": 0]]])
        let inside = b.draw()
        expect(has(inside, red, in: items.valueRect, within: 40), "a wrong cell inside makes its row red")
        // The fold carries the worst mark of its rows.
        let wide = b.addWide(20, at: CGPoint(x: 900, y: 40))
        let instance = b.addInstance(of: [wide], at: CGPoint(x: 900, y: 500))
        let more = try require(b.book.rows(of: instance).last)
        expectEqual(more.name, "+12 more")
        let foldRect = CGRect(x: more.rect.minX, y: more.rect.minY, width: 90, height: more.rect.height)
        let plain = b.draw(size: CGSize(width: 1300, height: 1000))
        expect(!has(plain, red, in: foldRect, within: 40) && !has(plain, amberText, in: foldRect, within: 40))
        b.book.checks = { _ in FieldCheck(problems: [problem(FieldPath(field: "f15"), .needed)]) }
        expect(has(b.draw(size: CGSize(width: 1300, height: 1000)), amberText, in: foldRect, within: 40), "amber for a needed one folded away")
        b.book.checks = { _ in FieldCheck(problems: [problem(FieldPath(field: "f15"), .needed), problem(FieldPath(field: "f12"), .wrong)]) }
        expect(has(b.draw(size: CGSize(width: 1300, height: 1000)), red, in: foldRect, within: 40), "red for a wrong one: the worst")
    },
    test("the red and the amber of a row's text each read at 4.5 to 1 or more on a note's yellow and on white") {
        func linear(_ c: CGFloat) -> CGFloat { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        func luminance(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGFloat { 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b) }
        func contrast(_ a: CGFloat, _ b: CGFloat) -> CGFloat { (max(a, b) + 0.05) / (min(a, b) + 0.05) }
        let yellow = luminance(1.0, 0.87, 0.45), white = luminance(1, 1, 1)
        for (name, ink) in [("red", luminance(0.74, 0.10, 0.10)), ("amber", luminance(0.55, 0.32, 0.0))] {
            expect(contrast(ink, yellow) >= 4.5, "\(name) on yellow: \(contrast(ink, yellow))")
            expect(contrast(ink, white) >= 4.5, "\(name) on white: \(contrast(ink, white))")
        }
    },
    test("zoomed out, a filled row has a second bar for its value, an empty one has none, and a wrong one is red") {
        let b = try Bench([FieldFixtures.person], zoom: 0.3)
        let id = b.addInstance(of: [FieldFixtures.personID], words: "")
        b.set(id, ["name": "Ann"])
        let rows = b.book.rows(of: id)
        let name = try require(rows.first { $0.name == "name" }), email = try require(rows.first { $0.name == "email" })
        let view = { (rect: CGRect) in b.editor.camera.toView(rect) }
        let drawn = b.draw(size: CGSize(width: 400, height: 400))
        let skeleton = pixel(drawn, at: CGPoint(x: view(email.valueRect).midX, y: view(email.valueRect).midY))
        expect(ink(drawn, in: view(name.valueRect).insetBy(dx: 1, dy: 0), paper: skeleton, by: 6) > 0, "a bar for Ann")
        expectEqual(ink(drawn, in: view(email.valueRect).insetBy(dx: 1, dy: 0), paper: skeleton, by: 6), 0, "none for an empty row")
        let letters = b.addInstance(of: [FieldFixtures.personID], words: "", at: CGPoint(x: 440, y: 500))
        b.set(letters, ["name": "Zed"])
        let other = try require(b.book.rows(of: letters).first { $0.name == "name" })
        let again = b.draw(size: CGSize(width: 800, height: 400))
        let barWidth = { (rep: NSBitmapImageRep, row: ShownRow) -> Int in
            let rect = view(row.valueRect)
            return Int(stride(from: rect.minX, to: rect.maxX, by: 1).filter { ink(rep, in: CGRect(x: $0, y: rect.minY, width: 1, height: rect.height), paper: skeleton, by: 6) > 0 }.count)
        }
        expectEqual(barWidth(again, name), barWidth(again, other), "a bar says only that there is a value, never what it says")
        b.book.checks = { _ in FieldCheck(problems: [FieldProblem(path: FieldPath(field: "name"), kind: .wrong, keyword: "x", place: [], message: "")]) }
        let wrong = b.draw(size: CGSize(width: 400, height: 400))
        expect(has(wrong, [235, 120, 73], in: view(name.valueRect), within: 45), "a wrong value's bar is red")
        expect(!has(drawn, [235, 120, 73], in: view(name.valueRect), within: 45))
    },
])
