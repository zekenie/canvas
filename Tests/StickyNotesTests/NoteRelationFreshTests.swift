import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Connections
import Foundation
import Geometry
import LanguageModels
import Mentions
import StickyNotes
import TestKit
import Titles
import Types

// Relation rows on real notes and real arrows, against a second editor opened on the same file.

@MainActor private func freshRegistry() throws -> Registry {
    try Registry(plugins: notePlugins + [ArrowsPlugin(), ArrowPortsPlugin(), LanguageModelsPlugin(model: ScriptedLanguageModel())])
}

@MainActor private final class FreshBoard {
    let editor: CanvasEditor
    let feature = ShapeID(), layer = ShapeID(), rel = ShapeID()
    var book: RowBook { editor.rowBook! }

    init() throws {
        editor = CanvasEditor(registry: try freshRegistry(), scheduler: ManualScheduler())
        editor.viewportDidResize(to: CGSize(width: 900, height: 800))
        type(feature, #"{"type": "object", "properties": {"purpose": {"type": "string"}}}"#, "Feature", at: CGPoint(x: 40, y: 900))
        type(layer, #"{"type": "object", "properties": {"order": {"type": "number"}}}"#, "Layer", at: CGPoint(x: 440, y: 900))
        type(rel, TypeSchemaProperty.starter, "in", at: CGPoint(x: 240, y: 1300), marked: true)
        arrow(feature, rel)
        arrow(rel, layer)
    }

    func type(_ id: ShapeID, _ schema: String, _ title: String, at origin: CGPoint, marked: Bool = false, of types: [ShapeID] = []) {
        var note = ShapeRecord(id: id, StickyNote(frame: CGRect(origin: origin, size: CGSize(width: 200, height: 200)), text: MentionText(plain: "")))
        note[TypeSchemaProperty.self] = SchemaText(schema)
        note[TitleProperty.self] = title
        if marked { note[RelationshipProperty.self] = true }
        if !types.isEmpty { note[IsAProperty.self] = types.map(TypeLink.init) }
        let record = AnyShapeRecord(note)
        editor.transact { $0.insert(record) }
    }

    @discardableResult
    func note(of types: [ShapeID], words: String, at origin: CGPoint) -> ShapeID {
        var note = ShapeRecord(StickyNote(frame: CGRect(origin: origin, size: CGSize(width: 200, height: 200)), text: MentionText(plain: words)))
        note[IsAProperty.self] = types.map(TypeLink.init)
        let record = AnyShapeRecord(note)
        editor.transact { $0.insert(record) }
        return record.id
    }

    func bound(_ id: ShapeID) -> ArrowTerminal {
        .bound(ArrowBinding(shapeID: id, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false, isExact: false))
    }

    @discardableResult
    func arrow(_ from: ShapeID, _ to: ShapeID, of types: [ShapeID] = []) -> ShapeID {
        var record = ShapeRecord(id: ShapeID(), Arrow(start: bound(from), end: bound(to), startArrowhead: false, endArrowhead: true))
        if !types.isEmpty { record[IsAProperty.self] = types.map(TypeLink.init) }
        let arrow = AnyShapeRecord(record)
        editor.transact { $0.insert(arrow) }
        return arrow.id
    }

    func laidOut(_ id: ShapeID) -> CGRect? { editor.shapeContext.frame(of: id) }

    func labels(_ id: ShapeID, _ name: String) -> [String] {
        guard case .related(let pills, _)? = book.rows(of: id).first(where: { $0.name == name })?.content else { return [] }
        return pills.map(\.label)
    }

    /// A second editor opened on the same file.
    func fresh() throws -> CanvasEditor {
        let other = CanvasEditor(registry: try freshRegistry(), file: editor.file, scheduler: ManualScheduler())
        other.viewportDidResize(to: CGSize(width: 900, height: 800))
        return other
    }
}

@MainActor let noteRelationFreshTests = Suite("relation rows on real notes against a fresh read", [
    test("a relationship re-aimed at another note, its undo and redo, change no laid-out frame and move the pill") {
        let b = try FreshBoard()
        let note = b.note(of: [b.feature], words: "Sign in", at: CGPoint(x: 40, y: 40))
        let one = b.note(of: [b.layer], words: "Foundation", at: CGPoint(x: 400, y: 40)), two = b.note(of: [b.layer], words: "Presentation", at: CGPoint(x: 800, y: 40))
        let relation = b.arrow(note, one, of: [b.rel])
        let ids = [note, one, two, b.feature, b.layer, b.rel]
        let frames = ids.map { b.laidOut($0) }
        expectEqual(b.labels(note, "layer"), ["Foundation"])
        let layout = b.editor.layoutRevision
        b.editor.transact("Re-aim") { $0.update(relation, as: Arrow.self) { $0.props.end = b.bound(two) } }
        expectEqual(ids.map { b.laidOut($0) }, frames, "re-aimed")
        expectEqual(b.labels(note, "layer"), ["Presentation"])
        expectEqual(b.labels(one, "feature"), [])
        expectEqual(b.labels(two, "feature"), ["Sign in"])
        b.editor.undo()
        expectEqual(ids.map { b.laidOut($0) }, frames, "undone")
        expectEqual(b.labels(note, "layer"), ["Foundation"])
        b.editor.redo()
        expectEqual(ids.map { b.laidOut($0) }, frames, "redone")
        expectEqual(b.labels(note, "layer"), ["Presentation"])
        expectEqual(b.editor.layoutRevision, layout, "no layout announced by any of it")
    },
    test("a note counted in +N renamed to sort first: the row shows what a second editor on the same file shows") {
        let b = try FreshBoard()
        let note = b.note(of: [b.feature], words: "Sign in", at: CGPoint(x: 40, y: 40))
        var last = ShapeID()
        for index in 0..<8 {
            last = b.note(of: [b.layer], words: "Layer number \(index)", at: CGPoint(x: 400 + 240 * Double(index), y: 40))
            b.arrow(note, last, of: [b.rel])
        }
        let before = b.labels(note, "layer")
        expect(!before.contains("Layer number 7") && !before.isEmpty, "the last is counted, not shown: \(before)")
        b.editor.transact("Rename") { $0.update(last, as: StickyNote.self) { $0.props.text = MentionText(plain: "Aardvark") } }
        let other = try b.fresh()
        guard case .related(let pills, _)? = other.rowBook?.rows(of: note).first(where: { $0.name == "layer" })?.content else {
            expect(false, "the second editor shows pills")
            return
        }
        expectEqual(b.labels(note, "layer"), pills.map(\.label))
    },
    test("a type that builds on an end type deleted: its notes' rows and frames are what a second editor on the same file gives") {
        let b = try FreshBoard()
        let task = ShapeID()
        b.type(task, #"{"type": "object", "properties": {"due": {"type": "string"}}}"#, "Task", at: CGPoint(x: 840, y: 900), of: [b.feature])
        let note = b.note(of: [task], words: "Ship it", at: CGPoint(x: 40, y: 40))
        expectEqual(b.book.rows(of: note).map(\.name), ["purpose", "due", "layer"])
        b.editor.transact("Delete") { $0.delete([task]) }
        let other = try b.fresh()
        expectEqual(b.book.rows(of: note).map(\.name), other.rowBook?.rows(of: note).map(\.name) ?? ["?"], "rows")
        expectEqual(b.laidOut(note), other.shapeContext.frame(of: note), "frame")
    },
    test("a relationship between two real notes draws a pill in the row of each, and a rename of one draws the other's with the new name") {
        let b = try FreshBoard()
        let note = b.note(of: [b.feature], words: "Sign in", at: CGPoint(x: 40, y: 40))
        let layer = b.note(of: [b.layer], words: "Foundation", at: CGPoint(x: 400, y: 40))
        let size = CGSize(width: 900, height: 800)
        let area = CGRect(origin: .zero, size: size)
        let empty = renderBitmap(b.editor, size: size)
        b.arrow(note, layer, of: [b.rel])
        expectEqual(b.labels(note, "layer"), ["Foundation"])
        expectEqual(b.labels(layer, "feature"), ["Sign in"])
        #if DEBUG
        let before = MentionDrawingCounts.pillsDrawnStraight
        #endif
        let drawn = renderBitmap(b.editor, size: size)
        #if DEBUG
        expect(MentionDrawingCounts.pillsDrawnStraight - before >= 2, "a pill in each row")
        #endif
        expect(largestDifference(empty, drawn, in: area) > 0, "the empty rows are not the pills")
        b.editor.transact("Rename") { $0.update(layer, as: StickyNote.self) { $0.props.text = MentionText(plain: "A much longer name for the foundation") } }
        expectEqual(b.labels(note, "layer"), ["A much longer name for the foundation"])
        expect(largestDifference(drawn, renderBitmap(b.editor, size: size), in: area) > 0, "drawn again with the new name")
    },
])
