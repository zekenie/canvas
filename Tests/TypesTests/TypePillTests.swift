import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Foundation
import Mentions
import TestKit
import Titles
import Types

// The layout input a relationship type is drawn by (`TypeRows.pill`): provided for every shape that holds a schema and the
// mark, of a kind that says where its rows go, whatever it holds; none for a plain type, a note that is an instance, or
// a kind that draws no rows. Its size is its text measured: the name (or `Untitled`), `· N` when it has fields, the padding,
// 40 at least and 240 at most. The editing view of the name is a line that hands each change and the key that ends it.

private let twoFields = #"{"type": "object", "properties": {"since": {"type": "string"}, "primary": {"type": "boolean"}}}"#

@MainActor let relationshipTypePillTests = Suite("A relationship type's pill", [
    test("a relationship type has one, with or without a title, words or fields; a plain type and an instance have none") {
        let editor = try rowEditor()
        @MainActor func relationship(_ schema: String = TypeSchemaProperty.starter, words: String = "", title: String? = nil) -> ShapeID {
            let record = slipTypeRecord(schema, words: words, title: title)
            var marked = ShapeRecord(id: record.id, record.typed(as: RowSlip.self)!.props)
            marked[TypeSchemaProperty.self] = record[TypeSchemaProperty.self]
            marked[RelationshipProperty.self] = true
            if let title { marked[TitleProperty.self] = title }
            editor.transact { $0.insert(AnyShapeRecord(marked)) }
            return record.id
        }
        @MainActor func pill(_ id: ShapeID) -> TypePill? { editor.shapeContext.layoutInput(TypeRows.pill, for: id) }
        let bare = relationship()
        expectEqual(pill(bare)?.title, nil)
        expectEqual(pill(bare)?.fields, 0)
        let named = relationship(title: "owner")
        expectEqual(pill(named)?.title, "owner")
        let full = relationship(twoFields, words: "who owns what", title: "owner")
        expectEqual(pill(full)?.fields, 2)
        expect(try require(pill(full)).size.width > (try require(pill(named)).size.width), "`owner · 2` is wider than `owner`")
        expectEqual(pill(full)?.size.height, TypesStyle.pillHeight)
        expectEqual(editor.shapeContext.layoutInput(TypeRows.extent, for: full), nil, "none of it is rows")
        let plain = editor.addSlipType(twoFields, title: "Person")
        expectEqual(pill(plain), nil, "a plain type")
        let instance = editor.addSlip("Ann", of: [plain])
        expectEqual(pill(instance), nil, "an instance")
    },
    test("its size is its text measured: `Untitled` for none, never under 40 or over 240, the same for the same text, wider with a count") {
        let untitled = TypePills.pill(title: nil, fields: 0)
        expectEqual(untitled.size.height, TypesStyle.pillHeight)
        expect(untitled.size.width >= TypesStyle.pillMinimumWidth)
        expectEqual(TypePills.pill(title: "a", fields: 0).size.width, TypesStyle.pillMinimumWidth, "a short name has the least")
        expectEqual(TypePills.pill(title: String(repeating: "wide ", count: 60), fields: 2).size.width, TypesStyle.pillMaximumWidth)
        let one = TypePills.pill(title: "owner", fields: 0), two = TypePills.pill(title: "owner", fields: 2)
        expect(two.size.width > one.size.width)
        expectEqual(TypePills.pill(title: "owner", fields: 2), two, "kept by what it says")
        expectEqual(TypePills.pill(title: "owner", fields: 2).text, "owner")
        expectEqual(untitled.text, "Untitled")
    },
    test("it follows its own commits and, with no commit of its own, a change to a type it builds on") {
        let editor = try rowEditor()
        let parent = editor.addSlipType(#"{"type": "object", "properties": {"since": {"type": "string"}}}"#, title: "Dated")
        var record = ShapeRecord(id: ShapeID(), RowSlip(frame: CGRect(x: 40, y: 300, width: 240, height: 80), text: ""))
        record[TypeSchemaProperty.self] = SchemaText(TypeSchemaProperty.starter)
        record[RelationshipProperty.self] = true
        record[TitleProperty.self] = "owner"
        editor.transact { $0.insert(AnyShapeRecord(record)) }
        let child = record.id
        editor.addTypeLink(parent, to: child)
        @MainActor func pill() -> TypePill? { editor.shapeContext.layoutInput(TypeRows.pill, for: child) }
        expectEqual(pill()?.fields, 1)
        editor.transact("Rename") { $0.update(child) { $0[TitleProperty.self] = "owner of it" } }
        expectEqual(pill()?.title, "owner of it")
        let revision = editor.layoutRevision
        editor.transact("Field") { $0.update(parent) { $0[TypeSchemaProperty.self] = SchemaText(twoFields) } }
        expectEqual(pill()?.fields, 2)
        expect(editor.layoutRevision > revision, "laid out again")
    },
    test("the editing line hands each change and the key that ends it, from the title it is given, the caret at its end") {
        let editing = TypePillEditor(title: "own", ink: .white)
        expectEqual(editing.field.string, "own")
        expectEqual(editing.field.selectedRange(), NSRange(location: 3, length: 0))
        var typed: [String] = []
        var ended: [TypePillEditor.Ending] = []
        editing.typed = { typed.append($0) }
        editing.finished = { ended.append($0) }
        editing.field.insertText("er", replacementRange: NSRange(location: 3, length: 0))
        expectEqual(typed.last, "owner")
        editing.field.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        editing.field.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        editing.field.doCommand(by: #selector(NSResponder.insertTab(_:)))
        expectEqual(ended, [.done, .escape, .tab])
        expect(TypePillEditor(title: nil, ink: .white).field.string.isEmpty, "untitled: nothing in the line")
    },
])
