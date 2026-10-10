import Canvas
import CanvasTesting
import CoreGraphics
import TestKit
import Types

// The one writer of a shape's field values: its door (what it refuses), the step it names, the run it
// keeps, and what it stores. Callers (rows, the card, the panel) are key and mouse handlers.

private let giftNote = FieldPath(field: "giftNote"), status = FieldPath(field: "status"), price = FieldPath(field: "price")
private let lineItems = FieldPath(field: "lineItems")

@MainActor private func values(_ editor: CanvasEditor, _ id: ShapeID) -> FieldValues? { editor.document[id]?[FieldValuesProperty.self] }

@MainActor private func order(_ editor: CanvasEditor) -> ShapeID { editor.addInstance("", of: [FieldFixtures.orderID]) }

@MainActor let fieldWriterTests = Suite("The field writer", [
    test("a set value is stored in a step named for its field; undo and redo put the record back exactly") {
        let editor = try fieldEditor()
        let id = order(editor)
        let writer = try require(editor.fieldWriter)
        let before = try require(editor.document[id])
        expect(writer.set("Happy birthday", at: giftNote, of: id))
        expectEqual(values(editor, id)?["giftNote"], "Happy birthday")
        expectEqual(editor.undoHistory.undoName, "Change Gift Note")
        let after = try require(editor.document[id])
        editor.undo()
        expectEqual(editor.document[id], before)
        editor.redo()
        expectEqual(editor.document[id], after)
    },
    test("several typed writes to one field are several commits and one step") {
        let editor = try fieldEditor()
        let id = order(editor)
        let writer = try require(editor.fieldWriter)
        let start = editor.revision
        for typed in ["a", "ab", "abc"] { writer.setTyped(typed, as: .text, at: giftNote, of: id) }
        expectEqual(editor.revision, start + 3, "a commit each")
        expectEqual(values(editor, id)?["giftNote"], "abc")
        editor.undo()
        expectEqual(values(editor, id), nil, "one undo empties it")
        expect(!editor.canUndo || editor.undoHistory.undoName != "Change Gift Note")
    },
    test("a write to another field ends the run, and so does sealing the history") {
        let editor = try fieldEditor()
        let id = order(editor)
        let writer = try require(editor.fieldWriter)
        writer.set("a", at: giftNote, of: id)
        writer.set("draft", at: status, of: id)
        writer.set("ab", at: giftNote, of: id)
        var names: [String] = []
        while let name = editor.undoHistory.undoName, name.hasPrefix("Change") {
            names.append(name)
            editor.undo()
        }
        expectEqual(names, ["Change Gift Note", "Change Status", "Change Gift Note"], "three steps")
        let again = try fieldEditor()
        let other = order(again)
        let w = try require(again.fieldWriter)
        w.set("a", at: giftNote, of: other)
        again.undoHistory.seal()
        w.set("ab", at: giftNote, of: other)
        again.undo()
        expectEqual(values(again, other)?["giftNote"], "a", "two steps")
        again.undo()
        expectEqual(values(again, other), nil)
    },
    test("a write deep under one field runs with the field's own writes") {
        let editor = try fieldEditor()
        let id = order(editor)
        let writer = try require(editor.fieldWriter)
        writer.set("Mug", at: lineItems.index(0).key("product"), of: id)
        writer.set([["product": "Plate"]], at: lineItems, of: id)
        writer.setTyped("2", as: .number(integer: true), at: lineItems.index(0).key("quantity"), of: id)
        expectEqual(editor.undoHistory.undoName, "Change Line Items")
        editor.undo()
        expectEqual(values(editor, id), nil, "one step")
    },
    test("empty clears and prunes: a group's last member takes the group, an element takes the rest up, nothing left takes the property") {
        let editor = try fieldEditor()
        let id = order(editor)
        let writer = try require(editor.fieldWriter)
        let city = FieldPath(field: "shippingAddress").key("city")
        writer.set("Leeds", at: city, of: id)
        expect(writer.set(nil, at: city, of: id))
        expectEqual(values(editor, id)?["shippingAddress"], nil, "the group goes with its last member")
        expectEqual(editor.document[id]?[FieldValuesProperty.self], nil, "and the property with the last value")
        writer.set([["product": "Mug"], ["product": "Plate"]], at: lineItems, of: id)
        expect(writer.remove(at: lineItems.index(0), of: id))
        expectEqual(values(editor, id)?.value(at: lineItems.index(0).key("product")), "Plate")
        expect(writer.remove(at: lineItems.index(0), of: id))
        expectEqual(editor.document[id]?[FieldValuesProperty.self], nil)
    },
    test("a write that changes nothing is true, makes no commit and no step, and keeps what there was to redo") {
        let editor = try fieldEditor()
        let id = order(editor)
        let writer = try require(editor.fieldWriter)
        writer.set("a", at: giftNote, of: id)
        writer.set("b", at: status, of: id)
        editor.undo()
        expect(editor.canRedo)
        let before = editor.revision
        expect(writer.set(nil, at: price, of: id), "nothing there, nothing to take")
        expect(writer.set("a", at: giftNote, of: id), "the value stands")
        expectEqual(editor.revision, before)
        expect(editor.canRedo, "what there was to redo stays")
        expectEqual(editor.undoHistory.undoName, "Change Gift Note")
    },
    test("a shape that can't change is refused and heard; a shape on another board, a kind with no values and a path with no key are refused, unheard") {
        let log = RefusalLog()
        let editor = try fieldEditor(more: [FreezingPlugin(log: log), PocketsPlugin()])
        let id = order(editor)
        let writer = try require(editor.fieldWriter)
        writer.set("a", at: giftNote, of: id)
        editor.freeze([id])
        let before = editor.revision
        let undoable = editor.undoHistory.undoName
        expect(!writer.set("b", at: giftNote, of: id))
        expect(!writer.remove(at: giftNote, of: id))
        expect(!writer.rename("a", to: "b", under: FieldPath(field: "labels"), of: id))
        expect(!writer.removeUnnamed("giftNote", of: id))
        expectEqual(values(editor, id)?["giftNote"], "a")
        expectEqual(editor.revision, before)
        expectEqual(editor.undoHistory.undoName, undoable, "no empty step")
        expect(log.refusals.contains { $0.contains(id) }, "services hear it")
        log.refusals = []
        expect(!writer.set("x", at: giftNote, of: ShapeID()))
        let pocket = editor.add(Pocket(CGRect(x: 0, y: 0, width: 100, height: 100)))
        expect(!writer.set("x", at: giftNote, of: pocket), "a kind that holds no values")
        editor.freeze([id], false)
        expect(!writer.set("x", at: FieldPath(), of: id), "the root")
        expect(!writer.set("x", at: FieldPath([.index(0)]), of: id), "a path that starts with an index")
        expect(log.refusals.isEmpty)
    },
    test("a shape on a board that isn't shown is refused") {
        let pocket = ShapeID(), card = ShapeID()
        let file = CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(ShapeRecord(id: pocket, Pocket(CGRect(x: 0, y: 0, width: 100, height: 100))))]),
                              children: [pocket: CanvasDocument(shapes: [instanceRecord("", of: [], at: .zero, id: card)])])
        let editor = try typeEditor(file: file, more: [PocketsPlugin()])
        let writer = try require(editor.fieldWriter)
        expect(!writer.set("x", at: giftNote, of: card))
        expect(editor.showBoard(BoardID(owner: pocket)))
        expect(writer.set("x", at: giftNote, of: card))
        expect(editor.showBoard(.root))
        expectEqual(writer.values(of: card), FieldValues(), "not the board shown's")
        expect(!writer.set("y", at: giftNote, of: card))
    },
    test("typed text is stored as the kind reads it: 9.50 is 9.5, 02134 is text, a number below a minimum stays, empty clears") {
        let editor = try fieldEditor()
        let id = order(editor)
        let writer = try require(editor.fieldWriter)
        let quantity = lineItems.index(0).key("quantity")
        writer.setTyped("9.50", as: .number(integer: false), at: price, of: id)
        expectEqual(values(editor, id)?["price"], 9.5)
        writer.setTyped("02134", as: .number(integer: false), at: price, of: id)
        expectEqual(values(editor, id)?["price"], "02134")
        writer.setTyped("0", as: .number(integer: true), at: quantity, of: id)
        expectEqual(values(editor, id)?.value(at: quantity), 0, "below the minimum of 1, kept")
        writer.setTyped("", as: .number(integer: false), at: price, of: id)
        expectEqual(values(editor, id)?["price"], nil)
    },
    test("rename moves a pair in one commit, and is false when it can't, changing nothing") {
        let editor = try fieldEditor()
        editor.addFieldTypes([FieldFixtures.everyKind.b])
        let id = editor.addInstance("", of: [FieldFixtures.kindsBID])
        let writer = try require(editor.fieldWriter)
        let labels = FieldPath(field: "labels")
        writer.set(["size": "L", "color": "red"], at: labels, of: id)
        var before = editor.revision
        expect(writer.rename("size", to: "length", under: labels, of: id))
        expectEqual(editor.revision, before + 1, "one commit")
        expectEqual(values(editor, id)?.value(at: labels), ["length": "L", "color": "red"])
        before = editor.revision
        expect(!writer.rename("length", to: "color", under: labels, of: id), "taken")
        expect(!writer.rename("nobody", to: "x", under: labels, of: id), "absent")
        expect(!writer.rename("length", to: "", under: labels, of: id), "empty")
        expect(!writer.rename("length", to: "length", under: labels, of: id), "the same")
        expect(!writer.rename("labels", to: "tags", under: FieldPath(), of: id), "a field's own key")
        expectEqual(editor.revision, before)
    },
    test("removeUnnamed is a step named for the key, never joined to another") {
        let editor = try fieldEditor()
        let id = order(editor)
        let writer = try require(editor.fieldWriter)
        writer.set("a", at: FieldPath(field: "nickname"), of: id)
        writer.set("b", at: FieldPath(field: "pet name"), of: id)
        writer.set("c", at: giftNote, of: id)
        expect(writer.removeUnnamed("nickname", of: id))
        expectEqual(editor.undoHistory.undoName, "Remove Nickname")
        expect(writer.removeUnnamed("pet name", of: id))
        expectEqual(editor.undoHistory.undoName, "Remove Pet Name")
        expectEqual(values(editor, id)?.values.keys.sorted(), ["giftNote"])
        editor.undo()
        expectEqual(values(editor, id)?["pet name"], "b", "each its own step")
        expectEqual(values(editor, id)?["nickname"], nil)
    },
    test("a key no field names is named by the same split, and a field with a title is named by it") {
        let editor = try fieldEditor()
        let titled = editor.addType(#"{"type": "object", "properties": {"shipAddr": {"type": "string", "title": "shipping address"}}}"#, title: "Parcel")
        let id = editor.addInstance("", of: [titled])
        let writer = try require(editor.fieldWriter)
        writer.set("x", at: FieldPath(field: "shipAddr"), of: id)
        expectEqual(editor.undoHistory.undoName, "Change Shipping Address")
        writer.set("y", at: FieldPath(field: "nickname"), of: id)
        expectEqual(editor.undoHistory.undoName, "Change Nickname")
    },
    test("a card's writes join by its key, and a following own-run write ends the step") {
        let editor = try fieldEditor()
        let id = order(editor)
        let writer = try require(editor.fieldWriter)
        writer.set("a", at: giftNote, of: id, step: .card(key: 1))
        writer.set("draft", at: status, of: id, step: .card(key: 1))
        writer.set("ab", at: giftNote, of: id)
        editor.undo()
        expectEqual(values(editor, id)?["giftNote"], "a")
        expectEqual(values(editor, id)?["status"], "draft")
        editor.undo()
        expectEqual(values(editor, id), nil, "the card's two together")
    },
    test("a value written after its field left the type is a key the panel lists as no field's") {
        let editor = try fieldEditor()
        let id = order(editor)
        let writer = try require(editor.fieldWriter)
        editor.transact { $0.update(FieldFixtures.orderID) { $0[TypeSchemaProperty.self] = SchemaText(#"{"type": "object", "properties": {"status": {"type": "string"}}}"#) } }
        expect(writer.set("hello", at: giftNote, of: id))
        let resolved = try require(editor.fieldBook).fields(of: try require(editor.document[id]))
        expectEqual(writer.values(of: id).keys(unnamedBy: resolved), ["giftNote"])
        expectEqual(editor.undoHistory.undoName, "Change Gift Note")
    },
])
