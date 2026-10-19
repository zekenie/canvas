import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Foundation
import Keyboard
import Mentions
import TestKit
import Titles
import Types

// What a shape's rows are made of and the room they take (`RowBook`): the extent a kind lays itself out
// with, the templates kept for each list of types, and what a type's change announces. Slips show rows;
// the memo, which says nowhere its rows go, shows none.

/// The room `count` rows take with words over them and without.
@MainActor private func rowsHeight(_ count: Int, hasWords: Bool = true) -> CGFloat {
    (hasWords ? TypesStyle.rowsLead : 0) + CGFloat(count) * TypesStyle.rowHeight
}

@MainActor private func extent(_ editor: CanvasEditor, _ id: ShapeID) throws -> RowsExtent? {
    try require(editor.rowBook).extent(of: try require(editor.document[id]))
}

/// A service ahead of Types that asks for a shape's frame as it hears each commit: the trap of a layout kept
/// against what Types has not yet heard.
@MainActor
private final class FrameProbe: EditorService {
    var watching: ShapeID?
    var frames: [CGRect?] = []
    func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) {
        if let watching { frames.append(editor.frame(inFile: watching)) }
    }
}

private struct FrameProbePlugin: CanvasPlugin {
    let probe: FrameProbe
    var id: PluginID { "frame-probe" }
    func register(into registrar: inout PluginRegistrar) {
        let probe = probe
        registrar.service { _ in probe }
    }
}

/// Person, an Employee that is a Person and a slip that is an Employee, in a root with a pocket holding a slip
/// that is a Person: so a type's change reaches the board shown and another.
@MainActor
private struct Reach {
    let editor: CanvasEditor
    let person = ShapeID(), employee = ShapeID(), instance = ShapeID(), pocket = ShapeID(), away = ShapeID()

    init() throws {
        let file = CanvasFile(root: CanvasDocument(shapes: [
            slipTypeRecord(wideSchema(2), words: "A person", title: "Person", at: .zero, id: person),
            slipTypeRecord(#"{"type":"object","properties":{"role":{"type":"string"}}}"#, words: "An employee", title: "Employee", at: CGPoint(x: 400, y: 0), id: employee),
            slipRecord("Ann", of: [employee], at: CGPoint(x: 800, y: 0), id: instance),
            AnyShapeRecord(ShapeRecord(id: pocket, Pocket(CGRect(x: 0, y: 600, width: 100, height: 100)))),
        ]), children: [pocket: CanvasDocument(shapes: [slipRecord("Bo", of: [person], at: .zero, id: away)])])
        editor = try rowEditor(file: file, more: [PocketsPlugin()])
        editor.addTypeLink(person, to: employee)
    }
}

@MainActor let rowBookTests = Suite("Rows kept", [
    test("a type of three fields has an extent of 320 and three rows' height, with the lead only when it has words") {
        let editor = try rowEditor()
        let withWords = editor.addSlipType(wideSchema(3), words: "Three fields", title: "A")
        let without = editor.addSlipType(wideSchema(3), title: "B")
        expectEqual(try extent(editor, withWords), RowsExtent(minimumWidth: 320, height: rowsHeight(3)))
        expectEqual(try extent(editor, without), RowsExtent(minimumWidth: 320, height: rowsHeight(3, hasWords: false)))
        expectEqual(editor.laidOut(withWords)?.width, 320, "laid out as wide as the rows read at")
        expectEqual(editor.laidOut(withWords)?.height, (editor.document[withWords]?.box?.height ?? 0) + rowsHeight(3))
    },
    test("a plain slip, an instance whose types are gone and an instance of a fieldless type have none") {
        let editor = try rowEditor()
        let fieldless = editor.addSlipType(TypeSchemaProperty.starter, words: "Nothing yet", title: "Empty")
        let plain = editor.addSlip("Plain")
        let ofFieldless = editor.addSlip("Of nothing", of: [fieldless])
        let gone = editor.addSlip("Of a type gone", of: [ShapeID()])
        for id in [plain, ofFieldless, gone] {
            expectEqual(try extent(editor, id), nil)
            expectEqual(editor.laidOut(id), editor.document[id]?.box, "as big as it stores")
        }
    },
    test("ten thousand asks for instances of one list build one template, and a schema edit builds it once more") {
        let editor = try rowEditor()
        let type = editor.addSlipType(wideSchema(4), words: "Four", title: "Four")
        let instances = (0..<10).map { editor.addSlip("Of four \($0)", of: [type], at: CGPoint(x: 400 * Double($0), y: 400)) }
        let book = try require(editor.rowBook)
        #if DEBUG
        let made = book.templatesMade
        #endif
        let records = try instances.map { try require(editor.document[$0]) }
        for ask in 0..<10_000 { expectEqual(book.extent(of: records[ask % 10])?.height, rowsHeight(4), "ask \(ask)") }
        #if DEBUG
        expectEqual(book.templatesMade - made, 1)
        #endif
        editor.transact { $0.update(type) { $0[TypeSchemaProperty.self] = SchemaText(wideSchema(5)) } }
        #if DEBUG
        let edited = book.templatesMade
        #endif
        for record in records { expectEqual(book.extent(of: record)?.height, rowsHeight(5)) }
        #if DEBUG
        expect(book.templatesMade - edited <= 1, "made again once, for all ten (the type's own may have been made by the commit)")
        #endif
    },
    test("a type's change announces the type and its instances, near and far: each is a row taller, on the board shown and another, with no step") {
        let r = try Reach()
        let editor = r.editor
        let book = try require(editor.rowBook)
        let people = [r.person, r.employee, r.instance]
        let before = people.map { editor.laidOut($0)?.height ?? 0 }
        let beforeAway = try require(editor.frame(inFile: r.away)).height
        expectEqual(book.rows(of: r.person).count, 2)
        // The pocket's board is entered once, so what it holds is laid out where the editor keeps it.
        expect(editor.showBoard(BoardID(owner: r.pocket)))
        expect(editor.showBoard(.root))
        let step = editor.undoHistory.undoName, revision = editor.revision, layout = editor.layoutRevision
        editor.transact("Add Field") { $0.update(r.person) { $0[TypeSchemaProperty.self] = SchemaText(wideSchema(3)) } }
        let after = people.map { editor.laidOut($0)?.height ?? 0 }
        for (b, a) in zip(before, after) { expectEqual(a, b + TypesStyle.rowHeight) }
        expectEqual(try require(editor.frame(inFile: r.away)).height, beforeAway + TypesStyle.rowHeight, "on another board")
        expectEqual(editor.undoHistory.undoName, "Add Field")
        expectEqual(editor.revision, revision + 1, "one commit, the type's")
        expect(editor.layoutRevision > layout, "and the layout moved")
        _ = step
        editor.undo()
        expectEqual(people.map { editor.laidOut($0)?.height ?? 0 }, before, "undone with the type")
        expectEqual(try require(editor.frame(inFile: r.away)).height, beforeAway)
    },
    test("a service ahead of Types that asks for an instance's frame as it hears the commit that adds a field still sees the right frame at the next read") {
        let probe = FrameProbe()
        let registry = try Registry(plugins: [FrameProbePlugin(probe: probe)] + typePlugins() + [RowSlipsPlugin()])
        let editor = CanvasEditor(registry: registry, file: CanvasFile(root: CanvasDocument()), scheduler: ManualScheduler())
        let type = editor.addSlipType(wideSchema(2), words: "Two", title: "Two")
        let instance = editor.addSlip("Ann", of: [type])
        let two = try require(editor.laidOut(instance)).height
        probe.watching = instance
        editor.transact { $0.update(type) { $0[TypeSchemaProperty.self] = SchemaText(wideSchema(3)) } }
        expect(!probe.frames.isEmpty, "the probe asked as it heard the commit")
        expectEqual(editor.laidOut(instance)?.height, two + TypesStyle.rowHeight, "the next read is the new frame")
        expectEqual(editor.frame(inFile: instance)?.height, two + TypesStyle.rowHeight)
    },
    test("a type and its instance inserted in one transaction: the instance has its rows before the commit") {
        let editor = try rowEditor()
        let type = slipTypeRecord(wideSchema(3), words: "Three", title: "Three")
        let instance = slipRecord("Ann", of: [type.id])
        var inside: CGRect?
        editor.transact { transaction in
            transaction.insert(type)
            transaction.insert(instance)
            inside = transaction.shapes.frame(of: instance.id)
        }
        let stored = try require(editor.document[instance.id]?.box)
        expectEqual(inside?.size, CGSize(width: 320, height: stored.height + rowsHeight(3)), "laid out in the transaction")
        expectEqual(editor.laidOut(instance.id), inside, "as it is after the commit")
    },
    test("a rename announces no layout and redraws; a row that folds under `from Person` reads `from Human` after, and no other template is built again") {
        let editor = try rowEditor()
        let person = editor.addSlipType(wideSchema(4), words: "Four", title: "Person")
        let employee = editor.addSlipType(#"{"type":"object","properties":{"e1":{"type":"string"},"e2":{"type":"string"},"e3":{"type":"string"},"e4":{"type":"string"},"e5":{"type":"string"},"e6":{"type":"string"}}}"#,
                                          words: "Six", title: "Employee", at: CGPoint(x: 400, y: 0))
        editor.addTypeLink(person, to: employee)
        let book = try require(editor.rowBook)
        _ = editor.laidOut(employee)
        expectEqual(book.rows(of: employee).first?.name, "from Person")
        expectEqual(book.rows(of: person).count, 4)
        let layout = editor.layoutRevision
        #if DEBUG
        let made = book.templatesMade
        #endif
        editor.transact("Rename") { $0.update(person) { $0[TitleProperty.self] = "Human" } }
        expectEqual(editor.layoutRevision, layout, "a rename moves no size")
        expectEqual(book.rows(of: employee).first?.name, "from Human")
        expectEqual(book.rows(of: person).count, 4)
        #if DEBUG
        expectEqual(book.templatesMade - made, 1, "only the template that says a name is made again")
        #endif
    },
    test("a type deleted: its instances have no extent; undo brings it back") {
        let editor = try rowEditor()
        let type = editor.addSlipType(wideSchema(3), words: "Three", title: "Three")
        let instance = editor.addSlip("Ann", of: [type])
        expectEqual(try extent(editor, instance)?.height, rowsHeight(3))
        let stored = editor.document[instance]?.box
        editor.transact("Delete") { $0.delete([type]) }
        expectEqual(try extent(editor, instance), nil)
        expectEqual(editor.laidOut(instance), stored, "its stored size again")
        editor.undo()
        expectEqual(try extent(editor, instance)?.height, rowsHeight(3))
        expectEqual(editor.laidOut(instance)?.width, 320)
    },
    test("broken JSON mid-edit keeps the rows of the last good JSON; text never an object has none; an instance inserted while its type's JSON is broken is laid out with those rows in the transaction, as after it") {
        let editor = try rowEditor()
        let type = editor.addSlipType(wideSchema(3), words: "Three", title: "Three")
        let instance = editor.addSlip("Ann", of: [type])
        editor.transact { $0.update(type) { $0[TypeSchemaProperty.self] = SchemaText(#"{"type": "object", "properties": {"a": "#) } }
        expectEqual(try extent(editor, instance)?.height, rowsHeight(3), "the last good JSON's rows")
        expectEqual(try extent(editor, type)?.height, rowsHeight(3))
        let pasted = slipRecord("Bo", of: [type], at: CGPoint(x: 400, y: 400))
        var inside: CGRect?
        editor.transact { transaction in
            transaction.insert(pasted)
            inside = transaction.shapes.frame(of: pasted.id)
        }
        let stored = try require(editor.document[pasted.id]?.box)
        expectEqual(inside?.height, stored.height + rowsHeight(3), "in the transaction")
        expectEqual(editor.laidOut(pasted.id)?.height, stored.height + rowsHeight(3), "and after it")
        let never = editor.addSlipType("not json at all", words: "Never an object", title: "Never")
        let ofNever = editor.addSlip("Cy", of: [never])
        expectEqual(try extent(editor, ofNever), nil)
    },
    test("a file put in place drops everything kept") {
        let editor = try rowEditor()
        let type = editor.addSlipType(wideSchema(3), words: "Three", title: "Three")
        let instance = editor.addSlip("Ann", of: [type])
        expectEqual(try extent(editor, instance)?.height, rowsHeight(3))
        let other = slipTypeRecord(wideSchema(5), words: "Five", title: "Three", at: .zero, id: type)
        let note = slipRecord("Ann", of: [type], id: instance)
        editor.replaceFile(with: CanvasFile(root: CanvasDocument(shapes: [other, note])))
        expectEqual(try extent(editor, instance)?.height, rowsHeight(5), "another file's type")
        expectEqual(editor.laidOut(instance)?.height, (editor.document[instance]?.box?.height ?? 0) + rowsHeight(5))
    },
    test("a kind that did not say where its rows go is given no extent: the memo") {
        let editor = try rowEditor()
        let type = editor.addType(wideSchema(3), words: "Three", title: "Three")
        let instance = editor.addInstance("Ann", of: [type])
        expectEqual(try extent(editor, type), nil)
        expectEqual(try extent(editor, instance), nil)
        expectEqual(editor.shapeContext.frame(of: instance), editor.document[instance]?.box)
    },
    test("the service is made with the others and reaches the index and the sync as it is made: a type change in the very first commit is announced") {
        let editor = try rowEditor()
        expect(editor.rowBook != nil)
        let layout = editor.layoutRevision
        let type = editor.addSlipType(wideSchema(3), words: "Three", title: "Three")
        expect(editor.layoutRevision > layout, "announced before anything asked for a row")
        _ = type
        let bare = CanvasEditor(registry: try Registry(plugins: [KeyboardPlugin()]), scheduler: ManualScheduler())
        expect(bare.rowBook == nil, "none without Types")
    },
])
