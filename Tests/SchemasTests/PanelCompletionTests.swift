import AppKit
import Canvas
import CanvasTesting
import DetailPanel
import Foundation
import LanguageModels
import Schemas
import TestKit

// The card's JSON completed in its panel, as a person does it: ⌃Space, what's typed, Return. The
// engine and its candidates are CompletionTests'; the keys and the list are DetailPanel's.

extension SchemaPanelWindow {
    /// The JSON's list, while it's open, and what it lists, top to bottom.
    var completions: CaretListWindow? { (code as? DetailTextView)?.caretListWindow }
    var listed: [CaretListItem] { completions?.list.rows.compactMap(\.item) ?? [] }
    var highlighted: String? { completions?.list.highlightedItem?.title }

    func controlSpace() { window.press(" ", code: 49, modifiers: .control) }
    func left() { window.press("\u{F702}", code: 123, modifiers: [.numericPad, .function]) }
    /// ⌘↩, to the window's key equivalents first, as the app hands it.
    func commandReturn() {
        let event = window.keyEvent("\r", code: 36, modifiers: .command)
        if !window.performKeyEquivalent(with: event) { window.sendEvent(event) }
    }

    /// A new property's schema typed into the starter, `type` picked there with ⌃Space: the list
    /// open again, for the type's name, over a schema that's JSON already (`"type": ""`).
    func pickType() throws -> ShapeID {
        let id = show(blankCard)
        let code = try require(self.code)
        focus(code, caret: (SchemaCard.starter as NSString).range(of: "{}").location + 1)
        window.type(#""name": {}"#)
        left()
        controlSpace()
        window.type("ty")
        window.pressReturn()
        expect(code.string.contains(#"{"name": {"type": ""}}"#), code.string)
        expect(!listed.isEmpty, "open again")
        return id
    }
}

/// The meta-schema's description of a keyword.
private func described(_ keyword: String) -> String? { MetaSchema.root["properties"]?[keyword]?["description"]?.string }

@MainActor let panelCompletionTests = Suite("Schema card completions", [
    test("in the starter schema, ⌃Space where a new property's schema goes offers JSON Schema's keywords, each with its description") {
        let panel = try SchemaPanelWindow()
        _ = panel.show(blankCard)
        let code = try require(panel.code)
        panel.focus(code, caret: (SchemaCard.starter as NSString).range(of: "{}").location + 1)
        panel.window.type(#""name": {}"#)
        panel.left()
        panel.controlSpace()
        let listed = panel.listed
        expectEqual(listed.prefix(4).map(\.title), ["title", "description", "type", "properties"])
        expectEqual(listed.first?.detail, "Short name for people")
        expect(listed.count > 20, "\(listed.count) keywords")
        for item in listed { expectEqual(item.detail, described(item.title), item.title) }
        expect(!listed.contains { $0.title == "$vocabulary" }, "only a root has it")
        expectEqual(panel.highlighted, "title")
    },
    test("pick type and the list opens again with the type names; pick string: the card's schema is the text, one step, Change JSON, and nothing's asked before a commit") {
        let panel = try SchemaPanelWindow()
        let id = panel.show(blankCard)
        let code = try require(panel.code)
        panel.focus(code, caret: (SchemaCard.starter as NSString).range(of: "{}").location + 1)
        panel.window.type(#""name": {}"#)
        panel.left()
        panel.controlSpace()
        panel.window.type("ty")
        expectEqual(panel.highlighted, "type")
        panel.window.pressReturn()
        expectEqual(code.string, "{\n  \"type\": \"object\",\n  \"properties\": {\"name\": {\"type\": \"\"}}\n}")
        expectEqual(panel.listed.map(\.title), ["string", "number", "integer", "boolean", "object", "array", "null"], "open again, in its quotes")
        expectEqual(panel.listed.first?.detail, "Text")
        panel.window.pressReturn()
        let picked = "{\n  \"type\": \"object\",\n  \"properties\": {\"name\": {\"type\": \"string\"}}\n}"
        expectEqual(code.string, picked)
        expect(panel.completions == nil)
        expectEqual(panel.card(id)?.schema, picked)
        expectEqual(panel.editor.undoHistory.undoName, "Change JSON")
        panel.window.settle()
        expectEqual(panel.model.requests.count, 0, "a pick is typing: the sync waits for a commit")
        panel.editor.undo()
        expectEqual(panel.card(id)?.schema, SchemaCard.starter, "the typing and both picks, one step")
    },
    test("a keyword picked after a member with no comma after it brings the comma, in the same edit") {
        let panel = try SchemaPanelWindow()
        let text = "{\n  \"type\": \"string\"\n  \n}"
        let id = panel.show(card(text))
        let code = try require(panel.code)
        panel.focus(code, caret: (text as NSString).range(of: "\n  \n").location + 3)
        panel.window.type("\"fo")
        panel.window.settle()       // typing's own step of the text's undo
        panel.controlSpace()
        expectEqual(panel.highlighted, "format")
        panel.window.pressReturn()
        let picked = "{\n  \"type\": \"string\",\n  \"format\": \"\"\n}"
        expectEqual(code.string, picked)
        expectEqual(panel.card(id)?.schema, picked)
        expectEqual(panel.listed.prefix(3).map(\.title), ["date-time", "date", "time"], "format's values, open again")
        panel.window.pressEscape()
        panel.window.settle()
        try require(code.undoManager).undo()
        expectEqual(code.string, "{\n  \"type\": \"string\"\n  \"fo\n}", "one undo takes back the comma and the key together")
    },
    test("while the list is open the sync's idle wait waits too: a pick that opens it again asks nothing until the list closes, and then idleDelay more") {
        let scheduler = ManualScheduler()
        let panel = try SchemaPanelWindow(scheduler: scheduler)
        _ = try panel.pickType()
        scheduler.advance(by: SchemaSync.idleDelay * 3)
        panel.window.settle()
        expectEqual(panel.model.requests.count, 0, "the person is still choosing")
        expect(panel.completions != nil)
        panel.window.pressReturn()       // string
        expect(panel.completions == nil)
        scheduler.advance(by: SchemaSync.idleDelay - .milliseconds(1))
        panel.window.settle()
        expectEqual(panel.model.requests.count, 0)
        scheduler.advance(by: .milliseconds(1))
        spinRunLoop(until: { panel.model.requests.count == 1 })
        let asked = panel.model.requests.first?.messages.last?.text ?? ""
        expect(asked.contains(#"{"name": {"type": "string"}}"#), "asked once, with what was picked: \(asked)")

        let closed = try SchemaPanelWindow(scheduler: ManualScheduler())
        let manual = try require(closed.editor.scheduler as? ManualScheduler)
        _ = try closed.pickType()
        closed.window.pressEscape()
        expect(closed.completions == nil)
        manual.advance(by: SchemaSync.idleDelay)
        spinRunLoop(until: { closed.model.requests.count == 1 })
    },
    test("⌘↩ with the list open closes it and syncs at once, as it does with the list closed") {
        let panel = try SchemaPanelWindow(scheduler: ManualScheduler())
        panel.model.holdsAnswers = true
        let id = try panel.pickType()
        panel.commandReturn()
        expect(panel.completions == nil)
        spinRunLoop(until: { panel.model.waiting == 1 })
        expectEqual(panel.model.requests.count, 1)
        expectEqual(panel.editor.schemaSync?.status(of: id), .updating(.prompt), "the description, from the schema")
        expect(panel.window.firstResponder === panel.code, "the JSON keeps the keyboard")
        panel.model.release()
    },
    test("while the model writes the schema, ⌃Space opens nothing in it; once it's written, it does") {
        let panel = try SchemaPanelWindow()
        _ = panel.show(blankCard)
        panel.model.holdsAnswers = true
        panel.model.queue(petSchema)
        panel.focus(try require(panel.prompt))
        panel.window.type("a pet in my household")
        panel.window.pressReturn()
        spinRunLoop(until: { panel.model.waiting == 1 })
        panel.window.spin { panel.code?.isEditable == false }
        let code = try require(panel.code)
        panel.focus(code, caret: 1)
        panel.controlSpace()
        expect(panel.completions == nil && (code as? DetailTextView)?.holdsKeys == false)
        expectEqual(code.string, SchemaCard.starter)
        panel.model.release()
        panel.window.spin { panel.code?.isEditable == true && panel.code?.string == petSchema }
        panel.focus(code, caret: 1)
        panel.controlSpace()
        expect(panel.completions != nil)
    },
])
