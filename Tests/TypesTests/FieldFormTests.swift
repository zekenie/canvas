import AppKit
import Canvas
import CanvasRPC
import CanvasTesting
import Foundation
import TestKit
import TextEditing
import Types

// The form's view in an unshown window: the proof of focus and Tab order, every key of rows-and-cards, what
// each keystroke writes, and the draft of a line the file does not hold. Keys go through `window.press`, which
// routes them to the first responder as AppKit does; a click is `form.activate`, a menu is caught by `menuPresenter`.

private let holder = #"""
{
  "type": "object",
  "properties": {
    "shipment": {
      "type": "object",
      "properties": {
        "note": { "type": "string" },
        "count": { "type": "number" },
        "due": { "type": "string", "format": "date" },
        "rush": { "type": "boolean" },
        "mode": { "enum": ["air", "sea"] },
        "to": { "$ref": "\#(FieldFixtures.uri(of: FieldFixtures.addressID))" },
        "tags": { "type": "array", "items": { "type": "string" } }
      }
    },
    "tags": { "type": "array", "items": { "type": "string" } },
    "counts": { "type": "array", "items": { "type": "number" } },
    "lines": {
      "type": "array",
      "items": { "type": "object", "properties": { "sku": { "type": "string" }, "qty": { "type": "integer" }, "ok": { "type": "boolean" }, "size": { "enum": ["S", "M"] } } }
    },
    "labels": { "type": "object", "additionalProperties": { "type": "string" } },
    "roles": { "type": "array", "items": { "enum": ["engineer", "designer", "manager"] }, "uniqueItems": true },
    "six": { "type": "array", "items": { "type": "object", "properties": { "a": { "type": "string" }, "b": { "type": "string" }, "c": { "type": "string" }, "d": { "type": "string" }, "e": { "type": "string" }, "f": { "type": "string" } } } },
    "grid": { "type": "array", "items": { "type": "object", "properties": { "a": { "type": "string" }, "b": { "type": "string" }, "c": { "type": "string" }, "d": { "type": "string" }, "e": { "type": "string" }, "f": { "type": "string" }, "g": { "type": "string" }, "h": { "type": "string" }, "i": { "type": "string" } } } },
    "payment": { "anyOf": [{ "type": "object", "properties": { "card": { "type": "string" } } }, { "type": "number" }] },
    "meta": { "anyOf": [{ "type": "object", "additionalProperties": { "type": "string" } }, { "type": "string" }] }
  }
}
"""#

/// A form in an unshown window over an instance of `holder`, its keys and its closings logged.
@MainActor private final class FormWindow {
    let editor: CanvasEditor
    let shape: ShapeID
    let window: NSWindow
    let form: FieldFormView
    var closings: [FieldFormView.Closing] = []
    var menus: [NSMenu] = []
    let field: String

    init(_ name: String, stored: JSONValue? = nil, mode: FieldFormMode = .values, readOnly: Bool = false, presentation: FieldFormContext.Presentation = .card,
         check: (@MainActor (AnyShapeRecord) -> FieldCheck)? = nil, log: RefusalLog? = nil, scheduler: ManualScheduler = ManualScheduler(), width: CGFloat = 300, height: CGFloat = 420) throws {
        field = name
        editor = try fieldEditor(scheduler: scheduler, more: log.map { [FreezingPlugin(log: $0)] } ?? [])
        let type = editor.addType(holder, title: "Holder")
        shape = editor.addInstance("Holder", of: [type])
        let book = try require(editor.fieldBook)
        let resolved = try require(book.fields(types: [type]).field(named: name))
        if let stored { editor.fieldWriter?.set(stored, at: FieldPath(field: name), of: shape) }
        if readOnly, log != nil { editor.freeze([shape]) }
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        form = FieldFormView(editor: editor, shape: shape, root: .field(path: FieldPath(field: name), field: resolved, kind: book.kind(of: resolved)), mode: mode,
                             isReadOnly: readOnly, presentation: presentation, cardKey: presentation == .card ? "card" : nil, check: check)
        form.frame = CGRect(x: 0, y: 0, width: width, height: height)
        window.contentView?.addSubview(form)
        form.onClose = { [weak self] closing in self?.closings.append(closing) }
        form.menuPresenter = { [weak self] menu, _ in self?.menus.append(menu) }
        window.makeFirstResponder(form)
    }

    var values: FieldValues { editor.fieldWriter?.values(of: shape) ?? FieldValues() }
    func value(_ path: FieldPath) -> JSONValue? { values.value(at: path) }
    var path: FieldPath { FieldPath(field: field) }
    var inEditor: Bool { window.firstResponder === form.cellEditor }
    var inForm: Bool { window.firstResponder === form }
    var stop: FieldStop? { form.focus }
    func tab() { window.press("\t", code: 48) }
    func backtab() { window.press("\u{19}", code: 48, modifiers: .shift) }
    func space() { window.press(" ", code: 49) }
    func up() { window.press("\u{F700}", code: 126) }
    func down() { window.press("\u{F701}", code: 125) }
    func left() { window.press("\u{F702}", code: 123) }
    func right() { window.press("\u{F703}", code: 124) }
    func at(_ line: Int, _ column: Int = 0) -> FieldStop { FieldStop(line: line, column: column) }
    func text(_ line: Int, _ cell: Int = 0) -> String { form.sheet.lines[line].cells[cell].shown }
    func close() { window.close() }
}

@MainActor let fieldFormTests = Suite("Field form", [
    test("rows: the caret in the first cell, Tab from row to row, onto a box and a row with more the form has the keyboard and nothing opens; Return goes down, or opens; Esc goes back, and from the top closes") {
        let f = try FormWindow("shipment")
        defer { f.close() }
        expectEqual(f.form.sheet.lines.map(\.name), ["note", "count", "due", "rush", "mode", "to", "tags"])
        f.form.focusFirst()
        expectEqual(f.stop, f.at(0))
        expect(f.inEditor, "the caret is in the first cell")
        f.tab()
        expectEqual(f.stop, f.at(1))
        expect(f.inEditor)
        f.tab(); f.tab()
        expectEqual(f.stop, f.at(3), "a box")
        expect(f.inForm, "the form has the keyboard on a box")
        f.tab()
        expectEqual(f.stop, f.at(4), "a choice")
        expect(f.inForm)
        f.tab()
        expectEqual(f.stop, f.at(5, -1), "a row with more is focused, not opened")
        expect(f.inForm)
        expectEqual(f.form.depth, 0)
        f.backtab()
        expectEqual(f.stop, f.at(4))
        f.backtab(); f.backtab(); f.backtab()
        expectEqual(f.stop, f.at(1))
        expect(f.inEditor)
        f.backtab()
        f.window.pressReturn()
        expectEqual(f.stop, f.at(1), "Return in a cell goes to the next row")
        f.tab(); f.tab(); f.tab(); f.tab()
        expectEqual(f.stop, f.at(5, -1))
        f.window.pressReturn()
        expectEqual(f.form.depth, 1, "Return on a row with more opens it")
        expectEqual(f.form.sheet.back, "‹ shipment")
        expectEqual(f.form.sheet.chip, FieldFixtures.addressID)
        expectEqual(f.stop, f.at(0), "its first row")
        f.window.pressEscape()
        expectEqual(f.form.depth, 0, "Esc goes back")
        expectEqual(f.stop, f.at(5, -1), "to the same stop")
        expectEqual(f.closings, [])
        f.window.pressEscape()
        expectEqual(f.closings, [.escaped])
    },
    test("Tab off the last stop and ⇧Tab off the first are asked of the host; inside a level they go back to the right stop") {
        let f = try FormWindow("shipment")
        defer { f.close() }
        f.form.focusFirst()
        f.backtab()
        expectEqual(f.closings, [.tabbed(forward: false)])
        f.form.focus(f.at(6, -1))
        f.tab()
        expectEqual(f.closings, [.tabbed(forward: false), .tabbed(forward: true)])
        f.form.focus(f.at(5, -1))
        f.window.pressReturn()
        expectEqual(f.form.depth, 1)
        f.backtab()
        expectEqual(f.form.depth, 0)
        expectEqual(f.stop, f.at(5, -1), "back to the stop it was opened from")
        f.window.pressReturn()
        f.tab(); f.tab()
        expectEqual(f.stop, f.at(2), "the last row of Address")
        f.tab()
        expectEqual(f.form.depth, 0)
        expectEqual(f.stop, f.at(6, -1), "Tab off the end goes to the stop after the one it was opened from")
        expectEqual(f.closings.count, 2, "nothing was asked of the host")
    },
    test("typing writes each keystroke; the editor keeps what was typed while the stored value is the number, and the cell reads it once the caret leaves; a date typed whole is stored as a date") {
        let f = try FormWindow("shipment")
        defer { f.close() }
        let shipment = f.path
        f.form.focusFirst()
        f.window.type("Leeds")
        expectEqual(f.value(shipment.key("note")), "Leeds")
        expectEqual(f.editor.document[f.shape]?[FieldValuesProperty.self]?.value(at: shipment.key("note")), "Leeds")
        f.window.type("!")
        expectEqual(f.value(shipment.key("note")), "Leeds!", "a keystroke is a commit")
        f.tab()
        f.window.type("9.50")
        expectEqual(f.value(shipment.key("count")), 9.5)
        expectEqual(f.form.cellEditor.string, "9.50", "the editor keeps what was typed")
        f.tab()
        expectEqual(f.text(1), "9.5", "the cell reads the stored value once the caret leaves")
        f.window.type("Mar 3, 2026")
        expectEqual(f.value(shipment.key("due")), "2026-03-03")
        f.tab()
        expectEqual(f.text(2), "Mar 3, 2026")
    },
    test("a list: typing in the waiting line appends and a new one waits; Return goes to the next line; Return on the blank last line asks to close; deleting a middle line's text drops the item and keeps the line") {
        let f = try FormWindow("tags")
        defer { f.close() }
        f.form.focusFirst()
        expectEqual(f.form.sheet.stops, [f.at(0)], "the waiting line alone")
        f.window.type("a")
        expectEqual(f.value(f.path), ["a"])
        expectEqual(f.form.sheet.lines.count, 2, "a new waiting line")
        f.window.pressReturn()
        expectEqual(f.stop, f.at(1))
        f.window.type("b")
        expectEqual(f.value(f.path), ["a", "b"])
        f.window.pressReturn()
        expectEqual(f.stop, f.at(2))
        f.window.pressReturn()
        expectEqual(f.closings, [.returned], "Return on a blank last line")
    },
    test("a line emptied in the middle keeps its place: the line after writes to its own index, typing in it again puts the item back, and Backspace on it takes it out") {
        let f = try FormWindow("tags", stored: ["a", "b", "c"])
        defer { f.close() }
        f.form.focus(f.at(1))
        f.window.pressDelete()
        expectEqual(f.value(f.path), ["a", "c"], "the item is out of the list")
        expectEqual(f.form.sheet.lines.count, 4, "and its line stays")
        expectEqual(f.text(1), "")
        f.window.type("x")
        expectEqual(f.value(f.path), ["a", "x", "c"], "the item put back in its place, the one after it untouched")
        f.window.pressDelete()
        expectEqual(f.value(f.path), ["a", "c"])
        f.tab()
        expectEqual(f.stop, f.at(2))
        f.window.type("!")
        expectEqual(f.value(f.path), ["a", "!"], "the line after writes to the right index")
        f.form.focus(f.at(1))
        f.window.type("y")
        f.window.pressDelete()
        f.window.pressDelete()
        expectEqual(f.form.sheet.lines.count, 3, "Backspace on the empty line removes it")
        expectEqual(f.stop, f.at(0), "the caret goes to the line before")
        expect(f.inEditor)
        expectEqual(f.form.cellEditor.selectedRange().location, 1, "at its end")
        f.form.focus(f.at(2))
        f.window.pressDelete()
        expectEqual(f.form.sheet.lines.count, 3, "nothing on the waiting line")
    },
    test("a held ⌘⌫ takes one line out of a list, not the lines the caret moves on to") {
        let f = try FormWindow("tags", stored: ["a", "b", "c", "d"])
        defer { f.close() }
        f.form.focus(f.at(2))
        KeyDriver(f.window).hold(Chord(.delete, .command), repeats: 4)
        f.window.settle()
        expectEqual(f.value(f.path), ["a", "b", "d"], "one press, one line")
    },
    test("a list written from elsewhere to another length loses its blank lines") {
        let f = try FormWindow("tags", stored: ["a", "b", "c"])
        defer { f.close() }
        f.form.focus(f.at(1))
        f.window.pressDelete()
        expectEqual(f.form.sheet.lines.count, 4)
        f.editor.fieldWriter?.set(["w", "x", "y", "z"], at: f.path, of: f.shape)
        expectEqual(f.form.sheet.lines.map { $0.cells[0].shown }, ["w", "x", "y", "z", ""])
        expect(f.form.sheet.lines.dropLast().allSatisfy { $0.cells[0].isStored })
    },
    test("a table: Tab goes cell to cell and off the last cell to the next line; typing in the waiting line stores an item with that member alone; a box and a choice's menu write") {
        let lines: JSONValue = [["sku": "Mug", "qty": 2, "ok": false, "size": "S"], ["sku": "Plate", "qty": 1]]
        let f = try FormWindow("lines", stored: lines)
        defer { f.close() }
        expectEqual(f.form.sheet.stops.count, 12, "four cells a line, the waiting line too")
        f.form.focusFirst()
        f.tab(); f.tab()
        expectEqual(f.stop, f.at(0, 2))
        expect(f.inForm, "a box")
        f.space()
        expectEqual(f.value(f.path.index(0).key("ok")), true)
        f.space()
        expectEqual(f.value(f.path.index(0).key("ok")), false)
        f.tab()
        expectEqual(f.stop, f.at(0, 3), "a choice")
        f.space()
        let menu = try require(f.menus.last)
        expectEqual(menu.outline, ["✓ S", "M", "None"])
        try menu.choose("M")
        expectEqual(f.value(f.path.index(0).key("size")), "M")
        f.space()
        try f.menus.last?.choose("None")
        expectEqual(f.value(f.path.index(0).key("size")), nil)
        f.tab()
        expectEqual(f.stop, f.at(1, 0), "off the last cell to the next line's first")
        f.form.focus(f.at(2, 1))
        f.window.type("5")
        expectEqual(f.value(f.path.index(2)), ["qty": 5], "an item with that member alone")
        expectEqual(f.form.sheet.lines.count, 4, "and a new waiting line")
        f.form.focus(f.at(0, 1))
        f.down()
        expectEqual(f.stop, f.at(1, 1), "Down keeps the column")
        f.up()
        expectEqual(f.stop, f.at(0, 1))
    },
    test("a table line emptied in the middle is put back in its place; Backspace in an empty line removes it") {
        let lines: JSONValue = [["sku": "a"], ["sku": "b"], ["sku": "c"]]
        let f = try FormWindow("lines", stored: lines)
        defer { f.close() }
        f.form.focus(f.at(1, 0))
        f.window.pressDelete()
        expectEqual(f.value(f.path), [["sku": "a"], ["sku": "c"]], "the item with nothing in it is out")
        expectEqual(f.form.sheet.lines.count, 4)
        f.window.type("x")
        expectEqual(f.value(f.path), [["sku": "a"], ["sku": "x"], ["sku": "c"]], "back in its place, the items after as they were")
        f.window.pressDelete()
        f.window.pressDelete()
        expectEqual(f.form.sheet.lines.count, 3)
        expectEqual(f.value(f.path), [["sku": "a"], ["sku": "c"]])
    },
    test("pairs: a name alone is not stored, with a value it is; Return after a value is on the next name; renaming moves the value; a name another has is kept, marked, and writes nothing; Backspace on an empty name removes the pair") {
        let f = try FormWindow("labels")
        defer { f.close() }
        f.form.focusFirst()
        f.window.type("size")
        expectEqual(f.value(f.path), nil, "a name alone is not stored")
        expectEqual(f.text(0, 0), "size")
        f.tab()
        f.window.type("L")
        expectEqual(f.value(f.path), ["size": "L"])
        expectEqual(f.form.sheet.lines.count, 2, "a waiting line after it")
        f.window.pressReturn()
        expectEqual(f.stop, f.at(1, 0), "after a value, the next name")
        f.window.type("w")
        f.window.pressReturn()
        expectEqual(f.stop, f.at(1, 1), "after a name, its value")
        f.form.focus(f.at(0, 0))
        f.window.type("weight")
        expectEqual(f.value(f.path), ["weight": "L"], "the value moves with the name")
        f.form.focus(f.at(1, 0))
        f.window.type("weight")
        expectEqual(f.value(f.path), ["weight": "L"], "a name another pair has writes nothing")
        expectEqual(f.form.sheet.lines[1].cells[0].mark, .wrong)
        f.tab()
        f.window.type("9")
        expectEqual(f.value(f.path), ["weight": "L"])
        f.form.focus(f.at(0, 0))
        f.window.pressDelete()
        expectEqual(f.value(f.path), nil)
        expectEqual(f.form.sheet.lines.count, 3, "its line stays, with its value, while there is a name to type")
        f.window.pressDelete()
        expectEqual(f.form.sheet.lines.count, 2, "Backspace on an empty name removes the pair")
    },
    test("an either of pairs and text with nothing stored: the pairs shown are typed as pairs, and picking the other branch and back drops the draft") {
        let f = try FormWindow("meta")
        defer { f.close() }
        expectEqual(f.form.sheet.layout, .pairs)
        f.form.focus(f.at(0, 0))
        f.window.type("size")
        f.tab()
        f.window.type("L")
        expectEqual(f.value(f.path), ["size": "L"], "an object of pairs, not a list item")
        f.form.focus(f.at(-1, 0))
        f.right()
        expectEqual(f.form.sheet.layout, .rows)
        expectEqual(f.text(0), "", "text over the object, empty")
        f.left()
        expectEqual(f.form.sheet.layout, .pairs)
        expectEqual(f.form.sheet.lines.map { $0.cells[0].shown }, ["size", ""])
    },
    test("pairs keep their lines while the form lives: a pair added after size stays last, and is first in a form made anew") {
        let f = try FormWindow("labels", stored: ["size": "L"])
        defer { f.close() }
        f.form.focus(f.at(1, 0))
        f.window.type("alpha")
        f.tab()
        f.window.type("x")
        expectEqual(f.value(f.path), ["size": "L", "alpha": "x"])
        expectEqual(f.form.sheet.lines.map { $0.cells[0].shown }, ["size", "alpha", ""])
        let anew = try FormWindow("labels", stored: ["size": "L", "alpha": "x"])
        defer { anew.close() }
        expectEqual(anew.form.sheet.lines.map { $0.cells[0].shown }, ["alpha", "size", ""])
    },
    test("several choices: Space ticks and the form is still there, Return ticks too, None clears") {
        let f = try FormWindow("roles")
        defer { f.close() }
        f.form.focusFirst()
        expectEqual(f.form.sheet.stops, (0...3).map { f.at($0, -1) })
        f.space()
        expectEqual(f.value(f.path), ["engineer"])
        f.down(); f.down()
        f.space()
        expectEqual(f.value(f.path), ["engineer", "manager"])
        expect(f.form.superview != nil && f.closings.isEmpty, "the card stays open")
        f.up()
        f.window.pressReturn()
        expectEqual(f.value(f.path), ["engineer", "designer", "manager"], "in the options' order")
        f.down(); f.down()
        expectEqual(f.stop, f.at(3, -1))
        f.space()
        expectEqual(f.value(f.path), nil)
    },
    test("either: Right on the branch names shows the other control and writes nothing; typing there replaces the value, a group branch as an object of that member alone") {
        let f = try FormWindow("payment")
        defer { f.close() }
        f.form.focusFirst()
        expectEqual(f.stop, FieldStop(line: -1, column: 0), "the branch names")
        expectEqual(f.form.sheet.branches, ["1 field", "Number"])
        f.right()
        expectEqual(f.form.sheet.branch, 1)
        expectEqual(f.value(f.path), nil, "nothing written")
        f.tab()
        expectEqual(f.stop, f.at(0))
        f.window.type("5")
        expectEqual(f.value(f.path), 5)
        f.form.focus(FieldStop(line: -1, column: 1))
        f.left()
        expectEqual(f.form.sheet.branch, 0)
        expectEqual(f.value(f.path), 5, "still the number")
        f.tab()
        f.window.type("visa")
        expectEqual(f.value(f.path), ["card": "visa"], "an object of the one member")
    },
    test("read-only: no caret, Tab still moves, Return opens a row with more; in a card a box and a choice are tries that shake the shape once each, in the panel and on a type's note nothing is refused") {
        let log = RefusalLog()
        let f = try FormWindow("shipment", stored: ["note": "n"], readOnly: true, log: log)
        defer { f.close() }
        f.form.focusFirst()
        expect(!f.inEditor, "no caret")
        expectEqual(f.stop, f.at(0))
        f.window.type("zz")
        expectEqual(f.value(f.path.key("note")), "n", "nothing changes")
        f.tab(); f.tab(); f.tab()
        expectEqual(f.stop, f.at(3))
        f.space()
        expectEqual(log.refusals, [[f.shape]])
        f.tab()
        f.space()
        expectEqual(log.refusals.count, 2, "a choice")
        f.window.pressReturn()
        expectEqual(log.refusals.count, 3, "Return on a choice")
        f.tab()
        f.window.pressReturn()
        expectEqual(f.form.depth, 1, "a row with more still opens")
        let panelLog = RefusalLog()
        let panel = try FormWindow("shipment", readOnly: true, presentation: .panel, log: panelLog)
        defer { panel.close() }
        panel.form.focusFirst()
        panel.space()
        let rush = try require(panel.form.sheet.stops.first { panel.form.sheet.lines[$0.line].name == "rush" })
        panel.form.focus(rush)
        panel.space()
        expect(panelLog.refusals.isEmpty, "in the panel nothing shakes")
        let kindsLog = RefusalLog()
        let kinds = try FormWindow("shipment", mode: .kinds, readOnly: true, log: kindsLog)
        defer { kinds.close() }
        kinds.form.focusFirst()
        kinds.space()
        kinds.window.pressReturn()
        expectEqual(kinds.form.depth, 1)
        expect(kindsLog.refusals.isEmpty, "on a type's note nothing is refused")
    },
    test("on a type's note: Return on › goes in, and no stop writes") {
        let f = try FormWindow("shipment", mode: .kinds, readOnly: true)
        defer { f.close() }
        expectEqual(f.form.sheet.stops, [f.at(5, -1)])
        f.form.focusFirst()
        f.window.type("abc")
        f.space()
        f.window.pressReturn()
        expectEqual(f.form.depth, 1)
        expectEqual(f.form.sheet.back, "‹ shipment")
        expectEqual(f.values, FieldValues(), "nothing written")
        f.window.pressEscape()
        expectEqual(f.form.depth, 0)
    },
    test("the cell with the caret tells the check it is being typed in, and says it is not as it loses the caret and as the form goes") {
        let f = try FormWindow("shipment")
        defer { f.close() }
        let checks = try require(f.editor.fieldChecks)
        f.form.focusFirst()
        expectEqual(checks.typing?.shape, f.shape)
        expectEqual(checks.typing?.path, f.path.key("note"))
        f.tab()
        expectEqual(checks.typing?.path, f.path.key("count"))
        f.tab(); f.tab()
        expectEqual(f.stop, f.at(3))
        expect(checks.typing == nil, "a box has no caret")
        f.form.focus(f.at(0))
        expect(checks.typing != nil)
        f.form.removeFromSuperview()
        expect(checks.typing == nil, "the form is gone")
    },
    test("a text cell has no autocorrect, no smart quotes or dashes, no spelling marks; a quote is stored as typed; a pasted line break is kept and the cell is one line") {
        let f = try FormWindow("shipment")
        defer { f.close() }
        let cell = f.form.cellEditor
        expect(!cell.isAutomaticQuoteSubstitutionEnabled && !cell.isAutomaticDashSubstitutionEnabled)
        expect(!cell.isAutomaticTextReplacementEnabled && !cell.isAutomaticSpellingCorrectionEnabled)
        expect(!cell.isContinuousSpellCheckingEnabled && !cell.isGrammarCheckingEnabled)
        f.form.focusFirst()
        f.window.type("\"")
        expectEqual(f.value(f.path.key("note")), "\"")
        cell.selectAll(nil)
        cell.insertText("a\nb", replacementRange: NSRange(location: NSNotFound, length: 0))
        expectEqual(f.value(f.path.key("note")), "a\nb", "the line break is kept")
        expectEqual(cell.textContainer?.maximumNumberOfLines, 1, "the cell shows its first line")
    },
    test("the text's own undo is one cell's: it is forgotten as the editor moves, and undoing writes the text back") {
        let f = try FormWindow("shipment")
        defer { f.close() }
        f.form.focusFirst()
        f.window.type("abc")
        f.tab()
        expect(f.form.cellEditor.undoManager?.canUndo != true, "nothing to undo in the next cell")
        f.window.type("12")
        expectEqual(f.value(f.path.key("count")), 12)
        f.form.cellEditor.undoManager?.undo()
        f.form.cellEditor.didChangeText()
        expect(f.value(f.path.key("count")) != 12, "what it puts back is written as typing is")
        expectEqual(f.value(f.path.key("note")), "abc", "the other cell is untouched")
    },
    test("a value written from elsewhere while the caret is in its cell shows in the editor; one written to another cell leaves the editor's text") {
        let f = try FormWindow("shipment")
        defer { f.close() }
        f.form.focusFirst()
        f.window.type("ab")
        f.editor.fieldWriter?.set(3, at: f.path.key("count"), of: f.shape)
        expectEqual(f.form.cellEditor.string, "ab")
        expectEqual(f.text(1), "3", "the other cell shows it")
        f.editor.fieldWriter?.set("zzz", at: f.path.key("note"), of: f.shape)
        expectEqual(f.form.cellEditor.string, "zzz")
    },
    test("a right-click's menu on a line of a list, a table or pairs is Remove and removes it; none on rows, the waiting line, or read-only") {
        let list = try FormWindow("tags", stored: ["a", "b"])
        defer { list.close() }
        expectEqual(list.form.contextMenu(for: list.at(0))?.outline, ["Remove"])
        expect(list.form.contextMenu(for: list.at(2)) == nil, "the waiting line")
        try list.form.contextMenu(for: list.at(0))?.choose("Remove")
        expectEqual(list.value(list.path), ["b"])
        expectEqual(list.form.sheet.lines.count, 2)
        let table = try FormWindow("lines", stored: [["sku": "a"], ["sku": "b"]])
        defer { table.close() }
        try table.form.contextMenu(for: table.at(1, 2))?.choose("Remove")
        expectEqual(table.value(table.path), [["sku": "a"]])
        let pairs = try FormWindow("labels", stored: ["x": "1", "y": "2"])
        defer { pairs.close() }
        try pairs.form.contextMenu(for: pairs.at(0, 1))?.choose("Remove")
        expectEqual(pairs.value(pairs.path), ["y": "2"])
        let rows = try FormWindow("shipment")
        defer { rows.close() }
        expect(rows.form.contextMenu(for: rows.at(0)) == nil, "rows")
        let locked = try FormWindow("tags", stored: ["a"], readOnly: true)
        defer { locked.close() }
        expect(locked.form.contextMenu(for: locked.at(0)) == nil, "read-only")
    },
    test("sizes: 240 at least and 480 at most whatever the row; six columns are 384, nine 480 with the lines wider than the card; forty lines are 360 tall with the focused line in view; the fold is 320") {
        let room = CGSize(width: 1000, height: 1000)
        let tags = try FormWindow("tags", stored: ["a"])
        defer { tags.close() }
        expectEqual(tags.form.fittingSize(anchorWidth: 100, room: room).width, 240)
        expectEqual(tags.form.fittingSize(anchorWidth: 900, room: room).width, 240, "the row's width sets none")
        expectEqual(tags.form.fittingSize(anchorWidth: 100, room: CGSize(width: 200, height: 1000)).width, 200, "never wider than the room")
        let six = try FormWindow("six", stored: [["a": "x"]])
        defer { six.close() }
        expectEqual(six.form.fittingSize(anchorWidth: 240, room: room).width, 384)
        let nine = try FormWindow("grid", stored: [["a": "x"]])
        defer { nine.close() }
        expectEqual(nine.form.fittingSize(anchorWidth: 240, room: room).width, 480)
        expect(nine.form.gridWidth > 480, "the lines scroll sideways")
        let forty = try FormWindow("tags", stored: .array((1...40).map { .string("item \($0)") }))
        defer { forty.close() }
        let size = forty.form.fittingSize(anchorWidth: 240, room: room)
        expectEqual(size.height, 360)
        forty.form.frame = CGRect(origin: .zero, size: size)
        forty.form.layoutSubtreeIfNeeded()
        forty.form.focus(forty.at(39))
        let rect = forty.form.rect(of: forty.at(39))
        expect(rect.maxY <= size.height && rect.minY >= 0, "the focused line is scrolled into view: \(rect)")
        expectEqual(forty.form.fittingSize(anchorWidth: 240, room: CGSize(width: 1000, height: 200)).height, 200, "cut to the room")
        let editor = try fieldEditor()
        editor.addFieldTypes([FieldFixtures.wide(30)])
        let id = editor.addInstance("", of: [FieldFixtures.wideID])
        let fields = try require(editor.fieldBook).fields(types: [FieldFixtures.wideID]).fields
        let fold = FieldFormView(editor: editor, shape: id, root: .fold(fields), mode: .values, isReadOnly: false, presentation: .card, cardKey: "card")
        expectEqual(fold.fittingSize(anchorWidth: 240, room: room).height, 320, "the fold's card")
        expectEqual(fold.sheet.chip, FieldFixtures.wideID, "one type brought every row")
    },
    test("drawing: a wrong cell has red ink and a plain one none; a table's names stay at the top as the lines scroll") {
        let problem = FieldProblem(path: FieldPath(field: "shipment").key("note"), kind: .wrong, keyword: "x", place: [], message: "")
        let wrong = try FormWindow("shipment", stored: ["note": "abc"], check: { _ in FieldCheck(problems: [problem]) })
        defer { wrong.close() }
        let plain = try FormWindow("shipment", stored: ["note": "abc"])
        defer { plain.close() }
        @MainActor func redPixels(_ view: NSView) -> Int {
            view.layoutSubtreeIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return 0 }
            view.cacheDisplay(in: view.bounds, to: rep)
            var count = 0
            for y in 0..<rep.pixelsHigh {
                for x in 0..<rep.pixelsWide {
                    guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.alphaComponent > 0.2 else { continue }
                    if color.redComponent > 0.7, color.greenComponent < 0.45, color.blueComponent < 0.45 { count += 1 }
                }
            }
            return count
        }
        expect(redPixels(wrong.form) > 0, "red ink")
        expectEqual(redPixels(plain.form), 0)
        let table = try FormWindow("lines", stored: .array((1...40).map { ["sku": .string("s\($0)")] }), height: 200)
        defer { table.close() }
        table.form.focus(table.at(39, 0))
        expect(table.form.headerHeight >= 20, "the names are above the scrolled lines, in the header")
        let rect = table.form.rect(of: table.at(39, 0))
        expect(rect.minY >= table.form.headerHeight, "the lines scroll under them: \(rect)")
    },
    test("a change to a type reaches a form that is showing it a turn later; a commit to the shape reaches it at once") {
        let scheduler = ManualScheduler()
        let f = try FormWindow("shipment", scheduler: scheduler)
        defer { f.close() }
        f.form.focus(f.at(5, -1))
        f.window.pressReturn()
        expectEqual(f.form.sheet.lines.map(\.name), ["street", "city", "postcode"])
        let address = """
        {"type": "object", "properties": {"street": {"type": "string"}, "city": {"type": "string"}, "postcode": {"type": "string"}, "country": {"type": "string"}}}
        """
        f.editor.transact("Write") { $0.update(FieldFixtures.addressID) { $0[TypeSchemaProperty.self] = SchemaText(address) } }
        scheduler.advance(by: .zero)
        expectEqual(f.form.sheet.lines.map(\.name), ["street", "city", "postcode", "country"], "a member added to the type")
        f.editor.fieldWriter?.set("Leeds", at: f.path.key("to").key("city"), of: f.shape)
        expectEqual(f.text(1), "Leeds", "a commit to the shape, at once")
        f.editor.transact("Write") { $0.update(FieldFixtures.addressID) { $0[TypeSchemaProperty.self] = SchemaText(#"{"type": "object", "properties": {"street": {"type": "string"}}}"#) } }
        scheduler.advance(by: .zero)
        expectEqual(f.form.sheet.lines.map(\.name), ["street"])
    },
])

// The form by keys alone, through the key-walk harness (keyboard navigation's P3 to P9): Tab through every stop of a card and of a
// table, ⇧Tab undoing each, what a stop that is no text does with a key, Escape's depth, ⌘↩, removing a line by key, ← and → on a
// line, and what VoiceOver reads at each stop.

extension FormWindow {
    func walk() -> KeyWalk {
        KeyWalk(window, editor: editor, readers: [.form({ [unowned self] in form })], settle: .runLoop)
    }
}

@MainActor let fieldFormKeysTests = Suite("Field form, by keys", [
    test("a card of rows: Tab visits every stop in reading order and ⇧Tab undoes each; Tab off the last and ⇧Tab off the first leave the card; each stop shows, named") {
        let f = try FormWindow("shipment")
        defer { f.close() }
        f.form.focusFirst()
        let walk = f.walk()
        let ids = formStopIDs(f.form)
        expectEqual(ids.count, 7)
        walk.expectCardStops(ids)
        walk.press(.tab)
        expectEqual(f.closings, [.tabbed(forward: true)])
        f.form.focusFirst()
        walk.press(.backTab)
        expectEqual(f.closings.last, .tabbed(forward: false))
        walk.expectShows(ids.map { Focus(surface: "card", element: String($0.dropFirst(5))) })
    },
    test("a stop that is no text takes no letter and no Delete: a box, a choice and a row with more change nothing, and Tab and ⇧Tab move on") {
        let f = try FormWindow("shipment")
        defer { f.close() }
        f.form.focusFirst()
        let walk = f.walk()
        let before = f.editor.document
        let stops = ["d0/3.0", "d0/4.0", "d0/5.-1"].map { Focus(surface: "card", element: $0) }
        walk.expectInert(Chord.inert, at: stops, escapes: false)
        expectEqual(f.editor.document, before)
        expectEqual(f.closings, [])
    },
    test("a level opened in a card: Tab runs its stops and out of it to the stop after its opener; ⇧Tab then lands on the opener (the one exception to the exact way back); Escape goes up one level at a time and closes at the top") {
        let f = try FormWindow("shipment")
        defer { f.close() }
        let walk = f.walk()
        f.form.focus(f.at(5, -1))
        walk.press(.return)
        expectEqual(f.form.depth, 1)
        let level = formStopIDs(f.form)
        expectEqual(level.count, 3)
        walk.expectCardStops(level)
        expectEqual(walk.press(.tab).id, "card/d0/6.-1", "out of the level, onto the stop after the one that opened it")
        expectEqual(f.form.depth, 0)
        expectEqual(walk.press(.backTab).id, "card/d0/5.-1", "⇧Tab lands on the opener, not on the level's last stop")
        walk.press(.return)
        expectEqual(f.form.depth, 1)
        walk.press(.escape)
        expectEqual(f.form.depth, 0)
        expectEqual(walk.focus.id, "card/d0/5.-1", "Escape lands on the opener")
        expectEqual(f.closings, [])
        walk.press(.escape)
        expectEqual(f.closings, [.escaped], "and from the top it closes")
    },
    test("⌘↩ in a cell at any depth does what Escape does at the top: the card closes; in the panel it closes nothing") {
        let f = try FormWindow("shipment")
        defer { f.close() }
        let walk = f.walk()
        f.form.focus(f.at(5, -1))
        walk.press(.return)
        expectEqual(f.form.depth, 1)
        f.window.type("Mill St")
        walk.press(.commandReturn)
        expectEqual(f.closings, [.escaped])
        expectEqual(f.form.depth, 0)
        expectEqual(f.value(f.path.key("to").key("street")), "Mill St", "what was typed is kept")
        f.form.focus(f.at(3, 0))
        walk.press(.commandReturn)
        expectEqual(f.closings, [.escaped, .escaped], "from a box too")
        let panel = try FormWindow("shipment", presentation: .panel)
        defer { panel.close() }
        panel.form.focusFirst()
        panel.walk().press(.commandReturn)
        expectEqual(panel.closings, [])
    },
    test("← and → on a stop that is no text go to the stop before and after on the line and stop at its ends") {
        let lines: JSONValue = [["sku": "Mug", "qty": 2, "ok": false, "size": "S"]]
        let f = try FormWindow("lines", stored: lines)
        defer { f.close() }
        let walk = f.walk()
        f.form.focus(f.at(0, 2))
        walk.press(.right)
        expectEqual(f.stop, f.at(0, 3))
        walk.press(.right)
        expectEqual(f.stop, f.at(0, 3), "the end of the line")
        walk.press(.left)
        expectEqual(f.stop, f.at(0, 2))
        walk.press(.left)
        expectEqual(f.stop, f.at(0, 1), "onto a text cell")
        walk.press(.left)
        expectEqual(f.stop, f.at(0, 1), "in a cell ← is the text's")
    },
    test("Delete on a stop that is no text takes its line out of a table in one step; ⌘⌫ in a cell with content does too; the waiting line and rows keep theirs") {
        let lines: JSONValue = [["sku": "Mug", "qty": 2, "ok": true, "size": "S"], ["sku": "Plate", "qty": 1, "ok": false, "size": "M"], ["sku": "Cup"]]
        let f = try FormWindow("lines", stored: lines)
        defer { f.close() }
        let walk = f.walk()
        @MainActor func skus() -> [String] { (f.value(f.path)?.arrayValue ?? []).compactMap { $0.objectValue?["sku"]?.stringValue } }
        f.form.focus(f.at(0, 2))
        expect(f.window.firstResponder === f.form, "a box has the keyboard itself")
        walk.press(.delete)
        expectEqual(skus(), ["Plate", "Cup"])
        f.editor.undo()
        expectEqual(skus(), ["Mug", "Plate", "Cup"], "one Undo brings it back")
        f.form.reload()
        f.form.focus(f.at(1, 0))
        expect(f.inEditor)
        expectEqual(f.form.cellEditor.string, "Plate")
        walk.press(Chord(Key.delete, .command))
        expectEqual(skus(), ["Mug", "Cup"])
        f.editor.undo()
        expectEqual(skus(), ["Mug", "Plate", "Cup"])
        f.form.reload()
        let waiting = f.form.sheet.lines.count - 1
        let before = f.editor.document
        f.form.focus(f.at(waiting, 0))
        walk.press(Chord(Key.delete, .command))
        walk.press(.delete)
        expectEqual(f.editor.document, before, "the waiting line cannot go")
        let rows = try FormWindow("shipment")
        defer { rows.close() }
        rows.form.focus(rows.at(3, 0))
        let rowsBefore = rows.editor.document
        rows.walk().press(.delete)
        expectEqual(rows.editor.document, rowsBefore, "a row is not a line of a list")
    },
    test("VoiceOver: the form is a group named for the shape, its children are the stops in Tab's order with a role by control, a label from the field and a value from the cell, and the stop with the keyboard is focused") {
        let f = try FormWindow("shipment", stored: ["note": "hello", "rush": true, "mode": "sea"])
        defer { f.close() }
        f.form.focusFirst()
        expectEqual(f.form.accessibilityRole(), .group)
        expectEqual(f.form.accessibilityLabel(), "Fields", "an untitled shape")
        // The stop with the caret is the cell editor over it, the object VoiceOver's focus is; the others are elements.
        let all = f.form.accessibilityChildren() ?? []
        expectEqual(all.count, f.form.sheet.stops.count)
        expect(all.first as AnyObject === f.form.cellEditor, "the first stop has the caret: its child is the editor over it")
        expectEqual(f.form.cellEditor.accessibilityLabel(), "note", "the editor is named for the cell it is over")
        expectEqual(f.form.cellEditor.string, "hello")
        let children = all.dropFirst().compactMap { $0 as? NSAccessibilityElement }
        expectEqual(children.count, all.count - 1)
        expectEqual(children.map { $0.accessibilityRole() }, [.textField, .textField, .checkBox, .popUpButton, .button, .button])
        expectEqual(children.map { $0.accessibilityLabel() }, ["count", "due", "rush", "mode", "to", "tags"])
        expectEqual(children[2].accessibilityValue() as? Int, 1)
        expectEqual(children[3].accessibilityValue() as? String, "sea")
        expect(children.allSatisfy { $0.accessibilityFrame().height > 0 })
        f.form.focus(f.at(3, 0))
        expectEqual((f.form.accessibilityFocusedUIElement as? NSAccessibilityElement)?.accessibilityLabel(), "rush")
        expect(children[2].accessibilityPerformPress(), "pressing toggles it")
        expectEqual(f.value(f.path.key("rush")), false)
    },
])
