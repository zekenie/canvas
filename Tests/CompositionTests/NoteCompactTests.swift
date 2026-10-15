import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import Foundation
import Geometry
import Mentions
import Selection
import StickyNotes
import TestKit
import Titles
import Types

// A relationship type that holds no words and no fields is drawn small (`TypeRows.isCompact`, Types': the second
// layout input beside the rows' extent): `NoteStyle.compactSize` from the top-left it stores, worked out and never
// stored. A word, a field, or the mark taken off makes it full again from the same top-left; nothing is written when
// it grows or shrinks beyond the text; and everything that asks how much room it takes follows the small paper.

/// `NoteStyle.compactSize`: 160 by 34.
private let small = CGSize(width: 160, height: 34)
private let stored = CGRect(x: 40, y: 60, width: 200, height: 200)
private let white = [255, 255, 255, 255]

@MainActor private func makeEditor(zoom: CGFloat = 1) throws -> CanvasEditor {
    let registry = try Registry(plugins: notePlugins + [ArrowsPlugin(), ArrowPortsPlugin()])
    let editor = CanvasEditor(registry: registry, scheduler: ManualScheduler())
    editor.camera.setZoom(zoom, around: .zero)
    editor.viewportDidResize(to: CGSize(width: 600, height: 500))
    return editor
}

extension CanvasEditor {
    /// A type note at `frame`: marked as a relationship type if asked, with `schema`.
    @MainActor fileprivate func addTypeNote(marked: Bool = true, schema: String = TypeSchemaProperty.starter, words: String = "",
                                            at frame: CGRect = stored) -> ShapeID {
        var note = ShapeRecord(StickyNote(frame: frame, text: MentionText(plain: words)))
        note[TypeSchemaProperty.self] = SchemaText(schema)
        if marked { note[RelationshipProperty.self] = true }
        let record = AnyShapeRecord(note)
        transact { $0.insert(record) }
        return record.id
    }

    @MainActor fileprivate func laid(_ id: ShapeID) -> CGRect? { shapeContext.frame(of: id) }
    @MainActor fileprivate func box(_ id: ShapeID) -> CGRect? { document[id]?.box }
}

@MainActor let noteCompactTests = Suite("A relationship type drawn small", [
    test("a relationship type with no words and no fields is the compact paper from its stored top-left; the stored box and every other type are as they were") {
        let editor = try makeEditor()
        let rel = editor.addTypeNote()
        let plain = editor.addTypeNote(marked: false, at: CGRect(x: 400, y: 60, width: 200, height: 200))
        let note = editor.add(StickyNote(frame: CGRect(x: 800, y: 60, width: 200, height: 200), text: ""))
        expectEqual(editor.laid(rel), CGRect(origin: stored.origin, size: small))
        expectEqual(editor.box(rel), stored, "what is stored is the note with no layout")
        expectEqual(editor.shapeContext.geometry(of: rel)?.bounds, CGRect(origin: stored.origin, size: small), "its geometry is the small paper")
        expectEqual(editor.laid(plain)?.size, CGSize(width: 200, height: 200), "a plain empty type stays full size")
        expectEqual(editor.laid(note)?.size, CGSize(width: 200, height: 200), "and so does a note")
        expectEqual(editor.shapeContext.layoutInput(TypeRows.isCompact, for: rel), true)
        expectEqual(editor.shapeContext.layoutInput(TypeRows.isCompact, for: plain), nil)
    },
    test("a word, a field, or the mark taken off makes it full from the same top-left, and writes nothing but that; undo makes it small again, byte for byte") {
        let editor = try makeEditor()
        let rel = editor.addTypeNote()
        let empty = editor.document
        editor.transact("Words") { $0.update(rel) { $0 = $0.typed(as: StickyNote.self).map { var n = $0; n.props.text = MentionText(plain: "A job"); return AnyShapeRecord(n) } ?? $0 } }
        expectEqual(editor.laid(rel)?.origin, stored.origin)
        expectEqual(editor.laid(rel)?.size, stored.size, "a word: full, its stored size")
        editor.undo()
        expectEqual(editor.document, empty, "undone exactly")
        expectEqual(editor.laid(rel)?.size, small, "and small again")
        let field = #"{"type": "object", "properties": {"role": {"type": "string"}}}"#
        editor.transact("Field") { $0.update(rel) { $0[TypeSchemaProperty.self] = SchemaText(field) } }
        expect(try require(editor.laid(rel)).height > small.height, "a field: its rows")
        expectEqual(editor.laid(rel)?.origin, stored.origin)
        editor.undo()
        expectEqual(editor.laid(rel)?.size, small)
        editor.makePlainTypes([rel])
        expectEqual(editor.laid(rel)?.size, stored.size, "the mark off: a plain type")
        expectEqual(editor.document[rel]?[RelationshipProperty.self], nil)
        editor.undo()
        expectEqual(editor.document, empty)
        expectEqual(editor.laid(rel)?.size, small)
        editor.makeRelationshipTypes([editor.addTypeNote(marked: false, at: CGRect(x: 400, y: 60, width: 200, height: 200))])
        let later = try require(editor.document.shapes.last).id
        expectEqual(editor.laid(later)?.size, small, "marked later: small at once")
    },
    test("read mid-transaction as it will be: a relationship type inserted in a transaction, and one given words in it, is sized as the commit will size it") {
        let editor = try makeEditor()
        var record = ShapeRecord(StickyNote(frame: stored, text: ""))
        record[TypeSchemaProperty.self] = SchemaText(TypeSchemaProperty.starter)
        record[RelationshipProperty.self] = true
        let made = AnyShapeRecord(record)
        var inside: [CGSize?] = []
        editor.transact("Make") {
            $0.insert(made)
            inside.append($0.shapes.frame(of: made.id)?.size)
            $0.update(made.id) { var note = $0.typed(as: StickyNote.self)!; note.props.text = MentionText(plain: "words"); $0 = AnyShapeRecord(note) }
            inside.append($0.shapes.frame(of: made.id)?.size)
        }
        expectEqual(inside.first ?? nil, small, "small as it is inserted")
        expect((inside.last ?? nil).map { $0.height >= stored.height } == true, "and full once it has words: \(inside)")
        expect(try require(editor.laid(made.id)).height >= stored.height, "as committed")
    },
    test("the paper is drawn at the small size and nothing below it; zoomed out its skeleton is the same box; the outline and the pill follow it") {
        let editor = try makeEditor()
        let rel = editor.addTypeNote()
        let rep = renderBitmap(editor, size: CGSize(width: 600, height: 500))
        expectEqual(pixel(rep, at: CGPoint(x: stored.minX + 80, y: stored.minY + 17)), white, "inside the small paper")
        let below = pixel(rep, at: CGPoint(x: stored.minX + 80, y: stored.minY + 100))
        expect(below != white, "and where the stored box would be, the canvas: \(below)")
        let outline = try require(editor.shapeContext.geometry(of: rel)).outline
        expect(outline.allSatisfy { $0.y <= stored.minY + small.height + 0.01 }, "the outline is the small paper's: \(outline)")
        let far = try makeEditor(zoom: 0.2)
        let farRel = far.addTypeNote()
        expectEqual(far.drawsSkeletons, true)
        expectEqual(far.laid(farRel)?.size, small, "a skeleton asks no provider: the kept frame, small")
        let skeleton = renderBitmap(far, size: CGSize(width: 600, height: 500))
        let middle = CGPoint(x: (stored.minX + 80) * 0.2, y: (stored.minY + 17) * 0.2)
        expect(pixel(skeleton, at: middle) != pixel(skeleton, at: CGPoint(x: 590, y: 490)), "the skeleton's paper")
        // The pill, above the top-left of what is laid out.
        let pill = try require(editor.titlePillRect(of: rel))
        expect(pill.maxY <= stored.minY, "the pill is above the small paper's top: \(pill)")
    },
    test("an arrow bound to it ends at the small paper, not at the box it stores; Zoom to Fit and the extent follow") {
        let editor = try makeEditor()
        let rel = editor.addTypeNote()
        let other = editor.add(StickyNote(frame: CGRect(x: 40, y: 400, width: 200, height: 100), text: ""))
        func bound(_ id: ShapeID) -> ArrowTerminal { .bound(ArrowBinding(shapeID: id, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false, isExact: false)) }
        let arrow = AnyShapeRecord(ShapeRecord(Arrow(start: bound(other), end: bound(rel), startArrowhead: false, endArrowhead: true)))
        editor.transact { $0.insert(arrow) }
        let end = try require(editor.arrowGeometry(of: arrow.id)).endHandle
        expect(abs(end.y - (stored.minY + small.height)) < 24, "the head stops by the small paper's bottom, not 200 down: \(end)")
        let bounds = try require(editor.shapeBounds)
        expectEqual(bounds.minY, stored.minY)
        expect(bounds.maxY < 520, "the board's extent is the laid-out frame and the other note: \(bounds)")
        let lone = try makeEditor()
        _ = lone.addTypeNote()
        expectEqual(lone.shapeBounds, CGRect(origin: stored.origin, size: small))
    },
    test("edited, a compact note's view is laid over the box it stores so the caret has a line; the first keystroke makes the paper full") {
        let editor = try makeEditor()
        let rel = editor.addTypeNote()
        editor.selection = rel
        expect(editor.beginEditing(rel))
        expectEqual(editor.editingFrame, stored, "over the stored box")
        let view = try require(editor.makeEditingView())
        let textView = try require(view.firstResponder as? NSTextView)
        textView.insertText("a", replacementRange: NSRange(location: 0, length: 0))
        expectEqual(editor.laid(rel)?.size, stored.size, "the paper is full from the first keystroke")
        expectEqual(editor.editingFrame, stored, "and the view is over it")
        editor.endEditing()
        expectEqual(editor.document[rel]?.typed(as: StickyNote.self)?.props.text.stored, "a")
    },
    test("hit testing and the area query follow the small paper, and the stored box again once it grows with a word and the small paper once it is undone") {
        let registry = try Registry(plugins: notePlugins + [ArrowsPlugin(), ArrowPortsPlugin()])
        let editor = CanvasEditor(registry: registry, scheduler: ManualScheduler())
        editor.viewportDidResize(to: CGSize(width: 600, height: 500))
        var note = ShapeRecord(StickyNote(frame: CGRect(x: 40, y: 60, width: 200, height: 200), text: ""))
        note[TypeSchemaProperty.self] = SchemaText(TypeSchemaProperty.starter)
        note[RelationshipProperty.self] = true
        let record = AnyShapeRecord(note)
        editor.transact { $0.insert(record) }
        let inside = CGPoint(x: 100, y: 75), outside = CGPoint(x: 100, y: 200)
        expect(editor.shapeContext.hitTest(inside, shape: record.id), "inside the small paper")
        expect(!editor.shapeContext.hitTest(outside, shape: record.id), "below the small paper, in the stored box")
        expectEqual(editor.shape(at: outside), nil, "nothing there")
        expectEqual(editor.shape(at: inside), record.id)
        // grows with a word
        editor.transact("Words") { $0.update(record.id) { var n = $0.typed(as: StickyNote.self)!; n.props.text = MentionText(plain: "A job"); $0 = AnyShapeRecord(n) } }
        expect(editor.shapeContext.hitTest(outside, shape: record.id), "full: the stored box is hit")
        editor.undo()
        expect(!editor.shapeContext.hitTest(outside, shape: record.id), "small again")
        // the spatial query by area (marquee)
        let paint = editor.paintOrder(in: CGRect(x: 90, y: 150, width: 20, height: 20)).map(\.id)
        expect(!paint.contains(record.id), "an area only the stored box reaches does not find it")
    },
])
