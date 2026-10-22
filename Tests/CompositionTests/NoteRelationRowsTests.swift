import AppKit
import Arrows
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

// The rows a relationship type's ends give, on real notes and real arrows: a note of a type at a drawn end is as tall
// as its words, its fields, the dashed line and a row for each relationship type, whatever any arrow is; the rows are
// drawn (the dashed line, the name, `add layer` or the pills) and, zoomed out, are name bars with no value bar; and a
// click on an empty one begins the session in the row and does no more yet. The arithmetic of the layout is
// `noteLayoutTests`'; the rows' logic over slips and bonds is TypesTests'.

private struct Failure: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

private let padding: CGFloat = 16, gap: CGFloat = 12
private let yellow = [255, 222, 115, 255]

/// The room `count` rows take with words over them, and the dashed line when asked.
@MainActor private func rowsHeight(_ count: Int, rule: Bool = false) -> CGFloat {
    TypesStyle.rowsLead + CGFloat(count) * TypesStyle.rowHeight + (rule ? TypesStyle.relationRuleHeight : 0)
}

/// `count` short lines, each its own.
private func lines(_ count: Int) -> String { (1...count).map { "x\($0)" }.joined(separator: "\n") }

/// A Feature type (a `purpose`), a Layer type (an `order`, a `purpose` and a `title`) and a relationship type `in`, as real
/// notes, a Feature note and a Layer note, and real arrows for the ends and the relationships.
@MainActor
private final class Bench {
    let h: EditorHarness
    let editor: CanvasEditor
    let window: NSWindow
    let canvas: CanvasView
    let feature = ShapeID(), layer = ShapeID(), rel = ShapeID()
    var book: RowBook { editor.rowBook! }

    init(zoom: CGFloat = 1) throws {
        let registry = try Registry(plugins: notePlugins + [ArrowsPlugin(), ArrowPortsPlugin(), LanguageModelsPlugin(model: ScriptedLanguageModel())])
        h = EditorHarness { CanvasEditor(registry: registry, scheduler: $0) }
        editor = h.editor
        editor.camera.setZoom(zoom, around: .zero)
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        canvas = CanvasView(editor: editor)
        window.contentView = canvas
        editor.viewportDidResize(to: CGSize(width: 900, height: 800))
        addType(feature, #"{"type": "object", "properties": {"purpose": {"type": "string"}}}"#, "Feature", at: CGPoint(x: 40, y: 900))
        addType(layer, #"{"type": "object", "properties": {"order": {"type": "number"}, "purpose": {"type": "string"}, "title": {"type": "string"}}}"#, "Layer", at: CGPoint(x: 440, y: 900))
        var record = ShapeRecord(id: rel, StickyNote(frame: CGRect(x: 40, y: 1250, width: 200, height: 200), text: MentionText(plain: "")))
        record[TypeSchemaProperty.self] = SchemaText(TypeSchemaProperty.starter)
        record[TitleProperty.self] = "in"
        record[RelationshipProperty.self] = true
        let relationship = AnyShapeRecord(record)
        editor.transact { $0.insert(relationship) }
    }

    func addType(_ id: ShapeID, _ schema: String, _ title: String, at origin: CGPoint) {
        var note = ShapeRecord(id: id, StickyNote(frame: CGRect(origin: origin, size: CGSize(width: 200, height: 200)), text: MentionText(plain: "")))
        note[TypeSchemaProperty.self] = SchemaText(schema)
        note[TitleProperty.self] = title
        let record = AnyShapeRecord(note)
        editor.transact { $0.insert(record) }
    }

    /// A note that is each of `types`, saying `words`.
    @discardableResult
    func note(of types: [ShapeID], words: String = "", at origin: CGPoint = CGPoint(x: 40, y: 40), _ values: JSONObject = [:]) -> ShapeID {
        var note = ShapeRecord(StickyNote(frame: CGRect(origin: origin, size: CGSize(width: 200, height: 200)), text: MentionText(plain: words)))
        note[IsAProperty.self] = types.map(TypeLink.init)
        if !values.isEmpty { note[FieldValuesProperty.self] = FieldValues(values) }
        let record = AnyShapeRecord(note)
        editor.transact { $0.insert(record) }
        return record.id
    }

    /// An arrow bound at both ends, of `types`.
    @discardableResult
    func arrow(_ from: ShapeID, _ to: ShapeID, of types: [ShapeID] = []) -> ShapeID {
        func bound(_ id: ShapeID) -> ArrowTerminal {
            .bound(ArrowBinding(shapeID: id, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false, isExact: false))
        }
        var record = ShapeRecord(id: ShapeID(), Arrow(start: bound(from), end: bound(to), startArrowhead: false, endArrowhead: true))
        if !types.isEmpty { record[IsAProperty.self] = types.map(TypeLink.init) }
        let arrow = AnyShapeRecord(record)
        editor.transact { $0.insert(arrow) }
        return arrow.id
    }

    /// Both ends: an arrow from Feature into the relationship type and one out of it to Layer.
    func drawEnds() {
        arrow(feature, rel)
        arrow(rel, layer)
    }

    func laidOut(_ id: ShapeID) -> CGRect? { editor.shapeContext.frame(of: id) }

    func row(_ id: ShapeID, _ name: String) throws -> ShownRow {
        try require(book.rows(of: id).first { $0.name == name }, "a row \(name) in \(book.rows(of: id).map(\.name))")
    }

    /// Where the note draws its words.
    func words(of id: ShapeID) -> CGRect? {
        editor.document[id].flatMap { editor.registry.mentionTextPlacements(of: $0, in: editor.shapeContext).first?.box }
    }

    func draw(size: CGSize = CGSize(width: 900, height: 1400)) -> NSBitmapImageRep { renderBitmap(editor, size: size) }

    var rowsView: RowsView? { canvas.descendants(RowsView.self).first }
}

/// The darkest red channel in `rect`.
@MainActor private func darkest(_ rep: NSBitmapImageRep, in rect: CGRect) -> Int {
    var low = 255
    for y in stride(from: rect.minY.rounded(.down), to: rect.maxY.rounded(.up), by: 1) {
        for x in stride(from: rect.minX.rounded(.down), to: rect.maxX.rounded(.up), by: 1) { low = min(low, pixel(rep, at: CGPoint(x: x, y: y))[0]) }
    }
    return low
}

/// How many pixels in `rect` differ from `paper`.
@MainActor private func ink(_ rep: NSBitmapImageRep, in rect: CGRect, paper: [Int] = yellow, by tolerance: Int = 12) -> Int {
    var count = 0
    for y in stride(from: rect.minY.rounded(.down), to: rect.maxY.rounded(.up), by: 1) {
        for x in stride(from: rect.minX.rounded(.down), to: rect.maxX.rounded(.up), by: 1)
        where zip(pixel(rep, at: CGPoint(x: x, y: y)), paper).prefix(3).contains(where: { abs($0 - $1) > tolerance }) { count += 1 }
    }
    return count
}

@MainActor let noteRelationRowsTests = Suite("Relation rows on notes", [
    test("a note of a type at a drawn end is as tall as the padding, its words, the gap, its fields, the dashed line and a row each relationship type gives, and a relationship changes none of it") {
        let b = try Bench()
        let note = b.note(of: [b.feature], words: lines(10))
        let layerNote = b.note(of: [b.layer], words: lines(10), at: CGPoint(x: 600, y: 40))
        let words = try require(b.words(of: note))
        let plain = padding + words.height + gap + rowsHeight(1) + padding
        expectEqual(b.laidOut(note)?.height, plain, "with no end: its one field")
        b.arrow(b.feature, b.rel)
        b.arrow(b.rel, b.layer)
        let rows = rowsHeight(2, rule: true)
        expectEqual(b.laidOut(note)?.height, padding + words.height + gap + rows + padding, "its field, the dashed line, and the row for `in`")
        expectEqual(b.laidOut(layerNote)?.height, padding + words.height + gap + rowsHeight(4, rule: true) + padding, "Layer's three fields and its row")
        let sizes = [b.laidOut(note), b.laidOut(layerNote), b.laidOut(b.feature), b.laidOut(b.layer)]
        let relation = b.arrow(note, layerNote, of: [b.rel])
        expectEqual([b.laidOut(note), b.laidOut(layerNote), b.laidOut(b.feature), b.laidOut(b.layer)], sizes, "a relationship drawn")
        b.editor.transact("Delete") { $0.delete([relation]) }
        expectEqual([b.laidOut(note), b.laidOut(layerNote), b.laidOut(b.feature), b.laidOut(b.layer)], sizes, "and deleted")
        // The end gone: both notes are as they were.
        b.editor.undo()
        b.editor.undo()
        b.editor.undo()
        b.editor.undo()
        expectEqual(b.laidOut(note)?.height, plain)
    },
    test("a type's note lists a row for each relationship after its fields and the dashed line: the way it runs and the type at the other end") {
        let b = try Bench()
        b.drawEnds()
        let rows = b.book.rows(of: b.feature)
        expectEqual(rows.map(\.name), ["purpose", "in"])
        expectEqual(rows[1].content, .relationType(direction: "→", chips: [b.layer], more: 0))
        expectEqual(b.book.rows(of: b.layer).last?.content, .relationType(direction: "←", chips: [b.feature], more: 0))
        let block = try require(b.book.rowsRect(of: b.feature))
        expectEqual(rows[1].rect.minY, rows[0].rect.maxY + TypesStyle.relationRuleHeight, "the dashed line takes eight points")
        let drawn = b.draw()
        // Ink in the name and in the kind side, and the dashed line between the fields and the row.
        let white = [255, 255, 255, 255]
        expect(ink(drawn, in: rows[1].nameRect, paper: white) > 10, "the row's name")
        expect(ink(drawn, in: CGRect(x: rows[1].valueRect.maxX - 90, y: rows[1].rect.minY, width: 90, height: rows[1].rect.height), paper: white) > 10, "→ and the chip")
        let line = CGRect(x: block.minX, y: rows[0].rect.maxY + TypesStyle.relationRuleHeight / 2 - 1, width: block.width, height: 2)
        let dashes = ink(drawn, in: line, paper: white, by: 6)
        expect(dashes > 20 && CGFloat(dashes) < block.width * 2 * 0.9, "dashed, not solid and not missing: \(dashes) of \(block.width * 2)")
    },
    test("a note's rows are drawn: the dashed line between its fields and its relation rows, the row's name and `add layer`; the same in the dark appearance") {
        let b = try Bench()
        b.drawEnds()
        let note = b.note(of: [b.feature], words: "Sign in", ["purpose": "sign in with no password"])
        for dark in [false, true] {
            let rows = b.book.rows(of: note)
            expectEqual(rows.map(\.name), ["purpose", "in"])
            let drawn: NSBitmapImageRep
            if dark {
                let size = CGSize(width: 900, height: 1400)
                drawn = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                let cg = NSGraphicsContext(bitmapImageRep: drawn)!.cgContext
                cg.translateBy(x: 0, y: size.height)
                cg.scaleBy(x: 1, y: -1)
                NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
                    b.editor.draw(in: cg, bounds: CGRect(origin: .zero, size: size), dirtyRect: CGRect(origin: .zero, size: size))
                    NSGraphicsContext.restoreGraphicsState()
                }
            } else {
                drawn = b.draw()
            }
            let related = rows[1]
            expect(ink(drawn, in: related.nameRect) > 10, "the name of the row, dark \(dark)")
            expect(ink(drawn, in: related.valueRect) > 10, "add layer, dark \(dark)")
            let line = CGRect(x: related.rect.minX, y: related.rect.minY - TypesStyle.relationRuleHeight / 2 - 1, width: related.rect.width, height: 2)
            let dashes = ink(drawn, in: line, by: 6)
            expect(dashes > 20 && CGFloat(dashes) < line.width * 2 * 0.9, "the dashed line, dark \(dark): \(dashes)")
            // Nothing in the gap but the line.
            expectEqual(ink(drawn, in: CGRect(x: related.rect.minX, y: related.rect.minY - TypesStyle.relationRuleHeight, width: related.rect.width, height: 2), by: 6), 0, "above the line")
        }
    },
    test("zoomed out a relation row is a name bar like a field's, with no value bar, and the dashed line has no bar") {
        let b = try Bench(zoom: 0.3)
        b.drawEnds()
        let note = b.note(of: [b.feature], words: lines(3), at: CGPoint(x: 40, y: 40), ["purpose": "sign in with no password"])
        let rows = b.book.rows(of: note)
        expectEqual(rows.map(\.name), ["purpose", "in"])
        let size = CGSize(width: 400, height: 300)
        let drawn = renderBitmap(b.editor, size: size)
        let camera = b.editor.camera
        func view(_ rect: CGRect) -> CGRect { CGRect(origin: camera.toView(rect.origin), size: CGSize(width: rect.width * 0.3, height: rect.height * 0.3)) }
        let field = rows[0], related = rows[1]
        expect(ink(drawn, in: view(field.nameRect)) > 3, "a field's name bar")
        expect(ink(drawn, in: view(field.valueRect)) > 3, "and its value's")
        expect(ink(drawn, in: view(related.nameRect)) > 3, "a relation row's name bar")
        expectEqual(ink(drawn, in: view(related.valueRect)), 0, "no value bar: a skeleton reads no relations")
        let gapRect = CGRect(x: field.rect.minX, y: field.rect.maxY, width: field.rect.width, height: TypesStyle.relationRuleHeight)
        expectEqual(ink(drawn, in: view(gapRect)), 0, "the dashed line has no bar")
        // A relationship drawn makes the same picture: a skeleton reads no relations.
        let layerNote = b.note(of: [b.layer], at: CGPoint(x: 700, y: 40))
        let before = renderBitmap(b.editor, size: size)
        b.arrow(note, layerNote, of: [b.rel])
        let after = renderBitmap(b.editor, size: size)
        expectEqual(ink(after, in: view(related.valueRect)), 0)
        _ = before
    },
    test("a press on an empty relation row begins the session in the row and no more: nothing is written and no list opens; Tab walks onto it and off it") {
        let b = try Bench()
        b.drawEnds()
        let note = b.note(of: [b.feature], words: "Ann", ["purpose": "sign in"])
        let before = b.editor.document[note]
        let related = try b.row(note, "in")
        expect(b.editor.beginEditing(note, at: CGPoint(x: related.valueRect.minX + 8, y: related.rect.midY)))
        expect(b.editor.editingShapeID == note)
        expectEqual(b.rowsView?.focusedRow, "in", "the row is the focus")
        b.window.type("Foundation")
        expectEqual(b.editor.document[note], before, "typing in a row that sets nothing yet writes nothing")
        // Tab off the last row goes on to the next note (the types' notes are notes too); ⇧Tab goes back to the field.
        b.window.press("\u{19}", code: 48, modifiers: .shift)
        expectEqual(b.rowsView?.focusedRow, "purpose")
        b.window.press("\t", code: 48)
        expectEqual(b.rowsView?.focusedRow, "in", "Tab walks onto a relation row")
        b.window.press("\t", code: 48)
        expect(b.editor.editingShapeID != nil && b.editor.editingShapeID != note, "off the last row, the next note is edited")
        expectEqual(b.editor.document[note], before)
    },
])
