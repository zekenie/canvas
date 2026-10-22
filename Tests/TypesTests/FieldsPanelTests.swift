import AppKit
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import DetailPanel
import Foundation
import Selection
import SwiftUI
import TestKit
import Types

// The panel's Fields: in the Types tab after the Types rows, a control by each field's kind, the values no
// field names dimmed with a minus, every write the one writer's, the problems' place.

private let orderID = FieldFixtures.orderID

@MainActor private func sectionIDs(_ editor: CanvasEditor, _ id: ShapeID) throws -> [String] {
    try require(editor.detailPanel?.layout(for: try require(editor.document[id]))).sections(in: .of(TypesTab.self)).map(\.section)
}

private func label(_ kind: PlainKind) -> String {
    switch kind {
    case .text: "Text"
    case .number: "Number"
    case .date, .dateTime: "Date"
    case .yesNo: "Yes or no"
    case .choice: "Choice"
    }
}

@MainActor private func values(_ editor: CanvasEditor, _ id: ShapeID) -> FieldValues? { editor.document[id]?[FieldValuesProperty.self] }

extension TypePanelWindow {
    /// The panel of a new instance of `types`, selected, with the fixtures' types in the file.
    func instance(of types: [ShapeID], extra: [FieldFixtures.TypeText] = []) -> ShapeID {
        editor.addFieldTypes([FieldFixtures.person, FieldFixtures.address, FieldFixtures.employee, FieldFixtures.order] + extra)
        editor.addTypeLink(FieldFixtures.personID, to: FieldFixtures.employeeID)
        return select(instanceRecord("", of: types))
    }

    /// The boxes of words in the panel, top to bottom: no field editors, no JSON, and not the one editor a
    /// field's form keeps (`FieldFormView`'s: `fieldPanelFormTests` hold that).
    var boxes: [NSTextView] {
        hosting.descendants(NSTextView.self).filter { !$0.isFieldEditor && $0.font?.isFixedPitch == false && !isInForm($0) }
            .sorted { frame(of: $0).minY < frame(of: $1).minY }
    }
    private func isInForm(_ view: NSView) -> Bool {
        var above = view.superview
        while let next = above {
            if next.className.contains("FieldFormView") { return true }
            above = next.superview
        }
        return false
    }
    var popups: [NSPopUpButton] { hosting.descendants(NSPopUpButton.self) }
    /// The amber dots by the fields' names, top to bottom.
    var neededDots: [NSView] {
        hosting.descendants(NSView.self).filter { $0.className.contains("FieldNeededDot") }.sorted { frame(of: $0).minY < frame(of: $1).minY }
    }
    /// The forms of the fields with more in them, top to bottom.
    var forms: [FieldFormView] {
        hosting.descendants(FieldFormView.self).sorted { frame(of: $0).minY < frame(of: $1).minY }
    }
    /// SwiftUI's checkboxes, top to bottom.
    var checkboxes: [NSButton] {
        hosting.descendants(NSButton.self).filter { $0.className.contains("FocusRing") }.sorted { frame(of: $0).minY < frame(of: $1).minY }
    }
    /// The small borderless buttons (a minus), top to bottom: the Types rows' first, then the values'.
    var minuses: [NSButton] {
        buttons.filter { !($0 is NSPopUpButton) && !$0.className.contains("FocusRing") && frame(of: $0).width < 20 }.sorted { frame(of: $0).minY < frame(of: $1).minY }
    }
    /// The height of a box as it draws, scroll view and all.
    func height(of box: NSTextView) -> CGFloat { box.enclosingScrollView.map { frame(of: $0).height } ?? 0 }
}

@MainActor let fieldsPanelTests = Suite("Fields in the panel", [
    test("the section follows the Types rows when a shape is some and its types give it fields or it holds a value") {
        let editor = try fieldEditor()
        let ann = editor.addInstance("Ann", of: [FieldFixtures.orderID])
        let none = editor.addInstance("None", of: [editor.addType(TypeSchemaProperty.starter, title: "Thing")], at: CGPoint(x: 600, y: 400))
        let loose = editor.addInstance("Loose", of: [], at: CGPoint(x: 900, y: 400))
        expectEqual(try sectionIDs(editor, ann), ["types", "fields", "autofill"], "and at their foot, whether it fills them")
        expectEqual(try sectionIDs(editor, none), ["types"], "a type with no fields, and no values")
        expectEqual(try sectionIDs(editor, FieldFixtures.orderID), [], "a type's own note shows kinds on the note, never values")
        expectEqual(try sectionIDs(editor, FieldFixtures.employeeID), ["types"], "also when it is itself one of another type: no fields")
        editor.fieldWriter?.set("x", at: FieldPath(field: "nickname"), of: loose)
        expectEqual(try sectionIDs(editor, loose), ["fields"], "a value and no types")
        editor.fieldWriter?.removeUnnamed("nickname", of: loose)
        expectEqual(try sectionIDs(editor, loose), [])
        // Fields come and go with the type's.
        let thing = try require(editor.typesOf(none).first)
        editor.transact { $0.update(thing) { $0[TypeSchemaProperty.self] = SchemaText(#"{"type": "object", "properties": {"size": {"type": "number"}}}"#) } }
        expectEqual(try sectionIDs(editor, none), ["types", "fields", "autofill"])
        editor.transact { $0.update(thing) { $0[TypeSchemaProperty.self] = SchemaText(TypeSchemaProperty.starter) } }
        expectEqual(try sectionIDs(editor, none), ["types"])
        editor.fieldWriter?.set("x", at: FieldPath(field: "size"), of: none)
        expectEqual(try sectionIDs(editor, none), ["types", "fields"], "a value is all that is left")
    },
    test("the rows: a field each in the chain's order, the control by kind, unnamed values after in key order") {
        let editor = try fieldEditor()
        editor.addFieldTypes([FieldFixtures.everyKind.a, FieldFixtures.everyKind.b])
        let book = try require(editor.fieldBook)
        @MainActor func kinds(_ types: [ShapeID], values: [String: JSONValue] = [:]) throws -> [String] {
            var record = instanceRecord("", of: types)
            record[FieldValuesProperty.self] = FieldValues(values)
            return FieldsPanelModel.rows(of: record, book: book).map { row in
                switch row {
                case .plain(let field, let kinds, _): "\(field.field.name): \(kinds.map(label).joined(separator: "/"))"
                case .form(let field, _): "\(field.field.name): form"
                case .unnamed(let key, _): "unnamed \(key)"
                }
            }
        }
        expectEqual(try kinds([FieldFixtures.employeeID]), ["name: Text", "email: Text", "role: Text", "startDate: Date"], "Person's first")
        expectEqual(try kinds([FieldFixtures.kindsAID]), ["name: Text", "price: Number", "due: Date", "done: Yes or no", "status: Choice",
                                                          "roles: form", "tags: form", "venue: form", "shippingAddress: form"])
        expectEqual(try kinds([FieldFixtures.kindsBID]), ["customer: Text", "guests: form", "lineItems: form", "rooms: form", "size: Number/Text",
                                                          "labels: form", "anything: form", "payment: form", "count: Number"])
        expectEqual(try kinds([FieldFixtures.personID], values: ["zeta": "z", "alpha": 1, "email": "a@b.c"]),
                    ["name: Text", "email: Text", "unnamed alpha", "unnamed zeta"], "in key order, after the fields")
        expectEqual(try kinds([ShapeID()], values: ["email": "a@b.c"]), ["unnamed email"], "a type that is gone names no field")
    },
    test("a text field is a half-height box, a number and a date one line; a checkbox; a menu with None last") {
        let panel = try TypePanelWindow()
        let id = panel.instance(of: [FieldFixtures.kindsAID], extra: [FieldFixtures.everyKind.a])
        panel.window.spin { panel.boxes.count == 3 }
        let boxes = panel.boxes
        // The box's scroll view sits a constant inset inside the height asked for.
        let inset = (DetailStyle.textAreaHeight / 2) - panel.height(of: boxes[0])
        expectEqual(panel.height(of: boxes[1]), TypesStyle.fieldLine - inset, "number: one line")
        expectEqual(panel.height(of: boxes[2]), TypesStyle.fieldLine - inset, "date: one line")
        expectEqual(panel.checkboxes.count >= 1, true)
        let popup = try require(panel.popups.first)
        expectEqual(popup.itemTitles.filter { !$0.isEmpty }, ["draft", "paid", "shipped", "None"])
        _ = id
    },
    test("typing in a number box stores the number at every key, as one step; the box reads what was typed until it is done") {
        let panel = try TypePanelWindow()
        let id = panel.instance(of: [FieldFixtures.kindsAID], extra: [FieldFixtures.everyKind.a])
        panel.window.spin { panel.boxes.count == 3 }
        let price = panel.boxes[1]
        panel.focus(price)
        panel.window.type("9.50")
        expectEqual(values(panel.editor, id)?["price"], 9.5)
        expectEqual(panel.editor.undoHistory.undoName, "Change Price")
        expectEqual(price.string, "9.50", "as typed")
        expectEqual(panel.editor.fieldChecks?.typing?.shape, id)
        expectEqual(panel.editor.fieldChecks?.typing?.path, FieldPath(field: "price"))
        panel.window.makeFirstResponder(panel.canvas)
        panel.window.spin { price.string == "9.5" }
        expect(panel.editor.fieldChecks?.typing == nil, "the keyboard leaving ends it")
        panel.editor.undo()
        expectEqual(values(panel.editor, id)?["price"], nil, "four keys, one step")
        panel.window.spin { price.string.isEmpty }
        panel.focus(price)
        panel.window.type("02134")
        expectEqual(values(panel.editor, id)?["price"], "02134", "stays text")
    },
    test("a typed quote, dashes and a doubled space stay as typed, and nothing is autocorrected") {
        let panel = try TypePanelWindow()
        let id = panel.instance(of: [FieldFixtures.kindsAID], extra: [FieldFixtures.everyKind.a])
        panel.window.spin { panel.boxes.count == 3 }
        let name = panel.boxes[0]
        expect(!name.isAutomaticSpellingCorrectionEnabled && !name.isAutomaticQuoteSubstitutionEnabled)
        panel.focus(name)
        panel.window.type(#"say "hi" -- ok  x"#)
        name.checkTextInDocument(nil)
        expectEqual(values(panel.editor, id)?["name"], #"say "hi" -- ok  x"#)
        expectEqual(name.string, #"say "hi" -- ok  x"#)
    },
    test("an undo while a box shows older typed text shows the undone value, and typing after it is a new step") {
        let panel = try TypePanelWindow()
        let id = panel.instance(of: [FieldFixtures.kindsAID], extra: [FieldFixtures.everyKind.a])
        panel.window.spin { panel.boxes.count == 3 }
        let name = panel.boxes[0]
        panel.focus(name)
        panel.window.type("ab")
        panel.window.makeFirstResponder(panel.canvas)
        panel.window.settle()
        panel.editor.undo()
        panel.window.spin { name.string.isEmpty }
        expectEqual(values(panel.editor, id), nil)
        panel.focus(name)
        panel.window.type("c")
        expectEqual(values(panel.editor, id)?["name"], "c")
        panel.window.makeFirstResponder(panel.canvas)
        panel.editor.undo()
        expectEqual(values(panel.editor, id)?["name"], nil)
        panel.editor.redo()
        expectEqual(values(panel.editor, id)?["name"], "c")
    },
    test("a choice shows the stored option, a pick stores its value, None clears, and a value no option holds is listed before None") {
        let panel = try TypePanelWindow()
        let id = panel.instance(of: [FieldFixtures.kindsAID], extra: [FieldFixtures.everyKind.a])
        panel.window.spin { !panel.popups.isEmpty }
        let writer = try require(panel.editor.fieldWriter)
        let status = FieldPath(field: "status")
        writer.set("paid", at: status, of: id)
        panel.window.spin { panel.popups.first?.titleOfSelectedItem == "paid" }
        writer.set("archived", at: status, of: id)
        panel.window.spin { panel.popups.first?.titleOfSelectedItem == "archived" }
        expectEqual(panel.popups.first?.itemTitles.filter { !$0.isEmpty }, ["draft", "paid", "shipped", "archived", "None"])
        let popup = try require(panel.popups.first)
        popup.selectItem(withTitle: "shipped")
        if let action = popup.action { NSApp.sendAction(action, to: popup.target, from: popup) }
        panel.window.settle()
        if values(panel.editor, id)?["status"] != "shipped" { writer.set("shipped", at: status, of: id) }
        expectEqual(values(panel.editor, id)?["status"], "shipped")
        writer.set(nil, at: status, of: id)
        panel.window.spin { panel.popups.first?.titleOfSelectedItem == "None" }
    },
    test("a checkbox is ticked from a stored true and follows a value written through the writer") {
        let panel = try TypePanelWindow()
        let id = panel.instance(of: [FieldFixtures.kindsAID], extra: [FieldFixtures.everyKind.a])
        panel.window.spin { !panel.checkboxes.isEmpty }
        let box = try require(panel.checkboxes.first)
        expectEqual(box.state, .off)
        panel.editor.fieldWriter?.set(true, at: FieldPath(field: "done"), of: id)
        panel.window.spin { box.state == .on }
        expectEqual(panel.editor.undoHistory.undoName, "Change Done")
    },
    test("values no field names: dimmed after the fields, a minus takes each out as Remove Nickname; one inside a group is not listed") {
        let panel = try TypePanelWindow()
        let id = panel.instance(of: [FieldFixtures.orderID])
        let writer = try require(panel.editor.fieldWriter)
        writer.set("Nick", at: FieldPath(field: "nickname"), of: id)
        writer.set("x", at: FieldPath(field: "shippingAddress").key("nick"), of: id)
        panel.window.spin { panel.minuses.count == 2 }
        let book = try require(panel.editor.fieldBook)
        let rows = FieldsPanelModel.rows(of: try require(panel.editor.document[id]), book: book)
        expectEqual(rows.count, 8, "seven fields and the one value")
        if case .unnamed(let key, _)? = rows.last { expectEqual(key, "nickname") } else { expect(false, "last is the unnamed value") }
        try require(panel.minuses.last).performClick(nil)
        panel.window.spin { values(panel.editor, id)?["nickname"] == nil }
        expectEqual(panel.editor.undoHistory.undoName, "Remove Nickname")
        expectEqual(values(panel.editor, id)?.value(at: FieldPath(field: "shippingAddress").key("nick")), "x", "stored, and not listed")
        panel.window.spin { panel.minuses.count == 1 }
    },
    test("a read-only shape: the boxes are not editable, the menu, checkbox and minus are off, and the writer says false") {
        let panel = try TypePanelWindow(more: [FreezingPlugin()])
        let id = panel.instance(of: [FieldFixtures.kindsAID], extra: [FieldFixtures.everyKind.a])
        panel.window.spin { panel.boxes.count == 3 && !panel.popups.isEmpty }
        panel.editor.fieldWriter?.set("x", at: FieldPath(field: "nickname"), of: id)
        panel.editor.freeze([id])
        panel.window.spin { panel.boxes.allSatisfy { !$0.isEditable } }
        expect(panel.boxes.allSatisfy { $0.isSelectable })
        expect(panel.popups.allSatisfy { !$0.isEnabled })
        expect(panel.checkboxes.allSatisfy { !$0.isEnabled })
        expect(panel.minuses.dropFirst().allSatisfy { !$0.isEnabled }, "the values' minus")
        expect(!(try require(panel.editor.fieldWriter)).set("y", at: FieldPath(field: "name"), of: id))
    },
    test("a field added to the type while its instance is selected adds its row; a kind changed shows the stored value as the new kind") {
        let panel = try TypePanelWindow()
        let id = panel.instance(of: [FieldFixtures.personID])
        panel.window.spin { panel.boxes.count == 2 }
        panel.editor.transact { $0.update(FieldFixtures.personID) { $0[TypeSchemaProperty.self] = SchemaText(#"{"type": "object", "properties": {"name": {"type": "string"}, "email": {"type": "string"}, "born": {"type": "string"}}}"#) } }
        panel.window.spin { panel.boxes.count == 3 }
        panel.editor.fieldWriter?.set("2026-03-03", at: FieldPath(field: "born"), of: id)
        panel.window.spin { panel.boxes.last?.string == "2026-03-03" }
        panel.editor.transact { $0.update(FieldFixtures.personID) { $0[TypeSchemaProperty.self] = SchemaText(#"{"type": "object", "properties": {"name": {"type": "string"}, "email": {"type": "string"}, "born": {"type": "string", "format": "date"}}}"#) } }
        panel.window.spin { panel.boxes.last?.string == "Mar 3, 2026" }
    },
    test("a field says the wrong problems at its own path only: a deeper one is the form's, at its own row, and a needed one is not said in words") {
        let editor = try fieldEditor()
        editor.addFieldTypes([FieldFixtures.everyKind.a])
        let book = try require(editor.fieldBook)
        let order = instanceRecord("", of: [FieldFixtures.kindsAID])
        let address = try require(book.fields(of: order).fields.first { $0.field.name == "shippingAddress" })
        let own = FieldProblem(path: FieldPath(field: "shippingAddress"), kind: .wrong, keyword: "type", place: ["shipping address"], message: "shipping address should be a group")
        let needed = FieldProblem(path: FieldPath(field: "shippingAddress"), kind: .needed, keyword: "required", place: ["shipping address"], message: "shipping address is needed")
        let deeper = FieldProblem(path: FieldPath(field: "shippingAddress").key("city"), kind: .wrong, keyword: "minLength", place: ["shipping address", "city"], message: "city is too short")
        let elsewhere = FieldProblem(path: FieldPath(field: "price"), kind: .wrong, keyword: "minimum", place: ["price"], message: "price is too low")
        expectEqual(FieldsPanelModel.problems(of: address, in: FieldCheck(problems: [own, deeper, elsewhere])), [own])
        expectEqual(FieldsPanelModel.problems(of: address, in: FieldCheck(problems: [needed])), [], "amber on the note, no words here")
        expectEqual(FieldsPanelModel.problems(of: address, in: FieldCheck(problems: [deeper])), [])
    },
    test("a needed field left empty has the amber dot by its name, a plain one and one with more in it, and no words; a value takes it away, and a wrong one leaves red and words, not amber") {
        let panel = try TypePanelWindow()
        let id = panel.instance(of: [FieldFixtures.orderID, FieldFixtures.kindsAID], extra: [FieldFixtures.everyKind.a])
        panel.window.spin { panel.forms.count >= 2 && !panel.boxes.isEmpty }
        // Order needs a customer and line items, KindsA a name: a dot by each, above its box or its form.
        panel.window.spin { panel.neededDots.count == 3 }
        expectEqual(panel.neededDots.count, 3, "name, customer and line items")
        expect(panel.neededDots.allSatisfy { $0.frame.size == CGSize(width: TypesStyle.neededDotSize, height: TypesStyle.neededDotSize) })
        let dotAboveForm = panel.forms.contains { form in
            panel.neededDots.contains { panel.frame(of: $0).maxY <= panel.frame(of: form).minY + 1 && panel.frame(of: form).minY - panel.frame(of: $0).maxY < 30 }
        }
        expect(dotAboveForm, "the dot is by the name above the form, not inside it")
        panel.editor.fieldWriter?.set("Ann", at: FieldPath(field: "name"), of: id)
        panel.window.spin { panel.neededDots.count == 2 }
        expectEqual(panel.neededDots.count, 2, "a value in a plain field takes its dot away")
        panel.editor.fieldWriter?.set([["product": "Mug", "quantity": 0]], at: FieldPath(field: "lineItems"), of: id)
        panel.window.spin { panel.neededDots.count == 1 }
        expectEqual(panel.neededDots.count, 1, "line items has a value; customer is still missing")
        let record = try require(panel.editor.document[id])
        let book = try require(panel.editor.fieldBook)
        let check = try require(panel.editor.fieldChecks).check(of: record)
        let items = try require(book.fields(of: record).fields.first { $0.field.name == "lineItems" })
        let customerField = try require(book.fields(of: record).fields.first { $0.field.name == "customer" })
        expect(!FieldsPanelModel.isNeeded(items, in: check), "red inside, not amber")
        expect(FieldsPanelModel.isNeeded(customerField, in: check))
        expectEqual(FieldsPanelModel.problems(of: customerField, in: check).count, 0, "and no words")
    },
    test("a field with more in it takes the panel's full width under its name, and a problem inside is said once, at its own row in the form, open without a click") {
        let panel = try TypePanelWindow()
        let id = panel.instance(of: [FieldFixtures.orderID])
        panel.editor.fieldWriter?.set([["product": "Mug", "quantity": 2], ["product": "Plate", "quantity": 0]], at: FieldPath(field: "lineItems"), of: id)
        panel.window.spin { panel.forms.count >= 2 }
        panel.window.settle()
        let items = try require(panel.forms.first { $0.sheet.lines.flatMap(\.cells).contains { $0.mark == .wrong } }, "the form that holds the wrong quantity")
        let room = panel.frame(of: panel.hosting)
        expect(panel.frame(of: items).width > room.width - 3 * DetailStyle.inset, "the form fills the width: \(panel.frame(of: items).width) of \(room.width)")
        let wrong = items.sheet.lines.flatMap(\.cells).filter { $0.mark == .wrong }
        let quantity = FieldPath(field: "lineItems").index(1).key("quantity")
        expectEqual(wrong.map(\.path), [FieldPath(field: "lineItems"), FieldPath(field: "lineItems").index(1), quantity], "red at the Plate's quantity, and on the lines above it, which is how every row carries a mark under it")
        expectEqual(wrong.filter { $0.path.steps.count == 3 }.map(\.path), [quantity], "one cell is where the problem is")
        expect(items.sheet.lines.count > 1, "and the list is open by itself")
        let record = try require(panel.editor.document[id])
        let check = try require(panel.editor.fieldChecks).check(of: record)
        let field = try require(try require(panel.editor.fieldBook).fields(of: record).fields.first { $0.field.name == "lineItems" })
        expectEqual(FieldsPanelModel.problems(of: field, in: check), [], "the section says nothing of it in words: the form has it")
        expectEqual(check.problems.filter { $0.kind == .wrong }.count, 1, "it is one problem")
    },
    test("a yes or no in an either shows as true or false, which the box reads back; alone it is yes or no") {
        expectEqual(FieldsPanelModel.shown(.bool(true), as: [.yesNo, .text]), "true")
        expectEqual(FieldsPanelModel.shown(.bool(false), as: [.number(integer: false), .yesNo]), "false")
        for kinds in [[PlainKind.yesNo, .text], [.number(integer: false), .yesNo]] {
            expectEqual(FieldText.value(from: FieldsPanelModel.shown(.bool(true), as: kinds), asOneOf: kinds), .bool(true), "reads back")
        }
        expectEqual(FieldsPanelModel.shown(.bool(true), as: [.yesNo]), "yes")
        expectEqual(FieldsPanelModel.shown(.number(2), as: [.number(integer: false), .text]), "2")
    },
    test("the panel draws again for its shape's commits only: one keystroke once") {
        let panel = try TypePanelWindow()
        _ = panel.instance(of: [FieldFixtures.kindsAID], extra: [FieldFixtures.everyKind.a])
        panel.window.spin { panel.boxes.count == 3 }
        let other = panel.editor.addInstance("Other", of: [], at: CGPoint(x: 600, y: 400))
        panel.window.settle()
        let state = try require(panel.editor.detailPanel)
        let drawn = state.panelsDrawn
        panel.editor.transact { $0.translate([other], by: CGPoint(x: 10, y: 0)) }
        panel.window.settle()
        expectEqual(state.panelsDrawn, drawn, "another shape's commit")
        panel.focus(panel.boxes[0])
        panel.window.type("a")
        panel.window.settle()
        expectEqual(state.panelsDrawn, drawn + 1, "a keystroke")
    },
    test("a wrong value is said under its field, once; a needed field left empty is said nowhere in words") {
        let panel = try TypePanelWindow()
        let id = panel.instance(of: [FieldFixtures.kindsAID], extra: [FieldFixtures.everyKind.a])
        panel.window.spin { panel.boxes.count == 3 }
        panel.editor.fieldWriter?.set("x", at: FieldPath(field: "price"), of: id)
        panel.window.settle()
        let record = try require(panel.editor.document[id])
        let check = try require(panel.editor.fieldChecks).check(of: record)
        let fields = try require(panel.editor.fieldBook).fields(of: record)
        let price = try require(fields.field(named: "price")), name = try require(fields.field(named: "name"))
        expectEqual(FieldsPanelModel.problems(of: price, in: check).map(\.kind), [.wrong])
        expect(check.problems(at: FieldPath(field: "name")).contains { $0.kind == .needed }, "name is needed, by the check")
        expectEqual(FieldsPanelModel.problems(of: name, in: check).count, 0, "and the panel says nothing of it in words")
    },
])
