import Adornments
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

// A relationship type is a pill (`TypeRows.pill`, Types'), not a note: Types says what it is (its name, its field count and
// the size the text measures), and the note lays itself out at that size about the middle of the frame it stores, so a longer
// name grows both ways and what is drawn through it stays put. Nothing is stored for it. It is drawn as a capsule in its type's
// color with its name (and `· 2`), zoomed out as a capsule with no letters; its outline is the capsule; no pill and no chip
// shows above it; its name is edited in place (the title, never the words), in the editing session's one step.

private let stored = CGRect(x: 40, y: 60, width: 200, height: 200)
private let paper = [255, 255, 255, 255]

@MainActor private func makeEditor(zoom: CGFloat = 1) throws -> CanvasEditor {
    let registry = try Registry(plugins: notePlugins + [ArrowsPlugin(), ArrowPortsPlugin()])
    let editor = CanvasEditor(registry: registry, scheduler: ManualScheduler())
    editor.camera.setZoom(zoom, around: .zero)
    editor.viewportDidResize(to: CGSize(width: 600, height: 500))
    return editor
}

extension CanvasEditor {
    /// A type note at `frame`: marked as a relationship type if asked, with `schema`.
    @MainActor func addTypeNote(marked: Bool = true, schema: String = TypeSchemaProperty.starter, words: String = "", title: String? = nil,
                                at frame: CGRect = stored, id: ShapeID = ShapeID()) -> ShapeID {
        var note = ShapeRecord(id: id, StickyNote(frame: frame, text: MentionText(plain: words)))
        note[TypeSchemaProperty.self] = SchemaText(schema)
        if marked { note[RelationshipProperty.self] = true }
        if let title { note[TitleProperty.self] = title }
        let record = AnyShapeRecord(note)
        transact { $0.insert(record) }
        return record.id
    }

    @MainActor fileprivate func laid(_ id: ShapeID) -> CGRect? { shapeContext.frame(of: id) }
    @MainActor fileprivate func box(_ id: ShapeID) -> CGRect? { document[id]?.box }
    @MainActor fileprivate func pill(_ id: ShapeID) -> TypePill? { shapeContext.layoutInput(TypeRows.pill, for: id) }
}

private let fieldsSchema = #"{"type": "object", "properties": {"since": {"type": "string"}, "primary": {"type": "boolean"}}}"#

/// `color` as the 0...255 RGB a bitmap holds it in (the light appearance, as `renderBitmap` draws).
@MainActor private func rgb(_ color: NSColor) -> [Int] {
    var out = [0, 0, 0]
    NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
        let c = color.usingColorSpace(.deviceRGB) ?? color
        out = [Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded())]
    }
    return out
}

private func close(_ a: [Int], _ b: [Int], within tolerance: Int = 3) -> Bool {
    zip(a.prefix(3), b.prefix(3)).allSatisfy { abs($0 - $1) <= tolerance }
}

@MainActor let notePillTests = Suite("A relationship type drawn as a pill", [
    test("every relationship type is a pill, with or without words or fields, centered on the middle of the frame it stores; the stored box and every other type are as they were") {
        let editor = try makeEditor()
        let rel = editor.addTypeNote()
        let plain = editor.addTypeNote(marked: false, at: CGRect(x: 400, y: 60, width: 200, height: 200))
        let note = editor.add(StickyNote(frame: CGRect(x: 800, y: 60, width: 200, height: 200), text: ""))
        let pill = try require(editor.pill(rel))
        expectEqual(pill.title, nil)
        expectEqual(pill.fields, 0)
        expectEqual(pill.size.height, TypesStyle.pillHeight)
        expect(pill.size.width >= TypesStyle.pillMinimumWidth && pill.size.width < 120, "the width of `Untitled`: \(pill.size)")
        expectEqual(editor.laid(rel)?.size, pill.size)
        expectEqual(editor.laid(rel)?.midX, stored.midX, "about the middle of the box it stores")
        expectEqual(editor.laid(rel)?.midY, stored.midY)
        expectEqual(editor.box(rel), stored, "what is stored is the note with no layout")
        expectEqual(editor.shapeContext.geometry(of: rel)?.bounds, editor.laid(rel), "its geometry is the capsule's frame")
        expectEqual(editor.laid(plain)?.size, CGSize(width: 200, height: 200), "a plain empty type stays full size")
        expectEqual(editor.laid(note)?.size, CGSize(width: 200, height: 200), "and so does a note")
        expectEqual(editor.pill(plain), nil)
        expectEqual(editor.pill(note), nil)
        expectEqual(editor.shapeContext.layoutInput(TypeRows.extent, for: rel), nil, "a pill has no rows")
        // Words and fields are kept and not drawn: the pill is a pill all the same.
        let full = editor.addTypeNote(schema: fieldsSchema, words: "who owns what, since when", title: "owner", at: CGRect(x: 40, y: 300, width: 200, height: 200))
        expectEqual(editor.pill(full)?.title, "owner")
        expectEqual(editor.pill(full)?.fields, 2)
        expectEqual(editor.shapeContext.layoutInput(TypeRows.extent, for: full), nil)
        expectEqual(editor.laid(full)?.height, TypesStyle.pillHeight)
        expect(editor.shapeContext.layoutInput(TypeRows.pill, for: full)?.size.width ?? 0 > pill.size.width, "`owner · 2` is wider than `Untitled`")
    },
    test("a name or a field makes the pill again from the same middle, a longer name growing both ways, and writes nothing but that; undo is byte for byte; the mark taken off is a plain type") {
        let editor = try makeEditor()
        let rel = editor.addTypeNote()
        let empty = editor.document
        let bare = try require(editor.laid(rel))
        editor.transact("Name") { $0.update(rel) { $0[TitleProperty.self] = "owner of the vehicle" } }
        let named = try require(editor.laid(rel))
        expect(named.width > bare.width, "wider: \(named) against \(bare)")
        expectEqual(named.midX, stored.midX, "it grew both ways")
        expectEqual(named.midY, stored.midY)
        expect(named.minX < bare.minX && named.maxX > bare.maxX)
        editor.undo()
        expectEqual(editor.document, empty, "undone exactly")
        expectEqual(editor.laid(rel), bare)
        editor.transact("Field") { $0.update(rel) { $0[TypeSchemaProperty.self] = SchemaText(fieldsSchema) } }
        expectEqual(editor.pill(rel)?.fields, 2, "a field added through the schema")
        expect(try require(editor.laid(rel)).width > bare.width, "` · 2` after the name")
        expectEqual(editor.laid(rel)?.midX, stored.midX)
        editor.undo()
        expectEqual(editor.laid(rel), bare)
        editor.makePlainTypes([rel])
        expectEqual(editor.laid(rel)?.size, stored.size, "the mark off: a plain type, full, from its box")
        expectEqual(editor.laid(rel)?.origin, stored.origin)
        expectEqual(editor.pill(rel), nil)
        editor.undo()
        expectEqual(editor.document, empty)
        expectEqual(editor.laid(rel), bare)
        editor.makeRelationshipTypes([editor.addTypeNote(marked: false, at: CGRect(x: 400, y: 60, width: 200, height: 200))])
        let later = try require(editor.document.shapes.last).id
        expectEqual(editor.laid(later)?.size, bare.size, "marked later: a pill at once")
    },
    test("a name over 240 points stops there; fields a type builds on give the count, and the pill follows when that type gains one, with no commit of its own") {
        let editor = try makeEditor()
        let rel = editor.addTypeNote(title: String(repeating: "a long name ", count: 12))
        expectEqual(editor.laid(rel)?.width, TypesStyle.pillMaximumWidth, "at most 240")
        let parent = editor.addTypeNote(marked: false, schema: #"{"type": "object", "properties": {"since": {"type": "string"}}}"#, title: "Dated",
                                        at: CGRect(x: 400, y: 60, width: 200, height: 200))
        let child = editor.addTypeNote(title: "owner", at: CGRect(x: 400, y: 400, width: 200, height: 200))
        editor.addTypeLink(parent, to: child)
        expectEqual(editor.pill(child)?.fields, 1, "the field it builds on")
        let before = try require(editor.laid(child)).width
        editor.transact("Field") { $0.update(parent) { $0[TypeSchemaProperty.self] = SchemaText(fieldsSchema) } }
        expectEqual(editor.pill(child)?.fields, 2)
        expectEqual(editor.pill(child)?.size, editor.laid(child)?.size, "laid out again, though only its parent changed")
        expect(try require(editor.laid(child)).width >= before)
    },
    test("read mid-transaction as it will be: a relationship type inserted in a transaction, with a title and fields, is sized as the commit will size it") {
        let editor = try makeEditor()
        var record = ShapeRecord(StickyNote(frame: stored, text: ""))
        record[TypeSchemaProperty.self] = SchemaText(fieldsSchema)
        record[RelationshipProperty.self] = true
        record[TitleProperty.self] = "owner"
        let made = AnyShapeRecord(record)
        var inside: [CGSize?] = []
        editor.transact("Make") {
            $0.insert(made)
            inside.append($0.shapes.frame(of: made.id)?.size)
        }
        let committed = try require(editor.laid(made.id)).size
        expectEqual(inside.first ?? nil, committed, "the same size before the commit and after")
        expectEqual(editor.pill(made.id)?.fields, 2)
        expectEqual(committed.height, TypesStyle.pillHeight)
    },
    test("it is drawn as a capsule in its type's color and nothing else: no paper where the box it stores would be; zoomed out the same capsule with no letters, whatever it is called") {
        let editor = try makeEditor()
        let rel = editor.addTypeNote(title: "owner")
        let color = rgb(try require(editor.types).look(of: rel).row)
        let frame = try require(editor.laid(rel))
        let rep = renderBitmap(editor, size: CGSize(width: 600, height: 500))
        expect(close(pixel(rep, at: CGPoint(x: frame.minX + 4, y: frame.midY)), color), "the capsule, in its type's color: \(pixel(rep, at: CGPoint(x: frame.minX + 4, y: frame.midY))) for \(color)")
        expect(!close(pixel(rep, at: CGPoint(x: frame.minX + 1, y: frame.minY + 1)), color), "its corner is round")
        let inStoredBox = pixel(rep, at: CGPoint(x: stored.minX + 10, y: stored.maxY - 10))
        expect(inStoredBox != paper && !close(inStoredBox, color), "no paper where the stored box would be: \(inStoredBox)")
        // The name is on it: some pixel of the capsule is not its color.
        var inked = false
        for x in Int(frame.minX) + 14..<Int(frame.maxX) - 14 where !close(pixel(rep, at: CGPoint(x: CGFloat(x), y: frame.midY)), color, within: 40) { inked = true }
        expect(inked, "its name is drawn in the ink the color gives it")
        // Zoomed out.
        let same = ShapeID()      // a type's color is its id's: one id, one color
        @MainActor func skeleton(_ title: String) throws -> NSBitmapImageRep {
            let far = try makeEditor(zoom: 0.2)
            _ = far.addTypeNote(title: title, id: same)
            expectEqual(far.drawsSkeletons, true)
            return renderBitmap(far, size: CGSize(width: 600, height: 500))
        }
        let far = try makeEditor(zoom: 0.2)
        let farRel = far.addTypeNote(title: "owner")
        let farColor = rgb(try require(far.types).look(of: farRel).row)
        let laid = try require(far.laid(farRel))
        let picture = renderBitmap(far, size: CGSize(width: 600, height: 500))
        let middle = CGPoint(x: laid.midX * 0.2, y: laid.midY * 0.2)
        expect(close(pixel(picture, at: middle), farColor), "the skeleton is the capsule in its color: \(pixel(picture, at: middle)) for \(farColor)")
        // Two names that are both the least width have one picture: no letters.
        expectEqual(largestDifference(try skeleton("a"), try skeleton("b"), in: CGRect(x: 0, y: 0, width: 600, height: 500)), 0, "a skeleton shows no letter: two short names, one picture")
    },
    test("the outline is the capsule, not the paper's corners; hit testing and the area query follow the capsule, not the box it stores") {
        let editor = try makeEditor()
        let rel = editor.addTypeNote(title: "owner")
        let frame = try require(editor.laid(rel))
        let path = try require(editor.registry.indicatorPath(of: try require(editor.document[rel]), in: editor.shapeContext))
        expect(path.contains(CGPoint(x: frame.midX, y: frame.midY)))
        expect(!path.contains(CGPoint(x: frame.minX + 1, y: frame.minY + 1)), "a round end: the corner is outside")
        expect(editor.shapeContext.hitTest(CGPoint(x: frame.midX, y: frame.midY), shape: rel), "the capsule is hit")
        expect(!editor.shapeContext.hitTest(CGPoint(x: stored.midX, y: stored.maxY - 10), shape: rel), "the stored box is not")
        expectEqual(editor.shape(at: CGPoint(x: stored.midX, y: stored.maxY - 10)), nil)
        expectEqual(editor.shape(at: CGPoint(x: frame.midX, y: frame.midY)), rel)
        let paint = editor.paintOrder(in: CGRect(x: 90, y: 250, width: 20, height: 5)).map(\.id)
        expect(!paint.contains(rel), "an area only the stored box reaches does not find it")
    },
    test("no title pill and no chip shows above it, titled or not, and no resize handles; it is selected as any note is") {
        let editor = try makeEditor()
        let titled = editor.addTypeNote(title: "owner")
        let untitled = editor.addTypeNote(at: CGRect(x: 400, y: 60, width: 200, height: 200))
        for id in [titled, untitled] {
            expectEqual(editor.titlePillRect(of: id), nil, "no pill above it")
            expectEqual(editor.adornmentFrames(of: id).count, 0, "and no chip")
        }
        editor.selection = titled
        expect(editor.handle(atViewPoint: try require(editor.laid(titled)).origin) == nil, "no handle")
        let plain = editor.addTypeNote(marked: false, title: "Person", at: CGRect(x: 40, y: 300, width: 200, height: 200))
        expect(editor.titlePillRect(of: plain) != nil, "a plain type keeps its pill")
    },
    test("an arrow bound to it ends at the capsule, not at the box it stores; the extent follows") {
        let editor = try makeEditor()
        let rel = editor.addTypeNote()
        let other = editor.add(StickyNote(frame: CGRect(x: 40, y: 400, width: 200, height: 100), text: ""))
        func bound(_ id: ShapeID) -> ArrowTerminal { .bound(ArrowBinding(shapeID: id, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false, isExact: false)) }
        let arrow = AnyShapeRecord(ShapeRecord(Arrow(start: bound(other), end: bound(rel), startArrowhead: false, endArrowhead: true)))
        editor.transact { $0.insert(arrow) }
        let frame = try require(editor.laid(rel))
        let end = try require(editor.arrowGeometry(of: arrow.id)).endHandle
        expect(abs(end.y - frame.maxY) < 24, "the head stops by the capsule's bottom, not 100 down: \(end)")
        let lone = try makeEditor()
        let alone = lone.addTypeNote()
        expectEqual(lone.shapeBounds, lone.laid(alone))
    },
])

@MainActor let notePillEditingTests = Suite("Naming a relationship type in its pill", [
    test("edited, its view is one line of the title over the capsule; each keystroke writes the title, folded, in one step named for the name; the capsule follows and the view with it") {
        let editor = try makeEditor()
        let rel = editor.addTypeNote()
        editor.undoHistory.seal()
        let start = editor.document
        let bare = try require(editor.laid(rel))
        editor.selection = rel
        expect(editor.beginEditing(rel))
        expectEqual(editor.editingFrame, bare, "over the capsule")
        let view = try require(editor.makeEditingView())
        let pillEditor = try require(view.view as? TypePillEditor)
        expect(view.firstResponder === pillEditor.field, "the caret is in the line")
        for letter in ["o", "w", "n"] { pillEditor.field.insertText(letter, replacementRange: NSRange(location: pillEditor.field.string.utf16.count, length: 0)) }
        expectEqual(editor.document[rel]?[TitleProperty.self], "own")
        expect(editor.document[rel]?.typed(as: StickyNote.self)?.props.text.stored == "", "never the words")
        expectEqual(editor.editingFrame, editor.laid(rel), "the view follows the capsule")
        expectEqual(editor.editingFrame?.midX, bare.midX, "growing both ways")
        pillEditor.field.insertText("  er ", replacementRange: NSRange(location: pillEditor.field.string.utf16.count, length: 0))
        expectEqual(editor.document[rel]?[TitleProperty.self], "own er", "folded as every title is")
        pillEditor.field.insertText("", replacementRange: NSRange(location: 0, length: pillEditor.field.string.utf16.count))
        expectEqual(editor.document[rel]?[TitleProperty.self], nil, "a blank is none")
        pillEditor.field.insertText("owner", replacementRange: NSRange(location: 0, length: 0))
        editor.endEditing()
        expectEqual(editor.undoHistory.undoName, TypesStyle.nameRelationshipType, "one step, named for what it is")
        editor.undo()
        expectEqual(editor.document, start, "one Undo takes the whole name")
        expect(editor.undoHistory.undoName != TypesStyle.nameRelationshipType, "and no more of it")
        editor.redo()
        expectEqual(editor.document[rel]?[TitleProperty.self], "owner")
    },
    test("Return, Escape and Tab end editing keeping what was typed; Escape on nothing typed leaves it untitled; Tab also asks for the card that defines the type, after editing has ended") {
        for (name, selector) in [("Return", #selector(NSResponder.insertNewline(_:))), ("Escape", #selector(NSResponder.cancelOperation(_:))),
                                 ("Tab", #selector(NSResponder.insertTab(_:))), ("Shift-Tab", #selector(NSResponder.insertBacktab(_:)))] {
            let editor = try makeEditor()
            let rel = editor.addTypeNote()
            let hooks = try require(editor.service(RelationshipHooks.self))
            var asked: [(ShapeID, Bool)] = []
            hooks.openDefinition = { id in asked.append((id, editor.editingShapeID == nil)); return true }
            editor.selection = rel
            editor.beginEditing(rel)
            let pillEditor = try require(editor.makeEditingView()?.view as? TypePillEditor)
            pillEditor.field.insertText("in", replacementRange: NSRange(location: 0, length: 0))
            pillEditor.field.doCommand(by: selector)
            expectEqual(editor.editingShapeID, nil, "\(name) ends editing")
            expectEqual(editor.document[rel]?[TitleProperty.self], "in", "\(name) keeps the name")
            let isTab = name.hasSuffix("Tab")
            expectEqual(asked.count, isTab ? 1 : 0, "\(name): the definition card is asked for by Tab alone")
            if isTab {
                expectEqual(asked.first?.0, rel)
                expectEqual(asked.first?.1, true, "once editing has ended")
            }
        }
        let editor = try makeEditor()
        let rel = editor.addTypeNote()
        editor.selection = rel
        editor.beginEditing(rel)
        let pillEditor = try require(editor.makeEditingView()?.view as? TypePillEditor)
        pillEditor.field.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        expectEqual(editor.document[rel]?[TitleProperty.self], nil, "untitled")
        expect(editor.document[rel] != nil, "and kept")
        expect(editor.undoHistory.undoName != TypesStyle.nameRelationshipType, "nothing typed, no step of naming")
    },
    test("nothing here wakes the model: a name typed in the pill is the title, so the words stay empty and nothing is asked") {
        let editor = try makeEditor()
        let rel = editor.addTypeNote()
        editor.selection = rel
        editor.beginEditing(rel)
        let pillEditor = try require(editor.makeEditingView()?.view as? TypePillEditor)
        pillEditor.field.insertText("owner", replacementRange: NSRange(location: 0, length: 0))
        editor.endEditing()
        expectEqual(editor.document[rel]?.typed(as: StickyNote.self)?.props.text.stored, "")
        expectEqual(editor.typeSync?.status(of: rel), .idle)
    },
    test("rendered while it is edited, the capsule shows and the name is the view's, never drawn twice") {
        let editor = try makeEditor()
        let rel = editor.addTypeNote(title: "owner")
        editor.selection = rel
        editor.beginEditing(rel)
        let view = try require(editor.makeEditingView())
        let color = rgb(try require(editor.types).look(of: rel).row)
        let frame = try require(editor.laid(rel))
        let rep = renderBitmap(editor, size: CGSize(width: 600, height: 500), editing: view)
        expect(close(pixel(rep, at: CGPoint(x: frame.minX + 4, y: frame.midY)), color), "the capsule")
        editor.endEditing()
    },
    test("a double-click on the pill begins editing its name, caret at the end; the step is named Name Relationship Type; a press elsewhere ends it keeping the name; one Undo takes the name") {
        let h = try EditorHarness(plugins: notePlugins + [ArrowsPlugin(), ArrowPortsPlugin()])
        let editor = h.editor
        editor.viewportDidResize(to: CGSize(width: 600, height: 500))
        let rel = editor.addTypeNote(title: "own")
        editor.selection = nil
        editor.undoHistory.seal()
        let start = editor.document
        let frame = try require(editor.laid(rel))
        h.click(at: h.view(CGPoint(x: frame.midX, y: frame.midY)), clickCount: 2)
        expectEqual(editor.editingShapeID, rel, "a double-click on the pill edits it")
        let pillEditor = try require(editor.makeEditingView()?.view as? TypePillEditor)
        expectEqual(pillEditor.field.string, "own")
        pillEditor.field.insertText("er", replacementRange: NSRange(location: 3, length: 0))
        expectEqual(editor.document[rel]?[TitleProperty.self], "owner")
        h.click(at: h.view(CGPoint(x: 500, y: 450)))
        expectEqual(editor.editingShapeID, nil, "a press elsewhere ends it")
        expectEqual(editor.document[rel]?[TitleProperty.self], "owner", "keeping the name")
        expectEqual(editor.undoHistory.undoName, TypesStyle.nameRelationshipType)
        editor.undo()
        expectEqual(editor.document, start)
    },
    test("the shape deleted while its name is edited ends editing and Undo brings it back as it was typed; the host's save point splits the step, and what is typed after it is a step of its own") {
        let editor = try makeEditor()
        let rel = editor.addTypeNote()
        editor.selection = rel
        editor.undoHistory.seal()
        let start = editor.document
        editor.beginEditing(rel)
        let first = try require(editor.makeEditingView()?.view as? TypePillEditor)
        first.field.insertText("in", replacementRange: NSRange(location: 0, length: 0))
        editor.transact("Delete") { $0.delete([rel]) }
        expectEqual(editor.editingShapeID, nil, "editing ends with the shape")
        editor.undo()
        expect(editor.document[rel] != nil, "back")
        expectEqual(editor.document[rel]?[TitleProperty.self], "in")
        editor.undo()
        expectEqual(editor.document, start, "two Undos")
        // The save point.
        editor.selection = rel
        editor.beginEditing(rel)
        let second = try require(editor.makeEditingView()?.view as? TypePillEditor)
        second.field.insertText("i", replacementRange: NSRange(location: 0, length: 0))
        editor.undoHistory.breakStep()
        second.field.insertText("n", replacementRange: NSRange(location: 1, length: 0))
        editor.endEditing()
        expectEqual(editor.document[rel]?[TitleProperty.self], "in")
        editor.undo()
        expectEqual(editor.document[rel]?[TitleProperty.self], "i", "the keystroke after the save point is a step of its own")
        editor.undo()
        expectEqual(editor.document, start)
    },
])

@MainActor let notePillCardTests = Suite("The card under a relationship type's pill", [
    test("a click on the pill opens the card that defines it, selected, under the pill; a second click closes it; a drag moves the pill and opens nothing") {
        let h = try EditorHarness(plugins: notePlugins + [ArrowsPlugin(), ArrowPortsPlugin()])
        let editor = h.editor
        editor.viewportDidResize(to: CGSize(width: 600, height: 500))
        let rel = editor.addTypeNote(title: "owner")
        editor.selection = nil
        let frame = try require(editor.laid(rel))
        let centre = h.view(CGPoint(x: frame.midX, y: frame.midY))
        h.click(at: centre)
        expectEqual(editor.card?.shape, rel)
        expectEqual(editor.card?.anchor, frame)
        expectEqual(editor.selectedShapeIDs, [rel])
        expectEqual(editor.definitionCards?.openType, rel)
        h.click(at: centre)
        expect(editor.card == nil, "a click on the open card's pill closes it")
        h.press(at: centre)
        h.drag(to: CGPoint(x: centre.x + 60, y: centre.y + 40), speed: 0.5)
        h.release()
        expect(editor.card == nil, "a drag is a move")
        expect(try require(editor.box(rel)).minX > stored.minX, "it moved")
    },
    test("a double-click edits the name and takes the card down; Tab in the name opens the card at add field") {
        let h = try EditorHarness(plugins: notePlugins + [ArrowsPlugin(), ArrowPortsPlugin()])
        let editor = h.editor
        editor.viewportDidResize(to: CGSize(width: 600, height: 500))
        let rel = editor.addTypeNote(title: "own")
        editor.selection = nil
        let frame = try require(editor.laid(rel))
        let centre = h.view(CGPoint(x: frame.midX, y: frame.midY))
        h.click(at: centre, clickCount: 1)
        h.click(at: centre, clickCount: 2)
        expectEqual(editor.editingShapeID, rel)
        expect(editor.card == nil, "editing takes the card down")
        let pillEditor = try require(editor.makeEditingView()?.view as? TypePillEditor)
        pillEditor.field.doCommand(by: #selector(NSResponder.insertTab(_:)))
        expectEqual(editor.editingShapeID, nil)
        expectEqual(editor.definitionCards?.openType, rel)
        expectEqual(editor.definitionCards?.openView?.focus, .addField)
    },
])
