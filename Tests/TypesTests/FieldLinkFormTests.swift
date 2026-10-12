import AppKit
import Canvas
import CanvasTesting
import Foundation
import Mentions
import Selection
import TestKit
import TextEditing
import Types

// A pointer in the form a card and the panel hold: the cell it is (`.link`), a list of pointers as a column of
// them, and what the keys do over it: typing, Space, Return and a click off the pill open the list of the notes of
// the type, Return or a click on a line picks, Tab, ⇧Tab and Escape close it with nothing stored, Backspace clears.
// Keys go through `window.press` as the form's tests do; the list is read through the editor's `caretListWindow`.

private let person = FieldFixtures.uri(of: FieldFixtures.personID)
private let pointer = #"{"type": "string", "contentMediaType": "text/x-canvas-link", "contentSchema": {"$ref": "\#(person)"}}"#
private let gone = #"{"type": "string", "contentMediaType": "text/x-canvas-link", "contentSchema": {"$ref": "\#(FieldFixtures.uri(of: ShapeID()))"}}"#

private let holder = #"""
{
  "type": "object",
  "properties": {
    "customer": \#(pointer),
    "guests": { "type": "array", "items": \#(pointer) },
    "party": { "type": "object", "properties": { "host": \#(pointer), "guests": { "type": "array", "items": \#(pointer) } } },
    "lines": { "type": "array", "items": { "type": "object", "properties": { "sku": { "type": "string" }, "owner": \#(pointer) } } },
    "lost": \#(gone),
    "lostGuests": { "type": "array", "items": \#(gone) },
    "note": { "type": "string" }
  }
}
"""#

private let ann = link(to: FieldFixtures.annLeeID, "Ann Lee")
private let bo = link(to: FieldFixtures.boParkID, "Bo Park")

/// A form in an unshown window over an instance of `holder`.
@MainActor private final class LinkForm {
    let editor: CanvasEditor
    let shape: ShapeID
    let window: NSWindow
    let form: FieldFormView
    var closings: [FieldFormView.Closing] = []
    let field: String
    let scheduler: ManualScheduler

    init(_ name: String, stored: JSONValue? = nil, others: JSONObject = [:], readOnly: Bool = false, presentation: FieldFormContext.Presentation = .card,
         log: RefusalLog? = nil, scheduler: ManualScheduler = ManualScheduler()) throws {
        field = name
        self.scheduler = scheduler
        editor = try fieldEditor(scheduler: scheduler, more: log.map { [FreezingPlugin(log: $0)] } ?? [])
        let type = editor.addType(holder, title: "Holder")
        shape = editor.addInstance("Holder", of: [type])
        let book = try require(editor.fieldBook)
        let resolved = try require(book.fields(types: [type]).field(named: name))
        if let stored { editor.fieldWriter?.set(stored, at: FieldPath(field: name), of: shape) }
        for (key, value) in others { editor.fieldWriter?.set(value, at: FieldPath(field: key), of: shape) }
        editor.undoHistory.seal()
        if readOnly, log != nil { editor.freeze([shape]) }
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 420), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        form = FieldFormView(editor: editor, shape: shape, root: .field(path: FieldPath(field: name), field: resolved, kind: book.kind(of: resolved)), mode: .values,
                             isReadOnly: readOnly, presentation: presentation, cardKey: presentation == .card ? "card" : nil)
        form.frame = CGRect(x: 0, y: 0, width: 300, height: 420)
        window.contentView?.addSubview(form)
        form.onClose = { [weak self] closing in self?.closings.append(closing) }
        window.makeFirstResponder(form)
    }

    func close() { window.close() }

    var values: FieldValues { editor.fieldWriter?.values(of: shape) ?? FieldValues() }
    func value(_ path: FieldPath) -> JSONValue? { values.value(at: path) }
    var path: FieldPath { FieldPath(field: field) }
    var inEditor: Bool { window.firstResponder === form.cellEditor }
    var inForm: Bool { window.firstResponder === form }
    var stop: FieldStop? { form.focus }
    func at(_ line: Int, _ column: Int = 0) -> FieldStop { FieldStop(line: line, column: column) }
    /// The list over the cell, if one is open.
    var list: CaretList? { form.cellEditor.caretListWindow?.list }
    var titles: [String] { list?.rows.compactMap(\.item).map(\.title) ?? [] }
    func tab() { window.press("\t", code: 48) }
    func backtab() { window.press("\u{19}", code: 48, modifiers: .shift) }
    func space() { window.press(" ", code: 49) }
    func down() { window.press("\u{F701}", code: 125) }
    func backspace() { window.press("\u{7f}", code: 51) }
    func delete() { window.press("\u{F728}", code: 117) }
    var undoName: String? { editor.undoHistory.undoName }
}

@MainActor let fieldLinkFormTests = Suite("A pointer in the form", [
    test("a pointer is a link cell: its token's name, the placeholder `add customer` when empty, the text as stored when it is no token, and a stop; a gone type is the chip, no stop") {
        let f = try LinkForm("customer", stored: ann)
        defer { f.close() }
        let cell = f.form.sheet.lines[0].cells[0]
        expectEqual(cell.control, .link(FieldFixtures.personID))
        expectEqual(cell.shown, "Ann Lee")
        expectEqual(cell.value, ann)
        expect(cell.isEditable)
        expectEqual(f.form.sheet.stops, [f.at(0)])
        let empty = try LinkForm("customer")
        defer { empty.close() }
        expectEqual(empty.form.sheet.lines[0].cells[0].placeholder, "add customer")
        expectEqual(empty.form.sheet.lines[0].cells[0].shown, "")
        let text = try LinkForm("customer", stored: "Ann Lee")
        defer { text.close() }
        expectEqual(text.form.sheet.lines[0].cells[0].shown, "Ann Lee", "not a token: the text as stored")
        let lost = try LinkForm("lost", stored: ann)
        defer { lost.close() }
        let missing = lost.form.sheet.lines[0].cells[0]
        expect(!missing.isEditable, "its type is gone")
        expectEqual(lost.form.sheet.stops, [])
    },
    test("a list of pointers is a column: a line a pointer, a waiting line; read-only has none; a pointer in a group is a cell, a list in a group is a summary that opens its column; in a table a cell") {
        let f = try LinkForm("guests", stored: [ann, bo])
        defer { f.close() }
        expectEqual(f.form.sheet.layout, .column)
        expectEqual(f.form.sheet.lines.map { $0.cells[0].shown }, ["Ann Lee", "Bo Park", ""])
        expectEqual(f.form.sheet.lines.map { $0.cells[0].control }, Array(repeating: .link(FieldFixtures.personID), count: 3))
        expectEqual(f.form.sheet.lines[2].cells[0].placeholder, "add", "the waiting line")
        expect(!f.form.sheet.lines[2].cells[0].isStored)
        expectEqual(f.form.sheet.stops, [f.at(0), f.at(1), f.at(2)])
        let log = RefusalLog()
        let shut = try LinkForm("guests", stored: [ann], readOnly: true, log: log)
        defer { shut.close() }
        expectEqual(shut.form.sheet.lines.count, 1, "no waiting line")
        expectEqual(shut.form.sheet.stops, [], "no stop")
        let group = try LinkForm("party", stored: ["host": ann, "guests": [bo]])
        defer { group.close() }
        expectEqual(group.form.sheet.lines.map(\.name), ["host", "guests"])
        expectEqual(group.form.sheet.lines[0].cells[0].control, .link(FieldFixtures.personID))
        expectEqual(group.form.sheet.lines[1].cells[0].control, .more(.pills(targets: ["Bo Park"], more: 0)))
        group.form.focus(group.at(1, -1))
        group.window.pressReturn()
        expectEqual(group.form.depth, 1, "a list of links inside a group opens in the card")
        expectEqual(group.form.sheet.layout, .column)
        expectEqual(group.form.sheet.lines.map { $0.cells[0].shown }, ["Bo Park", ""])
        let table = try LinkForm("lines", stored: [["sku": "a", "owner": ann]])
        defer { table.close() }
        expectEqual(table.form.sheet.layout, .table(["sku", "owner"]))
        expectEqual(table.form.sheet.lines[0].cells.map(\.control), [.text(.text), .link(FieldFixtures.personID)])
        expectEqual(table.form.sheet.lines[0].cells[1].shown, "Ann Lee")
        let lost = try LinkForm("lostGuests", stored: [ann])
        defer { lost.close() }
        expectEqual(lost.form.sheet.stops, [], "a gone type's list is words")
    },
    test("typing on a focused link cell opens the list of the type's notes over it and writes nothing; Return picks the highlighted line: one write of its token, the cell keeps the keyboard") {
        let f = try LinkForm("customer", presentation: .panel)
        defer { f.close() }
        f.form.focusFirst()
        expect(f.inForm, "a link has the form's keyboard, no caret")
        f.window.type("an")
        expect(f.inEditor, "the editor is over the cell for the query")
        expectEqual(f.form.cellEditor.string, "an")
        expectEqual(f.titles, ["Ann Lee"])
        expectEqual(f.value(f.path), nil, "nothing written while it is typed")
        expectEqual(f.editor.undoHistory.undoName, nil)
        expect(f.editor.fieldChecks?.typing == nil, "and the check is told nothing")
        f.window.pressReturn()
        expectEqual(f.value(f.path), ann)
        expectEqual(f.undoName, "Change Customer", "the panel's step")
        expect(f.list == nil && f.inForm, "the list is gone and the form has the keyboard")
        expectEqual(f.stop, f.at(0))
        expectEqual(f.form.sheet.lines[0].cells[0].shown, "Ann Lee")
        f.editor.undo()
        expectEqual(f.value(f.path), nil, "one step")
    },
    test("Space, Return and a click off the pill open the list with nothing typed; a click on a live pill goes to the note and not into the list") {
        let f = try LinkForm("customer", stored: ann)
        defer { f.close() }
        f.form.focusFirst()
        f.space()
        expect(f.list != nil, "Space")
        expectEqual(f.form.cellEditor.string, "")
        expect(f.titles.contains("Ann Lee") && f.titles.contains("Bo Park"))
        f.window.pressEscape()
        expect(f.list == nil && f.inForm)
        f.window.pressReturn()
        expect(f.list != nil, "Return")
        f.window.pressEscape()
        let cell = f.form.rect(of: f.at(0))
        f.form.press(at: CGPoint(x: cell.maxX - 6, y: cell.midY))
        expect(f.list != nil, "a click off the pill")
        f.window.pressEscape()
        f.form.press(at: CGPoint(x: cell.minX + 10, y: cell.midY))
        f.scheduler.advance(by: .zero)
        expect(f.list == nil, "a click on the pill does not open the list")
        expectEqual(f.editor.selection, FieldFixtures.annLeeID, "it goes to Ann Lee")
    },
    test("Tab with a line highlighted picks nothing and moves to the next cell; ⇧Tab the same the other way; Escape closes and keeps the old value, a second Escape closes the card") {
        let f = try LinkForm("guests", stored: [ann])
        defer { f.close() }
        f.form.focusFirst()
        f.window.type("bo")
        expectEqual(f.titles, ["Bo Park"])
        f.tab()
        expect(f.list == nil, "the list closed")
        expectEqual(f.value(f.path), [ann], "and picked nothing")
        expectEqual(f.stop, f.at(1), "the focus moved on, to the waiting line")
        expect(f.inForm)
        f.window.type("bo")
        f.backtab()
        expectEqual(f.value(f.path), [ann])
        expectEqual(f.stop, f.at(0), "⇧Tab goes back")
        f.space()
        expect(f.list != nil)
        f.window.pressEscape()
        expect(f.list == nil)
        expectEqual(f.value(f.path), [ann], "Escape keeps the old value")
        expect(f.closings.isEmpty, "and the card stays")
        f.window.pressEscape()
        expectEqual(f.closings, [.escaped], "a second Escape closes the card")
    },
    test("Return with no match stores nothing, and Backspace on an empty query closes the list") {
        let f = try LinkForm("customer", stored: ann)
        defer { f.close() }
        f.form.focusFirst()
        f.window.type("zzq")
        expectEqual(f.titles, [])
        f.window.pressReturn()
        expect(f.list != nil, "Return with nothing highlighted is taken: the list stays")
        expectEqual(f.value(f.path), ann, "nothing is stored")
        for _ in 0..<3 { f.backspace() }
        expect(f.list != nil, "the query is empty and the list shows the notes")
        f.backspace()
        expect(f.list == nil && f.inForm, "one more Backspace on the empty field closes it")
        expectEqual(f.value(f.path), ann)
    },
    test("Backspace and Delete on a filled cell clear it, one step; on a list's line they take the line out and the rest close up; on a table's cell they clear the member") {
        let f = try LinkForm("customer", stored: ann, presentation: .panel)
        defer { f.close() }
        f.form.focusFirst()
        f.backspace()
        expectEqual(f.value(f.path), nil)
        expectEqual(f.undoName, "Change Customer")
        expectEqual(f.form.sheet.lines[0].cells[0].placeholder, "add customer")
        f.editor.undo()
        expectEqual(f.value(f.path), ann)
        f.delete()
        expectEqual(f.value(f.path), nil, "Forward Delete too")
        let list = try LinkForm("guests", stored: [ann, bo])
        defer { list.close() }
        list.form.focus(list.at(0))
        list.backspace()
        expectEqual(list.value(list.path), [bo], "the line is out")
        expectEqual(list.form.sheet.lines.map { $0.cells[0].shown }, ["Bo Park", ""])
        let table = try LinkForm("lines", stored: [["sku": "a", "owner": ann]])
        defer { table.close() }
        table.form.focus(table.at(0, 1))
        table.backspace()
        expectEqual(table.value(table.path.index(0).key("owner")), nil)
        expectEqual(table.value(table.path.index(0).key("sku")), "a")
    },
    test("a pick on the waiting line adds an item and a new waiting line; a pick on a line replaces it; in a table's cell it sets the member") {
        let f = try LinkForm("guests", stored: [ann])
        defer { f.close() }
        f.form.focus(f.at(1))
        f.window.type("bo")
        f.window.pressReturn()
        expectEqual(f.value(f.path), [ann, bo])
        expectEqual(f.form.sheet.lines.map { $0.cells[0].shown }, ["Ann Lee", "Bo Park", ""], "a new waiting line")
        f.form.focus(f.at(0))
        f.window.type("bo")
        f.window.pressReturn()
        expectEqual(f.value(f.path), [bo, bo], "a pick on a line replaces it")
        let table = try LinkForm("lines", stored: [["sku": "a"]])
        defer { table.close() }
        table.form.focus(table.at(0, 1))
        table.window.type("an")
        table.window.pressReturn()
        expectEqual(table.value(table.path.index(0).key("owner")), ann)
    },
    test("a form read-only has no stop on a link, no list, and a click on its pill still goes to the note") {
        let log = RefusalLog()
        let f = try LinkForm("customer", stored: ann, readOnly: true, log: log)
        defer { f.close() }
        f.form.focusFirst()
        f.window.type("an")
        expect(f.list == nil)
        expectEqual(f.value(f.path), ann)
        let cell = f.form.rect(of: f.at(0, 0))
        f.form.press(at: CGPoint(x: cell.minX + 10, y: cell.midY))
        f.scheduler.advance(by: .zero)
        expectEqual(f.editor.selection, FieldFixtures.annLeeID)
        expect(log.refusals.isEmpty, "going changes nothing")
    },
    test("a pointer to a note that is gone is a dashed pill and not red; a pointer to one that is no longer a Person is red; a click on a dashed pill acts as one off it") {
        let f = try LinkForm("customer", stored: ann)
        defer { f.close() }
        f.editor.transact("Delete") { $0.delete([FieldFixtures.annLeeID]) }
        f.scheduler.advance(by: .zero)
        expectEqual(f.form.sheet.lines[0].cells[0].mark, .warning)
        expectEqual(f.form.sheet.lines[0].cells[0].shown, "Ann Lee", "the stored name")
        let cell = f.form.rect(of: f.at(0))
        f.form.press(at: CGPoint(x: cell.minX + 10, y: cell.midY))
        expect(f.list != nil, "a dashed pill is no pill face: the click opens the list")
        f.window.pressEscape()
        let g = try LinkForm("customer", stored: bo)
        defer { g.close() }
        g.editor.removeTypeLink(FieldFixtures.personID, from: FieldFixtures.boParkID)
        g.scheduler.advance(by: .zero)
        expectEqual(g.form.sheet.lines[0].cells[0].mark, .wrong)
    },
    test("drawing: a live pill draws its outline in the cell, a wrong one is red with the wave, a gone one is dashed and not red; the cell is as wide as its pill") {
        @MainActor func pixels(_ view: NSView, where match: (NSColor) -> Bool) -> Int {
            view.layoutSubtreeIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return 0 }
            view.cacheDisplay(in: view.bounds, to: rep)
            var count = 0
            for y in 0..<rep.pixelsHigh {
                for x in 0..<rep.pixelsWide {
                    guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.alphaComponent > 0.2 else { continue }
                    if match(color) { count += 1 }
                }
            }
            return count
        }
        let red: (NSColor) -> Bool = { $0.redComponent > 0.7 && $0.greenComponent < 0.45 && $0.blueComponent < 0.45 }
        let ink: (NSColor) -> Bool = { _ in true }
        let live = try LinkForm("customer", stored: ann)
        defer { live.close() }
        let empty = try LinkForm("customer")
        defer { empty.close() }
        expect(pixels(live.form, where: ink) > pixels(empty.form, where: ink), "a pill has more ink than the faint placeholder")
        expectEqual(pixels(live.form, where: red), 0)
        let wrong = try LinkForm("customer", stored: bo)
        defer { wrong.close() }
        wrong.editor.removeTypeLink(FieldFixtures.personID, from: FieldFixtures.boParkID)
        wrong.scheduler.advance(by: .zero)
        expect(pixels(wrong.form, where: red) > 0, "red")
        let missing = try LinkForm("customer", stored: ann)
        defer { missing.close() }
        missing.editor.transact("Delete") { $0.delete([FieldFixtures.annLeeID]) }
        missing.scheduler.advance(by: .zero)
        expectEqual(pixels(missing.form, where: red), 0, "a gone note is a warning: its dashed pill, nothing red")
        expect(pixels(missing.form, where: ink) > 0)
        let narrow = try LinkForm("customer", stored: link(to: FieldFixtures.annLeeID, String(repeating: "Ann ", count: 30)))
        defer { narrow.close() }
        expect(narrow.form.fittingSize(anchorWidth: 100, room: CGSize(width: 1000, height: 400)).width <= TypesStyle.formMaxWidth, "no wider than a card goes")
    },
])
