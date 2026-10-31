import AppKit
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CoreGraphics
import Foundation
import TestKit
import Titles
import Types
import Validation

// A row's first value in the issue walk's list (`IssueRowValuesPlugin`, Validation's `IssueRowValues` point): the first text
// Find would find on a note of a type or an arrow of a relationship type, none for a shape with no values.

private let voteSchema = #"{"type": "object", "properties": {"position": {"type": "string", "enum": ["Yea", "Nay"]}, "note": {"type": "string"}}}"#

/// The type plugins with slips, bonds and the point's plugin, after Validation, its owner.
@MainActor
private struct Bench {
    let editor: CanvasEditor
    let person: ShapeID, member: ShapeID, bill: ShapeID, vote: ShapeID
    let ann: ShapeID, law: ShapeID, nay: ShapeID
    let pocket = ShapeID()

    init() throws {
        editor = CanvasEditor(registry: try Registry(plugins: typePlugins() + [RowSlipsPlugin(), BondsPlugin(), RelaysPlugin(), PocketsPlugin(), IssueRowValuesPlugin()]),
                              scheduler: ManualScheduler())
        editor.viewportDidResize(to: CGSize(width: 1200, height: 900))
        let types = editor.addFieldSlips([FieldFixtures.person])
        person = types[0]
        member = editor.addSlipType(TypeSchemaProperty.starter, title: "Member", at: CGPoint(x: 40, y: 300))
        bill = editor.addSlipType(TypeSchemaProperty.starter, title: "Bill", at: CGPoint(x: 440, y: 300))
        let relationship = editor.addRelationshipType("Vote", at: CGPoint(x: 240, y: 300))
        vote = relationship
        editor.transact { $0.update(relationship) { $0[TypeSchemaProperty.self] = SchemaText(voteSchema) } }
        editor.addBond(member, vote, name: "votes")
        editor.addBond(vote, bill, name: "on")
        ann = editor.addSlip("Ann", of: [person], at: CGPoint(x: 40, y: 700))
        law = editor.addSlip("Law", of: [bill], at: CGPoint(x: 440, y: 900))
        let jerry = editor.addSlip("Jerry", of: [member], at: CGPoint(x: 40, y: 900))
        nay = editor.addBond(jerry, law, of: [vote])
        editor.transact { $0.insert(AnyShapeRecord(ShapeRecord(id: pocket, Pocket(CGRect(x: 800, y: 300, width: 100, height: 100))))) }
    }

    func set(_ id: ShapeID, _ values: JSONObject) {
        editor.transact { $0.update(id) { $0[FieldValuesProperty.self] = FieldValues(values) } }
    }

    /// What the list would end the shape's row in.
    func value(of id: ShapeID) throws -> String? {
        editor.registry.issueRowValue(of: try require(editor.shape(inFile: id), "the shape"), in: editor)
    }
}

private let namedSchema = #"{"type": "object", "properties": {"name": {"type": "string"}, "email": {"type": "string"}, "age": {"type": "number"}, "$title": {"x-canvas-from": "name"}}}"#

@MainActor let issueRowValuesTests = Suite("The issue list's first value", [
    test("a note of a type ends its row in the first of its values, in the order of its fields") {
        let b = try Bench()
        b.set(b.ann, ["name": "Ann Lee", "email": "ann@acme.com"])
        expectEqual(try b.value(of: b.ann), "Ann Lee")
        // The first field that holds a value, as its row shows it, not the first field of the type.
        b.set(b.ann, ["email": "ann@acme.com"])
        expectEqual(try b.value(of: b.ann), "ann@acme.com")
    },
    test("an arrow of a relationship type ends its row in the first value its card says: a Vote reads Nay") {
        let b = try Bench()
        b.set(b.nay, ["position": "Nay", "note": "Against the rule"])
        expectEqual(try b.value(of: b.nay), "Nay")
        b.set(b.nay, ["note": "Against the rule"])
        expectEqual(try b.value(of: b.nay), "Against the rule")
    },
    test("a shape with no values gives none: a note or an arrow of a type with nothing filled in, a plain note, a type") {
        let b = try Bench()
        expectEqual(try b.value(of: b.ann), nil)
        expectEqual(try b.value(of: b.nay), nil)
        b.set(b.nay, [:])
        expectEqual(try b.value(of: b.nay), nil)
        expectEqual(try b.value(of: b.law), nil)
        // A type's own note holds its schema, not values.
        expectEqual(try b.value(of: b.person), nil)
        let plain = b.editor.addSlip("Plain", at: CGPoint(x: 800, y: 700))
        expectEqual(try b.value(of: plain), nil)
    },
    test("a value that is the shape's own title is left out for the next field's: a type whose title comes from its first field") {
        let b = try Bench()
        let named = b.editor.addSlipType(namedSchema, title: "Named", at: CGPoint(x: 800, y: 40))
        let ann = b.editor.addSlip("", of: [named], at: CGPoint(x: 800, y: 700))
        @MainActor func hold(title: String?, _ values: JSONObject) {
            b.editor.transact { $0.update(ann) { $0[TitleProperty.self] = title; $0[FieldValuesProperty.self] = FieldValues(values) } }
        }
        hold(title: "Ann Lee", ["name": "Ann Lee", "email": "ann@acme.com"])
        expectEqual(try b.value(of: ann), "ann@acme.com", "the name is the title: the next field")
        hold(title: "Ann Lee", ["name": "Ann  Lee"])
        expectEqual(try b.value(of: ann), nil, "folded as titles are, and nothing is left")
        hold(title: nil, ["name": "Ann Lee", "email": "ann@acme.com"])
        expectEqual(try b.value(of: ann), "Ann Lee", "a note with no title keeps its first value")
        hold(title: "Annie", ["name": "Ann Lee", "email": "ann@acme.com"])
        expectEqual(try b.value(of: ann), "Ann Lee", "a title that is not a copy is not skipped")
    },
    test("a text with nothing in it is no row's value, with a title or without: the next field's is shown") {
        let b = try Bench()
        let named = b.editor.addSlipType(namedSchema, title: "Named", at: CGPoint(x: 800, y: 40))
        let ann = b.editor.addSlip("", of: [named], at: CGPoint(x: 800, y: 700))
        @MainActor func hold(title: String?, _ values: JSONObject) {
            b.editor.transact { $0.update(ann) { $0[TitleProperty.self] = title; $0[FieldValuesProperty.self] = FieldValues(values) } }
        }
        hold(title: "Annie", ["name": "   ", "email": "ann@acme.com"])
        expectEqual(try b.value(of: ann), "ann@acme.com", "a title typed by hand, a first field of spaces")
        hold(title: nil, ["name": "   ", "email": "ann@acme.com"])
        expectEqual(try b.value(of: ann), "ann@acme.com", "and with no title")
        hold(title: "Annie", ["name": "   "])
        expectEqual(try b.value(of: ann), nil, "nothing else to show")
    },
    test("a number is a first value as its row shows it, ahead of the text after it") {
        let b = try Bench()
        let counted = b.editor.addSlipType(#"{"type": "object", "properties": {"age": {"type": "number"}, "email": {"type": "string"}}}"#, title: "Counted", at: CGPoint(x: 800, y: 40))
        let note = b.editor.addSlip("", of: [counted], at: CGPoint(x: 800, y: 700))
        b.set(note, ["age": 42, "email": "ann@acme.com"])
        expectEqual(try b.value(of: note), "42")
        b.set(note, ["age": 9.5])
        expectEqual(try b.value(of: note), "9.5")
    },
    test("a typed note on a board that is not shown reads the same, and a relationship arrow's first value is its first filled field") {
        let b = try Bench()
        b.set(b.ann, ["name": "Ann Lee"])
        b.editor.transact("Move In") { $0.move([b.ann], toBoardOwnedBy: b.pocket) }
        expectEqual(b.editor.file.board(containing: b.ann), BoardID(owner: b.pocket))
        expectEqual(b.editor.board, .root, "the pocket's board is not shown")
        expectEqual(try b.value(of: b.ann), "Ann Lee")
        b.set(b.nay, ["position": "Yea"])
        expectEqual(try b.value(of: b.nay), "Yea")
    },
    test("the value follows an edit, and an undo") {
        let b = try Bench()
        b.set(b.ann, ["name": "Ann"])
        expectEqual(try b.value(of: b.ann), "Ann")
        b.set(b.ann, ["name": "Anne"])
        expectEqual(try b.value(of: b.ann), "Anne")
        b.editor.undo()
        expectEqual(try b.value(of: b.ann), "Ann")
    },
    test("the report names the point and its scope: the shapes that hold fieldValues") {
        let b = try Bench()
        let line = try require(b.editor.registry.report.split(separator: "\n").first { $0.hasPrefix("issue-row-values") }, "the plugin's line")
        expect(line.contains("IssueRowValues → every shape holding fieldValues"), "\(line)")
    },
])
