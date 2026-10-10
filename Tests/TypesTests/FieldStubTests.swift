import Canvas
import CanvasTesting
import CoreGraphics
import TestKit
import Types

// The services other tracks fill, as K0 leaves them: the writer is a plain transaction named for the field,
// the check says clean, the card does not open. What each answers now is what the track that fills it keeps.

private let email = FieldPath(field: "email"), name = FieldPath(field: "name")

@MainActor private func values(_ editor: CanvasEditor, _ id: ShapeID) -> FieldValues? { editor.document[id]?[FieldValuesProperty.self] }

@MainActor private func ann(_ editor: CanvasEditor) -> ShapeID { editor.addInstance("Ann", of: [FieldFixtures.personID]) }

@MainActor let fieldStubTests = Suite("Field services (stubs)", [
    test("the writer writes at a path, and names the step for the field") {
        let editor = try fieldEditor()
        let id = ann(editor)
        let writer = try require(editor.fieldWriter)
        expect(writer.setTyped("ann@acme.com", as: .text, at: email, of: id))
        expectEqual(values(editor, id)?["email"], "ann@acme.com")
        expectEqual(writer.values(of: id).value(at: email), "ann@acme.com")
        expectEqual(editor.undoHistory.undoName, "Change Email")
        let items = FieldPath(field: "lineItems").index(0).key("product")
        let order = editor.addInstance("", of: [FieldFixtures.orderID])
        expect(writer.set("Mug", at: items, of: order))
        expectEqual(values(editor, order)?.value(at: items), "Mug", "at any depth")
        expectEqual(editor.undoHistory.undoName, "Change Line Items", "the top-level field names the step")
        expect(writer.set("x", at: FieldPath(field: "shippingAddress").key("city"), of: order))
        expectEqual(editor.undoHistory.undoName, "Change Shipping Address")
        expect(writer.set("x", at: FieldPath(field: "nickname"), of: order))
        expectEqual(editor.undoHistory.undoName, "Change Nickname", "a key no field names")
    },
    test("several writes to one field are one step; two fields are two") {
        let editor = try fieldEditor()
        let id = ann(editor)
        let writer = try require(editor.fieldWriter)
        for typed in ["a", "an", "ann", "ann@"] { writer.setTyped(typed, as: .text, at: email, of: id) }
        expectEqual(values(editor, id)?["email"], "ann@")
        editor.undo()
        expectEqual(values(editor, id), nil, "one undo takes the whole run")
        editor.redo()
        writer.setTyped("Ann", as: .text, at: name, of: id)
        expectEqual(editor.undoHistory.undoName, "Change Name")
        editor.undo()
        expectEqual(values(editor, id)?["email"], "ann@", "the other field's step stays")
        expectEqual(values(editor, id)?["name"], nil)
        editor.undo()
        expectEqual(values(editor, id), nil)
    },
    test("a write that changes nothing makes no step and answers true; emptying removes the value, and the property with it") {
        let editor = try fieldEditor()
        let id = ann(editor)
        let writer = try require(editor.fieldWriter)
        let before = editor.revision
        expect(writer.set(nil, at: email, of: id), "nothing there, nothing to take")
        expect(writer.setTyped("", as: .text, at: email, of: id))
        expectEqual(editor.revision, before, "no commit")
        writer.setTyped("x", as: .text, at: email, of: id)
        let written = editor.revision
        expect(writer.setTyped("x", as: .text, at: email, of: id), "the same value again")
        expectEqual(editor.revision, written)
        expect(writer.setTyped("", as: .text, at: email, of: id))
        expectEqual(values(editor, id), nil, "empty is not kept")
        expectEqual(editor.document[id]?[FieldValuesProperty.self], nil)
    },
    test("remove takes an element out, the rest shifting up, or a member; rename moves a pair's value in one commit and refuses a taken name") {
        let editor = try fieldEditor()
        editor.addFieldTypes([FieldFixtures.everyKind.a, FieldFixtures.everyKind.b])
        let id = editor.addInstance("", of: [FieldFixtures.kindsAID, FieldFixtures.kindsBID])
        let writer = try require(editor.fieldWriter)
        let tags = FieldPath(field: "tags"), labels = FieldPath(field: "labels")
        writer.set(["a", "b", "c"], at: tags, of: id)
        expect(writer.remove(at: tags.index(0), of: id))
        expectEqual(values(editor, id)?.value(at: tags), ["b", "c"])
        expect(writer.remove(at: tags, of: id))
        expectEqual(values(editor, id)?.value(at: tags), nil)
        writer.set(["size": "L", "color": "red"], at: labels, of: id)
        let before = editor.revision
        expect(writer.rename("size", to: "length", under: labels, of: id))
        expectEqual(editor.revision, before + 1, "one commit")
        expectEqual(values(editor, id)?.value(at: labels), ["length": "L", "color": "red"])
        expect(!writer.rename("length", to: "color", under: labels, of: id), "taken")
        expect(!writer.rename("nobody", to: "x", under: labels, of: id), "no such pair")
        expect(writer.rename("length", to: "length", under: labels, of: id), "the same name changes nothing")
        expectEqual(values(editor, id)?.value(at: labels), ["length": "L", "color": "red"])
    },
    test("a value no field names is removed in a step of its own, named for it, never joined to another") {
        let editor = try fieldEditor()
        let id = ann(editor)
        let writer = try require(editor.fieldWriter)
        writer.set("x", at: FieldPath(field: "nick"), of: id)
        writer.set("y", at: FieldPath(field: "nick2"), of: id)
        expect(writer.removeUnnamed("nick", of: id))
        expectEqual(editor.undoHistory.undoName, "Remove Nick")
        expect(writer.removeUnnamed("nick2", of: id))
        expectEqual(values(editor, id), nil)
        editor.undo()
        expectEqual(values(editor, id)?["nick2"], "y", "each its own step")
        expectEqual(values(editor, id)?["nick"], nil)
    },
    test("a card's writes are the card's: joined by its key, one step") {
        let editor = try fieldEditor()
        let id = ann(editor)
        let writer = try require(editor.fieldWriter)
        writer.setTyped("a", as: .text, at: email, of: id, step: .card(key: "card"))
        writer.setTyped("ab", as: .text, at: email, of: id, step: .card(key: "card"))
        writer.setTyped("Ann", as: .text, at: name, of: id, step: .card(key: "card"))
        editor.undo()
        expectEqual(values(editor, id), nil, "all three")
    },
    test("a shape that can't change is refused (false, shaken, nothing written); so is a shape not on the board and a path with no key") {
        let log = RefusalLog()
        let editor = try fieldEditor(more: [FreezingPlugin(log: log)])
        let id = ann(editor)
        let writer = try require(editor.fieldWriter)
        writer.set("a@b.c", at: email, of: id)
        editor.freeze([id])
        let before = editor.revision
        expect(!writer.set("x@y.z", at: email, of: id))
        expect(!writer.set("x", at: name, of: id))
        expect(!writer.remove(at: email, of: id))
        expect(!writer.removeUnnamed("email", of: id))
        expectEqual(values(editor, id)?["email"], "a@b.c")
        expectEqual(editor.revision, before)
        expect(log.refusals.contains { $0.contains(id) }, "the core shakes it")
        expect(!writer.set("x", at: email, of: ShapeID()), "a shape that is not there")
        expect(!writer.set("x", at: FieldPath(), of: id), "the root has no key")
        expect(!writer.set("x", at: FieldPath([.index(0)]), of: id), "a path that starts with an index")
        expectEqual(writer.values(of: ShapeID()), FieldValues())
    },
    test("a shape of a kind that can't hold values is refused") {
        let editor = try typeEditor(more: [PocketsPlugin()])
        let pocket = editor.add(Pocket(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let before = editor.revision
        expect(!(try require(editor.fieldWriter)).set("x", at: email, of: pocket))
        expectEqual(editor.revision, before)
    },
    test("the check says clean, and keeps what is being typed in, redrawing") {
        let editor = try fieldEditor()
        let id = ann(editor)
        let checks = try require(editor.fieldChecks)
        let record = try require(editor.document[id])
        expectEqual(checks.check(of: record), .clean)
        expectEqual(checks.fullCheck(of: record), .clean)
        expectEqual(checks.typing == nil, true)
        let before = checks.revision
        checks.typing = (id, email)
        expectEqual(checks.typing?.shape, id)
        expectEqual(checks.typing?.path, email)
        expect(checks.revision > before, "setting it moves the revision")
        checks.typing = nil
        expectEqual(checks.typing == nil, true)
        expectEqual(checks.check(of: record), .clean)
    },
    test("the card does not open") {
        let editor = try fieldEditor()
        let id = ann(editor)
        let cards = try require(editor.fieldCards)
        let request = FieldCardRequest(shape: id, target: .field(email), mode: .values, isReadOnly: false, rowRect: CGRect(x: 0, y: 0, width: 200, height: 22),
                                       closed: {}, tabbedOut: { _ in })
        expect(!cards.open(request))
        expect(cards.openTarget == nil)
        expectEqual(cards.openFolded, nil)
        cards.close()
        let fold = FieldCardRequest(shape: id, target: .fold, mode: .kinds, isReadOnly: true, rowRect: .zero, folded: [], rowRectNow: { nil }, closed: {}, tabbedOut: { _ in })
        expect(!cards.open(fold))
        expectEqual(FieldCardRequest.Target.field(email), .field(email))
        expectEqual(Set([FieldCardRequest.Target.fold, .field(email), .field(email)]).count, 2, "a target is hashable")
    },
    test("each is a service of the shipped list, and nothing without TypesPlugin") {
        let editor = try fieldEditor()
        expect(editor.fieldWriter != nil && editor.fieldChecks != nil && editor.fieldCards != nil && editor.fieldBook != nil)
        let without = try CanvasEditor(registry: Registry(plugins: [PocketsPlugin()]), file: CanvasFile(root: CanvasDocument()), scheduler: ManualScheduler())
        expect(without.fieldWriter == nil && without.fieldChecks == nil && without.fieldCards == nil)
    },
])
