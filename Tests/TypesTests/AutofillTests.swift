import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Colors
import DetailPanel
import Foundation
import LanguageModels
import Selection
import TestKit
import Types
import Validation

// Whether a shape fills its fields from its words: a type's `$autofill` and the type's own `autofill` kept saying one
// thing, what a shape takes from its types, and the panel's box.

private typealias Directive = TypeAutofillDirective

/// The starter saying its notes don't fill, as the rule writes it into it.
private let quietStarter = """
{
  "type": "object",
  "properties": {
    "$autofill": {"const": false}
  }
}
"""

extension CanvasEditor {
    fileprivate func autofill(_ id: ShapeID) -> Bool? { document[id]?[AutofillProperty.self] }
    fileprivate func autofills(_ id: ShapeID) -> Bool? { document[id].flatMap { types?.autofills($0) } }
}

@MainActor let autofillDirectiveTests = Suite("Whether a type's notes fill, in its schema", [
    test("a schema says true, false, nothing, or something that isn't either; nothing while it isn't a JSON object") {
        expectEqual(Directive.reading(of: quietStarter), .autofills(false))
        expectEqual(Directive.reading(of: #"{"properties": {"$autofill": {"const": true}}}"#), .autofills(true))
        expectEqual(Directive.reading(of: TypeSchemaProperty.starter), Directive.Reading.none)
        expectEqual(Directive.reading(of: #"{"properties": {"$autofill": false}}"#), .notABool, "a bare false")
        expectEqual(Directive.reading(of: #"{"properties": {"$autofill": {"const": "no"}}}"#), .notABool)
        expectEqual(Directive.reading(of: #"{"properties": {"g": {"properties": {"$autofill": {"const": false}}}}}"#), Directive.Reading.none, "a group's member is a field's")
        expectEqual(Directive.reading(of: #"{"properties": {"#), nil)
    },
    test("it is written into a text as typed: put first in properties, its const replaced, taken out with its comma") {
        expectEqual(Directive.text(TypeSchemaProperty.starter, saying: false), quietStarter)
        expectEqual(Directive.text(quietStarter, saying: true), quietStarter.replacingOccurrences(of: "false", with: "true"))
        expectEqual(Directive.text(quietStarter, saying: false), quietStarter, "already says it")
        expectEqual(Directive.text(quietStarter, saying: nil), TypeSchemaProperty.starter)
        expectEqual(Directive.text(#"{"properties": {"a": {}}}"#, saying: false), #"{"properties": {"$autofill": {"const": false}, "a": {}}}"#)
        expectEqual(Directive.text(#"{"properties": {"#, saying: false), nil, "a text being typed")
    },
    test("a schema written whole keeps $color and $autofill unless it says them; the model sees neither; a change to them alone is none") {
        let held = #"{"properties": {"$color": {"const": "teal"}, "$autofill": {"const": false}, "a": {}}}"#
        let carried = HeldDirectives.carried(from: held, into: #"{"properties": {"b": {}}}"#)
        expectEqual(Directive.reading(of: carried), .autofills(false))
        expectEqual(TypeColorDirective.reading(of: carried), .color(.teal))
        expectEqual(HeldDirectives.carried(from: held, into: #"{"properties": {"$autofill": {"const": true}}}"#),
                    #"{"properties": {"$color": {"const": "teal"}, "$autofill": {"const": true}}}"#, "it says one, and keeps the other")
        expectEqual(HeldDirectives.stripped(held), #"{"properties": {"a": {}}}"#)
        expect(HeldDirectives.sameButHeld(held, #"{"properties": {"a": {}}}"#))
        expect(!HeldDirectives.sameButHeld(held, #"{"properties": {"b": {}}}"#))
    },
])

@MainActor let autofillStepTests = Suite("What a type and its shapes say of filling", [
    test("a type told its notes don't fill has it written in its JSON in the same step; told they do, it comes out; undo puts both back") {
        let editor = try typeEditor()
        let fill = try require(editor.fieldFill)
        let feature = editor.addType(TypeSchemaProperty.starter, title: "Feature")
        fill.setAutofill(false, of: feature)
        expectEqual(editor.schema(feature), quietStarter)
        expectEqual(editor.autofill(feature), false)
        expectEqual(editor.undoHistory.undoName, FieldFill.switchStep)
        fill.setAutofill(true, of: feature)
        expectEqual(editor.schema(feature), TypeSchemaProperty.starter, "on is what it takes with nothing said")
        expectEqual(editor.autofill(feature), nil)
        editor.undo()
        expectEqual(editor.schema(feature), quietStarter)
        expectEqual(editor.autofill(feature), false)
    },
    test("an $autofill written in the JSON is the type's say; taken out, it goes; one that isn't true or false says nothing and warns") {
        let editor = try typeEditor()
        let feature = editor.addType(TypeSchemaProperty.starter, title: "Feature")
        editor.transact("Change JSON") { $0.update(feature) { $0[TypeSchemaProperty.self] = SchemaText(quietStarter) } }
        expectEqual(editor.autofill(feature), false)
        editor.transact("Change JSON") { $0.update(feature) { $0[TypeSchemaProperty.self] = SchemaText(#"{"properties": {"$autofill": "no"}}"#) } }
        expectEqual(editor.autofill(feature), false, "a say that isn't one changes nothing")
        expect(editor.issues(feature).map(\.message).contains("“$autofill” isn’t true or false."), "\(editor.issues(feature).map(\.message))")
        editor.transact("Change JSON") { $0.update(feature) { $0[TypeSchemaProperty.self] = SchemaText(TypeSchemaProperty.starter) } }
        expectEqual(editor.autofill(feature), nil)
    },
    test("a type's say moves no revision and tells no type changed; the sync asks nothing of it") {
        let model = ScriptedLanguageModel()
        let editor = try typeEditor(model: model)
        let types = try require(editor.types), fill = try require(editor.fieldFill)
        let feature = editor.addType(fillFeatureSchema, words: "a feature: its purpose, status and estimate", title: "Feature")
        let revision = types.revision(of: feature)
        let told = Counter()
        types.onChange { change in if !change.types.isEmpty { told.count += 1 } }
        fill.setAutofill(false, of: feature)
        editor.transact("Change JSON") { $0.update(feature) { $0[TypeSchemaProperty.self] = SchemaText(fillFeatureSchema) } }
        expectEqual(types.revision(of: feature), revision)
        expectEqual(told.count, 0)
        try require(editor.typeSync).commit(feature)
        for _ in 0..<10 { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.002)) }
        expectEqual(model.requests.count, 0, "in step: the words say nothing of it")
    },
    test("a shape takes its say from its own, else the first of its chain's types, else on; the box keeps its own only where it differs") {
        let editor = try typeEditor()
        let fill = try require(editor.fieldFill)
        let vehicle = editor.addType(TypeSchemaProperty.starter, title: "Vehicle")
        let car = editor.addType(TypeSchemaProperty.starter, title: "Car", at: CGPoint(x: 40, y: 300))
        editor.addTypeLink(vehicle, to: car)
        let myCar = editor.addInstance(of: [car])
        expectEqual(editor.autofills(myCar), true, "none says")
        fill.setAutofill(false, of: vehicle)
        expectEqual(editor.autofills(myCar), false, "a type it is through Car says")
        expectEqual(editor.autofills(car), false, "and a type built on it")
        fill.setAutofill(true, of: car)
        expectEqual(editor.autofill(car), true, "Car says otherwise than what it builds on, so it holds it")
        expectEqual(editor.autofills(myCar), true, "the first of its chain")
        fill.setAutofill(false, of: myCar)
        expectEqual(editor.autofill(myCar), false)
        fill.setAutofill(true, of: myCar)
        expectEqual(editor.autofill(myCar), nil, "on, as its types say: it holds nothing, and follows them")
    },
])

extension TypePanelWindow {
    /// The section called Advanced in the selected shape's tab, opened, as a click on its header opens it.
    func openAdvanced(in tab: DetailTabID) throws {
        let id = try require(editor.selection)
        let state = try require(editor.detailPanel)
        let advanced = try require(state.layout(for: try require(editor.document[id])).sections(in: tab).first { $0.section.hasSuffix("autofill") })
        state.setCollapsed(advanced, false)
        window.settle()
    }
}

@MainActor let autofillPanelTests = Suite("The box that says whether a shape fills", [
    test("at the foot of a shape of a type's Types tab while its types give fields, and of a type's Schema tab; never a type's Types tab") {
        let editor = try typeEditor()
        let feature = editor.addType(fillFeatureSchema, title: "Feature")
        let empty = editor.addType(TypeSchemaProperty.starter, title: "Empty", at: CGPoint(x: 600, y: 40))
        let note = editor.addInstance(of: [feature]), bare = editor.addInstance(of: [empty], at: CGPoint(x: 40, y: 600))
        @MainActor func sections(_ id: ShapeID, _ tab: DetailTabID) throws -> [String] {
            try require(editor.detailPanel?.layout(for: try require(editor.document[id]))).sections(in: tab).map(\.section)
        }
        expectEqual(try sections(note, .of(TypesTab.self)).last, "autofill")
        expect(try !sections(bare, .of(TypesTab.self)).contains("autofill"), "no fields, nothing to fill")
        expectEqual(try sections(feature, .of(TypeSchemaTab.self)).last, "type-autofill")
        editor.addTypeLink(empty, to: feature)
        expect(try !sections(feature, .of(TypesTab.self)).contains("autofill"), "a type's own note fills nothing")
    },
    test("it is folded away, in Advanced, until opened, for every shape it reaches; then it stays open") {
        let editor = try typeEditor()
        let feature = editor.addType(fillFeatureSchema, title: "Feature")
        let ann = editor.addInstance(of: [feature]), bo = editor.addInstance(of: [feature], at: CGPoint(x: 40, y: 600))
        let state = try require(editor.detailPanel)
        @MainActor func advanced(_ id: ShapeID, _ tab: DetailTabID) throws -> DetailSectionKey {
            try require(state.layout(for: try require(editor.document[id])).sections(in: tab).first { $0.section.hasSuffix("autofill") })
        }
        expect(state.isCollapsed(try advanced(ann, .of(TypesTab.self))))
        expect(state.isCollapsed(try advanced(feature, .of(TypeSchemaTab.self))), "a type's too")
        state.setCollapsed(try advanced(ann, .of(TypesTab.self)), false)
        expect(!state.isCollapsed(try advanced(bo, .of(TypesTab.self))), "opened, for every note")
        expect(state.isCollapsed(try advanced(feature, .of(TypeSchemaTab.self))), "a type's is a section of its own")
    },
    // A checkbox's click is not driven in an unshown window: what it calls, `setAutofill`, is held by the tests above.
    test("the box shows what holds, follows its type's say with no commit to the shape, and its own say over it; a read-only shape's is off") {
        let panel = try TypePanelWindow(more: [FreezingPlugin()])
        let feature = panel.editor.addType(#"{"type": "object", "properties": {"purpose": {"type": "string"}}}"#, title: "Feature", at: CGPoint(x: 700, y: 40))
        let note = panel.select(instanceRecord("purpose is to sort the mail", of: [feature]))
        panel.window.settle()
        expectEqual(panel.checkboxes.count, 0, "folded away")
        try panel.openAdvanced(in: .of(TypesTab.self))
        panel.window.spin { panel.checkboxes.count == 1 }
        expectEqual(panel.checkboxes.first?.state, .on)
        let fill = try require(panel.editor.fieldFill)
        fill.setAutofill(false, of: feature)
        panel.window.spin { panel.checkboxes.first?.state == .off }
        fill.setAutofill(true, of: note)
        panel.window.spin { panel.checkboxes.first?.state == .on }
        expectEqual(panel.editor.document[note]?[AutofillProperty.self], true)
        panel.editor.freeze([note])
        panel.window.spin { panel.checkboxes.first?.isEnabled == false }
    },
    test("a fill under way is said at the foot of the Fields, with Advanced still folded; a failure there with its Retry") {
        let panel = try TypePanelWindow()
        let feature = panel.editor.addType(#"{"type": "object", "properties": {"purpose": {"type": "string"}}}"#, title: "Feature", at: CGPoint(x: 700, y: 40))
        let note = panel.select(instanceRecord("purpose is to sort the mail", of: [feature]))
        let fill = try require(panel.editor.fieldFill)
        panel.model.holdsAnswers = true
        panel.model.queue(.overloaded)
        fill.editingDidEnd(note, in: panel.editor)
        spinRunLoop(until: { panel.model.waiting == 1 })
        panel.window.spin { panel.spinners.count == 1 }
        expectEqual(panel.checkboxes.count, 0, "the box stays folded away")
        let buttons = panel.buttons.count
        panel.model.release()
        panel.window.spin { panel.spinners.isEmpty && panel.buttons.count == buttons + 1 }
        expectEqual(fill.status(of: note), .failed(FieldFillFailure(LanguageModelError.overloaded.message)))
    },
])
