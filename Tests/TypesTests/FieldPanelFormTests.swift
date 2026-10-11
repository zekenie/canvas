import AppKit
import Canvas
import CanvasTesting
import Foundation
import SwiftUI
import TestKit
import Types

// The form in the panel (`FieldForm`, the SwiftUI face of `FieldFormView` with `presentation: .panel`): closed
// until opened, open by itself on a problem, a line an item in a list of groups, the JSON box for `Other`, the
// keys that leave it, and what is open outliving the view. The panel's section that places it is another track's,
// so a form is placed here as a section would: in an `NSHostingView`, under a name, in an unshown window, with
// real time (SwiftUI's updates land as the main run loop runs).

/// A window that says which key-view calls were made of it: the panel's Tab-off is `selectKeyView`.
@MainActor private final class KeyViewWindow: NSWindow {
    var followed: [NSView] = []
    var preceded: [NSView] = []

    override func selectKeyView(following view: NSView) {
        followed.append(view)
        super.selectKeyView(following: view)
    }

    override func selectKeyView(preceding view: NSView) {
        preceded.append(view)
        super.selectKeyView(preceding: view)
    }
}

/// A note that is each of `types`, its fields as forms in the panel's place.
@MainActor private final class PanelRig {
    let editor: CanvasEditor
    let window: KeyViewWindow
    let note: ShapeID
    let types: [ShapeID]
    var hosting: NSHostingView<AnyView>?

    init(of types: [ShapeID], extra: [FieldFixtures.TypeText] = [], log: RefusalLog? = nil, scheduler: any Scheduler = TaskScheduler()) throws {
        editor = try fieldEditor(scheduler: scheduler, more: log.map { [FreezingPlugin(log: $0)] } ?? [])
        if !extra.isEmpty { editor.addFieldTypes(extra) }
        self.types = types
        note = editor.addInstance("A note", of: types, at: CGPoint(x: 40, y: 40))
        window = KeyViewWindow(contentRect: CGRect(x: 0, y: 0, width: 320, height: 600), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
    }

    func close() { window.close() }

    func path(_ field: String) -> FieldPath { FieldPath(field: field) }
    var values: FieldValues { editor.fieldWriter?.values(of: note) ?? FieldValues() }
    func set(_ value: JSONValue?, _ field: String) { editor.fieldWriter?.set(value, at: path(field), of: note) }

    func context(_ field: String, shape: ShapeID? = nil, readOnly: Bool = false) throws -> FieldFormContext {
        let book = try require(editor.fieldBook)
        let target = shape ?? note
        let kinds = editor.document[target]?[IsAProperty.self]?.map(\.shape) ?? []
        let resolved = try require(book.fields(types: kinds).fields.first { $0.field.name == field }, field)
        return FieldFormContext(editor: editor, shape: target, path: path(field), field: resolved, kind: book.kind(of: resolved), mode: .values,
                                isReadOnly: readOnly, presentation: .panel, step: .ownRun)
    }

    /// The fields as forms one under the other, as a section places them, in the window.
    func host(_ fields: [String], shape: ShapeID? = nil, readOnly: Bool = false) throws {
        let contexts = try fields.map { try context($0, shape: shape, readOnly: readOnly) }
        let view = AnyView(VStack(alignment: .leading, spacing: 4) {
            ForEach(contexts.indices, id: \.self) { FieldForm(contexts[$0]) }
        }.frame(width: 300))
        let hosting = NSHostingView(rootView: view)
        hosting.frame = CGRect(x: 0, y: 0, width: 320, height: 500)
        window.contentView = hosting
        self.hosting = hosting
        window.spin(until: { self.forms.count == fields.count })
        window.settle()
    }

    var forms: [FieldFormView] { hosting?.descendants(FieldFormView.self) ?? [] }

    /// A form of its own in the window, with a check handed in.
    func form(_ field: String, readOnly: Bool = false, check: (@MainActor (AnyShapeRecord) -> FieldCheck)? = nil) throws -> FieldFormView {
        let form = FieldFormView(try context(field, readOnly: readOnly), check: check)
        form.frame = CGRect(x: 0, y: 0, width: 300, height: 400)
        window.contentView = NSView(frame: CGRect(x: 0, y: 0, width: 320, height: 600))
        window.contentView?.addSubview(form)
        return form
    }

    func tab() { window.press("\t", code: 48) }
    func backtab() { window.press("\u{19}", code: 48, modifiers: .shift) }
    func commandReturn() { window.press("\r", code: 36, modifiers: .command) }
    func line(_ line: Int) -> FieldStop { FieldStop(line: line, column: -1) }
}

private let kinds = (a: FieldFixtures.everyKind.a, b: FieldFixtures.everyKind.b)

@MainActor let fieldPanelFormTests = Suite("Field form in the panel", [
    test("closed it is one line with a triangle, and opening it puts its rows under it and grows the host") {
        let r = try PanelRig(of: [FieldFixtures.orderID])
        defer { r.close() }
        r.set(["street": "12 Main St"], "shippingAddress")
        try r.host(["shippingAddress"])
        let form = try require(r.forms.first)
        expectEqual(form.sheet.lines.count, 1)
        expectEqual(form.sheet.lines[0].disclosure, false)
        expectEqual(form.frame.height, TypesStyle.formRowHeight, "one line tall")
        form.activate(r.line(0))
        expectEqual(form.sheet.lines.map(\.depth), [0, 1, 1, 1])
        expectEqual(form.sheet.lines[0].disclosure, true)
        r.window.spin(until: { form.frame.height == form.contentHeight && form.frame.height > 3 * TypesStyle.formRowHeight })
        form.activate(r.line(0))
        expectEqual(form.sheet.lines.count, 1, "a click on the triangle closes it again")
        r.window.spin(until: { form.frame.height == TypesStyle.formRowHeight })
    },
    test("a problem under it opens it without a click and marks the cell, with no words of its own; one the person closed stays closed") {
        let r = try PanelRig(of: [FieldFixtures.orderID])
        defer { r.close() }
        r.set([["product": "Mug", "quantity": 0]], "lineItems")
        let item = r.path("lineItems").index(0)
        let problem = FieldProblem(path: item.key("quantity"), kind: .wrong, keyword: "minimum", place: ["line items", "Mug", "quantity"],
                                   message: "line items › Mug › quantity is 0, and should be at least 1")
        let form = try r.form("lineItems") { _ in FieldCheck(problems: [problem]) }
        expectEqual(form.sheet.lines.count, 6, "the field, the item and its three rows, the add line")
        expectEqual(form.sheet.lines[0].disclosure, true)
        expectEqual(form.sheet.lines[1].disclosure, true, "the item with the problem in it too")
        let cell = try require(form.sheet.lines.flatMap(\.cells).first { $0.path == item.key("quantity") })
        expectEqual(cell.mark, .wrong)
        expect(form.sheet.lines.flatMap(\.cells).allSatisfy { !$0.shown.contains("should be at least") }, "the form says no problem in words")
        form.activate(r.line(0))
        expectEqual(form.sheet.lines.count, 1, "the person closed it")
        form.reload()
        expectEqual(form.sheet.lines.count, 1, "and it stays closed")
    },
    test("a list of groups is a line an item, and the add line opens an empty item's rows; filling one stores it") {
        let r = try PanelRig(of: [FieldFixtures.orderID])
        defer { r.close() }
        r.set([["product": "Mug", "quantity": 2], ["product": "Plate", "quantity": 1]], "lineItems")
        let form = try r.form("lineItems")
        form.activate(r.line(0))
        expectEqual(form.sheet.lines.count, 4, "the field, two items, the add line")
        expectEqual(form.sheet.lines[1].cells[0].shown, "Mug, 2")
        expectEqual(form.sheet.lines[3].cells[0].shown, "add")
        form.activate(r.line(3))
        expectEqual(form.sheet.lines.count, 7, "the add line open: its three rows")
        expectEqual(r.values.value(at: r.path("lineItems"))?.arrayValue?.count, 2, "nothing is stored by opening it")
        form.focus(FieldStop(line: 4, column: 0))
        r.window.type("Cup")
        expectEqual(r.values.value(at: r.path("lineItems").index(2).key("product")), "Cup")
        expectEqual(r.values.value(at: r.path("lineItems"))?.arrayValue?.count, 3)
        expectEqual(r.editor.undoHistory.undoName, "Change Line Items")
    },
    test("Other is a box of the value's JSON, always open: ⌘↩ stores what parses, what does not stays in the box with Not JSON and writes nothing, empty clears, and the keyboard leaving commits") {
        let r = try PanelRig(of: [FieldFixtures.kindsBID], extra: [kinds.b])
        defer { r.close() }
        r.set(["b": [1, 2], "a": 1], "anything")
        let form = try r.form("anything")
        let path = r.path("anything")
        let cell = form.sheet.lines[0].cells[0]
        expectEqual(cell.control, .json)
        expectEqual(cell.shown, FieldJSON.pretty(["b": [1, 2], "a": 1]))
        expect(cell.shown.contains("\n"), "indented")
        form.focusFirst()
        expect(r.window.firstResponder === form.jsonEditor, "the caret is in the box")
        expectEqual(form.jsonEditor.string, cell.shown)
        expectEqual(form.jsonEditor.font, TypesStyle.formJSONFont)
        let lines = CGFloat(cell.shown.split(separator: "\n").count)
        expectEqual(form.contentHeight, max(TypesStyle.formJSONMinHeight, lines * TypesStyle.formJSONLineHeight + 2 * TypesStyle.formJSONPad), "as tall as its lines, 76 at least, no name line of its own")
        let put = { (text: String) in
            form.jsonEditor.selectAll(nil)
            form.jsonEditor.insertText(text, replacementRange: form.jsonEditor.selectedRange())
        }
        put(#"{"k": 2}"#)
        expectEqual(r.values.value(at: path), ["b": [1, 2], "a": 1], "typing writes nothing")
        r.commandReturn()
        expectEqual(r.values.value(at: path), ["k": 2])
        expectEqual(r.editor.undoHistory.undoName, "Change Anything", "one step, named for the field")
        expectEqual(form.jsonEditor.string, FieldJSON.pretty(["k": 2]), "the box shows it indented")
        put("{")
        r.commandReturn()
        expectEqual(r.values.value(at: path), ["k": 2], "not JSON writes nothing")
        expectEqual(form.jsonEditor.string, "{", "and stays in the box")
        expectEqual(form.jsonErrors, [path])
        expectEqual(form.contentHeight, TypesStyle.formJSONMinHeight + TypesStyle.formRowHeight, "76 tall for a line, and a line under it says so")
        put(#"{"k": 3"#)
        expectEqual(form.jsonErrors, [], "the complaint waits until it is done again")
        put("[1]")
        r.window.makeFirstResponder(form)
        expectEqual(r.values.value(at: path), [1], "the keyboard leaving commits")
        form.focusFirst()
        put("  ")
        r.commandReturn()
        expectEqual(r.values.value(at: path), nil, "empty clears the field")
    },
    test("the box grows with its lines to twelve, and a member that is Other has the same box on its own line under its name") {
        let r = try PanelRig(of: [FieldFixtures.kindsBID], extra: [kinds.b])
        defer { r.close() }
        let long: JSONValue = .array((1...30).map { .number(Double($0)) })
        r.set(long, "anything")
        let form = try r.form("anything")
        expectEqual(form.sheet.lines[0].cells[0].shown.split(separator: "\n").count, 32)
        expectEqual(form.contentHeight, CGFloat(TypesStyle.formJSONMaxLines) * TypesStyle.formJSONLineHeight + 2 * TypesStyle.formJSONPad, "twelve lines and no more")
        expect(form.contentHeight > TypesStyle.formJSONMinHeight)
        // At depth: a group with a member no control suits.
        let group = (id: FieldFixtures.wideID, title: "Holder", words: "A holder.", schema: #"{"type": "object", "properties": {"box": {"type": "object", "properties": {"free": {}}}}}"#)
        let nested = try PanelRig(of: [FieldFixtures.wideID], extra: [group])
        defer { nested.close() }
        nested.set(["free": 1], "box")
        let inner = try nested.form("box")
        inner.activate(nested.line(0))
        expectEqual(inner.sheet.lines.count, 2)
        expectEqual(inner.sheet.lines[1].name, "free")
        expectEqual(inner.sheet.lines[1].cells[0].control, .json)
        expectEqual(inner.contentHeight, TypesStyle.formRowHeight + TypesStyle.formRowHeight + TypesStyle.formJSONMinHeight, "the field's line, its name's row, the box")
        let box = inner.rect(of: FieldStop(line: 1, column: 0))
        expectEqual(box.height, TypesStyle.formJSONMinHeight)
        expectEqual(box.minY, 2 * TypesStyle.formRowHeight, "under the name")
    },
    test("Tab off the last stop and ⇧Tab off the first go on to the panel's next and previous key view") {
        let r = try PanelRig(of: [FieldFixtures.orderID])
        defer { r.close() }
        try r.host(["shippingAddress", "lineItems"])
        let first = r.forms[0], second = r.forms[1]
        first.focusFirst()
        expect(r.window.firstResponder === first, "a closed field's line is a stop the form itself has")
        r.tab()
        expectEqual(r.window.followed.count, 1, "asked for the next key view once")
        expect(r.window.followed.first === first)
        expect(r.window.firstResponder === second, "and SwiftUI's hosting gives the keyboard to the form under it, a key view as any other")
        second.focusFirst()
        r.backtab()
        expectEqual(r.window.preceded.count, 1)
        expect(r.window.preceded.first === second)
        expect(r.window.firstResponder === first, "and back to the form over it")
    },
    test("a read-only note: no caret anywhere, the triangles still open, nothing refused") {
        let log = RefusalLog()
        let r = try PanelRig(of: [FieldFixtures.kindsBID], extra: [kinds.b], log: log)
        defer { r.close() }
        r.set([["product": "x"]], "lineItems")
        r.set(1, "anything")
        r.editor.freeze([r.note])
        let items = try r.form("lineItems", readOnly: true)
        items.focusFirst()
        expect(r.window.firstResponder !== items.cellEditor)
        items.activate(r.line(0))
        expectEqual(items.sheet.lines[0].disclosure, true, "the triangle opens")
        let box = try r.form("anything", readOnly: true)
        box.focusFirst()
        expect(r.window.firstResponder !== box.jsonEditor, "no caret in the box")
        expect(!box.isShowingJSONEditor)
        expectEqual(box.sheet.lines[0].cells[0].shown, "1")
        expectEqual(log.refusals.count, 0, "nothing shakes in the panel")
    },
    test("what is open outlives the view: made again for the same note it is open, for another it is closed") {
        let r = try PanelRig(of: [FieldFixtures.orderID])
        defer { r.close() }
        let other = r.editor.addInstance("Another", of: [FieldFixtures.orderID], at: CGPoint(x: 40, y: 200))
        r.set(["street": "x"], "shippingAddress")
        try r.host(["shippingAddress"])
        let form = try require(r.forms.first)
        form.activate(r.line(0))
        expectEqual(form.sheet.lines.count, 4)
        try r.host(["shippingAddress"])
        expectEqual(try require(r.forms.first).sheet.lines.count, 4, "a view made again for the same note")
        try r.host(["shippingAddress"], shape: other)
        expectEqual(try require(r.forms.first).sheet.lines.count, 1, "for another note")
        r.editor.transact("Delete") { $0.delete([r.note]) }
        expectEqual(r.editor.fieldCards?.panelOpen[r.note] == nil, true, "a deleted note's entry goes")
    },
    test("typing in one cell and on by Tab into the next of the same field is one step named for the field; a click between makes two; the JSON box's commit is one") {
        let r = try PanelRig(of: [FieldFixtures.kindsAID, FieldFixtures.kindsBID], extra: [kinds.a, kinds.b])
        defer { r.close() }
        let form = try r.form("venue")
        form.activate(r.line(0))
        form.focus(FieldStop(line: 1, column: 0))
        r.window.type("Loft")
        r.tab()
        r.window.type("Leeds")
        expectEqual(r.values.value(at: r.path("venue")), ["name": "Loft", "city": "Leeds"])
        expectEqual(r.editor.undoHistory.undoName, "Change Venue")
        r.editor.undo()
        expectEqual(r.values.value(at: r.path("venue")), nil, "both cells are one step")
        r.editor.redo()
        form.focus(FieldStop(line: 1, column: 0))
        r.window.type("!")
        r.editor.undoHistory.seal()
        r.tab()
        r.window.type("Hull")
        r.editor.undo()
        expectEqual(r.values.value(at: r.path("venue")), ["name": "!", "city": "Leeds"], "a seal (a click) between makes two: the second cell's typing alone is undone")
        let box = try r.form("anything")
        box.focusFirst()
        box.jsonEditor.insertText("[1, 2]", replacementRange: box.jsonEditor.selectedRange())
        r.commandReturn()
        expectEqual(r.editor.undoHistory.undoName, "Change Anything")
        r.editor.undo()
        expectEqual(r.values.value(at: r.path("anything")), nil)
    },
])
